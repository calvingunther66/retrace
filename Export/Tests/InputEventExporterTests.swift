import XCTest
import CoreGraphics
import SQLite3
import Database
import Shared
import Storage
@testable import Export

/// The exporter against a real in-memory database. Every gate asserts the same two things: the
/// event is skipped for the right reason, and *no pixels were written* for it.
final class InputEventExporterTests: XCTestCase {

    private let base: Int64 = 1_700_000_000_000

    private struct SolidImageSource: ExportFrameImageSource {
        var failing = false
        func image(for frame: InputExportFrameInfo) async throws -> CGImage {
            if failing { throw InputExportError.frameHasNoVideo(frameID: frame.frameID) }
            let context = CGContext(
                data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2560, height: 1600))
            return context.makeImage()!
        }
    }

    private var outDirectory: URL!
    private var database: DatabaseManager!
    private var connection: OpaquePointer!
    private var segmentID: Int64 = 0
    private var videoID: Int64 = 0

    override func setUp() async throws {
        outDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportTests_\(UUID().uuidString)", isDirectory: true)
        database = DatabaseManager(databasePath: "file:export_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()
        connection = await database.getConnection()
        segmentID = try await insertSegment(bundleID: "com.example.app", window: "Doc", url: nil)
        try exec("INSERT INTO video (height, width, path, frameRate, processingState) VALUES (1600, 2560, 'chunks/x', 0.5, 0);")
        videoID = sqlite3_last_insert_rowid(connection)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: outDirectory)
    }

    // MARK: Happy path

    func testExportsEventWithFramesAndTrainingFields() async throws {
        let (pre, down, post) = try await seedClick()

        let summary = try await runExport()

        XCTAssertEqual(summary.eventsExported, 1)
        XCTAssertEqual(summary.framesWritten, 3)
        let lines = try readLines()
        XCTAssertEqual(lines.count, 1)
        let line = lines[0]

        XCTAssertEqual(line["t"] as? Int64, base)
        XCTAssertEqual(line["type"] as? String, "click")
        XCTAssertEqual(line["button"] as? String, "left")
        XCTAssertEqual(line["count"] as? Int, 1)
        XCTAssertEqual(line["app"] as? String, "com.example.app")
        XCTAssertEqual(line["pre_frame_id"] as? Int64, pre)
        XCTAssertEqual(line["down_frame_id"] as? Int64, down)
        XCTAssertEqual(line["post_frame_id"] as? Int64, post)

        let display = try XCTUnwrap(line["display"] as? [String: Any])
        XCTAssertEqual(display["w"] as? Int, 3024)
        XCTAssertEqual(display["h"] as? Int, 1964)
        XCTAssertEqual(display["scale"] as? Double, 2)

        // Boxes are [x1, y1, x2, y2] in points, like the element lists training code consumes.
        let window = try XCTUnwrap(line["window"] as? [String: Any])
        XCTAssertEqual(window["box"] as? [Double], [0, 25, 1512, 982])
        let ax = try XCTUnwrap(line["ax"] as? [String: Any])
        XCTAssertEqual(ax["box"] as? [Double], [1398, 76, 1428, 100])
        XCTAssertEqual(ax["id"] as? String, "share-btn")
        let elements = try XCTUnwrap(line["ax_elements"] as? [[String: Any]])
        XCTAssertEqual(elements.first?["box"] as? [Double], [1398, 76, 1428, 100])

        // Click (1412, 88) pt on a 1512 pt wide display -> exported 1280 px wide image.
        let img = try XCTUnwrap(line["img"] as? [String: Any])
        XCTAssertEqual(img["w"] as? Int, 1280)
        XCTAssertEqual(img["h"] as? Int, 800)
        XCTAssertEqual(line["px"] as? Double, 2824, "1412 pt x 2 (backing scale) = display pixels")
        XCTAssertEqual(line["py"] as? Double, 176)
        let scale = 1280.0 / 1512.0
        XCTAssertEqual(try XCTUnwrap(img["x"] as? Double), 1412 * scale, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(img["y"] as? Double), 88 * scale, accuracy: 0.01)

        for id in [pre, down, post] {
            let url = outDirectory.appendingPathComponent("frames/\(id).jpg")
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDirectory.appendingPathComponent("manifest.json").path))
    }

    // MARK: Gates: skipped events leave no pixels behind

    func testRedactedPreFrameIsSkippedAndNothingIsWritten() async throws {
        let ids = try await seedClick()
        try exec("UPDATE frame SET redactionReason = 'Excluded app: FaceTime' WHERE id = \(ids.pre);")
        try await assertSkipped(.frameRedacted)
    }

    func testFramesThatHaveNotCompletedProcessingAreNotExported() async throws {
        let ids = try await seedClick()
        try exec("UPDATE frame SET processingStatus = 0 WHERE id = \(ids.pre);")
        try await assertSkipped(.frameNotReady)
    }

    func testFramesAwaitingPixelRedactionRewriteAreNotExported() async throws {
        let ids = try await seedClick()
        try exec("UPDATE frame SET processingStatus = 5, rewritePurpose = 'redaction' WHERE id = \(ids.pre);")
        try await assertSkipped(.frameNotReady)
        // Even if the status were wrong, an unfinished redaction rewrite blocks export.
        try exec("UPDATE frame SET processingStatus = 2 WHERE id = \(ids.pre);")
        try await assertSkipped(.frameRewritePending)
    }

    func testCompletedRewritesAreExported() async throws {
        let ids = try await seedClick()
        try exec("UPDATE frame SET processingStatus = 7, rewritePurpose = 'redaction', rewrittenAt = 1 WHERE id = \(ids.pre);")
        let summary = try await runExport()
        XCTAssertEqual(summary.eventsExported, 1)
    }

    func testFramesInUnfinalizedVideosAreNotExported() async throws {
        _ = try await seedClick()
        try exec("UPDATE video SET processingState = 1;")
        try await assertSkipped(.videoUnfinalized)
    }

    func testDeletionRewriteFramesAreNotExported() async throws {
        let ids = try await seedClick()
        try exec("UPDATE frame SET rewritePurpose = 'deletion' WHERE id = \(ids.pre);")
        // The resolver never links deletion frames, so re-point the link to prove the export gate.
        try exec("UPDATE input_event SET preFrameId = \(ids.pre);")
        try await assertSkipped(.frameDeleted)
    }

    func testStalePreFrameIsSkipped() async throws {
        let ids = try await seedClick()
        try exec("UPDATE input_event SET preGapMs = 9000 WHERE preFrameId = \(ids.pre);")
        try await assertSkipped(.preStale)
    }

    func testDisplayMismatchAndUnknownDisplayAreSkipped() async throws {
        let ids = try await seedClick()
        try exec("UPDATE frame SET displayId = 99 WHERE id = \(ids.pre);")
        try await assertSkipped(.displayMismatch)
        try exec("UPDATE frame SET displayId = NULL WHERE id = \(ids.pre);")
        try await assertSkipped(.displayUnknown)
    }

    func testDenyListedBundleURLWindowAndHiddenSegmentsAreSkipped() async throws {
        _ = try await seedClick()
        try await assertSkipped(.denyBundle, deny: ExportDenyList(excludeBundles: ["com.example.app"]))
        try await assertSkipped(.denyWindow, deny: ExportDenyList(excludeWindowPatterns: ["doc"]))

        try exec("UPDATE segment SET browserUrl = 'https://secure.chase.com/accounts' WHERE id = \(segmentID);")
        try await assertSkipped(.denyURL, deny: ExportDenyList(excludeURLPatterns: ["chase.com"]))

        try exec("INSERT INTO segment_tag (segmentId, tagId) SELECT \(segmentID), id FROM tag WHERE name = 'hidden';")
        try await assertSkipped(.denyHidden, deny: ExportDenyList(excludeHiddenSegments: true))
    }

    func testUnverifiedEventsAreSkippedUnlessOptedIn() async throws {
        _ = try await seedClick(privacyState: InputEvent.privacyAXUnavailable)
        try await assertSkipped(.privacyUnverified)

        let summary = try await runExport(includeUnverified: true)
        XCTAssertEqual(summary.eventsExported, 1)
        XCTAssertEqual(try readLines().first?["privacy"] as? String, "ax_unavailable")
    }

    func testRedactedAndPendingEventsAreSkipped() async throws {
        _ = try await seedClick()
        try exec("UPDATE input_event SET redacted = 1;")
        try await assertSkipped(.eventRedacted)
        try exec("UPDATE input_event SET redacted = 0, linkState = 0;")
        try await assertSkipped(.linkPending)
    }

    func testSecureFieldEventsInTheDatabaseAreStillSkipped() async throws {
        _ = try await seedClick()
        // Bypass the insert-time refusal to prove export is a second line of defence.
        try exec("UPDATE input_event SET axRole = 'AXTextField', axSubrole = 'AXSecureTextField';")
        try await assertSkipped(.secureField)
    }

    func testImageFailureSkipsTheEventWithoutWritingAnything() async throws {
        _ = try await seedClick()
        let summary = try await runExport(imageSource: SolidImageSource(failing: true))
        XCTAssertEqual(summary.skippedEvents["image_unavailable"], 1)
        XCTAssertEqual(summary.eventsExported, 0)
        XCTAssertEqual(try readLines().count, 0)
    }

    // MARK: Optional frames are gated independently

    func testPostFrameOnADeniedSiteIsOmittedButTheEventIsKept() async throws {
        let ids = try await seedClick()
        // After the click the user landed on a banking page: that segment is deny-listed.
        let bankSegment = try await insertSegment(bundleID: "com.example.app", window: "Doc", url: "https://secure.chase.com/")
        try exec("UPDATE frame SET segmentId = \(bankSegment) WHERE id = \(ids.post);")

        let summary = try await runExport(deny: ExportDenyList(excludeURLPatterns: ["chase.com"]))

        XCTAssertEqual(summary.eventsExported, 1)
        XCTAssertEqual(summary.omittedFrames["deny_url"], 1)
        let line = try XCTUnwrap(readLines().first)
        XCTAssertTrue(line["post_frame_id"] is NSNull)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDirectory.appendingPathComponent("frames/\(ids.post).jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outDirectory.appendingPathComponent("frames/\(ids.pre).jpg").path))
    }

    func testRedactedPostFrameIsOmitted() async throws {
        let ids = try await seedClick()
        try exec("UPDATE frame SET redactionReason = 'Private/incognito browsing window' WHERE id = \(ids.post);")
        let summary = try await runExport()
        XCTAssertEqual(summary.eventsExported, 1)
        XCTAssertEqual(summary.omittedFrames["frame_redacted"], 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDirectory.appendingPathComponent("frames/\(ids.post).jpg").path))
    }

    func testURLQueryStringsAndFragmentsAreStrippedByDefault() async throws {
        _ = try await seedClick()
        try exec("UPDATE segment SET browserUrl = 'https://app.example.com/oauth/callback?code=SECRET&state=abc#access_token=TOK' WHERE id = \(segmentID);")

        _ = try await runExport()
        let stripped = try XCTUnwrap(readLines().first)
        XCTAssertEqual(stripped["url"] as? String, "https://app.example.com/oauth/callback")
        let raw = try String(contentsOf: outDirectory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        XCTAssertFalse(raw.contains("SECRET"))
        XCTAssertFalse(raw.contains("access_token"))

        try? FileManager.default.removeItem(at: outDirectory)
        var options = InputExportOptions(
            sinceMs: base - 10_000, untilMs: base + 10_000_000, outDirectory: outDirectory,
            denyList: ExportDenyList(excludeHiddenSegments: false)
        )
        options.keepURLQuery = true
        _ = try await InputEventExporter(database: database, imageSource: SolidImageSource(), options: options).run()
        XCTAssertEqual(
            try readLines().first?["url"] as? String,
            "https://app.example.com/oauth/callback?code=SECRET&state=abc#access_token=TOK"
        )
    }

    func testExportedURLHelper() {
        XCTAssertNil(InputEventExporter.exportedURL(nil, keepQuery: false))
        XCTAssertNil(InputEventExporter.exportedURL("", keepQuery: false))
        XCTAssertEqual(InputEventExporter.exportedURL("https://a.com/x#frag", keepQuery: false), "https://a.com/x")
        XCTAssertEqual(InputEventExporter.exportedURL("not a url ?token=1", keepQuery: false), "not a url ")
        XCTAssertEqual(InputEventExporter.exportedURL("https://a.com/p", keepQuery: false), "https://a.com/p")
    }

    func testEventsOutsideTheTimeRangeOrKindAreNotExported() async throws {
        _ = try await seedClick()
        let after = try await runExport(since: base + 1_000)
        XCTAssertEqual(after.eventsSeen, 0)
        let scrolls = try await runExport(kinds: [.scroll])
        XCTAssertEqual(scrolls.eventsSeen, 0)
    }

    // MARK: Helpers

    private func assertSkipped(
        _ reason: ExportSkipReason,
        deny: ExportDenyList = ExportDenyList(excludeHiddenSegments: false),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try? FileManager.default.removeItem(at: outDirectory)
        let summary = try await runExport(deny: deny)
        XCTAssertEqual(summary.eventsExported, 0, "event must not be exported", file: file, line: line)
        XCTAssertEqual(summary.skippedEvents[reason.rawValue], 1, "\(summary.skippedEvents)", file: file, line: line)
        XCTAssertEqual(summary.framesWritten, 0, file: file, line: line)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: outDirectory.appendingPathComponent("frames").path)) ?? []
        XCTAssertEqual(written, [], "no pixels may be written for a skipped event", file: file, line: line)
        XCTAssertEqual(try readLines().count, 0, file: file, line: line)
    }

    private func runExport(
        since: Int64? = nil,
        kinds: [InputEventKind]? = nil,
        deny: ExportDenyList = ExportDenyList(excludeHiddenSegments: false),
        includeUnverified: Bool = false,
        imageSource: SolidImageSource = SolidImageSource()
    ) async throws -> InputExportSummary {
        var options = InputExportOptions(
            sinceMs: since ?? base - 10_000, untilMs: base + 10_000_000,
            outDirectory: outDirectory, denyList: deny
        )
        options.kinds = kinds
        options.includeUnverified = includeUnverified
        return try await InputEventExporter(database: database, imageSource: imageSource, options: options).run()
    }

    private func readLines() throws -> [[String: Any]] {
        let url = outDirectory.appendingPathComponent("events.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    /// One click with a pre frame (before), the forced down frame, and a settled post frame.
    @discardableResult
    private func seedClick(privacyState: String = InputEvent.privacyOK) async throws -> (pre: Int64, down: Int64, post: Int64) {
        let pre = try insertFrame(createdAt: base - 300)
        let down = try insertFrame(createdAt: base + 60)
        let post = try insertFrame(createdAt: base + 400)

        let display = InputDisplayGeometry(
            id: 1, x: 0, y: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, scale: 2
        )
        let event = InputEvent(
            tsMs: base, endTsMs: base + 80, kind: .click, button: "left", clickCount: 1,
            x: 1412, y: 88,
            displayID: 1, displayPixelWidth: 3024, displayPixelHeight: 1964, displayScale: 2,
            displays: [display],
            bundleID: "com.example.app", windowTitle: "Doc",
            windowX: 0, windowY: 25, windowWidth: 1512, windowHeight: 957,
            axTarget: InputAXTarget(
                role: "AXButton", title: "Share", identifier: "share-btn",
                x: 1398, y: 76, width: 30, height: 24
            ),
            axElements: [InputAXElement(role: "AXButton", name: "Share", box: [1398, 76, 30, 24])],
            downFrameTsMs: base + 60,
            privacyState: privacyState
        )
        _ = try await database.insertInputEvents([event])
        _ = try await database.resolveInputEventLinks(nowMs: base + 60_000)
        return (pre, down, post)
    }

    private func insertSegment(bundleID: String, window: String?, url: String?) async throws -> Int64 {
        try await database.insertSegment(
            bundleID: bundleID, startDate: Date(), endDate: Date(), windowName: window, browserUrl: url, type: 0
        )
    }

    private func insertFrame(createdAt: Int64) throws -> Int64 {
        try exec("""
            INSERT INTO frame (createdAt, imageFileName, segmentId, videoId, videoFrameIndex, isStarred,
                               processingStatus, encodedAt, displayId)
            VALUES (\(createdAt), 'f', \(segmentID), \(videoID), 0, 0, 2, \(createdAt + 10), 1);
            """)
        return sqlite3_last_insert_rowid(connection)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw NSError(domain: "ExportTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
