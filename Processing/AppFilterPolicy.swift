import Foundation

/// Decides whether a given app bundle ID is allowed to be processed, given the
/// user's OCR app-filter settings (inclusion or exclusion list).
///
/// Mirrors the exact logic in `FrameProcessingQueue.shouldProcessOCR`. Any consumer
/// that sends screen content to a third party (e.g. `SemanticIndexer` uploading
/// screenshots) must be constructed from the same `excludedBundleIDs`/`includedBundleIDs`
/// values `AppCoordinator` already computes for OCR, so app-exclusion settings can
/// never drift between the two pipelines.
public struct AppFilterPolicy: Sendable, Equatable {
    public let excludedBundleIDs: Set<String>
    public let includedBundleIDs: Set<String>

    public init(excludedBundleIDs: Set<String> = [], includedBundleIDs: Set<String> = []) {
        self.excludedBundleIDs = excludedBundleIDs
        self.includedBundleIDs = includedBundleIDs
    }

    /// No restrictions — every app is allowed.
    public static let allowAll = AppFilterPolicy()

    public func allows(bundleID: String?) -> Bool {
        guard let bundleID else { return true }

        // If inclusion list is set (onlyTheseApps mode), only process those apps.
        if !includedBundleIDs.isEmpty {
            return includedBundleIDs.contains(bundleID)
        }

        // Otherwise, process all except excluded apps.
        return !excludedBundleIDs.contains(bundleID)
    }
}
