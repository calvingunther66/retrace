import Foundation

/// App / URL / window-title / hidden-segment exclusions applied at export time.
///
/// Reads the same `[privacy]` table as the Retrace MCP server's `retrace_mcp.toml`
/// (`exclude_bundles`, `exclude_url_patterns`, `exclude_window_patterns`,
/// `exclude_hidden_segments`) so one list governs both surfaces. Matching mirrors the MCP SQL:
/// bundle ids match exactly; URL and window patterns are literal substrings, compared
/// case-insensitively (SQLite `LIKE` is case-insensitive for ASCII, and the exporter errs on the
/// broader, safer side).
public struct ExportDenyList: Sendable, Equatable {
    public var excludeBundles: Set<String>
    public var excludeURLPatterns: [String]
    public var excludeWindowPatterns: [String]
    public var excludeHiddenSegments: Bool

    public init(
        excludeBundles: Set<String> = [],
        excludeURLPatterns: [String] = [],
        excludeWindowPatterns: [String] = [],
        excludeHiddenSegments: Bool = true
    ) {
        self.excludeBundles = excludeBundles
        self.excludeURLPatterns = excludeURLPatterns
        self.excludeWindowPatterns = excludeWindowPatterns
        self.excludeHiddenSegments = excludeHiddenSegments
    }

    public enum Reason: String, Sendable, Equatable {
        case bundle
        case url
        case window
        case hidden
    }

    /// First rule the given context violates, or nil when it may be exported.
    public func violation(bundleIDs: [String?], urls: [String?], windowTitles: [String?], isHidden: Bool) -> Reason? {
        if excludeHiddenSegments, isHidden { return .hidden }
        for bundle in bundleIDs.compactMap({ $0 }) where excludeBundles.contains(bundle) { return .bundle }
        for url in urls.compactMap({ $0 }) where Self.matches(url, patterns: excludeURLPatterns) { return .url }
        for title in windowTitles.compactMap({ $0 }) where Self.matches(title, patterns: excludeWindowPatterns) { return .window }
        return nil
    }

    static func matches(_ value: String, patterns: [String]) -> Bool {
        guard !value.isEmpty else { return false }
        for pattern in patterns where !pattern.isEmpty {
            if value.range(of: pattern, options: [.caseInsensitive]) != nil { return true }
        }
        return false
    }

    /// Union of two lists (rules from both apply).
    public func merged(with other: ExportDenyList) -> ExportDenyList {
        ExportDenyList(
            excludeBundles: excludeBundles.union(other.excludeBundles),
            excludeURLPatterns: excludeURLPatterns + other.excludeURLPatterns.filter { !excludeURLPatterns.contains($0) },
            excludeWindowPatterns: excludeWindowPatterns + other.excludeWindowPatterns.filter { !excludeWindowPatterns.contains($0) },
            excludeHiddenSegments: excludeHiddenSegments || other.excludeHiddenSegments
        )
    }

    // MARK: - TOML

    public static func load(path: String) throws -> ExportDenyList {
        let expanded = NSString(string: path).expandingTildeInPath
        let text = try String(contentsOfFile: expanded, encoding: .utf8)
        return parse(toml: text)
    }

    /// Reads the `[privacy]` table. Unknown keys and tables are ignored. A missing
    /// `exclude_hidden_segments` defaults to true, like the MCP server.
    public static func parse(toml: String) -> ExportDenyList {
        var reader = TOMLReader(Array(toml.unicodeScalars))
        var list = ExportDenyList()
        var section = ""

        while let token = reader.nextStatement() {
            switch token {
            case .section(let name):
                section = name
            case .assignment(let key, let value):
                guard section == "privacy" else { continue }
                switch (key, value) {
                case ("exclude_bundles", .array(let items)): list.excludeBundles = Set(items)
                case ("exclude_url_patterns", .array(let items)): list.excludeURLPatterns = items
                case ("exclude_window_patterns", .array(let items)): list.excludeWindowPatterns = items
                case ("exclude_hidden_segments", .bool(let flag)): list.excludeHiddenSegments = flag
                default: break
                }
            }
        }
        return list
    }
}

/// Just enough TOML for the privacy table: `[section]`, `key = "string" | true | false | [ "a", ... ]`,
/// `#` comments (also inside arrays), multi-line arrays, trailing commas, `\"` escapes.
private struct TOMLReader {
    enum Value { case string(String), bool(Bool), array([String]), other }
    enum Statement { case section(String), assignment(String, Value) }

    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ scalars: [Unicode.Scalar]) {
        self.scalars = scalars
    }

    private var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    private mutating func skipSpaceAndComments(includingNewlines: Bool) {
        while let c = current {
            if c == "#" {
                while let d = current, d != "\n" { index += 1 }
            } else if c == "\n" || c == "\r" {
                if includingNewlines { index += 1 } else { return }
            } else if c == " " || c == "\t" {
                index += 1
            } else {
                return
            }
        }
    }

    private mutating func skipLine() {
        while let c = current, c != "\n" { index += 1 }
    }

    mutating func nextStatement() -> Statement? {
        while true {
            skipSpaceAndComments(includingNewlines: true)
            guard let c = current else { return nil }

            if c == "[" {
                index += 1
                var name = ""
                while let d = current, d != "]", d != "\n" { name.unicodeScalars.append(d); index += 1 }
                if current == "]" { index += 1 }
                skipLine()
                return .section(name.trimmingCharacters(in: .whitespaces))
            }

            var key = ""
            while let d = current, d != "=", d != "\n" { key.unicodeScalars.append(d); index += 1 }
            guard current == "=" else { skipLine(); continue }
            index += 1
            skipSpaceAndComments(includingNewlines: false)
            let value = readValue()
            skipLine()
            return .assignment(key.trimmingCharacters(in: .whitespaces), value)
        }
    }

    private mutating func readValue() -> Value {
        guard let c = current else { return .other }
        if c == "[" { return .array(readArray()) }
        if c == "\"" || c == "'" { return .string(readString()) }
        var word = ""
        while let d = current, d != "\n", d != "#", d != " ", d != "\t" { word.unicodeScalars.append(d); index += 1 }
        if word == "true" { return .bool(true) }
        if word == "false" { return .bool(false) }
        return .other
    }

    private mutating func readArray() -> [String] {
        index += 1  // [
        var items: [String] = []
        while true {
            skipSpaceAndComments(includingNewlines: true)
            guard let c = current else { return items }
            if c == "]" { index += 1; return items }
            if c == "," { index += 1; continue }
            if c == "\"" || c == "'" { items.append(readString()); continue }
            index += 1  // tolerate stray characters
        }
    }

    private mutating func readString() -> String {
        guard let quote = current else { return "" }
        index += 1
        var result = ""
        while let c = current {
            index += 1
            if c == quote { break }
            if c == "\\", quote == "\"", let escaped = current {
                index += 1
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.unicodeScalars.append(escaped)
                }
                continue
            }
            result.unicodeScalars.append(c)
        }
        return result
    }
}
