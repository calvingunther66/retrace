import XCTest
import Shared
@testable import App

final class LoggingSystemTests: XCTestCase {

    func testErrorContextWithRetraceError() {
        let error = StorageError.fileWriteFailed(path: "/tmp/test.mp4", underlying: "Permission denied")
        let ctx = Log.ErrorContext(from: error)

        XCTAssertEqual(ctx.errorCode, "STORAGE_002")
        XCTAssertTrue(ctx.typeName.contains("StorageError"))
        XCTAssertTrue(ctx.logLine.contains("code=STORAGE_002"))
        XCTAssertTrue(ctx.logLine.contains("type="))
    }

    func testErrorContextWithCustomRetraceError() {
        let error = TranscriptionError.modelLoadFailed("Corrupt weight file")
        let ctx = Log.ErrorContext(from: error)

        XCTAssertEqual(ctx.errorCode, "TRANSCRIPTION_003")
        XCTAssertTrue(ctx.typeName.contains("TranscriptionError"))
        XCTAssertTrue(ctx.logLine.contains("code=TRANSCRIPTION_003"))
    }

    func testErrorContextWithAppLifecycleError() {
        let error = AppLifecycleError.serviceNotReady
        let ctx = Log.ErrorContext(from: error)

        XCTAssertEqual(ctx.errorCode, "LIFECYCLE_002")
        XCTAssertTrue(ctx.typeName.contains("AppLifecycleError"))
        XCTAssertTrue(ctx.logLine.contains("code=LIFECYCLE_002"))
    }

    func testErrorContextWithGenericError() {
        enum SimpleError: Error {
            case somethingFailed
        }

        let error = SimpleError.somethingFailed
        let ctx = Log.ErrorContext(from: error)

        XCTAssertNil(ctx.errorCode)
        XCTAssertTrue(ctx.typeName.contains("SimpleError"))
        XCTAssertFalse(ctx.logLine.contains("code="))
    }

    func testErrorFrequencyGuardThresholding() {
        let guard_ = ErrorFrequencyGuard(key: "test.frequency.guard", summaryInterval: 3600)
        XCTAssertEqual(guard_.occurrenceCount, 0)

        // First occurrence
        guard_.log("Occurrence 1", category: .app)
        XCTAssertEqual(guard_.occurrenceCount, 1)

        // Occurrences 2-9
        for i in 2...9 {
            guard_.log("Occurrence \(i)", category: .app)
        }
        XCTAssertEqual(guard_.occurrenceCount, 9)

        // 10th occurrence should increment count to 10
        guard_.log("Occurrence 10", category: .app)
        XCTAssertEqual(guard_.occurrenceCount, 10)

        // Reset
        guard_.reset()
        XCTAssertEqual(guard_.occurrenceCount, 0)
    }

    func testAsyncTaskContextPropagation() async {
        XCTAssertNil(AsyncTaskContext.current)

        let traceID = AsyncTaskContext.makeTraceID()
        XCTAssertEqual(traceID.count, 8)

        await AsyncTaskContext.withContext(operationName: "unit_test_op", traceID: traceID) {
            let current = AsyncTaskContext.current
            XCTAssertNotNil(current)
            XCTAssertEqual(current?.operationName, "unit_test_op")
            XCTAssertEqual(current?.traceID, traceID)
            XCTAssertGreaterThanOrEqual(current?.elapsedMs ?? -1, 0)
        }

        XCTAssertNil(AsyncTaskContext.current)
    }

    func testCrashSignalHandlerInstallUninstall() {
        // Installing should not crash
        CrashSignalHandler.install()
        // Idempotent install
        CrashSignalHandler.install()
        // Uninstall
        CrashSignalHandler.uninstall()
    }

    func testLaunchDiagnosticReporterIdempotency() {
        // Multiple reports should execute without crash and remain idempotent
        LaunchDiagnosticReporter.report(databasePath: ":memory:")
        LaunchDiagnosticReporter.report(databasePath: ":memory:")
    }
}
