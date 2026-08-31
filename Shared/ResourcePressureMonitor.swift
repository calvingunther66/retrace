import Foundation
import Darwin

public enum ResourcePressureLevel: Int, Comparable, Sendable {
    case nominal = 0    // All clear
    case elevated = 1   // Reduce non-essential work (memory warning OR thermal .serious)
    case critical = 2   // Pause heavy operations (memory critical OR thermal .critical OR footprint > threshold)
    
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public final class ResourcePressureMonitor: @unchecked Sendable {
    public static let shared = ResourcePressureMonitor()
    
    private let monitorQueue = DispatchQueue(label: "com.retrace.resourceMonitor", qos: .utility)
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var timerSource: DispatchSourceTimer?
    private var thermalObserver: NSObjectProtocol?
    
    private let lock = NSLock()
    private var _currentLevel: ResourcePressureLevel = .nominal
    
    // Publishers
    private var streamContinuations: [UUID: AsyncStream<ResourcePressureLevel>.Continuation] = [:]
    
    // Thresholds
    public let elevatedFootprintBytes: UInt64
    public let criticalFootprintBytes: UInt64
    
    private init() {
        // Always scale with physical memory, rather than switching to a fixed cap above
        // 16GB — a fixed cap made larger-RAM machines trip "critical" at a *lower*
        // absolute footprint than an 8GB machine (1.8GB fixed vs. ~1.76GB at 8GB*0.22,
        // but ~7GB at 32GB*0.22), which is backwards and would present as OCR pausing
        // under pressure that wasn't actually there.
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        self.elevatedFootprintBytes = UInt64(Double(physicalMemory) * 0.15)
        self.criticalFootprintBytes = UInt64(Double(physicalMemory) * 0.22)
    }
    
    public var currentLevel: ResourcePressureLevel {
        lock.lock()
        defer { lock.unlock() }
        return _currentLevel
    }
    
    public var pressureStream: AsyncStream<ResourcePressureLevel> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            let current = _currentLevel
            streamContinuations[id] = continuation
            lock.unlock()
            
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock()
                self.streamContinuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }
    
    public func start() {
        lock.lock()
        guard memoryPressureSource == nil else {
            lock.unlock()
            return
        }
        lock.unlock()
        
        // System Memory Pressure
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: monitorQueue)
        source.setEventHandler { [weak self] in
            let event = source.data
            var memPressure: ResourcePressureLevel = .nominal
            var triggerStr = ""
            
            if event.contains(.critical) {
                memPressure = .critical
                triggerStr = "memoryCritical"
            } else if event.contains(.warning) {
                memPressure = .elevated
                triggerStr = "memoryWarning"
            }
            
            self?.evaluatePressure(trigger: triggerStr, memoryPressureTrigger: memPressure)
        }
        source.resume()
        
        // Thermal State
        let observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.monitorQueue.async {
                self?.evaluatePressure(trigger: "thermalStateChange")
            }
        }
        
        // Polling Timer for footprint
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            self?.evaluatePressure(trigger: "pollingTimer")
        }
        timer.resume()
        
        lock.lock()
        memoryPressureSource = source
        thermalObserver = observer
        timerSource = timer
        lock.unlock()
        
        monitorQueue.async {
            self.evaluatePressure(trigger: "start")
        }
    }
    
    public func stop() {
        lock.lock()
        
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        
        timerSource?.cancel()
        timerSource = nil
        
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
        
        for cont in streamContinuations.values {
            cont.finish()
        }
        streamContinuations.removeAll()
        
        lock.unlock()
    }
    
    private func evaluatePressure(trigger: String, memoryPressureTrigger: ResourcePressureLevel? = nil) {
        let footprint = readProcessFootprintBytes()
        let thermal = ProcessInfo.processInfo.thermalState
        
        var nextLevel: ResourcePressureLevel = .nominal
        var triggeredBy = trigger
        
        if footprint > criticalFootprintBytes {
            nextLevel = .critical
            triggeredBy = "footprintCritical"
        } else if footprint > elevatedFootprintBytes {
            nextLevel = max(nextLevel, .elevated)
            triggeredBy = "footprintElevated"
        }
        
        if thermal == .critical {
            nextLevel = max(nextLevel, .critical)
            triggeredBy = "thermalCritical"
        } else if thermal == .serious {
            nextLevel = max(nextLevel, .elevated)
            triggeredBy = "thermalSerious"
        }
        
        if let mp = memoryPressureTrigger {
            if mp > nextLevel {
                nextLevel = mp
                triggeredBy = trigger
            }
        }
        
        lock.lock()
        let oldLevel = _currentLevel
        let continuations = Array(streamContinuations.values)
        if oldLevel != nextLevel {
            _currentLevel = nextLevel
            lock.unlock()
            
            for cont in continuations {
                cont.yield(nextLevel)
            }
            
            let footprintGb = String(format: "%.2fGB", Double(footprint) / 1_073_741_824.0)
            let thermalStr = thermalString(thermal)
            let msg = "[ResourcePressure] level=\(nextLevel) trigger=\(triggeredBy) footprint=\(footprintGb) thermal=\(thermalStr)"
            
            if nextLevel == .nominal {
                Log.info(msg, category: .app)
            } else {
                Log.warning(msg, category: .app)
            }
        } else {
            lock.unlock()
        }
    }
    
    private func thermalString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
    
    private func readProcessFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }
}
