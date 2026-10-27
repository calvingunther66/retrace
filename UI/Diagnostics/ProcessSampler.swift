import Foundation
import Darwin
import MachO

/// Once a second: drains the run-loop frame stats and render/publish/notification counters into a single
/// `tick` record, alongside process CPU, main-thread CPU, memory footprint and thread count. When the
/// process is burning CPU it also samples the stacks of the hottest background threads (`bgstack`), so
/// "the UI is slow because OCR/indexing/capture is hogging cores" shows up directly.
final class ProcessSampler: @unchecked Sendable {
    private weak var diagnostics: UIDiagnostics?
    private let queue = DispatchQueue(label: "io.retrace.ui-diagnostics.tick", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    private var lastWallNanos = DispatchTime.now().uptimeNanoseconds
    private var lastProcessCPU = ProcessSampler.processCPUSeconds()
    private var lastThreadCPU: [mach_port_t: Double] = [:]
    private var lastMainCPU: Double = 0
    private var lastThermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private var lastLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: StackSampler.maxFrames)
    private let symbolicator = StackSampler.Symbolicator()
    private var hitchMonitor: HitchMonitor? { diagnostics?.hitchMonitorForSampler }

    init(diagnostics: UIDiagnostics) {
        self.diagnostics = diagnostics
    }

    deinit { buffer.deallocate() }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel(); timer = nil }

    // MARK: - Tick

    private func tick() {
        guard let diagnostics else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let wallSeconds = max(Double(now &- lastWallNanos) / 1_000_000_000, 0.001)
        lastWallNanos = now

        let processCPU = Self.processCPUSeconds()
        let cpuPct = (processCPU - lastProcessCPU) / wallSeconds * 100
        lastProcessCPU = processCPU

        let threads = Self.threadSnapshot()
        var mainPct = 0.0
        var hot: [(port: mach_port_t, pct: Double, name: String)] = []
        var newThreadCPU: [mach_port_t: Double] = [:]
        let mainPort = hitchMonitor?.mainPort ?? 0
        let selfPort = pthread_mach_thread_np(pthread_self())
        for t in threads {
            newThreadCPU[t.port] = t.cpuSeconds
            let delta = t.cpuSeconds - (lastThreadCPU[t.port] ?? t.cpuSeconds)
            let pct = delta / wallSeconds * 100
            if t.port == mainPort { mainPct = pct; continue }
            if t.port == selfPort { continue }
            hot.append((t.port, pct, t.name))
        }
        lastThreadCPU = newThreadCPU

        let frames = hitchMonitor?.drainFrameStats() ?? HitchMonitor.FrameStats()
        let counts = diagnostics.drainCounters()

        var tick: [String: Any] = [
            "cpu": round1(cpuPct),
            "main_cpu": round1(mainPct),
            "mb": Int(Self.footprintBytes() / 1_048_576),
            "threads": threads.count,
            "iters": frames.iterations,
            "commits": frames.commits,
            "over16": frames.over16ms,
            "hitches": frames.hitches,
            "iter_max": round1(frames.maxMs),
            "iter_p95": round1(frames.p95Ms),
            "commit_max": round1(frames.maxCommitMs),
        ]
        func loud(_ dict: [String: Int], min: Int) -> [String: Int] { dict.filter { $0.value >= min } }
        let renders = loud(counts.renders, min: 3)
        let pubs = loud(counts.pubs, min: 1)
        if !renders.isEmpty { tick["renders"] = renders }
        if !pubs.isEmpty { tick["pubs"] = pubs }
        let notifTotal = counts.notifs.values.reduce(0, +)
        tick["notif_total"] = notifTotal
        if notifTotal >= 40 {
            tick["notifs"] = Dictionary(uniqueKeysWithValues: counts.notifs.sorted { $0.value > $1.value }.prefix(8).map { ($0.key, $0.value) })
        }
        let topThreads = hot.filter { $0.pct >= 10 }.sorted { $0.pct > $1.pct }.prefix(4)
        if !topThreads.isEmpty {
            tick["hot_threads"] = topThreads.map { ["name": $0.name, "cpu": round1($0.pct)] as [String: Any] }
        }
        diagnostics.emit("tick", tick)

        // Background CPU hogs: sample where they are right now.
        if cpuPct >= 40 {
            for thread in topThreads.prefix(2) where thread.pct >= 20 {
                sampleBackground(thread: thread.port, name: thread.name, pct: thread.pct)
            }
        }

        let thermal = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        if thermal != lastThermal || lowPower != lastLowPower {
            diagnostics.emit("power", ["thermal": thermal.rawValue, "low_power": lowPower])
            lastThermal = thermal
            lastLowPower = lowPower
        }
    }

    private func sampleBackground(thread port: mach_port_t, name: String, pct: Double) {
        guard let pthread = pthread_from_mach_thread_np(port) else { return }
        let target = StackSampler.Target(pthread: pthread)
        let n = StackSampler.captureRaw(of: target, into: buffer, capacity: StackSampler.maxFrames)
        guard n > 0 else { return }
        let frames = symbolicator.resolve(UnsafeBufferPointer(start: buffer, count: n))
        diagnostics?.emit("bgstack", ["thread": name, "cpu": round1(pct), "frames": frames])
    }

    // MARK: - Mach helpers

    private struct ThreadInfo {
        let port: mach_port_t
        let cpuSeconds: Double
        let name: String
    }

    private static func threadSnapshot() -> [ThreadInfo] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        }
        var out: [ThreadInfo] = []
        for i in 0..<Int(count) {
            let port = list[i]
            defer { mach_port_deallocate(mach_task_self_, port) }
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard kr == KERN_SUCCESS else { continue }
            let cpu = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
                + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
            var name = "thread-\(port)"
            if let pt = pthread_from_mach_thread_np(port) {
                var buf = [CChar](repeating: 0, count: 64)
                if pthread_getname_np(pt, &buf, buf.count) == 0, buf[0] != 0 { name = String(cString: buf) }
            }
            out.append(ThreadInfo(port: port, cpuSeconds: cpu, name: name))
        }
        return out
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    private static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
