import XCTest
import Darwin
@testable import Retrace

/// Spins in a known, non-inlined function so the sampler has something specific to find.
@inline(never)
func uiDiagnosticsTestBusyLoop(_ stop: UnsafeMutablePointer<Int32>) -> Int {
    var x = 0
    while stop.pointee == 0 { x &+= 1 }
    return x
}

final class UIDiagnosticsTests: XCTestCase {
    func testStackSamplerFindsKnownFunctionOnAnotherThread() throws {
        let stop = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        stop.initialize(to: 0)
        defer { stop.deallocate() }

        let ready = expectation(description: "worker started")
        var threadRef: pthread_t?
        let worker = Thread {
            threadRef = pthread_self()
            ready.fulfill()
            _ = uiDiagnosticsTestBusyLoop(stop)
        }
        worker.start()
        wait(for: [ready], timeout: 5)
        usleep(50_000)
        let target = StackSampler.Target(pthread: try XCTUnwrap(threadRef))

        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: StackSampler.maxFrames)
        defer { buffer.deallocate() }
        let symbolicator = StackSampler.Symbolicator()

        var sawFunction = false
        for _ in 0..<20 where !sawFunction {
            let n = StackSampler.captureRaw(of: target, into: buffer, capacity: StackSampler.maxFrames)
            XCTAssertGreaterThan(n, 0, "sampling a running thread must produce frames")
            let frames = symbolicator.resolve(UnsafeBufferPointer(start: buffer, count: n))
            sawFunction = frames.contains { $0.contains("uiDiagnosticsTestBusyLoop") }
        }
        stop.pointee = 1
        XCTAssertTrue(sawFunction, "expected the busy-loop function in the sampled stack")
    }

    func testTraceWriterProducesValidJSONLAndKeepsPreviousSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ui-trace-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ui-trace.jsonl")

        let first = UITraceWriter(fileURL: url)
        first.write(["k": "a", "t": 1.5])
        first.flushSync()

        let second = UITraceWriter(fileURL: url)
        second.write(["k": "hitch", "ms": 42.0, "frames": ["Retrace foo+1"]])
        second.write(["k": "tick", "renders": ["X": 3]])
        second.flushSync()

        let lines = try String(contentsOf: url).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(obj?["k"])
        }
        let prev = dir.appendingPathComponent("ui-trace.prev.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prev.path), "previous session should be preserved")
    }
}
