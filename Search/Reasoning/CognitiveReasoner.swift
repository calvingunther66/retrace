import Foundation
import Shared

/// Multi-hop associative retrieval orchestrator and reasoning engine for "Ask AI".
///
/// Replaces naive keyword context dumping with a 3-hop associative memory expansion:
/// 1. Direct Hybrid Candidates (Lexical + Vector)
/// 2. Temporal Neighborhood Expansion (±60s causal context)
/// 3. Entity Graph Expansion (co-occurring files, URLs, tickets, collaborators)
///
/// Formats the context into an information-dense chronological storyboard grouped by Episode,
/// and streams synthesized reasoning with verified jump-citations.
public actor CognitiveReasoner: CognitiveReasonerProtocol {

    // MARK: - Dependencies

    private let database: any DatabaseProtocol
    private let ftsEngine: any FTSProtocol
    private let entityMesh: EntityMeshManager
    private let openRouterClient: OpenRouterClient

    // MARK: - Initialization

    public init(
        database: any DatabaseProtocol,
        ftsEngine: any FTSProtocol,
        entityMesh: EntityMeshManager,
        openRouterClient: OpenRouterClient = OpenRouterClient()
    ) {
        self.database = database
        self.ftsEngine = ftsEngine
        self.entityMesh = entityMesh
        self.openRouterClient = openRouterClient
    }

    // MARK: - Context Planning & Multi-Hop Retrieval

    public func planAndRetrieveContext(
        query: String,
        maxFrames: Int = 30
    ) async throws -> CognitiveStoryboardContext {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Hop 1: Direct FTS Candidates from Database
        // Use loose OR query on terms for natural-language questions
        let parsedQuery = try QueryParser().parse(rawQuery: cleanQuery)
        let ftsQuery = SearchManager.buildScopedFTSQuery(for: parsedQuery, matchAny: true)

        let initialMatches = (try? await ftsEngine.search(
            query: ftsQuery,
            filters: SearchFilters(),
            limit: min(maxFrames, 20),
            offset: 0
        )) ?? []

        var candidateFrameIDs = initialMatches.map { (m: FTSMatch) -> Int64 in m.frameID.value }

        // Hop 2: Entity Graph Expansion
        // Check if query or individual tokens match known entities
        var entityCandidates = (try? await entityMesh.findEntities(type: nil, prefix: cleanQuery, limit: 5)) ?? []
        let tokens = cleanQuery.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
        for token in tokens {
            if let directMatches = try? await entityMesh.findEntities(type: nil, prefix: token, limit: 3) {
                for m in directMatches where !entityCandidates.contains(where: { $0.id == m.id }) {
                    entityCandidates.append(m)
                }
            }
        }

        for ent in entityCandidates {
            let entityFrames = (try? await entityMesh.findFramesForEntity(normalizedValue: ent.normalizedValue, limit: 15)) ?? []
            candidateFrameIDs.append(contentsOf: entityFrames)
        }

        // Hop 3: Temporal Neighborhood Expansion
        // For top candidate frames, pull surrounding keyframes (±60s) to capture causal context
        var expandedFrameIDs = Set<Int64>(candidateFrameIDs)
        for focalID in candidateFrameIDs.prefix(5) {
            if let focalFrame = try await database.getFrame(id: FrameID(value: focalID)) {
                let startNeighbor = focalFrame.timestamp.addingTimeInterval(-60)
                let endNeighbor = focalFrame.timestamp.addingTimeInterval(60)

                let neighbors = (try? await database.getFrames(from: startNeighbor, to: endNeighbor, limit: 10)) ?? []
                for n in neighbors {
                    expandedFrameIDs.insert(n.id.value)
                }
            }
        }

        let resolvedFrameIDs = Array(expandedFrameIDs.prefix(maxFrames))

        // Build Storyboard Frames
        var storyboardFrames: [CognitiveStoryboardFrame] = []
        var episodesFound: [CognitiveEpisode] = []
        var allEntities: [MemoryEntity] = []

        for frameID in resolvedFrameIDs {
            guard let frameWithInfo = try await database.getFrameWithVideoInfoByID(id: FrameID(value: frameID)) else {
                continue
            }
            let ocrData = try await database.getOCRTextForFrame(frameID: frameID)
            let episode = try await database.getCognitiveEpisodeForFrame(frameId: frameID)
            let entities = try await database.getEntitiesForFrame(frameId: frameID)

            if let episode, !episodesFound.contains(where: { $0.id == episode.id }) {
                episodesFound.append(episode)
            }
            for ent in entities {
                if !allEntities.contains(where: { $0.id == ent.id }) {
                    allEntities.append(ent)
                }
            }

            let textContent = ocrData?.mainText ?? ""
            let preview = textContent.count > 400 ? String(textContent.prefix(400)) + "..." : textContent

            storyboardFrames.append(CognitiveStoryboardFrame(
                frameID: frameID,
                timestamp: frameWithInfo.frame.timestamp,
                appName: frameWithInfo.frame.metadata.appName ?? frameWithInfo.frame.metadata.appBundleID ?? "Unknown",
                windowTitle: frameWithInfo.frame.metadata.windowName,
                browserURL: frameWithInfo.frame.metadata.browserURL,
                summaryText: preview,
                isKeyframe: true,
                episodeTitle: episode?.title,
                entities: entities.map { (e: MemoryEntity) -> String in e.displayName }
            ))
        }

        // Sort storyboard frames chronologically
        storyboardFrames.sort { $0.timestamp < $1.timestamp }

        // Assemble Storyboard Prompt
        let assembledPrompt = assembleStoryboardPrompt(
            query: cleanQuery,
            episodes: episodesFound,
            frames: storyboardFrames,
            entities: allEntities
        )

        return CognitiveStoryboardContext(
            query: cleanQuery,
            episodes: episodesFound,
            frames: storyboardFrames,
            relatedEntities: allEntities,
            assembledPromptText: assembledPrompt
        )
    }

    // MARK: - Streaming Reasoning

    public func streamAnswer(
        query: String,
        context: CognitiveStoryboardContext,
        apiKey: String,
        model: String,
        temperature: Double = 0.2
    ) -> AsyncThrowingStream<String, Error> {
        let openRouterContextFrames = context.frames.map { f in
            OpenRouterContextFrame(
                frameID: f.frameID,
                timestamp: f.timestamp,
                appName: f.appName,
                windowTitle: f.windowTitle,
                browserURL: f.browserURL,
                extractedText: f.summaryText
            )
        }

        return openRouterClient.streamAnswerQuery(
            query: query,
            contextFrames: openRouterContextFrames,
            apiKey: apiKey,
            model: model,
            temperature: temperature
        )
    }

    // MARK: - Prompt Assembly

    private func assembleStoryboardPrompt(
        query: String,
        episodes: [CognitiveEpisode],
        frames: [CognitiveStoryboardFrame],
        entities: [MemoryEntity]
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        var prompt = "User Query: \"\(query)\"\n\n"

        if !entities.isEmpty {
            prompt += "Identified Context Entities: \(entities.prefix(8).map(\.displayName).joined(separator: ", "))\n\n"
        }

        prompt += "Chronological Storyboard Records:\n\n"

        if frames.isEmpty {
            prompt += "(No matching episodic screen records found in local memory)\n"
            return prompt
        }

        // Group frames by episode title
        var currentEpisode: String? = nil

        for frame in frames {
            let epTitle = frame.episodeTitle ?? "Working Session"
            if epTitle != currentEpisode {
                currentEpisode = epTitle
                prompt += "=== Episode: \(epTitle) ===\n"
            }

            let timeStr = formatter.string(from: frame.timestamp)
            prompt += "• [Frame #\(frame.frameID)] (\(timeStr)) [\(frame.appName)]"
            if let title = frame.windowTitle, !title.isEmpty {
                prompt += " Window: \"\(title)\""
            }
            if let url = frame.browserURL, !url.isEmpty {
                prompt += " URL: \(url)"
            }
            prompt += "\n  Text: \(frame.summaryText)\n\n"
        }

        prompt += "Instructions: Synthesize a clear, direct answer to the user query citing specific [Frame #<ID>] tags."
        return prompt
    }
}
