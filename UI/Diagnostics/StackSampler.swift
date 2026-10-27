import Foundation
import Darwin
import MachO

/// Captures the call stack of *another* thread by suspending it and walking the arm64 frame-pointer chain.
///
/// Deadlock rules while the target is suspended (it may hold the malloc lock, the dyld lock, or any Swift
/// runtime lock): no allocation, no locks, no logging, no Swift collections, no `dladdr`. The raw capture
/// only reads registers and stack memory into a caller-owned fixed buffer; resolution to symbol names
/// happens afterwards, once the thread has been resumed.
enum StackSampler {
    static let maxFrames = 96

    /// What's needed to walk a thread's stack. Computed once up-front (allocates) so the capture itself doesn't.
    struct Target {
        let port: mach_port_t
        let stackLow: UInt
        let stackHigh: UInt

        /// Target for the *calling* thread (call this from the thread you'll later sample, e.g. main at launch).
        static func currentThread() -> Target {
            Target(pthread: pthread_self())
        }

        init(pthread: pthread_t) {
            self.port = pthread_mach_thread_np(pthread)
            let high = UInt(bitPattern: pthread_get_stackaddr_np(pthread))
            let size = UInt(pthread_get_stacksize_np(pthread))
            self.stackHigh = high
            self.stackLow = high &- size
        }
    }

    private static let addressMask: UInt = 0x0000_7FFF_FFFF_FFFF

    /// Suspends `target`, records up to `capacity` return addresses (innermost first) into `buffer`, resumes it.
    /// Returns the number of frames written (0 on failure). Apple Silicon only.
    static func captureRaw(
        of target: Target,
        into buffer: UnsafeMutablePointer<UInt>,
        capacity: Int
    ) -> Int {
        #if arch(arm64)
        let port = target.port
        let lo = target.stackLow
        let hi = target.stackHigh
        let mask = addressMask
        let stateWords = MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size

        guard thread_suspend(port) == KERN_SUCCESS else { return 0 }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(stateWords)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &state) { statePtr in
            statePtr.withMemoryRebound(to: natural_t.self, capacity: stateWords) { raw in
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), raw, &count)
            }
        }

        var n = 0
        if kr == KERN_SUCCESS {
            let pc = UInt(state.__pc) & mask
            let lr = UInt(state.__lr) & mask
            let sp = UInt(state.__sp)
            var fp = UInt(state.__fp)

            if capacity > 0 { buffer[0] = pc; n = 1 }

            // Walk the frame chain: each frame record is [previous fp, return address].
            var firstReturn: UInt = 0
            var haveFirst = false
            while n < capacity,
                  fp >= sp, fp >= lo, fp &+ 16 <= hi, fp & 0xF == 0,
                  let record = UnsafePointer<UInt>(bitPattern: fp) {
                let next = record[0]
                let ret = record[1] & mask
                if ret == 0 { break }
                if !haveFirst {
                    haveFirst = true
                    firstReturn = ret
                    // The leaf may not have built a frame yet (prologue / frameless leaf): then LR is the
                    // true caller and the chain starts one level too high. Include LR when it differs.
                    if lr != 0, lr != ret, n < capacity { buffer[n] = lr; n += 1 }
                }
                if n < capacity { buffer[n] = ret; n += 1 }
                if next <= fp { break }
                fp = next
            }
            if !haveFirst, lr != 0, n < capacity { buffer[n] = lr; n += 1 }
            _ = firstReturn
        }

        thread_resume(port)
        return n
        #else
        return 0
        #endif
    }

    // MARK: - Symbolication (only call with the sampled thread running)

    /// Resolves raw addresses to `"Image symbol+offset"` strings via dladdr.
    /// Frames past the first are return addresses, so they're looked up at pc-1 to land inside the caller.
    final class Symbolicator {
        private var cache: [UInt: String] = [:]

        func resolve(_ pcs: UnsafeBufferPointer<UInt>) -> [String] {
            var out: [String] = []
            out.reserveCapacity(pcs.count)
            for (i, pc) in pcs.enumerated() {
                let lookup = i == 0 ? pc : pc &- 1
                if let hit = cache[lookup] { out.append(hit); continue }
                let text = Self.describe(lookup)
                if cache.count > 40_000 { cache.removeAll(keepingCapacity: true) }
                cache[lookup] = text
                out.append(text)
            }
            return out
        }

        private static func describe(_ address: UInt) -> String {
            guard let ptr = UnsafeRawPointer(bitPattern: address) else { return "?" }
            var info = Dl_info()
            guard dladdr(ptr, &info) != 0 else { return String(format: "0x%lx", address) }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let base = UInt(bitPattern: info.dli_fbase)
            if let sname = info.dli_sname {
                let offset = address &- UInt(bitPattern: info.dli_saddr)
                return "\(image) \(String(cString: sname))+\(offset)"
            }
            return "\(image) +0x\(String(address &- base, radix: 16))"
        }
    }
}
