import Foundation
import Shared

/// Manages application lifecycle states and transitions
/// Owner: APP integration
public actor AppLifecycle {

    // MARK: - State

    private(set) public var currentState: AppState = .idle
    private let coordinator: AppCoordinator

    // State change observers
    private var stateObservers: [(AppState) -> Void] = []

    // Memory pressure monitoring
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    // MARK: - Initialization

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        Log.info("AppLifecycle initialized", category: .app)
    }

    /// Sets up the system memory pressure dispatch source.
    /// Must be called after initialization to wire low-memory events.
    public func setupMemoryPressureMonitor() {
        guard memoryPressureSource == nil else { return }

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            let level = event.contains(.critical) ? "critical" : "warning"
            Log.warning("[AppLifecycle] System memory pressure: \(level)", category: .app)
            Task {
                try? await self.handleLowMemory()
            }
        }
        source.resume()
        memoryPressureSource = source
        Log.info("[AppLifecycle] Memory pressure monitor active", category: .app)
    }

    // MARK: - State Transitions

    /// Application launched - initialize services
    public func handleLaunch() async throws {
        guard currentState == .idle else {
            Log.warning("handleLaunch called in state \(currentState)", category: .app)
            return
        }

        await transition(to: .launching)
        Log.info("Application launching...", category: .app)

        do {
            try await coordinator.initialize()
            setupMemoryPressureMonitor()
            await transition(to: .ready)
            Log.info("Application ready", category: .app)
        } catch {
            await transition(to: .error(error))
            Log.error("Launch failed", context: error, category: .app)
            throw error
        }
    }

    /// Start capturing - begin the pipeline
    public func handleStart() async throws {
        guard currentState == .ready || currentState == .paused else {
            Log.warning("handleStart called in state \(currentState)", category: .app)
            throw AppLifecycleError.invalidStateTransition(from: currentState, to: .running)
        }

        await transition(to: .starting)
        Log.info("Starting capture pipeline...", category: .app)

        do {
            try await coordinator.startPipeline()
            await transition(to: .running)
            Log.info("Pipeline running", category: .app)
        } catch {
            await transition(to: .error(error))
            Log.error("Start failed", context: error, category: .app)
            throw error
        }
    }

    /// Pause capturing - stop pipeline but keep services ready
    public func handlePause() async throws {
        guard currentState == .running else {
            Log.warning("handlePause called in state \(currentState)", category: .app)
            return
        }

        await transition(to: .pausing)
        Log.info("Pausing capture pipeline...", category: .app)

        do {
            try await coordinator.stopPipeline()
            await transition(to: .paused)
            Log.info("Pipeline paused", category: .app)
        } catch {
            await transition(to: .error(error))
            Log.error("Pause failed", context: error, category: .app)
            throw error
        }
    }

    /// Resume from pause
    public func handleResume() async throws {
        guard currentState == .paused else {
            Log.warning("handleResume called in state \(currentState)", category: .app)
            return
        }

        try await handleStart()
    }

    /// Application will terminate - cleanup
    public func handleTermination() async throws {
        Log.info("Application terminating from state \(currentState)...", category: .app)

        await transition(to: .terminating)

        do {
            try await coordinator.shutdown()
            await transition(to: .terminated)
            Log.info("Application terminated cleanly", category: .app)
        } catch {
            Log.error("Termination error", context: error, category: .app)
            throw error
        }
    }

    /// System is going to sleep
    public func handleSleep() async throws {
        guard currentState == .running else { return }

        Log.info("System going to sleep, pausing pipeline...", category: .app)
        try await handlePause()
    }

    /// System woke from sleep
    public func handleWake() async throws {
        guard currentState == .paused else { return }

        Log.info("System woke from sleep, resuming pipeline...", category: .app)
        try await handleResume()
    }

    /// Handle background mode (user switched apps)
    public func handleBackground() async {
        // Continue running in background (macOS allows this)
        Log.info("Application entered background", category: .app)
    }

    /// Handle foreground mode (user returned to app)
    public func handleForeground() async {
        Log.info("Application entered foreground", category: .app)
    }

    /// Handle low memory warning — flush caches and reduce memory footprint
    public func handleLowMemory() async throws {
        Log.warning("[AppLifecycle] Low memory warning received — flushing caches", category: .app)

        // Clear in-memory credential caches
        OpenRouterCredentialsManager.clearMemoryCache()

        // Run database maintenance to free up resources (WAL checkpoint, temp table cleanup)
        if currentState == .running || currentState == .paused {
            try await coordinator.runDatabaseMaintenance()
        }

        // Log current memory diagnostic for troubleshooting
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let footprintMB = Double(info.phys_footprint) / (1024 * 1024)
            let residentMB = Double(info.resident_size) / (1024 * 1024)
            let compressedMB = Double(info.compressed) / (1024 * 1024)
            Log.info(
                "[AppLifecycle] Post-cleanup memory: footprint=\(String(format: "%.1f", footprintMB))MB resident=\(String(format: "%.1f", residentMB))MB compressed=\(String(format: "%.1f", compressedMB))MB",
                category: .app
            )
        }
    }

    /// Handle error recovery
    public func handleErrorRecovery() async throws {
        guard case .error = currentState else {
            Log.warning("handleErrorRecovery called in state \(currentState)", category: .app)
            return
        }

        Log.info("Attempting error recovery...", category: .app)

        // Try to restart services
        await transition(to: .launching)

        do {
            try await coordinator.shutdown()
            try await coordinator.initialize()
            await transition(to: .ready)
            Log.info("Error recovery successful", category: .app)
        } catch {
            await transition(to: .error(error))
            Log.error("Error recovery failed", context: error, category: .app)
            throw error
        }
    }

    // MARK: - State Observation

    /// Add observer for state changes
    public func observeState(_ observer: @escaping (AppState) -> Void) {
        stateObservers.append(observer)
        // Immediately notify of current state
        observer(currentState)
    }

    // MARK: - Private Helpers

    private func transition(to newState: AppState) async {
        let oldState = currentState
        currentState = newState

        Log.debug("State transition: \(oldState) → \(newState)", category: .app)

        // Notify observers
        for observer in stateObservers {
            observer(newState)
        }
    }
}

// MARK: - App State

public enum AppState: Sendable, Equatable {
    case idle           // Initial state, nothing initialized
    case launching      // Initializing services
    case ready          // Services ready, not capturing
    case starting       // Starting capture pipeline
    case running        // Capture pipeline active
    case pausing        // Stopping pipeline but keeping services
    case paused         // Pipeline stopped, services ready
    case terminating    // Shutting down
    case terminated     // Completely shut down
    case error(Error)   // Error state

    public static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.launching, .launching),
             (.ready, .ready),
             (.starting, .starting),
             (.running, .running),
             (.pausing, .pausing),
             (.paused, .paused),
             (.terminating, .terminating),
             (.terminated, .terminated):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }
}

// MARK: - Errors

public enum AppLifecycleError: RetraceError {
    case invalidStateTransition(from: AppState, to: AppState)
    case serviceNotReady
    case alreadyRunning

    public var errorCode: String {
        switch self {
        case .invalidStateTransition: return "LIFECYCLE_001"
        case .serviceNotReady:        return "LIFECYCLE_002"
        case .alreadyRunning:         return "LIFECYCLE_003"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidStateTransition(let from, let to):
            return "Invalid state transition from \(from) to \(to)"
        case .serviceNotReady:
            return "Service is not ready for the requested operation."
        case .alreadyRunning:
            return "Pipeline is already running."
        }
    }
}

// MARK: - Extensions

extension AppState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .launching: return "launching"
        case .ready: return "ready"
        case .starting: return "starting"
        case .running: return "running"
        case .pausing: return "pausing"
        case .paused: return "paused"
        case .terminating: return "terminating"
        case .terminated: return "terminated"
        case .error(let error): return "error(\(error))"
        }
    }
}
