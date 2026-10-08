import Foundation
import Shared

/// Writes the state/result of an Ask-AI run (started via `retrace://ask`) to
/// `<storage root>/ai_ask_last.json`, so command-line tooling (`scripts/retracectl.sh ask`) can read the answer
/// back without screen-scraping the UI. Only runs started by the deeplink are exported.
enum AIAskResultExport {
    static var fileURL: URL {
        URL(fileURLWithPath: AppPaths.expandedStorageRoot).appendingPathComponent("ai_ask_last.json")
    }

    /// Opt-in switch for the `retrace://ask` deeplink. Off by default so an arbitrary web page that opens a
    /// retrace:// URL cannot make Retrace query the user's AI provider.
    static let enabledDefaultsKey = "allowAskDeeplink"
    static var isDeeplinkEnabled: Bool { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }

    static func write(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
