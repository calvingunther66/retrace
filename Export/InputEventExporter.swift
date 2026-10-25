import CoreGraphics
import Database
import Foundation
import Shared
import Storage

// MARK: - Image source

/// Where exported pixels come from. A seam so tests do not need real HEVC chunks.
public protocol ExportFrameImageSource: Sendable {
    func image(for frame: InputExportFrameInfo) async throws -> CGImage
}

public enum InputExportError: Error, Equatable {
    case frameHasNoVideo(frameID: Int64)
}

/// Decodes frames from Retrace's HEVC chunks.
public struct HEVCFrameImageSource: ExportFrameImageSource {
    private let extractor: HEVCStorageExtractor

    /// - Parameter storageRoot: directory that contains `chunks/` (the app's storage root).
    public init(storageRoot: String) {
        self.extractor = HEVCStorageExtractor(storageRoot: storageRoot)
    }

    public func image(for frame: InputExportFrameInfo) async throws -> CGImage {
        guard let path = frame.videoPath, let index = frame.videoFrameIndex else {
            throw InputExportError.frameHasNoVideo(frameID: frame.frameID)
        }
        return try await extractor.extractFrameCGImage(videoPath: path, frameIndex: index, frameRate: frame.videoFrameRate)
    }
}

// MARK: - Options / summary

public struct InputExportOptions: Sendable {
    public var sinceMs: Int64
    public var untilMs: Int64
    public var kinds: [InputEventKind]?
    public var maxSide = 1280
    public var quality = 0.8
    public var format: FrameImageFormat = .jpeg
    public var outDirectory: URL
    public var denyList: ExportDenyList
    /// Export events whose privacy checks could not be completed (`privacyState != ok`).
    public var includeUnverified = false
    /// The pre frame must be at most this stale (ms) relative to the action. 0 disables the check.
    public var maxPreGapMs: Int64 = 5_000
    /// Require the frame's display to equal the event's display.
    public var requireDisplayMatch = true
    public var includeDownFrames = true
    /// Keep the URL's query string and fragment. Off by default: they routinely carry session
    /// tokens, signatures and one-time codes (`?token=...`, `&sig=...`).
    public var keepURLQuery = false
    public var limit: Int?

    public init(sinceMs: Int64, untilMs: Int64, outDirectory: URL, denyList: ExportDenyList) {
        self.sinceMs = sinceMs
        self.untilMs = untilMs
        self.outDirectory = outDirectory
        self.denyList = denyList
    }
}

public enum ExportSkipReason: String, Sendable, CaseIterable {
    case linkPending = "link_pending"
    case privacyUnverified = "privacy_unverified"
    case eventRedacted = "event_redacted"
    case secureField = "secure_field"
    case preMissing = "pre_frame_missing"
    case preStale = "pre_frame_stale"
    case frameMissing = "frame_missing"
    case frameRedacted = "frame_redacted"
    case frameNotReady = "frame_not_ready"
    case frameDeleted = "frame_deleted"
    case frameRewritePending = "frame_rewrite_pending"
    case videoUnfinalized = "video_unfinalized"
    case displayUnknown = "display_unknown"
    case displayMismatch = "display_mismatch"
    case denyBundle = "deny_bundle"
    case denyURL = "deny_url"
    case denyWindow = "deny_window"
    case denyHidden = "deny_hidden"
    case imageUnavailable = "image_unavailable"
}

public struct InputExportSummary: Sendable, Equatable, Codable {
    public var eventsSeen = 0
    public var eventsExported = 0
    public var framesWritten = 0
    /// Why events were not exported.
    public var skippedEvents: [String: Int] = [:]
    /// Optional (down/post) frames left out of an otherwise exported event, by reason.
    public var omittedFrames: [String: Int] = [:]

    public init() {}
}

// MARK: - Gates

enum ExportGate {
    /// Whether a frame's pixels may be exported at all (independent of any event).
    static func check(_ info: InputExportFrameInfo?) -> ExportSkipReason? {
        guard let info else { return .frameMissing }
        if info.redactionReason != nil { return .frameRedacted }
        // 2 = OCR/redaction pass done, 7 = pixel rewrite done. Anything else may still hold raw pixels.
        guard let status = info.processingStatus, status == 2 || status == 7 else { return .frameNotReady }
        if info.encodedAtMs == nil { return .frameNotReady }
        if info.rewritePurpose == "deletion" { return .frameDeleted }
        if info.rewritePurpose == "redaction", info.rewrittenAtMs == nil { return .frameRewritePending }
        if info.videoPath == nil || info.videoFrameIndex == nil { return .frameNotReady }
        if info.videoProcessingState != 0 { return .videoUnfinalized }
        return nil
    }

    static func denyReason(_ list: ExportDenyList, event: InputEvent, frame: InputExportFrameInfo) -> ExportSkipReason? {
        guard let violation = list.violation(
            bundleIDs: [event.bundleID, frame.bundleID],
            urls: [frame.browserURL],
            windowTitles: [event.windowTitle, frame.windowName],
            isHidden: frame.isHidden
        ) else { return nil }
        switch violation {
        case .bundle: return .denyBundle
        case .url: return .denyURL
        case .window: return .denyWindow
        case .hidden: return .denyHidden
        }
    }
}

// MARK: - Exporter

/// Writes privacy-filtered input events and the frames around them:
/// `<out>/events.jsonl`, `<out>/frames/<frameId>.<ext>`, `<out>/manifest.json`.
///
/// Nothing is written for a frame unless it passes `ExportGate`, and nothing for an event unless
/// its own privacy state, secure-field state and the deny-list allow it. The Keychain master key is
/// never loaded: scrambled regions stay scrambled.
public final class InputEventExporter: @unchecked Sendable {
    private let database: DatabaseManager
    private let imageSource: any ExportFrameImageSource
    private let options: InputExportOptions

    public init(database: DatabaseManager, imageSource: any ExportFrameImageSource, options: InputExportOptions) {
        self.database = database
        self.imageSource = imageSource
        self.options = options
    }

    struct WrittenFrame {
        let relativePath: String
        let width: Int
        let height: Int
    }

    public func run() async throws -> InputExportSummary {
        let fileManager = FileManager.default
        let framesDirectory = options.outDirectory.appendingPathComponent("frames", isDirectory: true)
        try fileManager.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        let eventsURL = options.outDirectory.appendingPathComponent("events.jsonl")
        fileManager.createFile(atPath: eventsURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: eventsURL)
        defer { try? handle.close() }

        var summary = InputExportSummary()
        var written: [Int64: WrittenFrame] = [:]
        var afterID: Int64 = 0

        pages: while true {
            let events = try await database.getInputEvents(
                sinceMs: options.sinceMs,
                untilMs: options.untilMs,
                kinds: options.kinds,
                afterID: afterID,
                limit: 500
            )
            guard !events.isEmpty else { break }
            afterID = events.last?.id ?? afterID

            var frameIDs = Set<Int64>()
            for event in events {
                [event.preFrameID, event.downFrameID, event.postFrameID].compactMap { $0 }.forEach { frameIDs.insert($0) }
            }
            let infos = try await database.getInputExportFrameInfo(frameIDs: Array(frameIDs))

            for event in events {
                if let limit = options.limit, summary.eventsExported >= limit { break pages }
                summary.eventsSeen += 1

                if let reason = eventGate(event, infos: infos) {
                    summary.skippedEvents[reason.rawValue, default: 0] += 1
                    continue
                }
                guard let preID = event.preFrameID, let preInfo = infos[preID] else { continue }

                // Optional frames: usable only if they pass the same gates and deny-list.
                func optional(_ id: Int64?) -> InputExportFrameInfo? {
                    guard let id else { return nil }
                    let info = infos[id]
                    if let reason = ExportGate.check(info) ?? info.flatMap({ ExportGate.denyReason(options.denyList, event: event, frame: $0) }) {
                        summary.omittedFrames[reason.rawValue, default: 0] += 1
                        return nil
                    }
                    if options.requireDisplayMatch, let display = event.displayID, info?.displayID != display {
                        summary.omittedFrames[ExportSkipReason.displayMismatch.rawValue, default: 0] += 1
                        return nil
                    }
                    return info
                }

                guard let preImage = await ensureWritten(preInfo, into: &written, framesDirectory: framesDirectory, summary: &summary) else {
                    summary.skippedEvents[ExportSkipReason.imageUnavailable.rawValue, default: 0] += 1
                    continue
                }
                var downImage: WrittenFrame?
                if options.includeDownFrames, let info = optional(event.downFrameID) {
                    downImage = await ensureWritten(info, into: &written, framesDirectory: framesDirectory, summary: &summary)
                }
                var postImage: WrittenFrame?
                if let info = optional(event.postFrameID) {
                    postImage = await ensureWritten(info, into: &written, framesDirectory: framesDirectory, summary: &summary)
                }

                let elements = event.kind == .click
                    ? ((try? await database.getInputEventAXElements(eventID: event.id ?? 0)) ?? [])
                    : []
                let line = Self.jsonLine(
                    event: event,
                    appBundleID: event.bundleID ?? preInfo.bundleID,
                    url: Self.exportedURL(preInfo.browserURL, keepQuery: options.keepURLQuery),
                    pre: preImage,
                    down: downImage.flatMap { _ in event.downFrameID },
                    downPath: downImage?.relativePath,
                    post: postImage.flatMap { _ in event.postFrameID },
                    postPath: postImage?.relativePath,
                    axElements: elements
                )
                try handle.write(contentsOf: line)
                summary.eventsExported += 1
            }
        }

        try writeManifest(summary)
        return summary
    }

    // MARK: Gating

    private func eventGate(_ event: InputEvent, infos: [Int64: InputExportFrameInfo]) -> ExportSkipReason? {
        if event.linkState == .pending { return .linkPending }
        if event.privacyState != InputEvent.privacyOK, !options.includeUnverified { return .privacyUnverified }
        if event.redacted { return .eventRedacted }
        if event.axTarget?.isSecureTextField ?? false { return .secureField }
        guard let preID = event.preFrameID else { return .preMissing }

        let pre = infos[preID]
        if let reason = ExportGate.check(pre) { return reason }
        guard let pre else { return .frameMissing }

        if options.maxPreGapMs > 0 {
            guard let gap = event.preGapMs, gap <= options.maxPreGapMs else { return .preStale }
        }
        if options.requireDisplayMatch {
            guard let eventDisplay = event.displayID, let frameDisplay = pre.displayID else { return .displayUnknown }
            if eventDisplay != frameDisplay { return .displayMismatch }
        }
        return ExportGate.denyReason(options.denyList, event: event, frame: pre)
    }

    // MARK: Images

    private func ensureWritten(
        _ info: InputExportFrameInfo,
        into written: inout [Int64: WrittenFrame],
        framesDirectory: URL,
        summary: inout InputExportSummary
    ) async -> WrittenFrame? {
        if let existing = written[info.frameID] { return existing }
        do {
            let image = try await imageSource.image(for: info)
            let encoded = try FrameImageEncoder.encode(
                image, maxSide: options.maxSide, format: options.format, quality: options.quality
            )
            let name = "\(info.frameID).\(options.format.fileExtension)"
            try encoded.data.write(to: framesDirectory.appendingPathComponent(name), options: .atomic)
            let frame = WrittenFrame(relativePath: "frames/\(name)", width: encoded.width, height: encoded.height)
            written[info.frameID] = frame
            summary.framesWritten += 1
            return frame
        } catch {
            return nil
        }
    }

    // MARK: JSONL

    /// The URL without its query string and fragment unless `keepQuery`. Unparseable input is
    /// truncated at the first `?` or `#` rather than passed through.
    static func exportedURL(_ url: String?, keepQuery: Bool) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if keepQuery { return url }
        if let end = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(url[..<end])
        }
        return url
    }

    /// `[x1, y1, x2, y2]` in points, matching the element-list format training code expects.
    static func corners(x: Double, y: Double, width: Double, height: Double) -> [Double] {
        [x, y, x + width, y + height]
    }

    static func jsonLine(
        event: InputEvent,
        appBundleID: String?,
        url: String?,
        pre: WrittenFrame,
        down: Int64?,
        downPath: String?,
        post: Int64?,
        postPath: String?,
        axElements: [InputAXElement]
    ) -> Data {
        var object: [String: Any] = [
            "t": event.tsMs,
            "type": event.kind.rawValue,
            "mods": event.modifiers,
            "app": appBundleID as Any? ?? NSNull(),
            "url": url as Any? ?? NSNull(),
            "pre_frame_id": event.preFrameID as Any? ?? NSNull(),
            "down_frame_id": down as Any? ?? NSNull(),
            "post_frame_id": post as Any? ?? NSNull(),
            "pre_gap_ms": event.preGapMs as Any? ?? NSNull(),
            "privacy": event.privacyState
        ]
        var frames: [String: Any] = ["pre": pre.relativePath]
        if let downPath { frames["down"] = downPath }
        if let postPath { frames["post"] = postPath }
        object["frames"] = frames

        if let end = event.endTsMs { object["end_t"] = end }
        if let button = event.button { object["button"] = button }
        if let count = event.clickCount { object["count"] = count }
        if let x = event.x, let y = event.y { object["x"] = x; object["y"] = y }
        if let key = event.keyCombo { object["key"] = key }
        if let typed = event.typedCount { object["typed"] = typed }
        if event.scrollDx != nil || event.scrollDy != nil {
            object["scroll"] = ["dx": event.scrollDx ?? 0, "dy": event.scrollDy ?? 0]
        }

        if let id = event.displayID {
            object["display"] = [
                "id": id,
                "w": event.displayPixelWidth as Any? ?? NSNull(),
                "h": event.displayPixelHeight as Any? ?? NSNull(),
                "scale": event.displayScale as Any? ?? NSNull()
            ]
        }
        if !event.displays.isEmpty {
            object["displays"] = event.displays.map {
                ["id": $0.id, "x": $0.x, "y": $0.y, "w": $0.width, "h": $0.height,
                 "pw": $0.pixelWidth, "ph": $0.pixelHeight, "scale": $0.scale] as [String: Any]
            }
        }
        if let wx = event.windowX, let wy = event.windowY, let ww = event.windowWidth, let wh = event.windowHeight {
            object["window"] = [
                "title": event.windowTitle as Any? ?? NSNull(),
                "box": corners(x: wx, y: wy, width: ww, height: wh)
            ] as [String: Any]
        }
        if let ax = event.axTarget {
            var axObject: [String: Any] = [
                "role": ax.role as Any? ?? NSNull(),
                "title": ax.title as Any? ?? NSNull(),
                "id": ax.identifier as Any? ?? NSNull()
            ]
            if let x = ax.x, let y = ax.y, let w = ax.width, let h = ax.height {
                axObject["box"] = corners(x: x, y: y, width: w, height: h)
            }
            object["ax"] = axObject
        }
        if !axElements.isEmpty {
            object["ax_elements"] = axElements.map { element -> [String: Any] in
                var item: [String: Any] = ["role": element.role, "name": element.name as Any? ?? NSNull()]
                if element.box.count == 4 {
                    item["box"] = corners(x: element.box[0], y: element.box[1], width: element.box[2], height: element.box[3])
                }
                return item
            }
        }

        // Where the action lands in the exported image: points relative to the display, scaled so the
        // display's width spans the image. Valid because capture covers the full display.
        if let x = event.x, let y = event.y,
           let displayID = event.displayID,
           let display = event.displays.first(where: { $0.id == displayID }), display.width > 0 {
            // Display pixels (points x backing scale), relative to the display's origin, for consumers
            // that want native pixels rather than the points `x`/`y` carry.
            object["px"] = (x - display.x) * display.scale
            object["py"] = (y - display.y) * display.scale
            let scale = Double(pre.width) / display.width
            object["img"] = [
                "w": pre.width, "h": pre.height,
                "x": (x - display.x) * scale, "y": (y - display.y) * scale,
                "scale": scale
            ] as [String: Any]
        }

        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return data + Data("\n".utf8)
    }

    // MARK: Manifest

    private func writeManifest(_ summary: InputExportSummary) throws {
        struct Manifest: Encodable {
            let generatedAt: String
            let sinceMs: Int64
            let untilMs: Int64
            let kinds: [String]?
            let maxSide: Int
            let format: String
            let denyList: [String: Int]
            let includeUnverified: Bool
            let keepURLQuery: Bool
            let maxPreGapMs: Int64
            let summary: InputExportSummary
        }
        let list = options.denyList
        let manifest = Manifest(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            sinceMs: options.sinceMs,
            untilMs: options.untilMs,
            kinds: options.kinds?.map(\.rawValue),
            maxSide: options.maxSide,
            format: options.format.rawValue,
            denyList: [
                "bundles": list.excludeBundles.count,
                "urlPatterns": list.excludeURLPatterns.count,
                "windowPatterns": list.excludeWindowPatterns.count,
                "hidden": list.excludeHiddenSegments ? 1 : 0
            ],
            includeUnverified: options.includeUnverified,
            keepURLQuery: options.keepURLQuery,
            maxPreGapMs: options.maxPreGapMs,
            summary: summary
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: options.outDirectory.appendingPathComponent("manifest.json"))
    }
}
