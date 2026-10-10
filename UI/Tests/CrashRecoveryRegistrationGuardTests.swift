import XCTest
import CrashRecoverySupport

/// Guards around `SMAppService.register()`, built on real temporary `.app` bundles.
///
/// History: Retrace crashed inside ServiceManagement's `_load_plist_from_bundle` (NULL strlen, uncatchable) on
/// 2026-10-07, and its helper was killed at launch ("Launch Constraint Violation") after a dev rebuild because the
/// registration refresh keyed only on `CFBundleVersion`, which never changes between dev builds.
final class CrashRecoveryRegistrationGuardTests: XCTestCase {
    private var root: URL!
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RegGuard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "RegGuardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Fake bundle

    private func makeBundle(helper: Bool = true, executable: Bool = true, plist: [String: Any]? = nil, writePlist: Bool = true, version: String = "11") throws -> Bundle {
        let app = root.appendingPathComponent("Retrace.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Library/Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Library/LaunchAgents"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "io.retrace.test", "CFBundleVersion": version, "CFBundleExecutable": "Retrace"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        if helper {
            let url = contents.appendingPathComponent("Library/Helpers/RetraceCrashRecoveryHelper")
            try Data(repeating: 0x7F, count: 4096).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
        if writePlist {
            let body = plist ?? ["Label": "io.retrace.app.crash-recovery", "BundleProgram": CrashRecoverySupport.helperBundleRelativePath]
            try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Library/LaunchAgents").appendingPathComponent(CrashRecoverySupport.launchAgentPlistName))
        }
        return try XCTUnwrap(Bundle(url: app))
    }

    private func thrown(_ bundle: Bundle) -> CrashRecoverySupport.RegistrationGuardError? {
        do { try CrashRecoverySupport.preflightLaunchAgentRegistration(bundle: bundle); return nil }
        catch { return error as? CrashRecoverySupport.RegistrationGuardError }
    }

    // MARK: - Preflight

    func testPreflightAcceptsACompleteBundle() throws {
        XCTAssertNil(thrown(try makeBundle()))
    }

    func testPreflightRefusesEveryShapeThatWouldMakeServiceManagementReadNothing() throws {
        XCTAssertEqual(thrown(try makeBundle(writePlist: false)).map(String.init(describing:))?.hasPrefix("launchAgentPlistMissing"), true)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Retrace.app"))
        XCTAssertEqual(thrown(try makeBundle(plist: ["Label": "x"])).map(String.init(describing:))?.hasPrefix("launchAgentPlistInvalid"), true, "missing BundleProgram")
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Retrace.app"))
        XCTAssertEqual(thrown(try makeBundle(plist: ["BundleProgram": "x"])).map(String.init(describing:))?.hasPrefix("launchAgentPlistInvalid"), true, "missing Label")
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Retrace.app"))
        XCTAssertEqual(thrown(try makeBundle(helper: false)).map(String.init(describing:))?.hasPrefix("helperMissing"), true)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("Retrace.app"))
        XCTAssertEqual(thrown(try makeBundle(executable: false)).map(String.init(describing:))?.hasPrefix("helperNotExecutable"), true)
    }

    func testPreflightRefusesABundleThatIsNotAnApp() throws {
        let notApp = root.appendingPathComponent("Plain")
        try FileManager.default.createDirectory(at: notApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "x"], format: .xml, options: 0).write(to: notApp.appendingPathComponent("Contents/Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: notApp))
        if case .notAnAppBundle? = thrown(bundle) {} else { XCTFail("an unbundled build (dev run outside .app) must not reach register()") }
    }

    // MARK: - Build identity follows the helper binary

    func testRebuildingTheHelperAtTheSameVersionChangesTheBuildIdentityAndForcesARefresh() throws {
        let bundle = try makeBundle()
        let before = CrashRecoverySupport.currentBuildIdentifier(bundle: bundle)
        XCTAssertTrue(before.hasPrefix("11+"), before)

        // A dev rebuild: same CFBundleVersion, helper re-copied and re-signed (different size/mtime).
        let helper = bundle.bundleURL.appendingPathComponent(CrashRecoverySupport.helperBundleRelativePath)
        try Data(repeating: 0x7F, count: 5120).write(to: helper)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: helper.path)
        let after = CrashRecoverySupport.currentBuildIdentifier(bundle: bundle)
        XCTAssertNotEqual(before, after)

        XCTAssertTrue(CrashRecoverySupport.shouldRefreshRegistration(
            storedBuild: before, currentBuild: after,
            storedLaunchTargetPath: bundle.bundlePath, currentLaunchTargetPath: bundle.bundlePath, status: .enabled),
            "an enabled registration for the old helper binary must be refreshed")
        XCTAssertFalse(CrashRecoverySupport.shouldRefreshRegistration(
            storedBuild: after, currentBuild: after,
            storedLaunchTargetPath: bundle.bundlePath, currentLaunchTargetPath: bundle.bundlePath, status: .enabled))
    }

    func testBuildIdentityFallsBackToTheVersionWhenThereIsNoHelper() throws {
        XCTAssertEqual(CrashRecoverySupport.currentBuildIdentifier(bundle: try makeBundle(helper: false, version: "12")), "12")
    }

    // MARK: - Crash-loop quarantine

    func testAttemptThatNeverFinishedQuarantinesThatBuildButNotOthersOrLaterDays() throws {
        let now: Int64 = 1_800_000_000
        try CrashRecoverySupport.beginRegistrationAttempt(build: "11+a", nowEpochSeconds: now, defaults: defaults)

        // The process "died" (no endRegistrationAttempt). Next launch, same build:
        XCTAssertThrowsError(try CrashRecoverySupport.beginRegistrationAttempt(build: "11+a", nowEpochSeconds: now + 60, defaults: defaults)) { error in
            XCTAssertEqual(error as? CrashRecoverySupport.RegistrationGuardError, .quarantined(build: "11+a", sinceEpochSeconds: now))
        }
        // A new build gets a fresh attempt (and replaces the marker).
        XCTAssertNoThrow(try CrashRecoverySupport.beginRegistrationAttempt(build: "11+b", nowEpochSeconds: now + 120, defaults: defaults))
        // The old build is retried after the quarantine window.
        CrashRecoverySupport.endRegistrationAttempt(defaults: defaults)
        try CrashRecoverySupport.beginRegistrationAttempt(build: "11+a", nowEpochSeconds: now, defaults: defaults)
        XCTAssertNoThrow(try CrashRecoverySupport.beginRegistrationAttempt(
            build: "11+a", nowEpochSeconds: now + CrashRecoverySupport.registrationQuarantineSeconds + 1, defaults: defaults))
    }

    func testFinishedAttemptLeavesNoMarker() throws {
        try CrashRecoverySupport.beginRegistrationAttempt(build: "11+a", nowEpochSeconds: 100, defaults: defaults)
        CrashRecoverySupport.endRegistrationAttempt(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: CrashRecoverySupport.registrationAttemptKey))
        XCTAssertNoThrow(try CrashRecoverySupport.beginRegistrationAttempt(build: "11+a", nowEpochSeconds: 101, defaults: defaults))
    }
}
