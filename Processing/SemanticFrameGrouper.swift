import Foundation

/// Collapses runs of near-identical pending frames so the cloud vision model is asked about each distinct screen
/// once. Pure value logic (no I/O, no clock) so it can be table-tested on real-shaped rows.
///
/// Why: capture runs every ~2s and pending frames are selected newest-first, so a batch of 5–12 used to be mostly
/// consecutive shots of the *same* screen. Replaying these exact rules over the live backlog (111K baseline-only
/// frames, batches of 12) one request-slot covers ~1.2× as many frames for the newest pending frames (half of which
/// have not been OCR'd yet, so cannot be grouped) and ~2–5× for older backlog. Spending a request slot on each of them describes the same screen several times and leaves the model no
/// distinct workflow to reason across. One representative per run goes to the model; its description is then
/// written to the rest of the run (their own OCR text is already indexed, so what the model uniquely adds — the
/// visual layer — is what the run shares).
///
/// Deliberately conservative — a frame only joins a group when ALL of these hold:
///  * same segment, or same app + window + URL;
///  * ≥ `minTokens` OCR tokens on both sides. Text-light frames (video, photos, canvases) can look identical to
///    OCR while differing visually, so they are never grouped;
///  * token Jaccard against the group's **anchor** (its first frame) ≥ `minJaccard` — anchored rather than
///    chained, so a slowly scrolling document cannot drift one small step at a time into a different screen;
///  * at most `maxChangedTokens` tokens differ from the anchor;
///  * ≤ `maxGapMs` since the previous member, ≤ `maxSpanMs` since the anchor, ≤ `maxGroupSize` members.
struct SemanticFrameGrouper: Sendable {

    struct Config: Sendable {
        var minTokens: Int = 8
        var minJaccard: Double = 0.9
        var maxGapMs: Int64 = 90_000
        var maxSpanMs: Int64 = 300_000
        /// Cap on tokens that differ between anchor and candidate. Jaccard alone lets a large static sidebar hide a
        /// completely different main pane (seen with chat apps); a ticking value or cursor changes only a few tokens.
        var maxChangedTokens: Int = 12
        var maxGroupSize: Int = 40
    }

    struct Frame: Sendable, Equatable {
        let frameID: Int64
        let segmentID: Int64
        /// `bundleID|windowName|browserURL`, so a context that re-opens as a new segment can still group.
        let contextKey: String
        let createdAtMs: Int64
        /// nil when the frame has no OCR text row at all.
        let tokens: Set<String>?
    }

    struct Group: Sendable, Equatable {
        /// The member whose description stands for the whole run (nearest the temporal middle).
        let representative: Frame
        /// Every other member, chronological.
        let siblings: [Frame]

        var captureCount: Int { siblings.count + 1 }
        /// First-to-last capture time of the run.
        var spanMs: Int64 {
            let all = siblings.map(\.createdAtMs) + [representative.createdAtMs]
            return (all.max() ?? 0) - (all.min() ?? 0)
        }
    }

    var config = Config()

    // MARK: - Tokens

    /// Lowercased alphanumeric words of ≥3 characters — the same shape the live-backlog measurement used.
    static func tokens(from text: String) -> Set<String> {
        var result = Set<String>()
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else {
                if current.count >= 3 { result.insert(current) }
                current.removeAll(keepingCapacity: true)
            }
        }
        if current.count >= 3 { result.insert(current) }
        return result
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        return Double(intersection) / Double(a.count + b.count - intersection)
    }

    // MARK: - Grouping

    /// Groups `frames` (given in selection-priority order). The result keeps that priority order: a group sits where
    /// its highest-priority member sat, so "newest first" selection still picks the newest screens first.
    func group(_ frames: [Frame]) -> [Group] {
        let priority = Dictionary(frames.enumerated().map { ($1.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        let chronological = frames.sorted { ($0.createdAtMs, $0.frameID) < ($1.createdAtMs, $1.frameID) }

        var runs: [[Frame]] = []
        var anchor: Frame?
        var current: [Frame] = []
        for frame in chronological {
            if let anchor, let previous = current.last, canJoin(frame, anchor: anchor, previous: previous, size: current.count) {
                current.append(frame)
            } else {
                if !current.isEmpty { runs.append(current) }
                anchor = frame
                current = [frame]
            }
        }
        if !current.isEmpty { runs.append(current) }

        let groups = runs.map { run -> (rank: Int, group: Group) in
            let middle = run.count / 2
            let representative = run[middle]
            var siblings = run
            siblings.remove(at: middle)
            let rank = run.compactMap { priority[$0.frameID] }.min() ?? Int.max
            return (rank, Group(representative: representative, siblings: siblings))
        }
        return groups.sorted { $0.rank < $1.rank }.map(\.group)
    }

    private func canJoin(_ frame: Frame, anchor: Frame, previous: Frame, size: Int) -> Bool {
        guard size < config.maxGroupSize,
              frame.segmentID == anchor.segmentID || frame.contextKey == anchor.contextKey,
              frame.createdAtMs - previous.createdAtMs <= config.maxGapMs,
              frame.createdAtMs - anchor.createdAtMs <= config.maxSpanMs,
              let anchorTokens = anchor.tokens, let tokens = frame.tokens,
              anchorTokens.count >= config.minTokens, tokens.count >= config.minTokens else { return false }
        return Self.jaccard(anchorTokens, tokens) >= config.minJaccard
            && anchorTokens.symmetricDifference(tokens).count <= config.maxChangedTokens
    }
}

// MARK: - Failure backoff

/// Spaces out retries while the provider is down. About 40% of deep-indexing requests fail on provider-side 502s,
/// and they come in bursts: on the live history P(fail) is 0.32 after a success but 0.91 once six requests in a row
/// have failed, and the 11:00–13:00 UTC window fails 80–91% of the time. Every failed attempt still counts against
/// the daily request cap, so retrying every 30s through an outage burns the day's budget on requests that cannot
/// succeed. Time is not the scarce resource (the cap is reached in 4–24h), so the cost of waiting is small.
///
/// Only availability failures count (5xx, embedded-200 errors, timeouts, transport). Size rejections, auth errors
/// and cancellations say nothing about provider health and leave the streak alone.
struct SemanticFailureBackoff: Sendable, Equatable {
    private(set) var consecutiveFailures = 0

    /// Failures tolerated at the normal polling cadence before backing off.
    static let freeFailures = 2
    static let ladderSeconds = [120, 300, 600, 1200]

    mutating func recordSuccess() { consecutiveFailures = 0 }

    mutating func recordAvailabilityFailure() { consecutiveFailures += 1 }

    /// Extra wait before the next attempt, or nil to keep the normal cadence.
    var delaySeconds: Int? {
        let beyondFree = consecutiveFailures - Self.freeFailures
        guard beyondFree > 0 else { return nil }
        return Self.ladderSeconds[min(beyondFree, Self.ladderSeconds.count) - 1]
    }
}
