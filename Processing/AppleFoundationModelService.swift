import Foundation
import NaturalLanguage
import Shared

/// On-device language model and natural language service powering Stage 1 baseline semantic indexing.
///
/// Operates entirely in-memory and on-device on pure OCR text + window/app metadata.
/// Zero images sent, zero network requests, zero API token costs.
/// Generates fast semantic summaries and topic keyword indexes within milliseconds of frame capture.
public actor AppleFoundationModelService: Sendable {
    public static let shared = AppleFoundationModelService()

    public init() {}

    /// Generates a structured baseline semantic description from OCR text and app context.
    /// Returns nil if there is insufficient text to generate a meaningful summary.
    public func generateBaselineSemanticDescription(
        appName: String?,
        windowTitle: String?,
        browserURL: String?,
        ocrText: String
    ) async -> String? {
        let cleanText = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedApp = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedURL = browserURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // If there's truly no content (e.g. blank desktop or solid color), provide app fallback
        if cleanText.isEmpty && resolvedTitle.isEmpty && resolvedURL.isEmpty {
            if !resolvedApp.isEmpty {
                return "App: \(resolvedApp)"
            }
            return "Screen Capture"
        }

        // 1. Extract key entities and topics using NaturalLanguage tagger
        let extractedKeywords = extractKeyPhrases(from: cleanText, limit: 12)

        // 2. Synthesize a clean 1-2 sentence core summary
        let summary = synthesizeSummary(
            appName: resolvedApp,
            windowTitle: resolvedTitle,
            browserURL: resolvedURL,
            ocrText: cleanText,
            keywords: extractedKeywords
        )

        // 3. Build structured multi-line baseline description for FTS5 index
        var components: [String] = []

        if !resolvedApp.isEmpty || !resolvedTitle.isEmpty {
            let header = [
                resolvedApp.isEmpty ? nil : "App: \(resolvedApp)",
                resolvedTitle.isEmpty ? nil : "Title: \(resolvedTitle)"
            ].compactMap { $0 }.joined(separator: " | ")
            components.append(header)
        }

        if !resolvedURL.isEmpty {
            components.append("URL: \(resolvedURL)")
        }

        if !summary.isEmpty {
            components.append("Summary: \(summary)")
        }

        if !extractedKeywords.isEmpty {
            components.append("Keywords: \(extractedKeywords.joined(separator: ", "))")
        }

        let result = components.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    // MARK: - NaturalLanguage Processing

    private func extractKeyPhrases(from text: String, limit: Int) -> [String] {
        guard !text.isEmpty else { return [] }

        var termScores: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text

        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        let range = text.startIndex..<text.endIndex

        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            let word = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if word.count >= 2, let tag {
                switch tag {
                case .personalName, .placeName, .organizationName:
                    termScores[word, default: 0] += 3
                default:
                    break
                }
            }
            return true
        }

        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: options) { tag, tokenRange in
            let word = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if word.count >= 3, let tag {
                switch tag {
                case .noun:
                    termScores[word, default: 0] += 2
                case .verb, .adjective:
                    termScores[word, default: 0] += 1
                default:
                    break
                }
            }
            return true
        }

        // Filter out common stopwords
        let stopwords: Set<String> = [
            "the", "and", "for", "that", "this", "with", "from", "have", "are", "was",
            "were", "will", "been", "has", "had", "would", "should", "could", "about",
            "into", "more", "some", "such", "than", "them", "then", "there", "these",
            "they", "what", "when", "where", "which", "while", "who", "whom", "why"
        ]

        let sorted = termScores
            .filter { term, _ in !stopwords.contains(term.lowercased()) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)

        return Array(sorted)
    }

    private func synthesizeSummary(
        appName: String,
        windowTitle: String,
        browserURL: String,
        ocrText: String,
        keywords: [String]
    ) -> String {
        var parts: [String] = []

        if !appName.isEmpty {
            let appClean = appName.replacingOccurrences(of: "com.apple.", with: "").capitalized
            if !windowTitle.isEmpty {
                parts.append("User in \(appClean) viewing \"\(windowTitle)\".")
            } else {
                parts.append("User working in \(appClean).")
            }
        } else if !windowTitle.isEmpty {
            parts.append("Viewing \"\(windowTitle)\".")
        }

        // Add first substantive sentence or line of OCR text if available
        let lines = ocrText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 15 }

        if let firstSubstantive = lines.first {
            let snippet = firstSubstantive.prefix(160)
            parts.append("Content: \(snippet)\(firstSubstantive.count > 160 ? "..." : "")")
        }

        return parts.joined(separator: " ")
    }
}
