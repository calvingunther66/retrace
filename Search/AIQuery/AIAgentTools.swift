import Foundation
import Shared

/// The tools the Ask-AI agent can call. The model decides *what* to look for (which app, which exact words, which
/// time window); this actor only executes those requests deterministically against the local index and returns
/// compact, citable text. It also remembers every frame it has shown so the final answer's `[Frame #ID]`
/// citations can be resolved.
public actor AIAgentTools {
    private let database: any DatabaseProtocol
    private let ftsEngine: any FTSProtocol
    private let apps: [AIQueryApp]
    private let now: Date

    /// Frames the model has been shown, by id (used for citations and the evidence export).
    private var shown: [Int64: OpenRouterContextFrame] = [:]
    private var shownOrder: [Int64] = []

    private static let selfBundleIDs = ["io.retrace.app", "io.retrace.app.dev"]
    private static let maxToolResultChars = 7_000

    public init(database: any DatabaseProtocol, ftsEngine: any FTSProtocol, apps: [AIQueryApp], now: Date = Date()) {
        self.database = database
        self.ftsEngine = ftsEngine
        var seen = Set<String>()
        self.apps = apps.filter { seen.insert($0.bundleID).inserted }
        self.now = now
    }

    public var shownFrames: [OpenRouterContextFrame] { shownOrder.compactMap { shown[$0] } }

    // MARK: Tool schemas (OpenAI / OpenRouter function-calling format)

    public static let toolSchemas: [[String: Any]] = [
        tool(
            "list_apps",
            "List the apps that have screen captures, with when each was last on screen. Call this first if you are unsure of an app's exact name.",
            properties: [:], required: []
        ),
        tool(
            "search_screen",
            """
            Full-text search over everything that was on screen (OCR text), optionally restricted to ONE app and a time window. \
            Returns matching moments with the passages around the matched words. Use specific words that would literally appear on screen. \
            Quote a multi-word string to require it as a phrase. Results are newest-first by default.
            """,
            properties: [
                "query": ["type": "string", "description": "Words or \"quoted phrase\" to find. Prefix matching is automatic (\"claud\" finds \"Claude\")."],
                "app": ["type": "string", "description": "Isolate to this single app (name or bundle id from list_apps). Omit to search all apps."],
                "since_hours": ["type": "number", "description": "Only look at the last N hours."],
                "start": ["type": "string", "description": "ISO 8601 start (e.g. 2026-10-14T09:00). Optional."],
                "end": ["type": "string", "description": "ISO 8601 end. Optional."],
                "match": ["type": "string", "enum": ["all", "any"], "description": "'all' (default): every word must appear in the same moment; auto-relaxes to 'any' if nothing matches."],
                "order": ["type": "string", "enum": ["newest", "relevance"], "description": "Default newest."],
                "limit": ["type": "integer", "description": "Max moments to return (default 8, max 20)."]
            ],
            required: ["query"]
        ),
        tool(
            "browse_app",
            "See what was happening in ONE app recently: its latest sessions with window titles, URLs and a frame id you can read with get_frame_text. Use for 'what was I doing in X' or to find the right window before searching inside it.",
            properties: [
                "app": ["type": "string", "description": "App name or bundle id."],
                "since_hours": ["type": "number", "description": "Only sessions within the last N hours."],
                "limit": ["type": "integer", "description": "Max sessions (default 8, max 20)."]
            ],
            required: ["app"]
        ),
        tool(
            "get_frame_text",
            "Read the on-screen text of one specific moment (a frame id from another tool). Pass `find` to read only the passages around a word instead of the whole screen.",
            properties: [
                "frame_id": ["type": "integer", "description": "Frame id."],
                "find": ["type": "string", "description": "Optional word/phrase: return only the text around it."],
                "max_chars": ["type": "integer", "description": "Default 2500, max 6000."]
            ],
            required: ["frame_id"]
        )
    ]

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required]
            ] as [String: Any]
        ]
    }

    // MARK: Dispatch

    /// Human-readable one-liner for the UI while a call runs.
    public static func statusLine(name: String, args: [String: Any]) -> String {
        switch name {
        case "list_apps": return "Looking at which apps were captured…"
        case "search_screen":
            let q = (args["query"] as? String) ?? ""
            if let app = args["app"] as? String, !app.isEmpty { return "Searching \(app) for “\(q)”…" }
            return "Searching all apps for “\(q)”…"
        case "browse_app": return "Browsing recent \((args["app"] as? String) ?? "app") activity…"
        case "get_frame_text": return "Reading a captured screen…"
        default: return "Working…"
        }
    }

    public func execute(name: String, arguments: [String: Any]) async -> String {
        let text: String
        switch name {
        case "list_apps": text = await listApps()
        case "search_screen": text = await searchScreen(arguments)
        case "browse_app": text = await browseApp(arguments)
        case "get_frame_text": text = await getFrameText(arguments)
        default: text = "Unknown tool '\(name)'. Available: list_apps, search_screen, browse_app, get_frame_text."
        }
        if text.count <= Self.maxToolResultChars { return text }
        return String(text.prefix(Self.maxToolResultChars)) + "\n[truncated — narrow the query, app or time window]"
    }

    // MARK: list_apps

    private func listApps() async -> String {
        var rows: [(name: String, bundle: String, last: Date?)] = []
        for app in apps where !Self.selfBundleIDs.contains(app.bundleID) {
            let seg = try? await database.getSegments(bundleID: app.bundleID, limit: 1).first
            rows.append((app.name, app.bundleID, seg?.endDate))
        }
        rows.sort { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
        guard !rows.isEmpty else { return "No captured apps found." }
        return rows.prefix(60).map { "- \($0.name) (\($0.bundle)) — last seen \($0.last.map(Self.stamp) ?? "unknown")" }.joined(separator: "\n")
    }

    // MARK: search_screen

    private func searchScreen(_ args: [String: Any]) async -> String {
        guard let rawQuery = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawQuery.isEmpty else {
            return "Error: `query` is required."
        }
        let parsed = Self.parseQuery(rawQuery)
        guard !parsed.units.isEmpty else { return "Error: the query contained no searchable words." }

        var notes: [String] = []
        var scope: [String]?
        var scopeName: String?
        if let appArg = (args["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !appArg.isEmpty {
            switch Self.resolveApp(appArg, in: apps) {
            case .found(let app):
                scope = [app.bundleID]
                scopeName = app.name
            case .none(let suggestions):
                return "No captured app matches '\(appArg)'." + (suggestions.isEmpty ? " Call list_apps." : " Did you mean: \(suggestions.joined(separator: ", "))?")
            }
        }

        let limit = max(1, min(20, (args["limit"] as? Int) ?? Int((args["limit"] as? Double) ?? 8)))
        let newestFirst = (args["order"] as? String) != "relevance"
        let (start, end) = Self.timeWindow(args, now: now)
        let asksAboutRetrace = scope?.contains { Self.selfBundleIDs.contains($0) } ?? false
        let wantAny = (args["match"] as? String) == "any"

        var matches: [FTSMatch] = []
        var tierUsed = wantAny ? 1 : 0
        let tiers = (wantAny || parsed.units.count == 1) ? [wantAny ? 1 : 0] : [0, 1]
        for tier in tiers {
            tierUsed = tier
            matches = await runSearch(parsed: parsed, tier: tier, scope: scope, start: start, end: end,
                                      newestFirst: newestFirst, excludeSelf: !asksAboutRetrace, wanted: limit)
            if !matches.isEmpty { break }
        }
        if tierUsed == 1, !wantAny, !matches.isEmpty {
            notes.append("No moment contained ALL the words, so these contain at least one of them.")
        }

        // Visual-description index (AI-written descriptions of the screenshot) as a supplement when OCR finds little.
        var semanticCount = 0
        if matches.count < limit {
            let filters = Self.filters(scope: scope, start: start, end: end, excludeSelf: !asksAboutRetrace)
            let expr = Self.expression(parsed, tier: tierUsed)
            if let extra = try? await ftsEngine.searchSemantic(query: expr, filters: filters, limit: 40, offset: 0) {
                let have = Set(matches.map { $0.frameID.value })
                for m in extra where !have.contains(m.frameID.value) {
                    matches.append(m)
                    semanticCount += 1
                }
            }
        }

        guard !matches.isEmpty else {
            var hint = "No matches for “\(rawQuery)”"
            if let scopeName { hint += " in \(scopeName)" }
            if start != nil || end != nil { hint += " in that time window" }
            hint += "."
            hint += " Try: fewer or different words / spellings, match=any, a wider time window" + (scope != nil ? ", or omit `app` to search every app (the text may have been in a browser or another app)." : ".")
            return hint
        }

        if newestFirst { matches.sort { $0.timestamp > $1.timestamp } }
        let facet = AIQueryFacet(label: rawQuery, terms: parsed.snippetTerms)
        var lines: [String] = []
        var kept: [(match: FTSMatch, snippet: String)] = []
        for m in matches {
            if kept.count >= limit { break }
            let text = await ocrText(frameID: m.frameID.value)
            var (snippet, _) = AIEvidenceRetriever.snippet(from: text, facet: facet, window: 160, maxChars: 520)
            if snippet.isEmpty {
                snippet = m.snippet.replacingOccurrences(of: "<mark>", with: "").replacingOccurrences(of: "</mark>", with: "")
            }
            guard !snippet.isEmpty else { continue }
            // Adjacent captures of one unchanged screen carry identical text.
            if kept.contains(where: {
                $0.snippet == snippet || ($0.match.appName == m.appName && abs($0.match.timestamp.timeIntervalSince(m.timestamp)) < 45)
            }) { continue }
            kept.append((m, AITimeResolver.annotate(snippet, capturedAt: m.timestamp, now: now)))
        }

        for (m, snippet) in kept {
            let app = m.appName.flatMap { id in apps.first { $0.bundleID == id }?.name } ?? m.appName ?? "Unknown"
            remember(frameID: m.frameID.value, timestamp: m.timestamp, app: app, window: m.windowName, text: snippet)
            var head = "[Frame #\(m.frameID.value)] \(Self.stamp(m.timestamp)) — \(app)"
            if let w = m.windowName, !w.isEmpty { head += " — \(w.prefix(80))" }
            lines.append(head + "\n  " + snippet)
        }
        var header = "\(kept.count) moment(s) for “\(rawQuery)”"
        if let scopeName { header += " in \(scopeName)" }
        header += newestFirst ? ", newest first" : ", best match first"
        if semanticCount > 0 { header += " (includes \(semanticCount) from AI visual descriptions)" }
        header += "."
        return ([header] + notes + lines).joined(separator: "\n")
    }

    private func runSearch(
        parsed: ParsedQuery, tier: Int, scope: [String]?, start: Date?, end: Date?,
        newestFirst: Bool, excludeSelf: Bool, wanted: Int
    ) async -> [FTSMatch] {
        let expr = Self.expression(parsed, tier: tier)
        let q = "((text:(\(expr))) OR (otherText:(\(expr))))"

        // A screen that stays open all day matches in thousands of frames; plain top-N by rank can miss the newest.
        // For newest-first, widen the window progressively and stop once there are enough distinct moments.
        let day: TimeInterval = 86_400
        let spans: [TimeInterval?] = (newestFirst && start == nil) ? [day, 3 * day, 7 * day, 30 * day, nil] : [nil]
        var best: [FTSMatch] = []
        for span in spans {
            let from = span.map { (end ?? now).addingTimeInterval(-$0) } ?? start
            let filters = Self.filters(scope: scope, start: from, end: end, excludeSelf: excludeSelf)
            guard let found = try? await ftsEngine.search(query: q, filters: filters, limit: 300, offset: 0) else { continue }
            best = found
            if distinctMoments(found) >= wanted { break }
        }
        return best
    }

    private func distinctMoments(_ matches: [FTSMatch]) -> Int {
        var count = 0
        var last: [String: Date] = [:]
        for m in matches.sorted(by: { $0.timestamp > $1.timestamp }) {
            let key = m.appName ?? ""
            if let t = last[key], abs(t.timeIntervalSince(m.timestamp)) < 45 { continue }
            last[key] = m.timestamp
            count += 1
        }
        return count
    }

    // MARK: browse_app

    private func browseApp(_ args: [String: Any]) async -> String {
        guard let appArg = args["app"] as? String, !appArg.isEmpty else { return "Error: `app` is required." }
        let app: AIQueryApp
        switch Self.resolveApp(appArg, in: apps) {
        case .found(let a): app = a
        case .none(let s): return "No captured app matches '\(appArg)'." + (s.isEmpty ? " Call list_apps." : " Did you mean: \(s.joined(separator: ", "))?")
        }
        let limit = max(1, min(20, (args["limit"] as? Int) ?? Int((args["limit"] as? Double) ?? 8)))
        let (start, _) = Self.timeWindow(args, now: now)
        guard let segments = try? await database.getSegments(bundleID: app.bundleID, limit: limit * 3) else {
            return "Could not read sessions for \(app.name)."
        }
        let recent = segments.filter { start == nil || $0.endDate >= start! }.prefix(limit)
        guard !recent.isEmpty else { return "\(app.name) has no captured sessions in that window." }
        var lines = ["Recent \(app.name) sessions, newest first:"]
        for seg in recent {
            let frames = (try? await database.getFrames(from: seg.startDate, to: seg.endDate, limit: 400)) ?? []
            var line = "- \(Self.stamp(seg.startDate)) → \(Self.stamp(seg.endDate))"
            if let w = seg.windowName, !w.isEmpty { line += " — “\(w.prefix(100))”" }
            if let u = seg.browserUrl, !u.isEmpty { line += " — \(u.prefix(120))" }
            if let last = frames.last { line += " — last frame #\(last.id.value)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: get_frame_text

    private func getFrameText(_ args: [String: Any]) async -> String {
        guard let id = (args["frame_id"] as? Int).map(Int64.init) ?? (args["frame_id"] as? Double).map(Int64.init) else {
            return "Error: `frame_id` (integer) is required."
        }
        let text = await ocrText(frameID: id)
        guard !text.isEmpty else { return "Frame #\(id) has no readable text." }
        let cap = max(500, min(6_000, (args["max_chars"] as? Int) ?? 2_500))
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")

        var body: String
        if let find = (args["find"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !find.isEmpty {
            let parsed = Self.parseQuery(find)
            let (snippet, coverage) = AIEvidenceRetriever.snippet(from: flat, facet: AIQueryFacet(label: find, terms: parsed.snippetTerms), window: 300, maxChars: cap)
            body = snippet.isEmpty ? "“\(find)” does not appear in this frame's text." : snippet
            if coverage > 0 { body = "(passages around “\(find)”)\n" + body }
        } else {
            body = String(flat.prefix(cap))
            if flat.count > cap { body += " … [more text omitted; use `find` to read around a word]" }
        }
        let ts = shown[id]?.timestamp
        if let ts = ts {
            body = AITimeResolver.annotate(body, capturedAt: ts, now: now)
            remember(frameID: id, timestamp: ts, app: shown[id]?.appName ?? "Unknown", window: shown[id]?.windowTitle, text: body)
        }
        return "[Frame #\(id)]\(ts.map { " " + Self.stamp($0) } ?? "")\n" + body
    }

    // MARK: Helpers

    private func remember(frameID: Int64, timestamp: Date, app: String, window: String?, text: String) {
        let frame = OpenRouterContextFrame(frameID: frameID, timestamp: timestamp, appName: app, windowTitle: window, browserURL: nil, extractedText: text)
        if shown[frameID] == nil { shownOrder.append(frameID) }
        shown[frameID] = frame
    }

    private func ocrText(frameID: Int64) async -> String {
        guard let t = try? await database.getOCRTextForFrame(frameID: frameID) else { return "" }
        return [t.mainText, t.chromeText ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func filters(scope: [String]?, start: Date?, end: Date?, excludeSelf: Bool) -> SearchFilters {
        SearchFilters(startDate: start, endDate: end, appBundleIDs: scope, excludedAppBundleIDs: excludeSelf ? selfBundleIDs : nil)
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        return f.string(from: date)
    }

    // MARK: Query parsing (pure — unit tested)

    /// One searchable unit: a single word (prefix-matched) or a phrase (exact word sequence).
    struct Unit: Equatable {
        let words: [String]
        var isPhrase: Bool { words.count > 1 }
    }

    struct ParsedQuery: Equatable {
        let units: [Unit]
        /// Words used for keyword-in-context highlighting.
        var snippetTerms: [String] { units.map { $0.words.joined(separator: " ") } }
    }

    /// Splits a model-written query into units. `"exact phrase"` stays together; `gpt-4`/`foo.bar` becomes the phrase
    /// "gpt 4" (FTS tokenises on punctuation); everything else is a prefix-matched word. FTS5 operators and
    /// punctuation never reach the engine, so a query cannot raise a syntax error.
    static func parseQuery(_ raw: String) -> ParsedQuery {
        var units: [Unit] = []
        var current = ""
        var inQuotes = false
        func flush() {
            defer { current = "" }
            let words = current.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { String($0).lowercased() }
            guard !words.isEmpty else { return }
            units.append(Unit(words: words))
        }
        for ch in raw {
            if ch == "\"" {
                flush()
                inQuotes.toggle()
            } else if ch.isWhitespace && !inQuotes {
                flush()
            } else {
                current.append(ch)
            }
        }
        flush()
        let stop: Set<String> = ["and", "or", "not", "near"]   // FTS5 operators typed as words
        units = units.filter { !($0.words.count == 1 && stop.contains($0.words[0])) }
        return ParsedQuery(units: units)
    }

    /// FTS5 expression body for a tier: 0 = every unit (AND), 1 = any unit (OR).
    static func expression(_ parsed: ParsedQuery, tier: Int) -> String {
        let parts = parsed.units.map { u -> String in
            u.isPhrase ? "\"" + u.words.joined(separator: " ") + "\"" : u.words[0] + "*"
        }
        return parts.joined(separator: tier == 0 ? " AND " : " OR ")
    }

    enum AppResolution: Equatable {
        case found(AIQueryApp)
        case none(suggestions: [String])
    }

    /// Exact name/bundle id, then name prefix, then substring either way, then bundle-id substring.
    static func resolveApp(_ input: String, in apps: [AIQueryApp]) -> AppResolution {
        let q = input.lowercased().trimmingCharacters(in: .whitespaces)
        func pick(_ pred: (AIQueryApp) -> Bool) -> AIQueryApp? { apps.first(where: pred) }
        if let a = pick({ $0.name.lowercased() == q || $0.bundleID.lowercased() == q }) { return .found(a) }
        if let a = pick({ $0.name.lowercased().hasPrefix(q) }) { return .found(a) }
        if let a = pick({ $0.name.lowercased().contains(q) || (q.count >= 4 && q.contains($0.name.lowercased()) && $0.name.count >= 3) }) { return .found(a) }
        if let a = pick({ $0.bundleID.lowercased().contains(q) }) { return .found(a) }
        let suggestions = apps.filter { app in
            let n = app.name.lowercased()
            return q.split(separator: " ").contains { n.contains($0) && $0.count >= 3 }
        }.prefix(5).map(\.name)
        return .none(suggestions: Array(suggestions))
    }

    static func timeWindow(_ args: [String: Any], now: Date) -> (Date?, Date?) {
        var start: Date?
        var end: Date?
        if let h = (args["since_hours"] as? Double) ?? (args["since_hours"] as? Int).map(Double.init), h > 0 {
            start = now.addingTimeInterval(-h * 3600)
        }
        if let s = args["start"] as? String, let d = parseDate(s) { start = d }
        if let e = args["end"] as? String, let d = parseDate(e) { end = d }
        return (start, end)
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.timeZone = .current
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
