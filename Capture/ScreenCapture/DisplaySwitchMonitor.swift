import Foundation
import AppKit
import ApplicationServices
import Shared

/// Monitors active window changes and detects when user switches to a different display
/// Uses NSWorkspace notifications and Accessibility API for real-time detection
actor DisplaySwitchMonitor {

    // MARK: - Properties

    private let displayMonitor: DisplayMonitor
    private var currentDisplayID: UInt32?
    private var notificationTask: Task<Void, Never>?
    private var axObserver: AXObserver?
    private var observedApp: NSRunningApplication?
    /// Token handed to the C callback in place of a pointer to `self`. Zero means "no observer installed".
    private var axToken: UInt = 0
    /// Bumped by every `setupAXObserverForFrontmostApp()`; a setup that finds it changed after an `await` was superseded.
    private var setupGeneration = 0
    private var nextWindowChangeEventID: UInt64 = 0

    /// Callback when display switch is detected
    nonisolated(unsafe) var onDisplaySwitch: (@Sendable (UInt32, UInt32) async -> Void)?

    /// Callback when accessibility permission is denied
    nonisolated(unsafe) var onAccessibilityPermissionDenied: (@Sendable () async -> Void)?

    /// Callback when active window changes (app switch or window focus change within app)
    /// Fires for immediate capture when captureOnWindowChange is enabled
    nonisolated(unsafe) var onWindowChange: (@Sendable (WindowChangeEvent) async -> Void)?

    // MARK: - Initialization

    init(displayMonitor: DisplayMonitor) {
        self.displayMonitor = displayMonitor
    }

    // MARK: - Lifecycle

    /// Start monitoring for display switches
    func startMonitoring(initialDisplayID: UInt32) {
        self.currentDisplayID = initialDisplayID

        // Start listening to workspace notifications on main actor
        notificationTask = Task { @MainActor in
            let center = NSWorkspace.shared.notificationCenter

            // Set up initial AX observer for frontmost app
            await self.setupAXObserverForFrontmostApp()

            // Observe when user switches to a different application
            for await notification in center.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                let activatedApp = Self.applicationSnapshot(
                    notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                )
                let frontmostApp = Self.applicationSnapshot(NSWorkspace.shared.frontmostApplication)
                let event = await self.makeWindowChangeEvent(
                    source: .appActivation,
                    activatedApp: activatedApp,
                    workspaceFrontmostApp: frontmostApp
                )
                // Notify window change for immediate capture (app switch)
                if let callback = self.onWindowChange {
                    await callback(event)
                }
                await self.checkForDisplaySwitch()
                // Re-setup AX observer for the new frontmost app
                await self.setupAXObserverForFrontmostApp()
            }
        }
    }

    /// Stop monitoring
    func stopMonitoring() async {
        notificationTask?.cancel()
        notificationTask = nil
        currentDisplayID = nil
        await removeCurrentAXObserver()
    }

    // MARK: - Accessibility Observer

    /// Set up AX observer for the frontmost application to detect window moves
    /// Uses safe wrappers to prevent crashes if permissions are revoked
    ///
    /// Crash history: the C callback used to receive `Unmanaged.passUnretained(wrapper)` as its refcon while this actor
    /// freed the wrapper whenever the observer was replaced (every app switch). A callback already queued on the main
    /// run loop — or an older observer leaked by two interleaved setups — then dereferenced freed memory
    /// (EXC_BAD_ACCESS in swift_getObjectType, or a trap in DefaultActorImpl::tryLock). The callback now receives an
    /// opaque TOKEN that is never dereferenced; `DisplaySwitchAXRegistry` maps it to a weak monitor reference, and a
    /// token that was unregistered simply resolves to nothing.
    private func setupAXObserverForFrontmostApp() async {
        setupGeneration &+= 1
        let generation = setupGeneration

        // Remove existing observer first
        await removeCurrentAXObserver()
        guard generation == setupGeneration else { return }   // superseded by a newer setup

        // Check permission before attempting any AX operations
        guard PermissionMonitor.shared.hasAccessibilityPermission() else {
            if let callback = onAccessibilityPermissionDenied {
                await callback()
            }
            return
        }

        // Get frontmost app on main actor
        let app: NSRunningApplication? = await MainActor.run {
            NSWorkspace.shared.frontmostApplication
        }
        guard generation == setupGeneration, let app else { return }

        let pid = app.processIdentifier
        let token = DisplaySwitchAXRegistry.shared.register(self)
        guard let refcon = UnsafeMutableRawPointer(bitPattern: token) else {
            DisplaySwitchAXRegistry.shared.unregister(token)
            return
        }

        // Use safe wrapper to create observer
        guard let observer = PermissionMonitor.shared.safeCreateAXObserver(
            pid: pid,
            callback: displaySwitchAXCallback
        ) else {
            DisplaySwitchAXRegistry.shared.unregister(token)
            Log.warning("[DisplaySwitchMonitor] Failed to create AX observer for \(app.localizedName ?? "unknown") - permission may have been revoked", category: .capture)
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        // Add notifications for window moved, focused window changed, and title changed
        // These may fail if permission is revoked mid-setup, but won't crash
        AXObserverAddNotification(observer, appElement, kAXMovedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXTitleChangedNotification as CFString, refcon)

        // Add observer to run loop on main actor
        let source = AXObserverGetRunLoopSource(observer)
        await MainActor.run {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // The hop above is a suspension point: if a newer setup (or stopMonitoring) ran meanwhile, this observer must
        // not become the current one. Clean up only what THIS call created.
        guard generation == setupGeneration else {
            DisplaySwitchAXRegistry.shared.unregister(token)
            await MainActor.run {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
                CFRunLoopSourceInvalidate(source)
            }
            return
        }

        // No suspension between the check above and these assignments, so state is always consistent.
        self.axObserver = observer
        self.observedApp = app
        self.axToken = token
    }

    /// Remove the current AX observer
    private func removeCurrentAXObserver() async {
        // Detach state and invalidate the token synchronously, BEFORE any suspension: from this line on, a callback
        // for the old observer resolves to nothing instead of reaching this actor.
        let observer = self.axObserver
        let token = self.axToken
        self.axObserver = nil
        self.observedApp = nil
        self.axToken = 0
        if token != 0 { DisplaySwitchAXRegistry.shared.unregister(token) }

        if let observer {
            let source = AXObserverGetRunLoopSource(observer)
            await MainActor.run {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
                CFRunLoopSourceInvalidate(source)
            }
        }
    }

    // MARK: - Private Methods

    /// Handle window change from AX observer (window focus change within app)
    /// Triggers immediate capture callback and then checks for display switch
    func handleWindowChangeFromAX(token: UInt) async {
        // A notification from an observer that has since been replaced or removed is stale.
        guard token != 0, token == axToken else { return }
        // Check permission first - if revoked, clean up and notify
        guard PermissionMonitor.shared.hasAccessibilityPermission() else {
            Log.warning("[DisplaySwitchMonitor] AX callback received but permission revoked - cleaning up", category: .capture)
            await removeCurrentAXObserver()
            if let callback = onAccessibilityPermissionDenied {
                await callback()
            }
            return
        }

        let frontmostApp = await MainActor.run {
            Self.applicationSnapshot(NSWorkspace.shared.frontmostApplication)
        }
        let event = makeWindowChangeEvent(
            source: .axActivation,
            activatedApp: nil,
            workspaceFrontmostApp: frontmostApp
        )
        // Notify window change for immediate capture
        if let callback = onWindowChange {
            await callback(event)
        }
        // Then check for display switch
        await checkForDisplaySwitch()
    }

    /// Check if the active window is on a different display
    private func checkForDisplaySwitch() async {
        guard let currentDisplay = currentDisplayID else { return }

        // Get the active display ID
        let (newDisplayID, hasAXPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()

        // Check if AX permission was denied
        if !hasAXPermission {
            if let callback = onAccessibilityPermissionDenied {
                await callback()
            }
            // Continue with current display even if AX is denied
            return
        }

        // If display changed, notify
        if newDisplayID != currentDisplay {
            // logger.info("Display switch detected: \(currentDisplay) → \(newDisplayID)")
            currentDisplayID = newDisplayID
            if let callback = onDisplaySwitch {
                await callback(currentDisplay, newDisplayID)
            }
        }
    }

    /// Get current display ID
    func getCurrentDisplayID() -> UInt32? {
        currentDisplayID
    }

    private func makeWindowChangeEvent(
        source: WindowChangeEventSource,
        activatedApp: CaptureAppSnapshot?,
        workspaceFrontmostApp: CaptureAppSnapshot?
    ) -> WindowChangeEvent {
        nextWindowChangeEventID += 1
        return WindowChangeEvent(
            id: nextWindowChangeEventID,
            source: source,
            observedAt: Date(),
            activatedApp: activatedApp,
            workspaceFrontmostApp: workspaceFrontmostApp
        )
    }

    @MainActor
    private static func applicationSnapshot(_ app: NSRunningApplication?) -> CaptureAppSnapshot? {
        guard let app else { return nil }

        let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CaptureAppSnapshot(
            name: name?.isEmpty == false ? name : nil,
            bundleID: bundleID?.isEmpty == false ? bundleID : nil,
            pid: app.processIdentifier
        )
    }

    private static func windowChangeEventDescription(_ event: WindowChangeEvent) -> String {
        "id=\(event.id) source=\(event.source.rawValue) observedAt=\(Log.timestamp(from: event.observedAt)) activated=\(event.activatedApp?.logDescription ?? "nil") frontmost=\(event.workspaceFrontmostApp?.logDescription ?? "nil")"
    }
}

// MARK: - AX callback plumbing

/// Maps the opaque token passed to the AX C callback back to a live monitor.
///
/// The token is an integer that is never dereferenced, and the registry holds the monitor weakly, so a callback that
/// fires after its observer was torn down (or after the monitor was deallocated) finds nothing and returns.
final class DisplaySwitchAXRegistry: @unchecked Sendable {
    static let shared = DisplaySwitchAXRegistry()

    private struct WeakMonitor { weak var monitor: DisplaySwitchMonitor? }
    private let lock = NSLock()
    private var nextToken: UInt = 1
    private var entries: [UInt: WeakMonitor] = [:]

    func register(_ monitor: DisplaySwitchMonitor) -> UInt {
        lock.lock(); defer { lock.unlock() }
        let token = nextToken
        nextToken &+= 1
        if nextToken == 0 { nextToken = 1 }
        entries[token] = WeakMonitor(monitor: monitor)
        return token
    }

    func unregister(_ token: UInt) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: token)
    }

    func monitor(for token: UInt) -> DisplaySwitchMonitor? {
        lock.lock(); defer { lock.unlock() }
        return entries[token]?.monitor
    }

    /// Entry point for the C callback. Safe to call with any refcon, including one whose observer is long gone.
    static func dispatch(refcon: UnsafeMutableRawPointer?) {
        guard let refcon else { return }
        let token = UInt(bitPattern: refcon)
        guard let monitor = shared.monitor(for: token) else { return }
        Task { await monitor.handleWindowChangeFromAX(token: token) }
    }
}

/// `AXObserverCallback` for window move / focus / title changes. Must not touch `refcon` as a pointer.
private func displaySwitchAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    DisplaySwitchAXRegistry.dispatch(refcon: refcon)
}
