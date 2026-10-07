import Foundation

// MARK: - Plan model

/// An app the user may have meant ("Cursor", "Claude"), resolved against the apps Retrace has captured.
public struct AIQueryApp: Sendable, Equatable {
    public let name: String
    public let bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }
}

/// One independent fact the question asks for ("weekly limit", "when the 5 hour window resets").
public struct AIQueryFacet: Sendable, Equatable {
    /// The clause of the question this facet came from (for display / the LLM prompt).
    public let label: String
    /// Lowercased content words. Empty means "just show me the scoped activity".
    public let terms: [String]

    public init(label: String, terms: [String]) {
        self.label = label
        self.terms = terms
    }
}

public enum AIQueryRecency: Sendable, Equatable {
    /// "the last time…", "most recently…", "latest…": prefer the newest matching episode.
    case latest
    /// No recency preference: best-matching evidence wins.
    case any
}

/// A structured reading of a natural-language question: *where/when* to look (scope) and *what* to find (facets).
public struct AIQueryPlan: Sendable, Equatable {
    public let question: String
    public let now: Date
    public let recency: AIQueryRecency
    public let timeStart: Date?
    public let timeEnd: Date?
    /// Apps the question scopes to. Empty means unscoped.
    public let apps: [AIQueryApp]
    public let facets: [AIQueryFacet]
    public let planner: String

    public init(
        question: String,
        now: Date,
        recency: AIQueryRecency,
        timeStart: Date? = nil,
        timeEnd: Date? = nil,
        apps: [AIQueryApp] = [],
        facets: [AIQueryFacet],
        planner: String = "heuristic"
    ) {
        self.question = question
        self.now = now
        self.recency = recency
        self.timeStart = timeStart
        self.timeEnd = timeEnd
        self.apps = apps
        self.facets = facets
        self.planner = planner
    }

    /// Human/LLM-readable one-liner, also used in CLI diagnostics.
    public var summary: String {
        var parts: [String] = []
        parts.append(recency == .latest ? "recency=latest" : "recency=any")
        if !apps.isEmpty { parts.append("apps=[\(apps.map(\.name).joined(separator: ", "))]") }
        if timeStart != nil || timeEnd != nil { parts.append("time-bounded") }
        parts.append("facets=[" + facets.map { $0.terms.isEmpty ? "(scope)" : $0.terms.joined(separator: " ") }.joined(separator: " | ") + "]")
        return parts.joined(separator: " ")
    }
}

// MARK: - Heuristic planner

/// Deterministic, offline question planner. It does the part of "figure out what I'm asking" that does not
/// need a language model:
///
///  * splits a compound question into independent facets ("…, what was X, and when will Y…"),
///  * lifts the *scope* out of the facets ("the last time I had Cursor open" → app + recency, not search terms),
///  * recognises relative time ("yesterday", "this morning", "past 3 hours"),
///  * strips question/filler words so only content words reach full-text search.
public enum AIQueryPlanner {

    public static func plan(
        question: String,
        now: Date = Date(),
        apps: [AIQueryApp] = [],
        calendar: Calendar = .current
    ) -> AIQueryPlan {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        let recency = detectRecency(in: lowered)
        let (timeStart, timeEnd) = detectTimeRange(in: lowered, now: now, calendar: calendar)
        let matchedApps = matchApps(in: lowered, known: apps)

        var clauses = splitClauses(trimmed)
        if clauses.isEmpty { clauses = [trimmed] }

        let hasInterrogative = clauses.contains { containsInterrogative($0.lowercased()) }
        var facets: [AIQueryFacet] = []

        for clause in clauses {
            let lc = clause.lowercased()
            let isQuestionClause = containsInterrogative(lc)
            // With at least one explicit question clause, clauses without one are scope ("the last time I had X open").
            if hasInterrogative && !isQuestionClause { continue }

            let terms = contentTerms(from: lc, removingApps: matchedApps)
            if terms.isEmpty && !isQuestionClause { continue }
            facets.append(AIQueryFacet(label: clause.trimmingCharacters(in: .whitespacesAndNewlines), terms: terms))
        }

        // Drop duplicate / empty-label facets; keep order.
        var seen = Set<[String]>()
        facets = facets.filter { f in
            guard !f.terms.isEmpty else { return true }
            return seen.insert(f.terms).inserted
        }

        // Nothing usable (e.g. "what was I doing in Xcode yesterday?"): one scope-only facet.
        let meaningful = facets.contains { !$0.terms.isEmpty }
        if !meaningful {
            facets = [AIQueryFacet(label: trimmed, terms: [])]
        } else {
            // Scope-only leftovers next to real facets add nothing.
            facets = facets.filter { !$0.terms.isEmpty }
        }

        return AIQueryPlan(
            question: trimmed,
            now: now,
            recency: recency,
            timeStart: timeStart,
            timeEnd: timeEnd,
            apps: matchedApps,
            facets: facets
        )
    }

    // MARK: Recency & time

    static func detectRecency(in lowered: String) -> AIQueryRecency {
        let markers = [
            "last time", "most recent", "most recently", "latest", "when i last", "when was the last",
            "when did i last", "just now", "right now", "currently", "at the moment", "the last "
        ]
        return markers.contains { lowered.contains($0) } ? .latest : .any
    }

    static func detectTimeRange(in lowered: String, now: Date, calendar: Calendar) -> (Date?, Date?) {
        let startOfToday = calendar.startOfDay(for: now)

        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: startOfToday) ?? startOfToday }

        if lowered.contains("yesterday") { return (day(-1), startOfToday) }
        if lowered.contains("this morning") {
            return (startOfToday, calendar.date(byAdding: .hour, value: 12, to: startOfToday) ?? now)
        }
        if lowered.contains("today") || lowered.contains("earlier today") { return (startOfToday, nil) }
        if lowered.contains("last night") {
            return (calendar.date(byAdding: .hour, value: -6, to: startOfToday), calendar.date(byAdding: .hour, value: 6, to: startOfToday))
        }
        if lowered.contains("last week") { return (day(-14), nil) }
        if lowered.contains("this week") { return (day(-7), nil) }

        // "past/last/in the last N hours|minutes|days"
        let pattern = #"(?:past|last|previous)\s+(\d{1,3})\s*(minute|min|hour|hr|day)s?"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
           let nRange = Range(m.range(at: 1), in: lowered), let uRange = Range(m.range(at: 2), in: lowered),
           let n = Int(lowered[nRange]) {
            let unit = String(lowered[uRange])
            let component: Calendar.Component = unit.hasPrefix("min") ? .minute : (unit.hasPrefix("h") ? .hour : .day)
            return (calendar.date(byAdding: component, value: -n, to: now), nil)
        }
        return (nil, nil)
    }

    // MARK: Apps

    static func matchApps(in lowered: String, known: [AIQueryApp]) -> [AIQueryApp] {
        // "Claude Code" is a product, not a mention of an app literally named "Code".
        let mentionsClaudeCode = lowered.contains("claude code")
        var hits: [AIQueryApp] = []
        for app in known {
            let name = app.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard name.count >= 3 else { continue }
            if mentionsClaudeCode && name == "code" { continue }
            if containsWholeWord(name, in: lowered) { hits.append(app) }
        }
        // Prefer the most specific (longest) names; "Visual Studio Code" over "Code".
        let longest = hits.map { $0.name.count }.max() ?? 0
        let filtered = hits.filter { $0.name.count >= max(3, longest / 2) || hits.count == 1 }
        var unique: [AIQueryApp] = []
        for app in filtered where !unique.contains(where: { $0.bundleID == app.bundleID }) { unique.append(app) }
        return unique
    }

    private static func containsWholeWord(_ word: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: word) + "(?![a-z0-9])") else {
            return false
        }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: Clauses & terms

    static let interrogatives: Set<String> = ["what", "when", "where", "which", "who", "why", "how", "whether", "whats", "what's"]

    static func containsInterrogative(_ lowered: String) -> Bool {
        let words = lowered.split { !$0.isLetter && $0 != "'" }.map(String.init)
        return words.contains { interrogatives.contains($0) }
    }

    /// Splits at commas/semicolons/question marks and at "and"/"also"/"then" when they introduce a new question word.
    static func splitClauses(_ question: String) -> [String] {
        var marked = question
        let boundary = #"(?i)\s+(?:and|also|then|plus)\s+(?=(?:what|when|where|which|who|why|how|whether)\b)"#
        marked = marked.replacingOccurrences(of: boundary, with: "|", options: .regularExpression)
        marked = marked.replacingOccurrences(of: #"[,;?|]"#, with: "|", options: .regularExpression)
        return marked.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static let stopwords: Set<String> = [
        // articles / prepositions / pronouns / auxiliaries
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "with", "from", "by", "about", "as", "into", "over",
        "and", "or", "but", "if", "so", "than", "that", "this", "these", "those", "it", "its", "i", "me", "my", "mine",
        "we", "our", "you", "your", "he", "she", "they", "them", "their", "is", "are", "was", "were", "be", "been",
        "being", "am", "do", "does", "did", "doing", "done", "have", "has", "had", "having", "will", "would", "can",
        "could", "should", "shall", "may", "might", "must", "not", "no", "yes", "up", "out", "off", "there", "here",
        // question words
        "what", "whats", "what's", "when", "where", "which", "who", "why", "how", "whether",
        // filler / scoping words that describe *when/where*, not *what*
        "last", "time", "times", "most", "recent", "recently", "latest", "ago", "just", "now", "currently", "right",
        "open", "opened", "opening", "running", "using", "used", "use", "were", "saw", "see", "seen", "look", "looked",
        "looking", "show", "tell", "find", "check", "please", "remember", "recall", "again", "still", "then", "also",
        "yesterday", "today", "tonight", "morning", "earlier", "week", "past", "previous", "any", "some", "thing",
        "things", "something", "like", "get", "got", "go", "went", "know", "much", "many", "left", "around", "screen"
    ]

    /// Pulls content words out of a clause: drops stopwords, app names, 1-2 digit numbers and 1-letter tokens.
    static func contentTerms(from lowered: String, removingApps apps: [AIQueryApp]) -> [String] {
        var text = lowered
        for app in apps {
            text = text.replacingOccurrences(of: app.name.lowercased(), with: " ")
        }
        // "claude code" is scope vocabulary when the user says "had Claude Code open".
        var terms: [String] = []
        for raw in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "%") }) {
            let word = String(raw)
            guard word.count >= 2, !stopwords.contains(word) else { continue }
            if word.allSatisfy(\.isNumber) { continue }
            if !terms.contains(word) { terms.append(word) }
        }
        return terms
    }

    // MARK: Term expansion (used by retrieval)

    /// Light synonym map for words screens abbreviate. Prefix matching in FTS covers plurals/inflections.
    static let synonyms: [String: [String]] = [
        "hour": ["hr", "hrs", "hours"], "hours": ["hr", "hrs", "hour"], "hr": ["hour", "hours"],
        "minute": ["min", "mins", "minutes"], "minutes": ["min", "mins"], "min": ["minute", "minutes"],
        "second": ["sec", "secs"], "percent": ["%"], "weekly": ["week"], "daily": ["day"],
        "reset": ["resets", "resetting"], "limit": ["limits"], "usage": ["used"], "window": ["session"],
        "rolling": ["session"], "cost": ["price", "$"], "price": ["cost", "$"], "error": ["failed", "exception"],
        "meeting": ["call", "zoom"], "password": ["passcode"]
    ]

    public static func expandedTerms(for facet: AIQueryFacet) -> [String] {
        var out: [String] = []
        for t in facet.terms {
            if !out.contains(t) { out.append(t) }
            for s in synonyms[t] ?? [] where !out.contains(s) { out.append(s) }
        }
        return out
    }
}
