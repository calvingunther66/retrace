import XCTest
import AppKit
@testable import Retrace

final class RetraceIconTests: XCTestCase {
    func testEveryTableEntryResolvesToDefinedGlyphArt() {
        XCTAssertEqual(RetraceIcons.missingGlyphs(), [], "Table entries reference glyphs with no art")
        for name in RetraceIcons.table.keys {
            XCTAssertNotNil(RetraceIcons.spec(forSystemName: name), name)
        }
    }

    func testEveryGlyphParsesIntoPathsInsideTheGrid() {
        for (glyph, _) in RetraceGlyphLibrary.art {
            for style in [RetraceIconStyle.plain, .ring, .disc] {
                guard let geometry = RetraceIconGeometry.resolve(.init(glyph: glyph, style: style)) else {
                    return XCTFail("\(glyph) did not resolve")
                }
                let bounds = geometry.strokes.boundingBoxOfPath.union(geometry.fills.boundingBoxOfPath)
                XCTAssertFalse(bounds.isNull, "\(glyph) drew nothing")
                XCTAssertGreaterThanOrEqual(bounds.minX, 0, glyph)
                XCTAssertGreaterThanOrEqual(bounds.minY, 0, glyph)
                XCTAssertLessThanOrEqual(bounds.maxX, 24, glyph)
                XCTAssertLessThanOrEqual(bounds.maxY, 24, glyph)
            }
        }
    }

    func testSymbolImagesRenderAsTemplates() {
        let mapped = NSImage.retraceSymbol("magnifyingglass", pointSize: 14)
        XCTAssertEqual(mapped?.isTemplate, true)
        // Unmapped names fall back to the SF Symbol rather than rendering nothing.
        XCTAssertNotNil(NSImage.retraceSymbol("globe.americas", pointSize: 14))
        XCTAssertEqual(NSImage.retraceMenuBarMark().isTemplate, true)
    }

    func testBundledFontsRegisterFromWorkingTree() {
        // `swift test` runs from the package root, where UI/Fonts is the registry's working-tree fallback.
        XCTAssertTrue(RetraceFontRegistry.isAvailable)
        XCTAssertNotNil(NSFont(name: RetraceFontRegistry.Face.serifSemibold, size: 13))
        XCTAssertNotNil(NSFont(name: RetraceFontRegistry.Face.monoMedium, size: 13))
    }
}
