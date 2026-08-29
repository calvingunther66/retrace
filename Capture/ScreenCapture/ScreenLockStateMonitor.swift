import Foundation
import AppKit

/// Tracks session lock/screensaver transitions published via distributed notifications.
final class ScreenLockStateMonitor: @unchecked Sendable {
    private let distributedCenter = DistributedNotificationCenter.default()
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private let stateLock = NSLock()
    private var distributedObserverTokens: [NSObjectProtocol] = []
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var isObserving = false
    private var isScreenLocked = false
    private var isScreenSaverRunning = false
    private var isDisplayAsleep = false

    private static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    private static let screenSaverDidStartNotification = Notification.Name("com.apple.screensaver.didstart")
    private static let screenSaverDidStopNotification = Notification.Name("com.apple.screensaver.didstop")

    func start() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isObserving else { return }
        isObserving = true

        distributedObserverTokens = [
            distributedCenter.addObserver(
                forName: Self.screenLockedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setScreenLocked(true)
            },
            distributedCenter.addObserver(
                forName: Self.screenUnlockedNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setScreenLocked(false)
                self?.setScreenSaverRunning(false)
            },
            distributedCenter.addObserver(
                forName: Self.screenSaverDidStartNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setScreenSaverRunning(true)
            },
            distributedCenter.addObserver(
                forName: Self.screenSaverDidStopNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setScreenSaverRunning(false)
            }
        ]

        // CAP-02: Observe display sleep and wake notifications to pause capture when screens sleep
        workspaceObserverTokens = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setDisplayAsleep(true)
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.setDisplayAsleep(false)
            }
        ]
    }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isObserving else { return }

        for token in distributedObserverTokens {
            distributedCenter.removeObserver(token)
        }
        distributedObserverTokens.removeAll()

        for token in workspaceObserverTokens {
            workspaceCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()

        isObserving = false
        isScreenLocked = false
        isScreenSaverRunning = false
        isDisplayAsleep = false
    }

    func captureBlockReason() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if isScreenLocked {
            return "session-locked"
        }
        if isScreenSaverRunning {
            return "screensaver-active"
        }
        if isDisplayAsleep {
            return "display-asleep"
        }
        return nil
    }

    private func setScreenLocked(_ value: Bool) {
        stateLock.lock()
        isScreenLocked = value
        stateLock.unlock()
    }

    private func setScreenSaverRunning(_ value: Bool) {
        stateLock.lock()
        isScreenSaverRunning = value
        stateLock.unlock()
    }

    private func setDisplayAsleep(_ value: Bool) {
        stateLock.lock()
        isDisplayAsleep = value
        stateLock.unlock()
    }
}
