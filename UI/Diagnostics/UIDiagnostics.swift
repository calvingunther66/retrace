import AppKit
import Combine
import Foundation
import MachO
import os
import Shared

/// Deep UI diagnostics: a high-resolution trace of main-thread run-loop hitches (with sampled stacks),
/// input events, window/app lifecycle, `ObservableObject` publish rates, SwiftUI body-evaluation counts and
/// per-second process/thread load, written as JSONL to `~/Library/Logs/Retrace/ui-trace.jsonl`.
///
/// Off by default. Enable with `scripts/retracectl.sh diag-on` (sets `RetraceUIDiagnostics` in the
/// `io.retrace.app` defaults domain) or `RETRACE_UI_DIAGNOSTICS=1`. The flag is read once at launch, so
/// when disabled every entry point below is a single branch on a cached static.
///
/// Privacy: key events record key codes and modifier flags, never characters. Window titles are only read
/// from Retrace's own windows.
final class UIDiagnostics: @unchecked Sendable {
    static let shared = UIDiagnostics()
    static let defaultsKey = "RetraceUIDiagnostics"
    static let environmentKey = "RETRACE_UI_DIAGNOSTICS"
    static let traceURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Retrace/ui-trace.jsonl")

    static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment[environmentKey] == "1" { return true }
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.bool(forKey: defaultsKey)
    }()

    private struct Counters {
        var renders: [String: Int] = [:]
        var pubs: [String: Int] = [:]
        var notifs: [String: Int] = [:]
        var pubSampleBudget: [String: Int] = [:]
    }

    struct LastInput {
        var uptimeNanos: UInt64 = 0
        var description: String = ""
    }

    private struct Subscription {
        weak var object: AnyObject?
        let cancellable: AnyCancellable
    }

    private let startNanos = DispatchTime.now().uptimeNanoseconds
    private let writer = OSAllocatedUnfairLock<UITraceWriter?>(initialState: nil)
    private let counters = OSAllocatedUnfairLock(initialState: Counters())
    private let lastInputState = OSAllocatedUnfairLock(initialState: LastInput())
    private let subscriptions = OSAllocatedUnfairLock(initialState: [Subscription]())
    private var started = false
    private var lastMarkNanos: UInt64 = 0

    private var hitchMonitor: HitchMonitor?
    private var breadcrumbs: UIBreadcrumbs?
    private var processSampler: ProcessSampler?

    var hitchMonitorForSampler: HitchMonitor? { hitchMonitor }

    private init() {}

    // MARK: - Lifecycle

    /// Call once, on the main thread, as early as possible in launch.
    func startIfEnabled() {
        guard Self.isEnabled, !started else { return }
        precondition(Thread.isMainThread, "UIDiagnostics.startIfEnabled must run on the main thread")
        started = true

        writer.withLock { $0 = UITraceWriter(fileURL: Self.traceURL) }
        let info = ProcessInfo.processInfo
        emit("session", [
            "wall0": Date().timeIntervalSince1970,
            "pid": Int(info.processIdentifier),
            "bundle": Bundle.main.bundleIdentifier ?? "?",
            "version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
            "build": (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?",
            "os": info.operatingSystemVersionString,
            "cores": info.activeProcessorCount,
            "ram_gb": Int(info.physicalMemory / 1_073_741_824),
            "exe": Bundle.main.executablePath ?? "?",
            "images": Self.loadedImages(),
        ])

        let hitch = HitchMonitor(diagnostics: self)
        hitch.start()
        hitchMonitor = hitch

        let crumbs = UIBreadcrumbs(diagnostics: self)
        crumbs.start()
        breadcrumbs = crumbs

        let sampler = ProcessSampler(diagnostics: self)
        sampler.start()
        processSampler = sampler

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.emit("terminate")
            self?.writer.withLock { $0 }?.flushSync()
        }
        Log.info("[UIDiagnostics] tracing to \(Self.traceURL.path) (mark an issue with ⌃⌥⌘M)", category: .ui)
    }

    // MARK: - Emission

    func elapsedMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000
    }

    /// Thread-safe. `fields` must be JSON-encodable (String/Int/Double/Bool/arrays/dictionaries of those).
    func emit(_ kind: String, _ fields: [String: Any] = [:]) {
        guard let w = writer.withLock({ $0 }) else { return }
        var record = fields
        record["k"] = kind
        record["t"] = (elapsedMs() * 100).rounded() / 100
        record["w"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        if !Thread.isMainThread { record["bg"] = 1 }
        w.write(record)
    }

    // MARK: - Markers

    /// Drops a MARK record (with a snapshot of Retrace's windows) so the analyzer can pull the trace around it.
    func mark(note: String? = nil) {
        guard Self.isEnabled else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.mark(note: note) }
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastMarkNanos < 500_000_000 { return }
        lastMarkNanos = now
        var fields: [String: Any] = ["windows": NSApp.windows.map(Self.describe(window:))]
        if let note { fields["note"] = note }
        if let input = lastInput() { fields["last_input"] = input }
        emit("mark", fields)
        NSSound(named: NSSound.Name("Tink"))?.play()
        Log.info("[UIDiagnostics] MARK recorded at t=\(Int(elapsedMs()))ms", category: .ui)
    }

    // MARK: - Counters

    /// Call from a SwiftUI `body` (`let _ = UIDiagnostics.render("Name")`) to count body evaluations per second.
    @inline(__always)
    static func render(_ name: String) {
        guard isEnabled else { return }
        shared.counters.withLock { $0.renders[name, default: 0] += 1 }
    }

    func countNotification(_ name: String) {
        counters.withLock { $0.notifs[name, default: 0] += 1 }
    }

    /// Watches an `ObservableObject`'s `objectWillChange` rate. For the first two publishes per second the
    /// publishing call stack is captured, which names the `@Published` setter responsible.
    func observe<O: ObservableObject>(_ object: O, name: String)
    where O.ObjectWillChangePublisher == ObservableObjectPublisher {
        guard Self.isEnabled else { return }
        let cancellable = object.objectWillChange.sink { [weak self] _ in
            self?.recordPublish(name)
        }
        subscriptions.withLock { subs in
            subs.removeAll { $0.object == nil }
            subs.append(Subscription(object: object, cancellable: cancellable))
        }
    }

    private func recordPublish(_ name: String) {
        let shouldSample: Bool = counters.withLock { c in
            c.pubs[name, default: 0] += 1
            let used = c.pubSampleBudget[name, default: 0]
            guard used < 2 else { return false }
            c.pubSampleBudget[name] = used + 1
            return true
        }
        guard shouldSample else { return }
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(18).map { String($0) }
        emit("pubsrc", ["vm": name, "frames": Array(frames)])
    }

    /// Per-second drain used by `ProcessSampler`. Resets counters and sample budgets.
    func drainCounters() -> (renders: [String: Int], pubs: [String: Int], notifs: [String: Int]) {
        counters.withLock { c in
            let out = (c.renders, c.pubs, c.notifs)
            c = Counters()
            return out
        }
    }

    // MARK: - Input context

    func noteInput(_ description: String) {
        lastInputState.withLock {
            $0.uptimeNanos = DispatchTime.now().uptimeNanoseconds
            $0.description = description
        }
    }

    /// "leftMouseDown view=… (123ms ago)" if an input event happened in the last 1.5s.
    func lastInput(within seconds: Double = 1.5) -> String? {
        let snapshot = lastInputState.withLock { $0 }
        guard snapshot.uptimeNanos != 0 else { return nil }
        let ageMs = Double(DispatchTime.now().uptimeNanoseconds &- snapshot.uptimeNanos) / 1_000_000
        guard ageMs <= seconds * 1000 else { return nil }
        return "\(snapshot.description) (\(Int(ageMs))ms ago)"
    }

    // MARK: - Descriptions

    static func describe(window: NSWindow) -> [String: Any] {
        [
            "class": String(describing: type(of: window)),
            "title": window.title,
            "frame": NSStringFromRect(window.frame),
            "level": window.level.rawValue,
            "visible": window.isVisible,
            "key": window.isKeyWindow,
            "main": window.isMainWindow,
            "occluded": !window.occlusionState.contains(.visible),
            "screen": window.screen?.localizedName ?? "none",
        ]
    }

    /// Name + load address of every dyld image, so the analyzer can attribute raw addresses.
    private static func loadedImages() -> [[String: Any]] {
        (0..<_dyld_image_count()).compactMap { index in
            guard let name = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) else { return nil }
            let path = String(cString: name)
            guard !path.hasPrefix("/System/") && !path.hasPrefix("/usr/lib/") || index == 0 else { return nil }
            return [
                "name": (path as NSString).lastPathComponent,
                "base": String(UInt(bitPattern: header), radix: 16),
                "slide": Int(_dyld_get_image_vmaddr_slide(index)),
            ]
        }
    }
}
