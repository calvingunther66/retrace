import Foundation
import Shared

/// Decides whether an input event may be recorded at all.
///
/// The policy is deliberately fail-closed: when a check cannot be completed the event is still
/// kept (so the decision is visible and auditable) but tagged with a `privacyState` other than
/// `ok`, and export skips it by default. Nothing is silently waved through.
struct InputPrivacyPolicy: Sendable, Equatable {
    var excludedBundleIDs: Set<String> = []
    var excludePrivateWindows = true
    var redactWindowTitlePatterns: [String] = []

    init(
        excludedBundleIDs: Set<String> = [],
        excludePrivateWindows: Bool = true,
        redactWindowTitlePatterns: [String] = []
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.excludePrivateWindows = excludePrivateWindows
        self.redactWindowTitlePatterns = redactWindowTitlePatterns
    }

    init(config: CaptureConfig) {
        self.init(
            excludedBundleIDs: config.excludedAppBundleIDs,
            excludePrivateWindows: config.excludePrivateWindows,
            redactWindowTitlePatterns: config.redactWindowTitlePatterns
        )
    }

    enum DropReason: String, Sendable, Equatable {
        case secureField
        /// An event in Retrace's own windows (also keeps us from AX-inspecting ourselves).
        case ownApp
        case excludedApp
        case excludedWindow
        case privateWindow
    }

    enum Decision: Sendable, Equatable {
        case allow
        /// Record, but flag: a required check could not be completed.
        case allowUnverified(privacyState: String)
        case drop(DropReason)
    }

    static let privateUnknown = "private_unknown"

    func evaluate(_ context: InputContext) -> Decision {
        if context.isOwnApp {
            return .drop(.ownApp)
        }
        if context.isSecureField {
            return .drop(.secureField)
        }
        if let bundleID = context.bundleID, excludedBundleIDs.contains(bundleID) {
            return .drop(.excludedApp)
        }
        if let title = context.windowTitle,
           ExclusionPatternMatcher.firstMatch(in: title, patterns: redactWindowTitlePatterns) != nil {
            return .drop(.excludedWindow)
        }
        if excludePrivateWindows, context.isPrivateWindow == true {
            return .drop(.privateWindow)
        }

        // Checks below could not be completed: keep the event, but mark it.
        if !context.axAvailable {
            return .allowUnverified(privacyState: InputEvent.privacyAXUnavailable)
        }
        if excludePrivateWindows, context.isPrivateWindow == nil, context.bundleID != nil {
            return .allowUnverified(privacyState: Self.privateUnknown)
        }
        return .allow
    }
}

/// Counters the monitor accumulates between metric drains.
public struct InputEventStats: Sendable, Equatable {
    public var click = 0
    public var scroll = 0
    public var shortcut = 0
    public var typing = 0
    public var droppedDrag = 0
    public var droppedSecureInput = 0
    public var droppedSecureField = 0
    public var droppedExcluded = 0
    public var unverified = 0

    public init() {}

    public var recorded: Int { click + scroll + shortcut + typing }
    public var isEmpty: Bool { self == InputEventStats() }
}

enum InputEventBuilder {
    static func makeEvent(
        draft: InputEventDraft,
        context: InputContext,
        privacyState: String
    ) -> InputEvent {
        InputEvent(
            tsMs: draft.tsMs,
            endTsMs: draft.endTsMs,
            kind: draft.kind,
            button: draft.button?.rawValue,
            clickCount: draft.clickCount,
            modifiers: draft.modifiers,
            x: draft.x,
            y: draft.y,
            scrollDx: draft.scrollDx,
            scrollDy: draft.scrollDy,
            keyCombo: draft.keyCombo,
            typedCount: draft.typedCount,
            displayID: context.displayID,
            displayPixelWidth: context.displayPixelWidth,
            displayPixelHeight: context.displayPixelHeight,
            displayScale: context.displayScale,
            displays: context.displays,
            bundleID: context.bundleID,
            windowTitle: context.windowTitle,
            windowX: context.windowFrame.map { Double($0.origin.x) },
            windowY: context.windowFrame.map { Double($0.origin.y) },
            windowWidth: context.windowFrame.map { Double($0.size.width) },
            windowHeight: context.windowFrame.map { Double($0.size.height) },
            axTarget: context.axTarget,
            axElements: context.axElements,
            privacyState: privacyState
        )
    }
}
