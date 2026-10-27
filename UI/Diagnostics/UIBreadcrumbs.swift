import AppKit
import Foundation
import os

/// Breadcrumbs that let a hitch be matched to what the user was doing: input events (with delivery lag),
/// window/app/space/screen/sleep notifications, and app-defined notifications. All callbacks are cheap and
/// run on whatever thread posts them; heavy work is deferred to the trace writer.
final class UIBreadcrumbs: @unchecked Sendable {
    private weak var diagnostics: UIDiagnostics?
    private var eventMonitor: Any?
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    // Main-thread-only input aggregation state.
    private var scrollEvents = 0
    private var scrollDelta = 0.0
    private var scrollWindowStart: UInt64 = 0
    private var lastDragEmit: UInt64 = 0

    private struct RateWindow { var startSecond = 0; var count = 0 }
    private let rate = OSAllocatedUnfairLock(initialState: [String: RateWindow]())

    private static let windowNames: Set<Notification.Name> = [
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
        NSWindow.didResizeNotification, NSWindow.didMoveNotification,
        NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
        NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification, NSWindow.didExposeNotification,
        NSWindow.didEndLiveResizeNotification, NSWindow.willBeginSheetNotification,
        NSWindow.didEndSheetNotification,
    ]

    init(diagnostics: UIDiagnostics) {
        self.diagnostics = diagnostics
    }

    func start() {
        installEventMonitor()
        installNotificationObservers()
    }

    // MARK: - Input events

    private func installEventMonitor() {
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
            .leftMouseDragged, .keyDown, .scrollWheel, .magnify, .swipe, .rotate, .smartMagnify,
        ]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        guard let diagnostics else { return }
        let lagMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
        let now = DispatchTime.now().uptimeNanoseconds

        switch event.type {
        case .scrollWheel:
            flushScrollIfStale(now: now, force: false)
            if scrollEvents == 0 { scrollWindowStart = now }
            scrollEvents += 1
            scrollDelta += abs(Double(event.scrollingDeltaY)) + abs(Double(event.scrollingDeltaX))
            if event.phase == .ended || event.momentumPhase == .ended || now &- scrollWindowStart > 100_000_000 {
                flushScrollIfStale(now: now, force: true, lagMs: lagMs, window: event.window)
            }
            diagnostics.noteInput("scroll")
            return
        case .leftMouseDragged:
            guard now &- lastDragEmit > 50_000_000 else { return }
            lastDragEmit = now
        default:
            break
        }

        // Fallback for the global ⌃⌥⌘M mark hotkey when Retrace is frontmost (mark() de-duplicates).
        if event.type == .keyDown, event.keyCode == 46,
           [NSEvent.ModifierFlags([.control, .option, .command]), NSEvent.ModifierFlags([.shift, .option, .command])]
            .contains(event.modifierFlags.intersection(.deviceIndependentFlagsMask)) {
            diagnostics.mark()
            return
        }

        var fields: [String: Any] = ["type": Self.name(of: event.type), "lag_ms": Self.round1(lagMs)]
        if let window = event.window {
            fields["window"] = "\(type(of: window)) \"\(window.title)\""
            if event.type != .keyDown, let content = window.contentView {
                let hit = content.hitTest(event.locationInWindow)
                fields["view"] = hit.map { String(describing: type(of: $0)) } ?? "nil"
            }
            if let responder = window.firstResponder {
                fields["responder"] = String(describing: type(of: responder))
            }
        }
        switch event.type {
        case .keyDown:
            // Key code + modifiers only; never the characters.
            fields["key_code"] = Int(event.keyCode)
            fields["mods"] = Int(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            fields["repeat"] = event.isARepeat
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp:
            fields["clicks"] = event.clickCount
        case .magnify:
            fields["magnification"] = Self.round1(Double(event.magnification))
        default:
            break
        }
        diagnostics.emit("input", fields)
        if event.type != .leftMouseDragged && event.type != .leftMouseUp && event.type != .rightMouseUp {
            diagnostics.noteInput("\(Self.name(of: event.type)) \((fields["view"] as? String).map { "view=\($0)" } ?? "")")
        }
    }

    private func flushScrollIfStale(now: UInt64, force: Bool, lagMs: Double = 0, window: NSWindow? = nil) {
        guard scrollEvents > 0 else { return }
        guard force || now &- scrollWindowStart > 250_000_000 else { return }
        diagnostics?.emit("input", [
            "type": "scroll",
            "events": scrollEvents,
            "delta": Self.round1(scrollDelta),
            "lag_ms": Self.round1(lagMs),
            "window": window.map { "\(type(of: $0)) \"\($0.title)\"" } ?? "?",
        ])
        scrollEvents = 0
        scrollDelta = 0
    }

    // MARK: - Notifications

    /// Retrace's own notification names (see `Notification.Name(...)` definitions in UI/ and App/).
    private static let appNotificationNames: [String] = [
        "AccessibilityPermissionRevoked", "CaptureObserved", "colorThemeDidChange", "dashboardDidBecomeKey",
        "dashboardDidClose", "dashboardDidOpen", "dashboardShowSettings", "dataSourceDidChange", "fontStyleDidChange",
        "forceRestartSemanticIndexing", "io.retrace.app.externalDashboardReveal", "navigateTimelineToDate",
        "openDashboard", "openFeedback", "openSearch", "openSettings", "OpenSettingsAI", "openSettingsAppearance",
        "openSettingsPauseReminderInterval", "openSettingsPower", "openSettingsPowerOCRCard",
        "openSettingsPowerOCRPriority", "openSettingsTags", "openSettingsTimelineScrollOrientation",
        "openSystemMonitor", "openTimeline", "PauseReminderSettingsDidChange", "PowerSettingsDidChange",
        "PowerSourceDidChange", "RecordingUnexpectedStop", "ScreenRecordingPermissionRevoked",
        "settingsSelectedTabDidChange", "showFrameContextMenu", "StorageCriticalLow", "StorageHealthy", "StorageLow",
        "tagColorsDidChange", "timelineDidClose", "timelineDidOpen", "toggleDashboard", "toggleSettings",
        "toggleSystemMonitor",
    ]

    /// Explicit names only. A wildcard (`name: nil`) observer was tried first and crashed the app: CoreMedia
    /// posts CF-level notifications whose bridging into `Notification` dereferences a bad pointer.
    private func installNotificationObservers() {
        let center = NotificationCenter.default
        var appNames: [Notification.Name] = Self.windowNames.map { $0 }
        appNames += [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSApplication.didChangeScreenParametersNotification, NSApplication.didChangeOcclusionStateNotification,
            NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
        ]
        appNames += Self.appNotificationNames.map { Notification.Name($0) }
        for name in appNames {
            let token = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                self?.handle(notification: note, source: "app")
            }
            tokens.append((center, token))
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in workspaceNames {
            let token = workspace.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                self?.handle(notification: note, source: "workspace")
            }
            tokens.append((workspace, token))
        }
    }

    private func handle(notification note: Notification, source: String) {
        guard let diagnostics else { return }
        let name = note.name.rawValue
        diagnostics.countNotification(name)
        guard allow(name) else { return }

        var fields: [String: Any] = ["name": name, "src": source]
        if let window = note.object as? NSWindow {
            fields["window"] = "\(type(of: window)) \"\(window.title)\""
            if note.name == NSWindow.didResizeNotification || note.name == NSWindow.didMoveNotification
                || note.name == NSWindow.didChangeOcclusionStateNotification {
                fields["frame"] = NSStringFromRect(window.frame)
                fields["occluded"] = !window.occlusionState.contains(.visible)
            }
        }
        if source == "workspace", let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            fields["app"] = app.bundleIdentifier ?? app.localizedName ?? "?"
        }
        diagnostics.emit("note", fields)
    }

    /// At most 20 individually-logged occurrences per name per second; the rest are only counted in `tick`.
    private func allow(_ name: String) -> Bool {
        let second = Int(DispatchTime.now().uptimeNanoseconds / 1_000_000_000)
        return rate.withLock { map in
            var w = map[name] ?? RateWindow()
            if w.startSecond != second { w = RateWindow(startSecond: second, count: 0) }
            w.count += 1
            map[name] = w
            return w.count <= 20
        }
    }

    // MARK: - Helpers

    private static func name(of type: NSEvent.EventType) -> String {
        switch type {
        case .leftMouseDown: return "leftMouseDown"
        case .leftMouseUp: return "leftMouseUp"
        case .rightMouseDown: return "rightMouseDown"
        case .rightMouseUp: return "rightMouseUp"
        case .otherMouseDown: return "otherMouseDown"
        case .leftMouseDragged: return "leftMouseDragged"
        case .keyDown: return "keyDown"
        case .scrollWheel: return "scrollWheel"
        case .magnify: return "magnify"
        case .swipe: return "swipe"
        case .rotate: return "rotate"
        case .smartMagnify: return "smartMagnify"
        default: return "event\(type.rawValue)"
        }
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
