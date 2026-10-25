import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Shared

/// Gathers display geometry, the window under the pointer and accessibility context for an input
/// event.
///
/// - **Off the cooperative pool.** Accessibility calls block on the target app's main thread, so
///   they run on a dedicated serial queue with short per-element messaging timeouts.
/// - **Per-app timeouts only.** Timeouts are set on the target app's element, never on the
///   system-wide element: that would change the timeout for every AX call in this process (the
///   browser-URL extractor included).
/// - **Labels, never values.** Only role, subrole, title/description, identifier and geometry are
///   read. `AXValue` (field contents) is never requested.
/// - **Bounded.** The clickable-element snapshot is capped by element count, depth, visited nodes
///   and wall-clock budget; a second snapshot request while one is queued skips elements.
final class LiveInputContextProvider: InputContextProviding, @unchecked Sendable {
    static let maxElements = 200
    static let maxDepth = 12
    static let maxVisited = 1_500
    static let snapshotBudgetSeconds: TimeInterval = 0.15
    static let messagingTimeoutSeconds: Float = 0.2
    static let maxNameLength = 80

    /// Roles that can plausibly be clicked or typed into: the training-relevant targets.
    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXMenuItem", "AXMenuBarItem",
        "AXMenuButton", "AXPopUpButton", "AXTab", "AXTextField", "AXTextArea", "AXComboBox",
        "AXSlider", "AXDisclosureTriangle", "AXIncrementor", "AXSegmentedControl", "AXSearchField"
    ]

    private let queue = DispatchQueue(label: "io.retrace.input-context", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingRequests = 0
    private var manualAccessibilityPIDs = Set<pid_t>()

    func context(at point: CGPoint?, wantsElements: Bool) async -> InputContext {
        lock.lock()
        pendingRequests += 1
        let busy = pendingRequests > 1
        lock.unlock()

        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                var context = buildContext(point: point, wantsElements: wantsElements && !busy)
                if wantsElements && busy {
                    context.axSnapshotTruncated = true
                }
                lock.lock()
                pendingRequests -= 1
                lock.unlock()
                continuation.resume(returning: context)
            }
        }
    }

    // MARK: - Context

    private func buildContext(point: CGPoint?, wantsElements: Bool) -> InputContext {
        var context = InputContext()

        let layout = Self.displayLayout()
        context.displays = layout

        let trusted = AXIsProcessTrusted()
        var window: WindowHit?
        var appElement: AXUIElement?
        var hitElement: AXUIElement?

        if let point {
            window = Self.windowUnderPoint(point)
            if let window, Self.isOwnProcess(window.pid) {
                return ownAppContext(base: context, window: window, point: point)
            }
            if let window {
                appElement = limited(AXUIElementCreateApplication(window.pid))
            }
            if trusted {
                let result = hitTest(point: point, appElement: appElement)
                context.axAvailable = result.available
                hitElement = result.element
            }
        } else {
            if let frontmost = NSWorkspace.shared.frontmostApplication {
                let pid = frontmost.processIdentifier
                if Self.isOwnProcess(pid) {
                    return ownAppContext(base: context, window: Self.topWindow(ofPID: pid), point: nil)
                }
                window = Self.topWindow(ofPID: pid) ?? WindowHit(
                    pid: pid,
                    bundleID: frontmost.bundleIdentifier,
                    ownerName: frontmost.localizedName ?? "",
                    title: nil,
                    frame: nil
                )
                appElement = limited(AXUIElementCreateApplication(pid))
            }
            if trusted, let appElement {
                let result = focusedElement(of: appElement)
                context.axAvailable = result.available
                hitElement = result.element
            }
        }

        if let window {
            context.bundleID = window.bundleID
            context.windowTitle = window.title
            context.windowFrame = window.frame
        }

        // "Skip any event where a password field is focused": the pointer may be on a different
        // control than the focus (a Sign-in button, a scroll bar), so check keyboard focus too.
        if trusted {
            var pids: [pid_t] = []
            if let owner = window?.pid { pids.append(owner) }
            if let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier, !pids.contains(frontmost) {
                pids.append(frontmost)
            }
            pids.removeAll(where: Self.isOwnProcess)  // never AX-inspect ourselves
            for pid in pids where focusedElementIsSecure(pid: pid, reusing: pid == window?.pid ? appElement : nil) {
                context.focusedElementIsSecure = true
                break
            }
        }

        // Which display: the one under the pointer; for keyboard events, the one holding the window.
        let anchor = point ?? window?.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        if let anchor, let display = layout.first(where: { $0.contains(anchor) }) ?? layout.first {
            context.displayID = display.id
            context.displayPixelWidth = display.pixelWidth
            context.displayPixelHeight = display.pixelHeight
            context.displayScale = display.scale
        }

        if let hitElement {
            context.axTarget = axTarget(of: hitElement)
            if wantsElements, let windowElement = containingWindow(of: hitElement) {
                let snapshot = snapshotElements(in: windowElement)
                context.axElements = snapshot.elements
                context.axSnapshotTruncated = snapshot.truncated
            }
        }

        context.isPrivateWindow = privateWindowState(window: window, trusted: trusted)
        return context
    }

    /// `false` for non-browsers, the AX-title verdict for browsers, `nil` when a browser's state
    /// cannot be determined (no Accessibility).
    private func privateWindowState(window: WindowHit?, trusted: Bool) -> Bool? {
        guard let window else { return nil }
        guard PrivateWindowDetector.isBrowserOwnerName(window.ownerName) else { return false }
        guard trusted, let title = window.title, !title.isEmpty else { return nil }
        return PrivateWindowDetector.isPrivateWindowViaAXTitle(
            pid: window.pid,
            windowTitle: title,
            bundleID: window.bundleID
        )
    }

    /// Whether `pid` is this app. Accessibility queries against our own process are serviced by
    /// AppKit on the main thread, so they must never be issued from the context queue.
    static func isOwnProcess(_ pid: pid_t) -> Bool {
        pid == ProcessInfo.processInfo.processIdentifier
    }

    /// Geometry only: enough to describe where the event was, with no accessibility traffic.
    private func ownAppContext(base: InputContext, window: WindowHit?, point: CGPoint?) -> InputContext {
        var context = base
        context.isOwnApp = true
        context.bundleID = window?.bundleID ?? Bundle.main.bundleIdentifier
        context.windowFrame = window?.frame
        let anchor = point ?? window?.frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        if let anchor, let display = context.displays.first(where: { $0.contains(anchor) }) ?? context.displays.first {
            context.displayID = display.id
            context.displayPixelWidth = display.pixelWidth
            context.displayPixelHeight = display.pixelHeight
            context.displayScale = display.scale
        }
        return context
    }

    // MARK: - Displays and windows

    static func displayLayout() -> [InputDisplayGeometry] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }

        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelWidth = mode?.pixelWidth ?? Int(bounds.width)
            let pixelHeight = mode?.pixelHeight ?? Int(bounds.height)
            let scale = bounds.width > 0 ? Double(pixelWidth) / Double(bounds.width) : 1
            return InputDisplayGeometry(
                id: id,
                x: Double(bounds.origin.x),
                y: Double(bounds.origin.y),
                width: Double(bounds.width),
                height: Double(bounds.height),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scale: scale
            )
        }
    }

    struct WindowHit {
        let pid: pid_t
        let bundleID: String?
        let ownerName: String
        let title: String?
        let frame: CGRect?
    }

    /// First on-screen layer-0 window, front to back, containing `point`.
    static func windowUnderPoint(_ point: CGPoint) -> WindowHit? {
        windows().first { ($0.frame?.contains(point)) ?? false }
    }

    static func topWindow(ofPID pid: pid_t) -> WindowHit? {
        windows().first { $0.pid == pid }
    }

    private static func windows() -> [WindowHit] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var hits: [WindowHit] = []
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 1, height > 1 else { continue }

            let title = info[kCGWindowName as String] as? String
            hits.append(WindowHit(
                pid: pid,
                bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: (title?.isEmpty ?? true) ? nil : title,
                frame: CGRect(x: x, y: y, width: width, height: height)
            ))
        }
        return hits
    }

    // MARK: - Accessibility

    private func limited(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeoutSeconds)
        return element
    }

    /// Chromium/Electron only build their accessibility tree on request. Same switch the URL
    /// extractor flips, set once per process.
    private func enableManualAccessibilityIfNeeded(_ appElement: AXUIElement, pid: pid_t) {
        lock.lock()
        let inserted = manualAccessibilityPIDs.insert(pid).inserted
        lock.unlock()
        guard inserted else { return }
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func focusedElementIsSecure(pid: pid_t, reusing existing: AXUIElement?) -> Bool {
        let appElement = existing ?? limited(AXUIElementCreateApplication(pid))
        guard let focused = focusedElement(of: appElement).element else { return false }
        return Self.string(focused, kAXSubroleAttribute) == "AXSecureTextField"
            || Self.string(focused, kAXRoleAttribute) == "AXSecureTextField"
    }

    private func hitTest(point: CGPoint, appElement: AXUIElement?) -> (element: AXUIElement?, available: Bool) {
        var element: AXUIElement?
        let result: AXError
        if let appElement {
            var pid: pid_t = 0
            AXUIElementGetPid(appElement, &pid)
            enableManualAccessibilityIfNeeded(appElement, pid: pid)
            result = AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &element)
        } else {
            // No window found: fall back to the system-wide hit test, leaving its timeout untouched.
            result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
        }
        return (element.map(limited), Self.axAnswered(result))
    }

    private func focusedElement(of appElement: AXUIElement) -> (element: AXUIElement?, available: Bool) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (nil, Self.axAnswered(result))
        }
        return (limited(unsafeBitCast(value, to: AXUIElement.self)), true)
    }

    /// The app answered (even "nothing there"); `apiDisabled`/`cannotComplete`/`notImplemented`
    /// mean the privacy checks could not be run.
    private static func axAnswered(_ result: AXError) -> Bool {
        switch result {
        case .success, .noValue, .attributeUnsupported, .illegalArgument: return true
        default: return false
        }
    }

    private func axTarget(of element: AXUIElement) -> InputAXTarget {
        let frame = Self.frame(of: element)
        return InputAXTarget(
            role: Self.string(element, kAXRoleAttribute),
            subrole: Self.string(element, kAXSubroleAttribute),
            title: Self.name(of: element),
            identifier: Self.string(element, "AXIdentifier"),
            x: frame.map { Double($0.origin.x) },
            y: frame.map { Double($0.origin.y) },
            width: frame.map { Double($0.size.width) },
            height: frame.map { Double($0.size.height) }
        )
    }

    private func containingWindow(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return limited(unsafeBitCast(value, to: AXUIElement.self))
        }
        // Fall back to walking parents until an AXWindow.
        var current = element
        for _ in 0..<20 {
            if Self.string(current, kAXRoleAttribute) == "AXWindow" { return current }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            current = limited(unsafeBitCast(parent, to: AXUIElement.self))
        }
        return nil
    }

    /// Breadth-first walk of the window collecting clickable elements, bounded in count, depth,
    /// visited nodes and time.
    private func snapshotElements(in window: AXUIElement) -> (elements: [InputAXElement], truncated: Bool) {
        let deadline = Date().addingTimeInterval(Self.snapshotBudgetSeconds)
        var elements: [InputAXElement] = []
        var visited = 0
        var truncated = false
        var frontier: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0

        while index < frontier.count {
            if elements.count >= Self.maxElements || visited >= Self.maxVisited || Date() > deadline {
                truncated = true
                break
            }
            let (element, depth) = frontier[index]
            index += 1
            visited += 1

            if let role = Self.string(element, kAXRoleAttribute),
               Self.clickableRoles.contains(role),
               let frame = Self.frame(of: element) {
                elements.append(InputAXElement(
                    role: role,
                    name: Self.name(of: element),
                    box: [Double(frame.origin.x), Double(frame.origin.y), Double(frame.size.width), Double(frame.size.height)]
                ))
            }

            guard depth < Self.maxDepth else { continue }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AnyObject] else { continue }
            for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
                frontier.append((limited(unsafeBitCast(child, to: AXUIElement.self)), depth + 1))
            }
        }
        if index < frontier.count { truncated = true }
        return (elements, truncated)
    }

    // MARK: - Attribute helpers (labels and geometry only; never AXValue)

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Human-visible label: title, then description. Truncated; never the element's value.
    private static func name(of element: AXUIElement) -> String? {
        let raw = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute)
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.prefix(maxNameLength))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}

extension InputDisplayGeometry {
    func contains(_ point: CGPoint) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }
}
