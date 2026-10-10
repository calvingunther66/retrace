// DescriptionSalvageParser.swift
//
// Replaces `OpenRouterClient.parseDescriptions` + `lastBalancedJSONArray`.
//
// Why: the legacy parser needs ONE balanced top-level `[ ... ]` that `JSONSerialization` accepts as `[[String: Any]]`.
// Anything else loses the WHOLE batch, and every frame in it burns a retry strike:
//   - output truncated by `max_tokens` (array never closes)           -> 0 of N parsed
//   - a single unescaped `"` inside one description                    -> 0 of N parsed
//   - trailing commentary containing a bracket ("(see [1])")           -> last balanced array is `[1]` -> 0 of N parsed
// This parser keeps every COMPLETE `{...}` entry and drops only a dangling one.
//
// Properties (all covered by SalvageTests.swift):
//   * array, JSON-lines, pretty-printed, fenced, `<think>`-prefixed, or prose-wrapped output all parse the same way
//   * a truncated final entry is dropped (never indexed half-written) and reported via `truncatedTail`
//   * the prompt's own placeholder example (`"description": "..."`) is rejected
//   * `image` may be Int, Double, "3", "Image 3", "#3"; zero-based numbering is detected and shifted
//   * duplicates: the LAST complete valid entry wins (consistent with the legacy "last array wins" rule)
//   * a second, marker-based pass recovers entries whose string contents broke strict JSON (unescaped inner quotes)

import Foundation

public enum DescriptionSalvageParser {

    public struct Diagnostics: Equatable, Sendable {
        public var objectsScanned = 0          // balanced {...} candidates found by the strict pass
        public var accepted = 0                // distinct in-range positions returned
        public var rejectedPlaceholder = 0
        public var rejectedOutOfRange = 0
        public var rejectedMalformed = 0       // balanced braces but not valid JSON / missing keys
        public var duplicatesOverwritten = 0
        public var recoveredByLenientPass = 0
        public var zeroBasedShift = false
        /// The text ends inside an unfinished `{...}` entry (typical `finish_reason == "length"`).
        public var truncatedTail = false
        /// An unterminated `<think>` swallowed the end of the output (nothing after it can be trusted).
        public var unterminatedThink = false
    }

    public struct Parsed: Sendable {
        /// 1-based image position -> trimmed description.
        public let byPosition: [Int: String]
        public let diagnostics: Diagnostics
    }

    public static func parse(_ rawContent: String, expectedCount: Int) -> Parsed {
        var diag = Diagnostics()
        var text = stripThinking(rawContent, diag: &diag)
        text = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")

        var found: [Int: String] = [:]          // raw index (may be 0-based) -> description
        let bytes = Array(text.utf8)
        scanObjects(bytes, found: &found, diag: &diag)

        // Second pass: positions the strict pass could not produce.
        lenientPass(text, expectedCount: expectedCount, found: &found, diag: &diag)

        // Zero-based numbering ("image": 0 ... N-1): shift by one when the evidence is unambiguous.
        if expectedCount > 0, found[0] != nil, found[expectedCount] == nil, found.keys.allSatisfy({ $0 >= 0 && $0 < expectedCount }) {
            var shifted: [Int: String] = [:]
            for (k, v) in found { shifted[k + 1] = v }
            found = shifted
            diag.zeroBasedShift = true
        }

        var result: [Int: String] = [:]
        for (k, v) in found {
            if k >= 1 && k <= expectedCount { result[k] = v } else { diag.rejectedOutOfRange += 1 }
        }
        diag.accepted = result.count
        return Parsed(byPosition: result, diagnostics: diag)
    }

    // MARK: - Pre-processing

    /// Removes closed `<think>...</think>` blocks. An UNCLOSED `<think>` means the model was still reasoning when it
    /// stopped: drop from the tag to the end (anything before it is still scanned).
    static func stripThinking(_ raw: String, diag: inout Diagnostics) -> String {
        var text = raw
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
                diag.unterminatedThink = true
                break
            }
        }
        // A stray closing tag with no opener (reasoning was emitted separately): keep only what follows the last one.
        if let lastClose = text.range(of: "</think>", options: .backwards) {
            text = String(text[lastClose.upperBound...])
        }
        return text
    }

    // MARK: - Pass 1: strict balanced-object scan

    /// Walks the text; at top level every `{` starts a candidate object that is scanned string-aware to its matching `}`.
    /// Text outside objects is never string-tracked (reasoning prose may contain apostrophes and quotes).
    private static func scanObjects(_ b: [UInt8], found: inout [Int: String], diag: inout Diagnostics) {
        let lbrace = UInt8(ascii: "{"), rbrace = UInt8(ascii: "}")
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        var i = 0
        while i < b.count {
            guard b[i] == lbrace else { i += 1; continue }
            var depth = 0, j = i
            var inString = false, escaped = false
            var end: Int?
            while j < b.count {
                let c = b[j]
                if inString {
                    if escaped { escaped = false }
                    else if c == backslash { escaped = true }
                    else if c == quote { inString = false }
                } else if c == quote { inString = true }
                else if c == lbrace { depth += 1 }
                else if c == rbrace {
                    depth -= 1
                    if depth == 0 { end = j; break }
                }
                j += 1
            }
            guard let e = end else {
                // Unbalanced to the end of the text. If it LOOKS like one of our entries (an opening brace followed by
                // nothing or a quote) it is a truncated entry: stop. Otherwise it is a stray brace in prose: skip it.
                let tail = String(decoding: b[(i + 1)...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty || tail.hasPrefix("\"") { diag.truncatedTail = true; return }
                i += 1
                continue
            }
            diag.objectsScanned += 1
            let slice = Data(b[i...e])
            if let obj = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any],
               let idx = imageIndex(obj["image"]),
               let desc = obj["description"] as? String {
                let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                if isPlaceholder(trimmed) { diag.rejectedPlaceholder += 1 }
                else {
                    if found[idx] != nil { diag.duplicatesOverwritten += 1 }
                    found[idx] = trimmed
                }
                i = e + 1
            } else {
                // Not one of ours. If it is a wrapper object (e.g. {"results":[ {...}, {...} ]}) descend into it instead of
                // skipping its whole span; otherwise count it malformed and skip past it.
                if let inner = (try? JSONSerialization.jsonObject(with: slice)) as? [String: Any], inner["image"] == nil {
                    i += 1   // wrapper object: step inside; its children are scanned next
                } else {
                    diag.rejectedMalformed += 1
                    i = e + 1
                }
            }
        }
    }

    static func imageIndex(_ v: Any?) -> Int? {
        switch v {
        case let n as Int: return n
        case let d as Double where d == d.rounded() && d >= 0 && d < 10_000: return Int(d)
        case let s as String:
            let digits = s.filter { $0.isNumber }
            guard !digits.isEmpty, digits.count <= 4 else { return nil }
            return Int(digits)
        default: return nil
        }
    }

    /// The prompt shows `{"image": 1, "description": "..."}`; models sometimes echo it. Anything that is not at least a
    /// few real words is not a description. (Threshold calibrated on the deep corpus: 1 of 46,407 accepted descriptions
    /// has < 10 characters and 3 have < 20.)
    static func isPlaceholder(_ s: String) -> Bool {
        let alnum = s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        if alnum < 8 { return true }
        let low = s.lowercased()
        if ["description", "<description>", "your description here", "string", "n/a"].contains(low) { return true }
        return false
    }

    // MARK: - Pass 2: marker-based (survives unescaped quotes that desynchronise the strict scanner)

    private static func lenientPass(_ text: String, expectedCount: Int, found: inout [Int: String], diag: inout Diagnostics) {
        guard expectedCount > 0 else { return }
        let missing = Set((1...expectedCount).filter { found[$0] == nil })
        if missing.isEmpty { return }
        guard let marker = try? NSRegularExpression(
            pattern: #""image"\s*:\s*"?\s*(?:Image\s*|#)?(\d{1,4})\s*"?\s*,\s*"description"\s*:\s*""#,
            options: [.caseInsensitive]) else { return }
        let ns = text as NSString
        let hits = marker.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !hits.isEmpty else { return }
        // anything that looks like the start of ANY entry (either key order) bounds the previous slice
        let anyStart = try? NSRegularExpression(pattern: #""image"\s*:"#)
        let starts = (anyStart?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []).map { $0.range.location }

        for (n, hit) in hits.enumerated() {
            guard let idx = Int(ns.substring(with: hit.range(at: 1))) else { continue }
            if found[idx] != nil { continue }
            if !(missing.contains(idx) || idx == 0) { continue }
            let contentStart = hit.range.location + hit.range.length
            // slice ends at the next entry start (if any) else end of text
            let nextStart = starts.first(where: { $0 > hit.range.location + 8 }) ?? ns.length
            let limit = (n + 1 < hits.count) ? min(nextStart, hits[n + 1].range.location) : nextStart
            guard limit > contentStart else { continue }
            let slice = ns.substring(with: NSRange(location: contentStart, length: limit - contentStart))
            // the entry is complete only if the slice contains a closing quote followed by `}`; take the LAST such quote
            guard let closeRange = slice.range(of: #""\s*\}"#, options: [.regularExpression, .backwards]) else { continue }
            let raw = String(slice[slice.startIndex..<closeRange.lowerBound])
            let desc = decodeLoosely(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlaceholder(desc) { continue }   // (already counted by the strict pass when it saw the same entry)
            found[idx] = desc
            diag.recoveredByLenientPass += 1
        }
    }

    /// JSON-decode the body if it is valid JSON string content, otherwise undo the common escapes by hand and keep stray quotes.
    static func decodeLoosely(_ body: String) -> String {
        if let data = ("\"" + body + "\"").data(using: .utf8),
           let s = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String { return s }
        return body
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
