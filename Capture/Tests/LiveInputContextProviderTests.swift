import XCTest
import CoreGraphics
import Shared
@testable import Capture

/// Exercises the real CoreGraphics display/window APIs. Accessibility is not assumed to be granted
/// to the test runner, so these assert only what must hold either way.
final class LiveInputContextProviderTests: XCTestCase {

    func testDisplayLayoutDescribesRealDisplaysInPointsAndPixels() throws {
        let layout = LiveInputContextProvider.displayLayout()
        try XCTSkipIf(layout.isEmpty, "no active display (headless environment)")

        for display in layout {
            XCTAssertGreaterThan(display.width, 0)
            XCTAssertGreaterThan(display.height, 0)
            XCTAssertGreaterThanOrEqual(display.scale, 1, "pixels per point is at least 1")
            XCTAssertGreaterThanOrEqual(display.pixelWidth, Int(display.width))
            XCTAssertEqual(display.scale, Double(display.pixelWidth) / display.width, accuracy: 0.001)
        }
        let main = CGMainDisplayID()
        XCTAssertTrue(layout.contains { $0.id == main })
    }

    func testContextAtAPointOnTheMainDisplayFillsGeometry() async throws {
        let layout = LiveInputContextProvider.displayLayout()
        let main = try XCTUnwrap(layout.first { $0.id == CGMainDisplayID() }, "main display missing from layout")
        let center = CGPoint(x: main.x + main.width / 2, y: main.y + main.height / 2)

        let context = await LiveInputContextProvider().context(at: center, wantsElements: false)

        XCTAssertEqual(context.displayID, main.id)
        XCTAssertEqual(context.displayPixelWidth, main.pixelWidth)
        XCTAssertEqual(context.displayScale, main.scale)
        XCTAssertEqual(context.displays.map(\.id), layout.map(\.id))
        XCTAssertTrue(context.axElements.isEmpty, "elements are only gathered on request")
    }

    func testOwnProcessIsRecognisedSoItIsNeverInspectedWithAccessibility() {
        XCTAssertTrue(LiveInputContextProvider.isOwnProcess(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(LiveInputContextProvider.isOwnProcess(1), "launchd is not us")
    }

    func testDisplayContainsUsesGlobalTopLeftPoints() {
        let secondary = InputDisplayGeometry(
            id: 2, x: 1512, y: -200, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, scale: 1
        )
        XCTAssertTrue(secondary.contains(CGPoint(x: 1600, y: -100)))
        XCTAssertFalse(secondary.contains(CGPoint(x: 1000, y: 100)))
        XCTAssertFalse(secondary.contains(CGPoint(x: 1512 + 1920, y: 0)), "right edge is exclusive")
    }

    func testConcurrentRequestsDegradeInsteadOfQueueingSnapshots() async {
        let provider = LiveInputContextProvider()
        let point = CGPoint(x: 100, y: 100)
        async let first = provider.context(at: point, wantsElements: true)
        async let second = provider.context(at: point, wantsElements: true)
        async let third = provider.context(at: point, wantsElements: true)
        let results = await [first, second, third]
        // Whatever order they ran in, requests that arrived while another was in flight must not
        // all pay for a snapshot.
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.contains { $0.axSnapshotTruncated } || results.allSatisfy { $0.axElements.isEmpty })
    }
}
