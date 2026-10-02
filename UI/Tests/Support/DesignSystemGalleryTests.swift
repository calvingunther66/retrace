import XCTest
import AppKit
import SwiftUI
@testable import Retrace

/// Renders the Linen/Dusk components in light and dark at several widths and checks the design tokens' contrast.
///
/// PNGs land in `.build/ui-gallery/` (override with `RETRACE_UI_GALLERY_DIR`) as
/// `{name}-{light|dark}-{width}.png` for visual inspection. The assertions are deliberately coarse: the render
/// produced ink, the requested appearance really applied, and token pairs meet WCAG contrast.
@MainActor
final class DesignSystemGalleryTests: XCTestCase {
    private let widths: [CGFloat] = [280, 520]

    override func setUp() async throws {
        try await super.setUp()
        // `swift test` runs from the package root, where UI/Fonts is the registry's working-tree fallback.
        XCTAssertTrue(RetraceFontRegistry.isAvailable, "Bundled fonts did not register; snapshots would show fallback faces")
    }

    // MARK: - Appearance sanity

    func testDarkAndLightRendersUseTheirOwnPageBackground() throws {
        for scheme in SnapshotRenderer.Scheme.allCases {
            let out = try SnapshotRenderer.render(name: "appearance-probe", width: 120, scheme: scheme) {
                Text("Probe").font(.retraceCallout).foregroundColor(.retraceInk)
            }
            let expected = SnapshotRenderer.rgb(scheme.pageHex)
            let corner = try XCTUnwrap(SnapshotRenderer.pixel(out.bitmap, x: 2, y: 2))
            XCTAssertEqual(corner.r, expected.r, accuracy: 0.02, "\(scheme) page red")
            XCTAssertEqual(corner.g, expected.g, accuracy: 0.02, "\(scheme) page green")
            XCTAssertEqual(corner.b, expected.b, accuracy: 0.02, "\(scheme) page blue")
        }
    }

    // MARK: - Component gallery

    func testBadgesRenderInEveryToneAndWidth() throws {
        try renderAll("badges") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RetraceBadge("Neutral")
                    RetraceBadge("Accent", tone: .accent)
                    RetraceBadge("Healthy", tone: .good)
                }
                HStack(spacing: 8) {
                    RetraceBadge("Warning", tone: .warning)
                    RetraceBadge("Critical", tone: .critical)
                }
                RetraceBadge("A considerably longer badge label that should wrap or truncate", tone: .warning)
            }
        }
    }

    func testMetersRenderAtBoundaryValues() throws {
        try renderAll("meters") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach([0.0, 4.0, 50.0, 96.0, 100.0, 140.0], id: \.self) { value in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(value))%").font(.retraceCaption).foregroundColor(.retraceInk2)
                        RetraceMeter(value: value, label: "Storage")
                    }
                }
                RetraceMeter(value: 72, label: "Critical", tint: .retraceCritical)
            }
        }
    }

    func testSwitchesRenderOnOffAndDisabled() throws {
        try renderAll("switches") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Record screen", isOn: .constant(true)).retraceSwitch()
                Toggle("Record screen", isOn: .constant(false)).retraceSwitch()
                Toggle("Disabled on", isOn: .constant(true)).retraceSwitch().disabled(true)
                Toggle("Disabled off", isOn: .constant(false)).retraceSwitch().disabled(true)
                Toggle("A very long setting label that describes something with a lot of words in it", isOn: .constant(true))
                    .retraceSwitch()
            }
        }
    }

    func testFieldsRenderEmptyFilledHintAndError() throws {
        try renderAll("fields") {
            VStack(alignment: .leading, spacing: 16) {
                RetraceField("Empty", text: .constant(""), placeholder: "Search your history")
                RetraceField("Filled", text: .constant("quarterly planning notes"), hint: "Matches OCR text and window titles")
                RetraceField("Error", text: .constant("???"), error: "That doesn't look like a valid date range")
                RetraceField("Long", text: .constant(String(repeating: "overflowing input text ", count: 6)))
            }
        }
    }

    func testTilesAndSectionHeadersRenderWithLongText() throws {
        try renderAll("tiles-headers") {
            VStack(alignment: .leading, spacing: 16) {
                RetraceSectionHeader("Capture", subtitle: "Every two seconds, deduplicated")
                RetraceSectionHeader("A long section title that will need to wrap at narrow widths", subtitle: "and an equally long italic subtitle that explains the section in detail")
                HStack(spacing: 12) {
                    RetraceTile(label: "Frames", value: "1,284,903", hint: "last 30 days")
                    RetraceTile(label: "Storage", value: "18.4 GB")
                }
                RetraceTile(label: "Searchable text", value: "9,999,999,999", hint: "an extremely long hint that keeps going and going")
            }
        }
    }

    func testButtonsRenderEveryKindSizeAndState() throws {
        try renderAll("buttons") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach([("Primary", RetraceButtonKind.primary), ("Secondary", .secondary), ("Ghost", .ghost), ("Danger", .danger)], id: \.0) { label, kind in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button(label) {}.buttonStyle(RetraceButtonStyle(kind))
                            Button(label) {}.buttonStyle(RetraceButtonStyle(kind, size: .sm))
                        }
                        Button("Disabled") {}.buttonStyle(RetraceButtonStyle(kind)).disabled(true)
                    }
                }
                Button("A button label that is far too long to fit on one line at narrow widths") {}
                    .buttonStyle(RetraceButtonStyle(.primary))
            }
        }
    }

    func testCardsAndIconSheetRender() throws {
        try renderAll("card") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Card title").font(.retraceTitle3).foregroundColor(.retraceInk)
                Text("Body copy inside a design-system card, long enough to wrap onto a second line at narrow widths.")
                    .font(.retraceBody)
                    .foregroundColor(.retraceInk2)
                Text("Muted metadata line").font(.retraceMeta).foregroundColor(.retraceMuted)
            }
            .retraceCard()
        }

        let names = RetraceIcons.table.keys.sorted()
        XCTAssertFalse(names.isEmpty)
        for scheme in SnapshotRenderer.Scheme.allCases {
            let out = try SnapshotRenderer.render(name: "icons", width: 760, scheme: scheme) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(names, id: \.self) { name in
                        VStack(spacing: 4) {
                            RetraceSymbol(name, size: 20).foregroundColor(.retraceInk)
                            Text(name).font(.retraceTiny).foregroundColor(.retraceMuted).lineLimit(1)
                        }
                    }
                }
            }
            XCTAssertGreaterThan(SnapshotRenderer.inkCoverage(out.bitmap, pageHex: scheme.pageHex), 0.001)
        }
    }

    // MARK: - Real views

    func testPermissionBannerAndAnalyticsCardRender() throws {
        try renderAll("permission-banner") {
            VStack(spacing: 10) {
                PermissionBanner(message: "Screen Recording permission is required to capture your screen.", actionTitle: "Open Settings", action: {}, onDismiss: {}, isPrimary: true)
                PermissionBanner(message: "Accessibility permission is needed for app context.", actionTitle: "Grant", action: {}, onDismiss: {})
            }
        }
        try renderAll("analytics-card") {
            VStack(spacing: 12) {
                AnalyticsCard(title: "Screen time", value: "6h 42m", subtitle: "up 12% from last week", icon: "clock")
                AnalyticsCard(title: "A long analytics card title", value: "12,345,678,901", subtitle: "an overlong subtitle that cannot fit on one line", icon: "magnifyingglass")
            }
        }
    }

    // MARK: - Token contrast

    func testTokenPairsMeetWCAGContrast() {
        struct Pair {
            let name: String
            let fg: RetraceToken
            let bg: RetraceToken
            let minimum: Double
        }
        let t = RetraceTokens.self
        let text = 4.5, ui = 3.0
        var pairs: [Pair] = []
        for (bgName, bg) in [("page", t.page), ("surface", t.surface), ("sunken", t.surfaceSunken), ("hover", t.surfaceHover)] {
            pairs.append(Pair(name: "ink on \(bgName)", fg: t.ink, bg: bg, minimum: text))
            pairs.append(Pair(name: "ink2 on \(bgName)", fg: t.ink2, bg: bg, minimum: text))
        }
        // `muted` is documented (UI/AGENTS.md design system) as page/surface-only text; on sunken/hover Linen it
        // is 4.18/4.33:1, so those pairings are intentionally not allowed and not asserted here.
        pairs.append(Pair(name: "muted on page", fg: t.muted, bg: t.page, minimum: text))
        pairs.append(Pair(name: "muted on surface", fg: t.muted, bg: t.surface, minimum: text))
        pairs += [
            Pair(name: "badge accent (ink on accentWash)", fg: t.ink, bg: t.accentWash, minimum: text),
            Pair(name: "badge good", fg: t.good, bg: t.goodBg, minimum: text),
            Pair(name: "badge warning", fg: t.warning, bg: t.warningBg, minimum: text),
            Pair(name: "badge critical", fg: t.critical, bg: t.criticalBg, minimum: text),
            Pair(name: "onAccent on accent (primary button)", fg: t.onAccent, bg: t.accent, minimum: text),
            Pair(name: "onAccent on accentHover", fg: t.onAccent, bg: t.accentHover, minimum: text),
            Pair(name: "critical text on page", fg: t.critical, bg: t.page, minimum: text),
            Pair(name: "critical text on surface", fg: t.critical, bg: t.surface, minimum: text),
            Pair(name: "warning text on surface", fg: t.warning, bg: t.surface, minimum: text),
            Pair(name: "good text on surface", fg: t.good, bg: t.surface, minimum: text),
            Pair(name: "accent text on page", fg: t.accent, bg: t.page, minimum: text),
            Pair(name: "accent text on surface", fg: t.accent, bg: t.surface, minimum: text),
            Pair(name: "termInk on termBg", fg: t.termInk, bg: t.termBg, minimum: text),
            Pair(name: "meter fill vs sunken track", fg: t.accent, bg: t.surfaceSunken, minimum: ui),
            Pair(name: "borderStrong on page (field/switch edge)", fg: t.borderStrong, bg: t.page, minimum: ui),
            Pair(name: "borderStrong on surface (field/switch edge)", fg: t.borderStrong, bg: t.surface, minimum: ui),
            Pair(name: "accent focus ring on page", fg: t.accent, bg: t.page, minimum: ui),
            Pair(name: "accent focus ring on surface", fg: t.accent, bg: t.surface, minimum: ui),
        ]

        var failures: [String] = []
        for pair in pairs {
            for (mode, fg, bg) in [("light", pair.fg.light, pair.bg.light), ("dark", pair.fg.dark, pair.bg.dark)] {
                let ratio = WCAGContrast.ratio(fg, bg)
                if ratio < pair.minimum {
                    failures.append(String(format: "%@ [%@]: %.2f:1 (needs %.1f:1)", pair.name, mode, ratio, pair.minimum))
                }
            }
        }
        XCTAssertEqual(failures, [], "Token pairs below WCAG contrast:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - Helpers

    /// Renders `content` for every scheme at every width and asserts something other than the page drew.
    private func renderAll<Content: View>(_ name: String, @ViewBuilder content: () -> Content) throws {
        let view = content()
        for scheme in SnapshotRenderer.Scheme.allCases {
            for width in widths {
                let out = try SnapshotRenderer.render(name: name, width: width, scheme: scheme) { view }
                XCTAssertGreaterThan(
                    SnapshotRenderer.inkCoverage(out.bitmap, pageHex: scheme.pageHex),
                    0.001,
                    "\(name) \(scheme.rawValue) @\(Int(width)) rendered blank"
                )
            }
        }
    }
}
