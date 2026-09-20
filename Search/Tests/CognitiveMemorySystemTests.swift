import XCTest
import Foundation
import Shared
import Database
@testable import Search

final class CognitiveMemorySystemTests: XCTestCase {

    private var database: DatabaseManager!
    private var vectorEngine: AcceleratedVectorEngine!
    private var entityMesh: EntityMeshManager!
    private var sessionizer: CognitiveSessionizer!
    private var reasoner: CognitiveReasoner!
    private var ftsEngine: FTSManager!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("test.db").path
        database = DatabaseManager(databasePath: dbPath)
        try await database.initialize()

        ftsEngine = FTSManager(databasePath: dbPath)
        try await ftsEngine.initialize()

        vectorEngine = AcceleratedVectorEngine(
            database: database,
            dimensions: 64,
            modelName: "test-model",
            storageDirectory: tempDir
        )
        try await vectorEngine.initialize()

        entityMesh = EntityMeshManager(database: database)
        sessionizer = CognitiveSessionizer(database: database)
        reasoner = CognitiveReasoner(
            database: database,
            ftsEngine: ftsEngine,
            entityMesh: entityMesh
        )
    }

    override func tearDown() async throws {
        try? await vectorEngine.clear()
        try? FileManager.default.removeItem(at: tempDir)
        try await ftsEngine.close()
        try await database.close()
        database = nil
        vectorEngine = nil
        entityMesh = nil
        sessionizer = nil
        reasoner = nil
    }

    // MARK: - Accelerated Vector Engine Tests

    func testAcceleratedVectorEngineSIMDSearch() async throws {
        // Generate orthogonal test vectors of dimension 64
        var vecA = [Float](repeating: 0, count: 64)
        var vecB = [Float](repeating: 0, count: 64)
        vecA[0] = 1.0
        vecB[1] = 1.0

        let frameA = FrameID(value: 101)
        let frameB = FrameID(value: 102)

        try await vectorEngine.addVector(frameID: frameA, vector: vecA)
        try await vectorEngine.addVector(frameID: frameB, vector: vecB)

        let count = await vectorEngine.vectorCount
        XCTAssertEqual(count, 2)

        // Query closer to vector A
        var query = [Float](repeating: 0, count: 64)
        query[0] = 0.95
        query[1] = 0.05

        let nearest = try await vectorEngine.searchNearest(queryVector: query, limit: 2)

        XCTAssertEqual(nearest.count, 2)
        XCTAssertEqual(nearest[0].frameID, frameA)
        XCTAssertGreaterThan(nearest[0].similarity, 0.90)
        XCTAssertLessThan(nearest[1].similarity, 0.20)
    }

    func testOnDeviceEmbeddingSynthesis() async throws {
        let text = "Xcode debugging Swift database concurrency issues"
        let vec = await vectorEngine.embedTextOnDevice(text)

        XCTAssertEqual(vec.count, 64)
        // Verify vector is not all zeros
        let nonZero = vec.contains { abs($0) > 0.0001 }
        XCTAssertTrue(nonZero, "Synthesized on-device embedding should not be all zeros")
    }

    // MARK: - Entity Mesh Tests

    func testEntityMeshHarvestingAndAssociation() async throws {
        let sampleOCR = """
        Fixing crash in /Users/dev/retrace/Search/SearchManager.swift
        Linear ticket RET-404 discussed with @sarah on https://github.com/org/repo
        """

        let frameID: Int64 = 5001
        let harvested = try await entityMesh.harvestEntities(
            from: sampleOCR,
            appName: "com.apple.dt.Xcode",
            windowTitle: "SearchManager.swift - retrace",
            browserURL: nil,
            frameID: frameID,
            episodeID: nil
        )

        XCTAssertFalse(harvested.isEmpty)

        // Validate entity types were harvested
        let types = Set(harvested.map(\.entityType))
        XCTAssertTrue(types.contains(.file), "Should harvest file path entity")
        XCTAssertTrue(types.contains(.ticket), "Should harvest ticket entity")
        XCTAssertTrue(types.contains(.person), "Should harvest person @mention entity")
        XCTAssertTrue(types.contains(.url), "Should harvest URL entity")

        // Validate mentions in database
        let frameEntities = try await database.getEntitiesForFrame(frameId: frameID)
        XCTAssertGreaterThanOrEqual(frameEntities.count, 4)

        // Validate co-occurrence associations exist between them
        if let ticketEntity = frameEntities.first(where: { $0.entityType == .ticket }) {
            let associated = try await entityMesh.findAssociatedEntities(for: ticketEntity.id, limit: 10)
            XCTAssertFalse(associated.isEmpty, "Associated entities should exist for ticket")
            XCTAssertGreaterThanOrEqual(associated[0].weight, 1.0)
        }
    }

    // MARK: - Cognitive Sessionizer Tests

    func testCognitiveSessionizerClusteringAndKeyframeSalience() async throws {
        let t0 = Date()
        let t1 = t0.addingTimeInterval(2)
        let t2 = t0.addingTimeInterval(4)
        let t3 = t0.addingTimeInterval(300) // 5 minutes later (triggers new episode boundary)

        let frame1 = PendingCognitiveFrame(
            frameID: 1001,
            timestamp: t0,
            appName: "com.apple.dt.Xcode",
            windowTitle: "Retrace.xcodeproj",
            ocrText: "Initial project load"
        )
        let frame2 = PendingCognitiveFrame(
            frameID: 1002,
            timestamp: t1,
            appName: "com.apple.dt.Xcode",
            windowTitle: "Retrace.xcodeproj",
            ocrText: "Initial project load" // Redundant text
        )
        let frame3 = PendingCognitiveFrame(
            frameID: 1003,
            timestamp: t2,
            appName: "com.google.Chrome",
            windowTitle: "StackOverflow - Swift Actors", // App switch + title change
            ocrText: "Actors provide synchronization for shared mutable state"
        )
        let frame4 = PendingCognitiveFrame(
            frameID: 1004,
            timestamp: t3,
            appName: "com.apple.Terminal",
            windowTitle: "zsh - build",
            ocrText: "swift build complete"
        )

        let episodes = try await sessionizer.clusterFrames([frame1, frame2, frame3, frame4])

        // Should produce 2 distinct episodes due to 5-minute idle gap
        XCTAssertEqual(episodes.count, 2)

        // Verify keyframes
        let ep1 = episodes[0]
        let keyframes = try await database.getKeyframesForEpisode(episodeId: ep1.id)
        XCTAssertFalse(keyframes.isEmpty)
        XCTAssertTrue(keyframes.contains(1001), "First frame of episode should be marked keyframe")
    }

    // MARK: - Cognitive Reasoner Tests

    func testCognitiveReasonerStoryboardAssembly() async throws {
        // Insert a video segment and frame into database
        let now = Date()
        let segID = try await database.insertSegment(
            bundleID: "com.apple.dt.Xcode",
            startDate: now,
            endDate: now,
            windowName: "SearchManager.swift",
            browserUrl: nil,
            type: 0
        )
        let frameRef = FrameReference(
            id: FrameID(value: 9001),
            timestamp: now,
            segmentID: AppSegmentID(value: segID),
            frameIndexInSegment: 0,
            metadata: FrameMetadata(
                appBundleID: "com.apple.dt.Xcode",
                appName: "Xcode",
                windowName: "SearchManager.swift",
                browserURL: nil
            )
        )
        let insertedFrameID = try await database.insertFrame(frameRef)
        try await database.markFrameReadable(frameID: insertedFrameID)

        // Add entity mention
        let entId = try await database.upsertMemoryEntity(
            entityType: MemoryEntityType.ticket.rawValue,
            normalizedValue: "RET-900",
            displayName: "RET-900"
        )
        try await database.recordEntityMention(entityId: entId, frameId: insertedFrameID)

        // Retrieve context using Cognitive Reasoner
        let context = try await reasoner.planAndRetrieveContext(query: "RET-900", maxFrames: 10)

        XCTAssertFalse(context.frames.isEmpty, "Context should contain frames expanded from entity graph")
        XCTAssertTrue(context.assembledPromptText.contains("[Frame #\(insertedFrameID)]"))
        XCTAssertTrue(context.assembledPromptText.contains("Xcode"))
        XCTAssertTrue(context.assembledPromptText.contains("RET-900"))
    }
}
