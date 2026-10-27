import Foundation

/// Buffered JSONL writer for the UI diagnostics trace.
///
/// Deliberately independent of `Log.*`: that path does os.log + print + a synchronous lock-guarded file
/// write on the caller's thread, which at trace volume would itself cause the hitches we're hunting.
/// Callers hand over a dictionary; JSON encoding, file I/O and flushing all happen on a private
/// utility-QoS queue.
final class UITraceWriter: @unchecked Sendable {
    static let maxFileBytes: Int64 = 150 * 1024 * 1024

    private final class Box: @unchecked Sendable {
        let value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }

    let fileURL: URL
    private let queue = DispatchQueue(label: "io.retrace.ui-trace-writer", qos: .utility)
    private var handle: FileHandle?
    private var buffer = Data()
    private var bytesWritten: Int64 = 0
    private var truncated = false
    private var flushTimer: DispatchSourceTimer?

    init(fileURL: URL) {
        self.fileURL = fileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep exactly one previous session around so a relaunch doesn't destroy the trace being analysed.
        let prev = fileURL.deletingPathExtension().appendingPathExtension("prev.jsonl")
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: prev)
            try? fm.moveItem(at: fileURL, to: prev)
        }
        fm.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        buffer.reserveCapacity(256 * 1024)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.flushLocked() }
        timer.resume()
        flushTimer = timer
    }

    /// Enqueue one record. Safe from any thread (including a suspended-main sampler once it has resumed main).
    func write(_ record: [String: Any]) {
        let box = Box(record)
        queue.async { [weak self] in self?.append(box.value) }
    }

    /// Blocks until everything enqueued so far is on disk. Only for termination/tests, never UI paths.
    func flushSync() {
        queue.sync { flushLocked() }
    }

    private func append(_ record: [String: Any]) {
        guard !truncated else { return }
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        buffer.append(data)
        buffer.append(0x0A)
        if buffer.count >= 192 * 1024 { flushLocked() }
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        if bytesWritten + Int64(buffer.count) > Self.maxFileBytes {
            truncated = true
            let marker = "{\"k\":\"truncated\",\"reason\":\"max file size reached\"}\n"
            try? handle?.write(contentsOf: Data(marker.utf8))
            buffer.removeAll(keepingCapacity: true)
            return
        }
        try? handle?.write(contentsOf: buffer)
        bytesWritten += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }
}
