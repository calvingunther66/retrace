import Foundation
import Shared
import Database
import Search
import Processing

// retrace-cli: command-line harness for the AI search / semantic indexing stack.
//
// SAFETY: this tool runs the real SearchManager / vector engine / reasoner, which run schema
// migrations and can write the vector file + DB rows. It therefore REFUSES to open the live
// store (~/Library/Application Support/Retrace) unless --allow-live is given. Point --db at a
// snapshot copy:  sqlite3 <live.db> ".backup '<dir>/retrace.db'" && cp vectors.bin <dir>/
//
// Nothing is sent off-machine except by `ask --send`, which needs OPENROUTER_API_KEY in the env.

/// All CLI results go through `out` so the wrapper can separate them from the app's own debug logging
/// (which shares stdout and can span multiple lines).
func out(_ s: String = "") {
    for line in s.split(separator: "\n", omittingEmptySubsequences: false) { print("»" + line) }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct Options {
    var command = ""
    var positional: [String] = []
    var flags: [String: String] = [:]

    func int(_ k: String, _ d: Int) -> Int { flags[k].flatMap(Int.init) ?? d }
    func has(_ k: String) -> Bool { flags[k] != nil }

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var rest = Array(args.dropFirst())
        if let first = rest.first, !first.hasPrefix("-") { o.command = first; rest.removeFirst() }
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                    o.flags[key] = rest[i + 1]; i += 2
                } else {
                    o.flags[key] = "true"; i += 1
                }
            } else {
                o.positional.append(a); i += 1
            }
        }
        return o
    }
}

func ms(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}

@discardableResult
func timed<T>(_ label: String, into table: inout [String: [Double]], _ body: () async throws -> T) async rethrows -> T {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    table[label, default: []].append(ms(start.duration(to: clock.now)))
    return value
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func printStageTable(_ table: [String: [Double]], order: [String]) {
    out(String(format: "%-34@ %6@ %9@ %9@ %9@", "stage" as NSString, "n" as NSString, "p50 ms" as NSString, "p95 ms" as NSString, "max ms" as NSString))
    for k in order {
        guard let xs = table[k] else { continue }
        out(String(format: "%-34@ %6d %9.1f %9.1f %9.1f", k as NSString, xs.count, pct(xs, 0.5), pct(xs, 0.95), xs.max() ?? 0))
    }
}

struct Stack {
    let db: DatabaseManager
    let fts: FTSManager
    let vectors: AcceleratedVectorEngine
    let mesh: EntityMeshManager
    let search: SearchManager
    let dbPath: String
    let storageDir: String
}

func openStack(_ o: Options) async throws -> Stack {
    guard let dbPath = o.flags["db"] else { throw CLIError("--db <path to snapshot retrace.db> is required") }
    let live = AppPaths.defaultStorageRoot + "/retrace.db"
    if URL(fileURLWithPath: dbPath).resolvingSymlinksInPath().path == URL(fileURLWithPath: live).resolvingSymlinksInPath().path,
       !o.has("allow-live") {
        throw CLIError("refusing to open the live database; use a snapshot copy (or pass --allow-live if you really mean it)")
    }
    let storageDir = o.flags["storage-dir"] ?? URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
    let db = DatabaseManager(databasePath: dbPath, storageRootPath: storageDir)
    try await db.initialize()
    let fts = FTSManager(databasePath: dbPath)
    try await fts.initialize()
    let vectors = AcceleratedVectorEngine(database: db, storageDirectory: URL(fileURLWithPath: storageDir, isDirectory: true))
    let mesh = EntityMeshManager(database: db)
    let search = SearchManager(database: db, ftsEngine: fts, vectorEngine: vectors, entityMesh: mesh)
    try await search.initialize(config: .default)
    return Stack(db: db, fts: fts, vectors: vectors, mesh: mesh, search: search, dbPath: dbPath, storageDir: storageDir)
}

func sqliteScalar(_ dbPath: String, _ sql: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["file:\(dbPath)?mode=ro", sql]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
}

// MARK: - Commands

func cmdVectorStatus(_ o: Options) async throws {
    guard let dbPath = o.flags["db"] else { throw CLIError("--db required") }
    let dir = o.flags["storage-dir"] ?? URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
    let size = (try? FileManager.default.attributesOfItem(atPath: dir + "/vectors.bin")[.size] as? Int) ?? 0
    let dims = 512
    out("vectors.bin bytes          : \(size)  (\(size / (dims * 4)) vectors @ \(dims) dims; remainder \(size % (dims * 4)))")
    out("metadata rows              : \(sqliteScalar(dbPath, "select count(*) from keyframe_vector_metadata"))")
    out("distinct vectorOffset      : \(sqliteScalar(dbPath, "select count(distinct vectorOffset) from keyframe_vector_metadata"))")
    out("max vectorOffset           : \(sqliteScalar(dbPath, "select max(vectorOffset) from keyframe_vector_metadata"))")
    out("duplicate-offset rows      : \(sqliteScalar(dbPath, "select count(*) from (select vectorOffset from keyframe_vector_metadata group by vectorOffset having count(*)>1)"))")
    out("frames status 2 (deep)     : \(sqliteScalar(dbPath, "select count(*) from frame where semanticStatus=2"))")
    out("frames status 5 (baseline) : \(sqliteScalar(dbPath, "select count(*) from frame where semanticStatus=5"))")
    out("frames with metadata row   : \(sqliteScalar(dbPath, "select count(*) from keyframe_vector_metadata m join frame f on f.id=m.frameId"))")
    let stack = try await openStack(o)
    let meta = try await stack.db.getAllKeyframeVectorMetadata()
    out("engine.initialize() loads  : (calling) metadata=\(meta.count)")
    try await stack.vectors.initialize()
    let loaded = await stack.vectors.vectorCount
    out("engine vectorCount after initialize(): \(loaded)  -> \(loaded == 0 && meta.count > 0 ? "INDEX DISCARDED (count mismatch)" : "ok")")
}

func cmdSearch(_ o: Options) async throws {
    guard let q = o.positional.first else { throw CLIError("usage: search <query> --db <db>") }
    let stack = try await openStack(o)
    let limit = o.int("limit", 50)
    var t: [String: [Double]] = [:]
    let loops = o.int("repeat", 1)
    var last: SearchResults?
    for _ in 0..<loops {
        let parsed = try QueryParser().parse(rawQuery: q)
        let matchAny = o.has("any")
        let ocrQ = SearchManager.buildScopedFTSQuery(for: parsed, matchAny: matchAny)
        let semQ = SearchManager.buildSemanticFTSQuery(for: parsed, matchAny: matchAny)
        let ocr = try await timed("1 ocr FTS", into: &t) { try await stack.fts.search(query: ocrQ, filters: .none, limit: limit, offset: 0) }
        _ = try await timed("2 semantic FTS", into: &t) { try await stack.fts.searchSemantic(query: semQ, filters: .none, limit: limit, offset: 0) }
        let qv = await timed("3a embed query", into: &t) { await stack.vectors.embedTextOnDevice(q) }
        let near = try await timed("3b searchNearest", into: &t) { try await stack.vectors.searchNearest(queryVector: qv, limit: limit) }
        await timed("4 getFrame x\(min(limit, ocr.count)) (serial)", into: &t) {
            for m in ocr.prefix(limit) { _ = try? await stack.db.getFrame(id: m.frameID) }
        }
        last = try await timed("TOTAL SearchManager.search", into: &t) {
            matchAny ? try await stack.search.searchForAIContext(question: q, limit: limit)
                     : try await stack.search.search(query: SearchQuery(text: q, limit: limit))
        }
        if loops == 1 {
            let sims = near.map { Double($0.similarity) }
            out("vector sims: top=\(sims.first ?? 0) median=\(pct(sims, 0.5)) >=0.20: \(sims.filter { $0 >= 0.2 }.count)/\(sims.count)")
        }
    }
    if let r = last {
        out("fts query: \(SearchManager.buildScopedFTSQuery(for: try QueryParser().parse(rawQuery: q), matchAny: o.has("any")))")
        out("results: \(r.results.count)  sources: \(Dictionary(grouping: r.results, by: { String(describing: $0.matchSource) }).mapValues(\.count))")
        for x in r.results.prefix(o.int("show", 5)) {
            out("  #\(x.id.value) \(x.timestamp) [\(String(describing: x.matchSource))] \(x.metadata.appName ?? "?") | \(x.metadata.windowName ?? "")")
        }
    }
    printStageTable(t, order: t.keys.sorted())
}

func cmdAIContext(_ o: Options) async throws {
    guard let q = o.positional.first else { throw CLIError("usage: ai-context <question> --db <db>") }
    let stack = try await openStack(o)
    let reasoner = CognitiveReasoner(database: stack.db, ftsEngine: stack.fts, entityMesh: stack.mesh)
    var t: [String: [Double]] = [:]
    let limit = o.int("limit", 30)
    let ctx = try await timed("cognitive planAndRetrieveContext", into: &t) {
        try await reasoner.planAndRetrieveContext(query: q, maxFrames: limit)
    }
    let fallback = try await timed("fallback searchForAIContext", into: &t) {
        try await stack.search.searchForAIContext(question: q, limit: limit)
    }
    out("cognitive: \(ctx.frames.count) frames, \(ctx.episodes.count) episodes, \(ctx.relatedEntities.count) entities, prompt chars=\(ctx.assembledPromptText.count)")
    out("fallback : \(fallback.results.count) frames")
    let chars = ctx.frames.map { $0.summaryText.count }.reduce(0, +)
    out("context payload chars sent to LLM ≈ \(chars) (~\(chars / 4) tokens)")
    let fts = try await stack.fts.search(query: SearchManager.buildScopedFTSQuery(for: try QueryParser().parse(rawQuery: q), matchAny: true), filters: .none, limit: min(limit, 20), offset: 0)
    let ftsIDs = fts.map(\.frameID.value)
    let kept = Set(ctx.frames.map(\.frameID))
    out("direct-FTS hop-1 frames: \(ftsIDs.count); of those retained in final context: \(ftsIDs.filter { kept.contains($0) }.count)")
    for f in ctx.frames.prefix(o.int("show", 8)) {
        out("  #\(f.frameID) \(f.timestamp) \(f.appName) | \(f.windowTitle ?? "") | ents=\(f.entities.prefix(3))")
    }
    printStageTable(t, order: t.keys.sorted())
}

func cmdBench(_ o: Options) async throws {
    guard let file = o.flags["queries"] else { throw CLIError("--queries <file, one per line> required") }
    let queries = try String(contentsOfFile: file, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    let stack = try await openStack(o)
    var t: [String: [Double]] = [:]
    var vectorOnlyDropped = 0, totalVecHits = 0
    for q in queries {
        guard let parsed = try? QueryParser().parse(rawQuery: q) else { continue }
        FileHandle.standardError.write(Data("[bench] \(q.prefix(40))\n".utf8))
        let ocrQ = SearchManager.buildScopedFTSQuery(for: parsed)
        let ocr = (try? await timed("ocr FTS (AND)", into: &t) { try await stack.fts.search(query: ocrQ, filters: .none, limit: 50, offset: 0) }) ?? []
        _ = try? await timed("semantic FTS", into: &t) { try await stack.fts.searchSemantic(query: SearchManager.buildSemanticFTSQuery(for: parsed), filters: .none, limit: 50, offset: 0) }
        let qv = await timed("embed query", into: &t) { await stack.vectors.embedTextOnDevice(q) }
        let near = (try? await timed("searchNearest", into: &t) { try await stack.vectors.searchNearest(queryVector: qv, limit: 50) }) ?? []
        let hits = near.filter { $0.similarity >= 0.2 }.map(\.frameID)
        let ocrIDs = Set(ocr.map(\.frameID))
        totalVecHits += hits.count
        vectorOnlyDropped += hits.filter { !ocrIDs.contains($0) }.count
        _ = try? await timed("SearchManager.search (total)", into: &t) { try await stack.search.search(query: SearchQuery(text: q, limit: 50)) }
        _ = try? await timed("SearchManager.searchForAIContext", into: &t) { try await stack.search.searchForAIContext(question: q, limit: 30) }
        let reasoner = CognitiveReasoner(database: stack.db, ftsEngine: stack.fts, entityMesh: stack.mesh)
        _ = try? await timed("cognitive context (30 frames)", into: &t) { try await reasoner.planAndRetrieveContext(query: q, maxFrames: 30) }
    }
    out("queries: \(queries.count)")
    out("vector hits >=0.20: \(totalVecHits); of those NOT in OCR results (never surfaced by merge): \(vectorOnlyDropped)")
    printStageTable(t, order: ["ocr FTS (AND)", "semantic FTS", "embed query", "searchNearest", "SearchManager.search (total)", "SearchManager.searchForAIContext", "cognitive context (30 frames)"])
}

func cmdIndexBench(_ o: Options) async throws {
    let stack = try await openStack(o)
    let n = o.int("n", 20)
    let pending = try await stack.db.selectPendingBaselineSemanticFrames(limit: n)
    let sessionizer = CognitiveSessionizer(database: stack.db)
    var t: [String: [Double]] = [:]
    out("benchmarking baseline stage on \(pending.count) pending snapshot frames (writes go to the snapshot only)")
    for f in pending {
        let ocr = try? await timed("a getOCRTextForFrame", into: &t) { try await stack.db.getOCRTextForFrame(frameID: f.frameID) }
        let desc = await timed("b foundation-model description", into: &t) {
            await AppleFoundationModelService.shared.generateBaselineSemanticDescription(
                appName: f.bundleID, windowTitle: f.windowName ?? ocr?.title, browserURL: f.browserUrl ?? ocr?.chromeText, ocrText: ocr?.mainText ?? "")
        }
        _ = try? await timed("c writeBaselineDescription", into: &t) {
            try await stack.db.writeBaselineSemanticDescription(frameID: f.frameID, description: desc ?? "x", indexedAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        }
        _ = try? await timed("d entityMesh.harvest", into: &t) {
            try await stack.mesh.harvestEntities(from: ocr?.mainText ?? "", appName: f.bundleID, windowTitle: f.windowName, browserURL: f.browserUrl, frameID: f.frameID, episodeID: nil)
        }
        _ = try? await timed("e sessionizer.clusterFrames([1])", into: &t) {
            try await sessionizer.clusterFrames([PendingCognitiveFrame(frameID: f.frameID, timestamp: Date(timeIntervalSince1970: Double(f.createdAtMs) / 1000), appName: f.bundleID ?? "Unknown", windowTitle: f.windowName, browserURL: f.browserUrl, ocrText: ocr?.mainText ?? "")])
        }
        let v = await timed("f embedTextOnDevice", into: &t) { await stack.vectors.embedTextOnDevice(desc ?? "x") }
        _ = try? await timed("g vectors.addVector", into: &t) { try await stack.vectors.addVector(frameID: FrameID(value: f.frameID), vector: v) }
    }
    await stack.vectors.flushPendingPersist()
    printStageTable(t, order: t.keys.sorted())
    let per = t.values.map { $0.reduce(0, +) }.reduce(0, +) / Double(max(1, pending.count))
    out(String(format: "≈ %.1f ms/frame (n=%d) => %.1f frames/s serial for the on-device baseline stage", per, pending.count, 1000 / max(per, 0.001)))
    out("note: baseline stage is NOT the bottleneck for the existing backlog; the vision-LLM deep lane is budget-bound (see dailyBackfillBudget).")
}

/// Embeds existing semantic descriptions into the snapshot's vector engine, then reports how well
/// dense similarity separates queries — i.e. whether the vector index is worth keeping at all.
func cmdRebuildVectors(_ o: Options) async throws {
    guard let dbPath = o.flags["db"] else { throw CLIError("--db required") }
    let n = o.int("n", 2000)
    let stack = try await openStack(o)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    p.arguments = ["-json", "file:\(dbPath)?mode=ro",
                   "SELECT sdf.frameId AS id, sr.description AS d FROM semantic_doc_frame sdf JOIN semanticRanking sr ON sr.rowid = sdf.docid ORDER BY sdf.frameId DESC LIMIT \(n);"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CLIError("no rows") }
    out("embedding \(rows.count) descriptions")
    var t: [String: [Double]] = [:]
    for r in rows {
        guard let id = (r["id"] as? NSNumber)?.int64Value, let d = r["d"] as? String else { continue }
        let v = await timed("embedTextOnDevice", into: &t) { await stack.vectors.embedTextOnDevice(d) }
        try await timed("addVector", into: &t) { try await stack.vectors.addVector(frameID: FrameID(value: id), vector: v) }
    }
    await timed("flushPendingPersist", into: &t) { await stack.vectors.flushPendingPersist() }
    printStageTable(t, order: ["embedTextOnDevice", "addVector", "flushPendingPersist"])
    out("engine vectorCount: \(await stack.vectors.vectorCount)")

    // Self-retrieval: query with a description's own middle words; does the dense index rank that frame near the top?
    var selfRanks: [Int] = []
    for (i, r) in rows.enumerated() where i % 15 == 0 {
        guard let id = (r["id"] as? NSNumber)?.int64Value, let d = r["d"] as? String else { continue }
        let words = d.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 12 else { continue }
        let q = words[(words.count / 2 - 4)..<(words.count / 2 + 4)].joined(separator: " ")
        let near = try await stack.vectors.searchNearest(queryVector: await stack.vectors.embedTextOnDevice(q), limit: 3000)
        selfRanks.append((near.firstIndex { $0.frameID.value == id } ?? 3000) + 1)
    }
    if !selfRanks.isEmpty {
        let f = { (k: Int) in Double(selfRanks.filter { $0 <= k }.count) / Double(selfRanks.count) }
        out(String(format: "self-retrieval (n=%d, 8-word excerpt of own description, 3000 candidates): top1=%.2f top10=%.2f top100=%.2f median rank=%d", selfRanks.count, f(1), f(10), f(100), selfRanks.sorted()[selfRanks.count / 2]))
    }

    guard let qf = o.flags["queries"] else { return }
    let queries = try String(contentsOfFile: qf, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    var top1: [Double] = [], median: [Double] = [], above: [Double] = [], overlap: [Double] = []
    for q in queries {
        let qv = await stack.vectors.embedTextOnDevice(q)
        let near = try await stack.vectors.searchNearest(queryVector: qv, limit: 50)
        let sims = near.map { Double($0.similarity) }
        guard !sims.isEmpty, let parsed = try? QueryParser().parse(rawQuery: q) else { continue }
        top1.append(sims[0]); median.append(pct(sims, 0.5)); above.append(Double(sims.filter { $0 >= 0.2 }.count))
        let fts = (try? await stack.fts.search(query: SearchManager.buildScopedFTSQuery(for: parsed), filters: .none, limit: 50, offset: 0)) ?? []
        let ids = Set(fts.map(\.frameID))
        let hits = near.prefix(20).filter { ids.contains($0.frameID) }.count
        overlap.append(Double(hits))
    }
    out("similarity over \(top1.count) queries (top-50 of \(await stack.vectors.vectorCount) vectors):")
    out(String(format: "  top1 p50=%.3f p95=%.3f | median-of-50 p50=%.3f | #>=0.20 of 50: p50=%.0f | vector-top20 ∩ FTS-top50: p50=%.0f", pct(top1, 0.5), pct(top1, 0.95), pct(median, 0.5), pct(above, 0.5), pct(overlap, 0.5)))
}

/// Runs the new planner + evidence retriever end-to-end (no network) and prints what would be sent to the LLM.
func cmdAskPlan(_ o: Options) async throws {
    guard let q = o.positional.first else { throw CLIError("usage: ask-plan <question> --db <db> [--expect a,b]") }
    let stack = try await openStack(o)
    var names: [String: String] = [:]
    if let data = FileManager.default.contents(atPath: stack.storageDir + "/app_names.json"),
       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] { names = dict }
    let known = names.map { AIQueryApp(name: $0.value, bundleID: $0.key) }
    let plan = AIQueryPlanner.plan(question: q, now: Date(), apps: known)
    out("plan: \(plan.summary)")
    for f in plan.facets { out("  facet: \(f.terms.joined(separator: " ")) | expanded: \(AIQueryPlanner.expandedTerms(for: f).joined(separator: " "))") }
    let memory = AISearchMemory(fileURL: URL(fileURLWithPath: stack.storageDir).appendingPathComponent("ai_search_memory.json"))
    let retriever = AIEvidenceRetriever(database: stack.db, ftsEngine: stack.fts, appNames: names, memory: o.has("no-memory") ? nil : memory)
    let pack = await retriever.retrieve(plan: plan)
    out("memory hints used: \(pack.usedHints.count)")
    out("evidence: \(pack.evidence.count) frames, anchors: \(pack.anchors.count)")
    out("timings ms: " + pack.timingsMs.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.0f", $0.value))" }.joined(separator: " "))
    out("--- preamble ---\n" + pack.promptPreamble())
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let maxChars = o.int("chars", 350)
    for e in pack.evidence {
        out("--- #\(e.frameID) \(df.string(from: e.timestamp)) \(e.appName) cov=\(String(format: "%.2f", e.coverage)) rel=\(String(format: "%.2f", e.relevance)) scoped=\(e.scoped) facets=\(e.facetLabels.count)")
        out(String(e.snippet.prefix(maxChars)))
    }
    if let expect = o.flags["expect"] {
        let blob = pack.evidence.map(\.snippet).joined(separator: "\n").lowercased()
        for token in expect.split(separator: ",").map({ String($0).lowercased() }) {
            out("expect '\(token)': \(blob.contains(token) ? "FOUND" : "missing")")
        }
    }
    out("context chars ≈ \(pack.evidence.map { $0.snippet.count }.reduce(0, +))")
    if o.has("learn") {
        // Stand-in for "the model cited this evidence": every frame with usable coverage counts as cited.
        let cited = Set(pack.evidence.filter { $0.coverage >= 0.7 }.map(\.frameID))
        let total = try? await stack.db.getFrameCount()
        let n = await memory.learn(from: pack, citedFrameIDs: cited, ftsEngine: stack.fts, totalDocuments: total)
        out("learned from \(n) facet(s); memory now holds \(await memory.list().count) recipe(s)")
    }
}

func cmdMemory(_ o: Options) async throws {
    guard let dbPath = o.flags["db"] else { throw CLIError("--db required") }
    let dir = o.flags["storage-dir"] ?? URL(fileURLWithPath: dbPath).deletingLastPathComponent().path
    let live = AppPaths.defaultStorageRoot
    if URL(fileURLWithPath: dir).resolvingSymlinksInPath().path == URL(fileURLWithPath: live).resolvingSymlinksInPath().path, !o.has("allow-live") {
        throw CLIError("refusing to touch the live memory file; pass --allow-live")
    }
    let memory = AISearchMemory(fileURL: URL(fileURLWithPath: dir).appendingPathComponent("ai_search_memory.json"))
    switch o.positional.first ?? "list" {
    case "clear": await memory.clear(); out("memory cleared")
    default:
        let recipes = await memory.list()
        out("\(recipes.count) recipe(s)")
        for r in recipes {
            out("- terms=\(r.terms.joined(separator: ",")) apps=\(r.bundleIDs.joined(separator: ",")) phrases=\(r.phrases) hits=\(r.hits) misses=\(r.misses)")
        }
    }
}

/// Full pipeline with NO network: plan → evidence → Apple's on-device model answers.
func cmdAskLocal(_ o: Options) async throws {
    guard let q = o.positional.first else { throw CLIError("usage: ask-local <question> --db <db>") }
    let tier: OnDeviceLanguageModel.Tier = o.flags["tier"] == "pcc" ? .privateCloud : .onDevice
    guard OnDeviceLanguageModel.isAvailable(tier) else { throw CLIError("Apple's \(tier.displayName) model is not available on this Mac") }
    let stack = try await openStack(o)
    var names: [String: String] = [:]
    if let data = FileManager.default.contents(atPath: stack.storageDir + "/app_names.json"),
       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] { names = dict }
    let known = names.map { AIQueryApp(name: $0.value, bundleID: $0.key) }
    let memory = AISearchMemory(fileURL: URL(fileURLWithPath: stack.storageDir).appendingPathComponent("ai_search_memory.json"))
    // The snapshot ends before "now"; --now lets the demo act as if asked right after the last captured frame.
    var now = Date()
    if let iso = o.flags["now"], let d = ISO8601DateFormatter().date(from: iso) { now = d }
    let plan = AIQueryPlanner.plan(question: q, now: now, apps: known)
    let retriever = AIEvidenceRetriever(database: stack.db, ftsEngine: stack.fts, appNames: names, memory: memory)
    var pack = await retriever.retrieve(plan: plan)
    out("plan: \(plan.summary) | evidence: \(pack.evidence.count) frames")

    if o.has("refine"), !pack.weakFacets.isEmpty {
        let t0 = Date()
        pack = await AIQueryRefiner.refine(pack: pack, retriever: retriever, transport: OnDeviceTransport(tier: tier), knownApps: known, rounds: 2)
        out(String(format: "on-device refinement: %.1fs, evidence now %d frames, plan %@", Date().timeIntervalSince(t0), pack.evidence.count, pack.plan.summary))
    }

    let ctx = await OnDeviceLanguageModel.contextTokens(tier)
    let fitted = OnDeviceLanguageModel.fit(query: q, frames: pack.contextFrames(), preamble: pack.promptPreamble(), contextTokens: ctx)
    out("context window: \(ctx) tokens; prompt chars: \(fitted.prompt.count); frames used: \(fitted.framesUsed)/\(pack.evidence.count)")
    if o.has("show-prompt") { out("--- prompt ---\n" + fitted.prompt) }
    let t0 = Date()
    var answer = ""
    var first: Double?
    for try await tok in OnDeviceLanguageModel.stream(system: OnDeviceLanguageModel.systemPrompt, user: fitted.prompt, tier: tier) {
        if first == nil { first = Date().timeIntervalSince(t0) }
        answer += tok
    }
    out(String(format: "first token %.1fs, total %.1fs", first ?? -1, Date().timeIntervalSince(t0)))
    out("--- answer ---\n" + answer)
}

func cmdAsk(_ o: Options) async throws {
    guard let q = o.positional.first else { throw CLIError("usage: ask <question> --db <db> --model <slug> --send") }
    let stack = try await openStack(o)
    let reasoner = CognitiveReasoner(database: stack.db, ftsEngine: stack.fts, entityMesh: stack.mesh)
    let ctx = try await reasoner.planAndRetrieveContext(query: q, maxFrames: o.int("limit", 30))
    let chars = ctx.frames.map { $0.summaryText.count }.reduce(0, +)
    out("context: \(ctx.frames.count) frames, ~\(chars / 4) tokens of screen text")
    guard o.has("send") else {
        out("dry run. Re-run with --send --model <slug> (and OPENROUTER_API_KEY in env) to transmit this OCR text to OpenRouter.")
        return
    }
    guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else { throw CLIError("OPENROUTER_API_KEY not set") }
    guard let model = o.flags["model"] else { throw CLIError("--model required") }
    let frames = ctx.frames.map { OpenRouterContextFrame(frameID: $0.frameID, timestamp: $0.timestamp, appName: $0.appName, windowTitle: $0.windowTitle, browserURL: $0.browserURL, extractedText: $0.summaryText) }
    let clock = ContinuousClock(); let start = clock.now
    var first: Double?
    var answer = ""
    for try await tok in OpenRouterClient().streamAnswerQuery(query: q, contextFrames: frames, apiKey: key, model: model) {
        if first == nil { first = ms(start.duration(to: clock.now)) }
        answer += tok
    }
    out("time to first token: \(first ?? -1) ms; total \(ms(start.duration(to: clock.now))) ms; \(answer.count) chars")
    out(answer)
}

@main
struct RetraceCLI {
    static func main() async {
        let o = Options.parse(CommandLine.arguments)
        do {
            switch o.command {
            case "vector-status": try await cmdVectorStatus(o)
            case "search": try await cmdSearch(o)
            case "ai-context": try await cmdAIContext(o)
            case "bench": try await cmdBench(o)
            case "index-bench": try await cmdIndexBench(o)
            case "rebuild-vectors": try await cmdRebuildVectors(o)
            case "ask-plan": try await cmdAskPlan(o)
            case "memory": try await cmdMemory(o)
            case "ask-local": try await cmdAskLocal(o)
            case "ask": try await cmdAsk(o)
            default:
                out("""
                retrace-cli <command> --db <snapshot retrace.db> [--storage-dir <dir>]
                  vector-status              file vs metadata vector counts, init behaviour
                  search <q> [--any] [--limit N] [--repeat N]   per-stage timings of the search pipeline
                  ai-context <question>      what the Ask-AI context builder would send (no network)
                  bench --queries <file>     p50/p95 across many queries
                  index-bench [--n 20]       time each step of the baseline indexing stage
                  rebuild-vectors [--n 2000] [--queries f]   embed existing descriptions into the snapshot index; report similarity stats
                  memory [list|clear]        inspect/clear the learned search hints (snapshot dir only)
                  ask-plan <question> [--expect a,b] [--learn] [--no-memory]   new planner + evidence retriever (no network); prints what the LLM would see
                  ask-local <question> [--tier pcc] [--refine] [--now ISO]   plan → evidence → Apple on-device model answers (fully offline)
                  ask <question> --model <slug> --send   OPT-IN: sends OCR text to OpenRouter (key via OPENROUTER_API_KEY)
                """)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
