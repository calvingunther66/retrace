import Foundation
import Shared

/// Clusters multi-app activity into cognitive task episodes and identifies salient keyframes.
///
/// Converts a stream of 2-second raw captures into meaningful cognitive episodes (e.g. "Debugging SQLite locking")
/// and filters out 90%+ of redundant typing/scrolling frames by scoring keyframe salience.
public actor CognitiveSessionizer: CognitiveSessionizerProtocol {

    // MARK: - Dependencies

    private let database: any DatabaseProtocol
    private let maxEpisodeDuration: TimeInterval = 45 * 60 // 45 minutes max per episode
    private let maxIdleGap: TimeInterval = 3 * 60          // 3 minutes idle gap creates new episode

    // In-memory state tracking current open episode
    private var activeEpisode: CognitiveEpisode?
    private var lastProcessedFrameTime: Date?
    private var lastProcessedText: String = ""
    private var lastProcessedApp: String = ""
    private var lastProcessedTitle: String = ""

    // MARK: - Initialization

    public init(database: any DatabaseProtocol) {
        self.database = database
    }

    // MARK: - Clustering

    public func clusterFrames(_ candidates: [PendingCognitiveFrame]) async throws -> [CognitiveEpisode] {
        guard !candidates.isEmpty else { return [] }

        // Sort chronologically
        let sorted = candidates.sorted { $0.timestamp < $1.timestamp }
        var generatedEpisodes: [CognitiveEpisode] = []

        // If we don't have an active episode, attempt to resume latest from database
        if activeEpisode == nil {
            activeEpisode = try await database.getLatestCognitiveEpisode()
        }

        for frame in sorted {
            let shouldStartNewEpisode = evaluateEpisodeBoundary(for: frame)

            if shouldStartNewEpisode || activeEpisode == nil {
                // Finalize active episode if it exists
                if let current = activeEpisode {
                    try await database.updateCognitiveEpisode(
                        episodeId: current.id,
                        endTime: current.endTime,
                        title: current.title,
                        summary: current.summary,
                        primaryAppBundleID: current.primaryAppBundleID,
                        keyframeIDs: current.keyframeIDs
                    )
                    generatedEpisodes.append(current)
                }

                // Start new episode
                let defaultTitle = generateEpisodeTitle(appName: frame.appName, windowTitle: frame.windowTitle)
                let newEpisode = CognitiveEpisode(
                    startTime: frame.timestamp,
                    endTime: frame.timestamp,
                    title: defaultTitle,
                    summary: nil,
                    primaryAppBundleID: frame.appName,
                    keyframeIDs: [],
                    createdAt: Date()
                )

                let newId = try await database.insertCognitiveEpisode(newEpisode)
                activeEpisode = CognitiveEpisode(
                    id: newId,
                    startTime: newEpisode.startTime,
                    endTime: newEpisode.endTime,
                    title: newEpisode.title,
                    summary: newEpisode.summary,
                    primaryAppBundleID: newEpisode.primaryAppBundleID,
                    keyframeIDs: [],
                    createdAt: newEpisode.createdAt
                )
            }

            // Compute salience score for frame
            let salience = computeSalienceScore(for: frame)
            let isKeyframe = salience >= 0.50

            guard var current = activeEpisode else { continue }

            // Extend episode end time
            current = CognitiveEpisode(
                id: current.id,
                startTime: current.startTime,
                endTime: max(current.endTime, frame.timestamp),
                title: current.title,
                summary: current.summary,
                primaryAppBundleID: current.primaryAppBundleID,
                keyframeIDs: isKeyframe ? current.keyframeIDs + [frame.frameID] : current.keyframeIDs,
                createdAt: current.createdAt
            )
            activeEpisode = current

            // Link frame to episode
            try await database.linkFrameToEpisode(
                episodeId: current.id,
                frameId: frame.frameID,
                salienceScore: salience,
                isKeyframe: isKeyframe
            )

            // Update tracking variables
            lastProcessedFrameTime = frame.timestamp
            lastProcessedText = frame.ocrText
            lastProcessedApp = frame.appName
            lastProcessedTitle = frame.windowTitle ?? ""
        }

        // Persist final active episode state
        if let current = activeEpisode {
            try await database.updateCognitiveEpisode(
                episodeId: current.id,
                endTime: current.endTime,
                title: current.title,
                summary: current.summary,
                primaryAppBundleID: current.primaryAppBundleID,
                keyframeIDs: current.keyframeIDs
            )
            generatedEpisodes.append(current)
        }

        return generatedEpisodes
    }

    // MARK: - Lookup

    public func getEpisode(for frameID: FrameID) async throws -> CognitiveEpisode? {
        try await database.getCognitiveEpisodeForFrame(frameId: frameID.value)
    }

    public func getEpisodes(from startDate: Date, to endDate: Date, limit: Int = 50) async throws -> [CognitiveEpisode] {
        try await database.getCognitiveEpisodes(from: startDate, to: endDate, limit: limit)
    }

    // MARK: - Boundary Detection & Salience

    private func evaluateEpisodeBoundary(for frame: PendingCognitiveFrame) -> Bool {
        guard let current = activeEpisode else { return true }

        // Condition 1: Long idle gap between frames
        if let lastTime = lastProcessedFrameTime, frame.timestamp.timeIntervalSince(lastTime) > maxIdleGap {
            return true
        }

        // Condition 2: Max episode duration reached
        if frame.timestamp.timeIntervalSince(current.startTime) > maxEpisodeDuration {
            return true
        }

        return false
    }

    private func computeSalienceScore(for frame: PendingCognitiveFrame) -> Double {
        var score: Double = 0.1 // Base score

        // Signal 1: Application Switch (+0.4)
        if !lastProcessedApp.isEmpty && frame.appName != lastProcessedApp {
            score += 0.4
        }

        // Signal 2: Window Title Change (+0.3)
        let currentTitle = frame.windowTitle ?? ""
        if !lastProcessedTitle.isEmpty && currentTitle != lastProcessedTitle {
            score += 0.3
        }

        // Signal 3: Substantial Text Novelty (+0.3)
        let newTokens = Set(frame.ocrText.lowercased().split(separator: " ").map(String.init))
        let oldTokens = Set(lastProcessedText.lowercased().split(separator: " ").map(String.init))
        let diff = newTokens.subtracting(oldTokens)
        if diff.count > 10 {
            score += 0.3
        }

        // Signal 4: First frame in episode is always a keyframe
        if activeEpisode?.keyframeIDs.isEmpty ?? true {
            score += 0.6
        }

        return min(1.0, score)
    }

    private func generateEpisodeTitle(appName: String, windowTitle: String?) -> String {
        let cleanApp = appName.replacingOccurrences(of: "com.apple.", with: "").capitalized
        if let windowTitle, !windowTitle.isEmpty {
            let shortened = windowTitle.prefix(40)
            return "\(cleanApp) · \(shortened)"
        }
        return "Working in \(cleanApp)"
    }
}
