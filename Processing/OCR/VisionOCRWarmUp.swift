import Foundation
import Vision
import CoreGraphics
import CoreText
import Shared

/// Single-flight, per-process warm-up gate for Vision's `.accurate` text model.
///
/// Why this exists: the first `.accurate` recognition after a new binary is
/// installed (or after the on-device model cache is purged) has to compile the
/// text-recognition model for the Neural Engine. That compile runs in the system
/// `ANECompilerService`, which handles requests serially and takes tens of seconds
/// -- measured at 41-45s uncontended, longer when abandoned compiles are queued
/// ahead of it. `VisionOCR`'s normal 20s watchdog is shorter than that, so a cold
/// start looked like a wedged Vision: the request was cancelled, the 2-strike circuit
/// breaker tripped, and "Restart OCR"/relaunch only started another doomed compile
/// (the compile never completes into the cache because it's abandoned each time).
/// Meanwhile the OCR queue backed up to `maxQueueSize` and shed its oldest frames.
///
/// This gate lets exactly one request absorb the cold start, with a long budget and
/// without ever calling `request.cancel()`, while every other caller suspends on the
/// same outcome (suspended tasks, not blocked threads). Warm-up outcomes never count
/// toward the circuit breaker; the normal watchdog and breaker apply only once the
/// model is warm, where a timeout really does mean a genuine hang.
final class VisionOCRWarmUp: @unchecked Sendable {
    enum Outcome: Sendable, Equatable {
        case warm
        case failed
    }

    private enum Entry {
        case warming(Task<Outcome, Never>)
        case finished(Outcome)
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Bumped by `reset()` so a probe that was in flight when the gate was reset can't
    /// write its (stale) outcome into the fresh state.
    private var generation = 0

    /// Whether any warm-up probe is currently in flight.
    var isWarming: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.contains { entry in
            if case .warming = entry { return true }
            return false
        }
    }

    /// Returns once the model identified by `key` is warm, running `probe` if this is
    /// the first caller. Concurrent callers share the single in-flight probe; later
    /// callers get the recorded outcome immediately.
    func ensureWarm(
        key: String,
        probe: @escaping @Sendable () async -> Outcome
    ) async -> Outcome {
        switch claim(key: key, probe: probe) {
        case .finished(let outcome):
            return outcome
        case .warming(let task):
            return await task.value
        }
    }

    /// Synchronous so the lock is never held across (or taken from) an async context.
    private func claim(
        key: String,
        probe: @escaping @Sendable () async -> Outcome
    ) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key] { return entry }
        let startedGeneration = generation
        let task = Task { [self] in
            let outcome = await probe()
            finish(key: key, generation: startedGeneration, outcome: outcome)
            return outcome
        }
        let entry = Entry.warming(task)
        entries[key] = entry
        return entry
    }

    /// Forgets every recorded outcome so the next caller runs a fresh probe. Called when
    /// the circuit breaker is reset: a wedged or restarted Vision may need to recompile.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        entries.removeAll()
    }

    private func finish(key: String, generation startedGeneration: Int, outcome: Outcome) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == startedGeneration else { return }
        entries[key] = .finished(outcome)
    }
}

// MARK: - Probe

extension VisionOCR {
    /// Upper bound for a cold `.accurate` compile. Generous on purpose: waiting workers
    /// are suspended (not blocked), so a long budget costs nothing but latency, while a
    /// short one is exactly the failure this gate exists to prevent.
    static let warmUpTimeoutSeconds: TimeInterval = 600

    static let accurateWarmUp = VisionOCRWarmUp()

    /// Ensures the `.accurate` model for `languages` is compiled and ready. Returns
    /// `.failed` only if the warm-up probe itself errored or exceeded its budget, in
    /// which case the circuit breaker has already been tripped so callers stop issuing
    /// Vision calls that would each leak a thread.
    static func ensureAccurateModelWarm(
        languages: [String],
        usesLanguageCorrection: Bool
    ) async -> VisionOCRWarmUp.Outcome {
        await accurateWarmUp.ensureWarm(key: languages.joined(separator: ",")) {
            await runWarmUpProbe(languages: languages, usesLanguageCorrection: usesLanguageCorrection)
        }
    }

    private static func runWarmUpProbe(
        languages: [String],
        usesLanguageCorrection: Bool
    ) async -> VisionOCRWarmUp.Outcome {
        guard let image = makeWarmUpImage() else {
            // Can't build the probe image: don't block OCR on it. The regular watchdog
            // still protects real requests.
            Log.warning("[VisionOCR] Could not render warm-up image; skipping accurate-model warm-up", category: .processing)
            return .warm
        }

        Log.info(
            "[VisionOCR] Accurate-model warm-up started (cold start compiles the on-device text model; "
                + "can take up to \(Int(warmUpTimeoutSeconds))s). Other OCR requests wait for it.",
            category: .processing
        )
        let startedAt = Date()

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = usesLanguageCorrection
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let error: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let resumeGuard = WatchdogResumeGuard()
            // Timeout is scheduled off the work queue for the same reason as in
            // performWithWatchdog, and deliberately does NOT cancel the request: cancelling
            // an in-flight compile is what kept it from ever reaching the cache.
            let timeoutWorkItem = DispatchWorkItem {
                resumeGuard.fireOnce {
                    continuation.resume(returning: "timed out after \(Int(warmUpTimeoutSeconds))s")
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + warmUpTimeoutSeconds, execute: timeoutWorkItem)

            DispatchQueue(label: "processing.ocr.vision_warmup", qos: .utility).async {
                do {
                    try autoreleasepool { try handler.perform([request]) }
                    timeoutWorkItem.cancel()
                    resumeGuard.fireOnce { continuation.resume(returning: nil) }
                } catch {
                    timeoutWorkItem.cancel()
                    resumeGuard.fireOnce { continuation.resume(returning: error.localizedDescription) }
                }
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        guard let error else {
            Log.info(
                "[VisionOCR] Accurate-model warm-up completed in \(String(format: "%.1f", elapsed))s",
                category: .processing
            )
            return .warm
        }

        circuitBreaker.trip()
        Log.error(
            "[VisionOCR] Accurate-model warm-up failed after \(String(format: "%.1f", elapsed))s (\(error)) -- "
                + "OCR is paused; use Restart OCR to retry.",
            category: .processing
        )
        return .failed
    }

    /// Small image with real text, so the probe exercises the same detector + recognizer
    /// models as production frames rather than short-circuiting on a blank image.
    static func makeWarmUpImage() -> CGImage? {
        let width = 960
        let height = 240
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Retrace OCR warm-up 0123456789", attributes: attributes)
        )
        context.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
