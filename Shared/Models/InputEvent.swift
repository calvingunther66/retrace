import Foundation

// MARK: - Input Events
//
// A user action (click, scroll, shortcut, typing burst) recorded alongside the frame stream so
// frames can be paired with what the user did next. Privacy contract: typed characters are never
// represented here. Typing is only a count; shortcuts are only a key combination.

/// What kind of user action an `InputEvent` describes.
public enum InputEventKind: String, Codable, Sendable, CaseIterable {
    case click
    case scroll
    case shortcut
    case typing
}

/// Progress of pairing an event with its surrounding frames.
public enum InputEventLinkState: Int, Codable, Sendable {
    /// Frames may not exist yet (insert lag, dedup); the resolver keeps trying.
    case pending = 0
    /// The post frame was found and the links are final.
    case resolved = 1
    /// No post frame appeared within the give-up window; whatever was found is kept.
    case gaveUp = 2
}

/// One display's placement and size at the moment of an event.
public struct InputDisplayGeometry: Codable, Sendable, Equatable {
    public let id: UInt32
    /// Global origin and size in points (top-left origin, matching `CGEvent.location`).
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    /// Native pixel size (e.g. 3024x1964 on a Retina laptop panel).
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Backing scale factor (pixels per point).
    public let scale: Double

    public init(
        id: UInt32,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
    }
}

/// The accessibility element under the pointer (click) or focused (typing) when the event began.
/// Boxes are in global points, top-left origin. Element *values* are never recorded.
public struct InputAXTarget: Codable, Sendable, Equatable {
    public let role: String?
    public let subrole: String?
    public let title: String?
    public let identifier: String?
    public let x: Double?
    public let y: Double?
    public let width: Double?
    public let height: Double?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Secure text fields must never produce an exported event.
    public var isSecureTextField: Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

/// One entry of the capped clickable-element snapshot taken at mouse-down.
public struct InputAXElement: Codable, Sendable, Equatable {
    public let role: String
    public let name: String?
    /// `[x, y, width, height]` in global points, top-left origin.
    public let box: [Double]

    public init(role: String, name: String?, box: [Double]) {
        self.role = role
        self.name = name
        self.box = box
    }
}

/// A single recorded user action.
public struct InputEvent: Codable, Sendable, Equatable, Identifiable {
    /// Database row id; `nil` until persisted.
    public var id: Int64?

    /// Decision time in epoch milliseconds: mouse-down, first key of a burst, or scroll start.
    /// Same clock and units as `frame.createdAt`.
    public var tsMs: Int64
    /// End of the action (mouse-up, last key, last scroll tick).
    public var endTsMs: Int64?
    public var kind: InputEventKind

    // Click
    /// `left`, `right` or `other`.
    public var button: String?
    public var clickCount: Int?
    /// Canonical order: cmd, ctrl, opt, shift.
    public var modifiers: [String]

    /// Pointer position in global points, top-left origin.
    public var x: Double?
    public var y: Double?

    // Scroll (summed point deltas over the burst)
    public var scrollDx: Double?
    public var scrollDy: Double?

    // Keyboard
    /// e.g. `cmd+shift+t`. Never a typed character sequence.
    public var keyCombo: String?
    /// Number of character keys in a typing burst. Content is never read.
    public var typedCount: Int?

    // Geometry
    public var displayID: UInt32?
    public var displayPixelWidth: Int?
    public var displayPixelHeight: Int?
    public var displayScale: Double?
    /// Full layout of all online displays at event time.
    public var displays: [InputDisplayGeometry]

    // App / window
    public var bundleID: String?
    public var windowTitle: String?
    public var windowX: Double?
    public var windowY: Double?
    public var windowWidth: Double?
    public var windowHeight: Double?

    // Accessibility
    public var axTarget: InputAXTarget?
    /// Capped snapshot of clickable elements; stored compressed in a side table.
    public var axElements: [InputAXElement]

    // Frame links (filled by the resolver)
    /// Strict last frame with `createdAt <= tsMs`: the screen before the action.
    public var preFrameID: Int64?
    /// `tsMs - preFrame.createdAt` in ms; large values mean the pre frame is stale.
    public var preGapMs: Int64?
    /// Timestamp of the forced mouse-down capture as reported by capture; nil if it was not kept.
    public var downFrameTsMs: Int64?
    /// Forced mouse-down capture. May already show pressed/open state.
    public var downFrameID: Int64?
    /// First frame after the action settled.
    public var postFrameID: Int64?

    public var linkState: InputEventLinkState
    /// `ok` when every privacy check completed; anything else is skipped by export by default.
    public var privacyState: String
    /// Set when a linked frame was redacted at capture time; window/AX detail is then removed.
    public var redacted: Bool

    public static let privacyOK = "ok"
    public static let privacyAXUnavailable = "ax_unavailable"

    public init(
        id: Int64? = nil,
        tsMs: Int64,
        endTsMs: Int64? = nil,
        kind: InputEventKind,
        button: String? = nil,
        clickCount: Int? = nil,
        modifiers: [String] = [],
        x: Double? = nil,
        y: Double? = nil,
        scrollDx: Double? = nil,
        scrollDy: Double? = nil,
        keyCombo: String? = nil,
        typedCount: Int? = nil,
        displayID: UInt32? = nil,
        displayPixelWidth: Int? = nil,
        displayPixelHeight: Int? = nil,
        displayScale: Double? = nil,
        displays: [InputDisplayGeometry] = [],
        bundleID: String? = nil,
        windowTitle: String? = nil,
        windowX: Double? = nil,
        windowY: Double? = nil,
        windowWidth: Double? = nil,
        windowHeight: Double? = nil,
        axTarget: InputAXTarget? = nil,
        axElements: [InputAXElement] = [],
        preFrameID: Int64? = nil,
        preGapMs: Int64? = nil,
        downFrameTsMs: Int64? = nil,
        downFrameID: Int64? = nil,
        postFrameID: Int64? = nil,
        linkState: InputEventLinkState = .pending,
        privacyState: String = InputEvent.privacyOK,
        redacted: Bool = false
    ) {
        self.id = id
        self.tsMs = tsMs
        self.endTsMs = endTsMs
        self.kind = kind
        self.button = button
        self.clickCount = clickCount
        self.modifiers = modifiers
        self.x = x
        self.y = y
        self.scrollDx = scrollDx
        self.scrollDy = scrollDy
        self.keyCombo = keyCombo
        self.typedCount = typedCount
        self.displayID = displayID
        self.displayPixelWidth = displayPixelWidth
        self.displayPixelHeight = displayPixelHeight
        self.displayScale = displayScale
        self.displays = displays
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowX = windowX
        self.windowY = windowY
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.axTarget = axTarget
        self.axElements = axElements
        self.preFrameID = preFrameID
        self.preGapMs = preGapMs
        self.downFrameTsMs = downFrameTsMs
        self.downFrameID = downFrameID
        self.postFrameID = postFrameID
        self.linkState = linkState
        self.privacyState = privacyState
        self.redacted = redacted
    }

    /// Milliseconds since epoch exactly as the database stores `frame.createdAt`.
    public static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}

/// Outcome counts from one link-resolution pass (feeds the `inputEventLinked` metric).
public struct InputEventLinkSummary: Sendable, Equatable {
    public var resolved = 0
    public var gaveUp = 0
    public var stillPending = 0
    public var redacted = 0
    public var preMissing = 0
    public var postMissing = 0

    public init() {}
}
