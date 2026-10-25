import Foundation

/// Case- and diacritic-insensitive substring matching for user-configured exclusion patterns.
///
/// Shared by capture-time redaction (`CGWindowListCapture`) and input-event logging
/// (`InputPrivacyPolicy`) so both surfaces agree on what "matches" means.
enum ExclusionPatternMatcher {

    static func hasContent(_ pattern: String) -> Bool {
        pattern.contains(where: { !$0.isWhitespace })
    }

    /// The first pattern (trimmed) that occurs in `value`, or nil. Empty values and blank patterns never match.
    static func firstMatch(in value: String, patterns: [String]) -> String? {
        guard !value.isEmpty else { return nil }
        for rawPattern in patterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard hasContent(pattern) else { continue }

            if value.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return pattern
            }
        }
        return nil
    }
}
