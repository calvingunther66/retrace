import SwiftUI
import AppKit

// MARK: - Retrace icon set
//
// Stroke-only icons drawn on a 24 x 24 grid: hairline weight, round caps and joins, soft curves, one color
// (the current foreground style). They replace SF Symbols throughout the UI so the icon language matches the
// Linen / Dusk design system. Use `RetraceSymbol("sf.symbol.name", size:)` where an SF Symbol name is already in
// hand (dynamic names, tables) and `RetraceIcon.view(_:size:)` where the glyph is known.
//
// Names that have no entry in `RetraceIcons.table` fall back to the SF Symbol so nothing ever renders blank.

// MARK: Spec

public enum RetraceIconStyle: String, Sendable {
    /// Stroke only.
    case plain
    /// Stroke plus a faint wash of the foreground inside closed shapes ("selected" / `.fill` variants).
    case filled
    /// Glyph inside an outline circle.
    case ring
    /// Glyph knocked out of a solid disc.
    case disc
    /// Glyph with a diagonal strike through it.
    case slashed
}

public struct RetraceIconSpec: Hashable, Sendable {
    public let glyph: String
    public let style: RetraceIconStyle
}

public enum RetraceIconWeight: Sendable {
    case light, regular, medium, semibold

    /// Stroke width on the 24pt grid.
    var gridStroke: CGFloat {
        switch self {
        case .light: return 1.25
        case .regular: return 1.5
        case .medium: return 1.75
        case .semibold: return 2.0
        }
    }

    init(_ weight: Font.Weight) {
        switch weight {
        case .ultraLight, .thin, .light: self = .light
        case .medium: self = .medium
        case .semibold, .bold, .heavy, .black: self = .semibold
        default: self = .regular
        }
    }
}

// MARK: Glyph art

/// SVG-path-data strings on a 24 grid. `strokes` are outlined, `fills` are solid (dots).
struct RetraceGlyphArt {
    let strokes: [String]
    let fills: [String]

    init(_ strokes: [String], fills: [String] = []) {
        self.strokes = strokes
        self.fills = fills
    }
}

private func C(_ cx: Double, _ cy: Double, _ r: Double) -> String {
    "M\(cx - r) \(cy)a\(r) \(r) 0 1 0 \(2 * r) 0a\(r) \(r) 0 1 0 \(-2 * r) 0Z"
}

private func R(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> String {
    "M\(x + r) \(y)H\(x + w - r)a\(r) \(r) 0 0 1 \(r) \(r)V\(y + h - r)a\(r) \(r) 0 0 1 \(-r) \(r)H\(x + r)"
        + "a\(r) \(r) 0 0 1 \(-r) \(-r)V\(y + r)a\(r) \(r) 0 0 1 \(r) \(-r)Z"
}

/// Rounded gear outline with `teeth` teeth.
private func gearPath(teeth: Int = 8, outer: Double = 9.6, inner: Double = 7.3) -> String {
    var points: [(Double, Double)] = []
    let step = 2 * Double.pi / Double(teeth)
    for i in 0..<teeth {
        let a = Double(i) * step - Double.pi / 2
        let widthOuter = step * 0.17
        let widthInner = step * 0.36
        for (angle, radius) in [(a - widthInner, inner), (a - widthOuter, outer), (a + widthOuter, outer), (a + widthInner, inner)] {
            points.append((12 + radius * cos(angle), 12 + radius * sin(angle)))
        }
    }
    var d = ""
    for (index, point) in points.enumerated() {
        d += (index == 0 ? "M" : "L") + String(format: "%.2f %.2f", point.0, point.1)
    }
    return d + "Z"
}

private let slashPath = "M4.5 4.5L19.5 19.5"

enum RetraceGlyphLibrary {
    static let art: [String: RetraceGlyphArt] = [
        // Marks
        "xmark": .init(["M6.5 6.5L17.5 17.5", "M17.5 6.5L6.5 17.5"]),
        "plus": .init(["M12 5.5V18.5", "M5.5 12H18.5"]),
        "minus": .init(["M5.5 12H18.5"]),
        "check": .init(["M5.5 12.5l4.5 4.5L18.5 7.5"]),
        "exclaim": .init(["M12 6.5v6.5"], fills: [C(12, 17.2, 1.15)]),
        "info": .init(["M12 11v6"], fills: [C(12, 7.5, 1.15)]),
        "question": .init(["M9.3 9.4a2.7 2.7 0 1 1 4.2 2.2c-1 .7-1.5 1.3-1.5 2.4"], fills: [C(12, 17.4, 1.1)]),
        "warning": .init(
            ["M10.3 4.7L3.5 16.6A2 2 0 0 0 5.2 19.6h13.6a2 2 0 0 0 1.7-3L13.7 4.7a2 2 0 0 0-3.4 0Z", "M12 9.8v3.6"],
            fills: [C(12, 16.4, 1.0)]
        ),

        // Chevrons and arrows
        "chevronDown": .init(["M6.5 9.5l5.5 5.5 5.5-5.5"]),
        "chevronUp": .init(["M6.5 14.5l5.5-5.5 5.5 5.5"]),
        "chevronLeft": .init(["M14.5 6.5l-5.5 5.5 5.5 5.5"]),
        "chevronRight": .init(["M9.5 6.5l5.5 5.5-5.5 5.5"]),
        "arrowRight": .init(["M5 12h14", "M13.5 6.5L19 12l-5.5 5.5"]),
        "arrowLeft": .init(["M19 12H5", "M10.5 6.5L5 12l5.5 5.5"]),
        "arrowUp": .init(["M12 19V5", "M6.5 10.5L12 5l5.5 5.5"]),
        "arrowDown": .init(["M12 5v14", "M6.5 13.5L12 19l5.5-5.5"]),
        "arrowUpRight": .init(["M7 17L17 7", "M9 7h8v8"]),
        "arrowUpDown": .init(["M8 19V5", "M4.5 8.5L8 5l3.5 3.5", "M16 5v14", "M12.5 15.5L16 19l3.5-3.5"]),
        "arrowLeftRight": .init(["M5 8h14", "M15.5 4.5L19 8l-3.5 3.5", "M19 16H5", "M8.5 12.5L5 16l3.5 3.5"]),
        "expand": .init(["M14 4.5h5.5V10", "M19.5 4.5l-6 6", "M10 19.5H4.5V14", "M4.5 19.5l6-6"]),
        "uturn": .init(["M9 6.5L4.5 11 9 15.5", "M4.5 11h9a5 5 0 0 1 0 10H9.5"]),
        "triUp": .init(["M12 7l5.5 9.5h-11Z"]),
        "triDown": .init(["M12 17l5.5-9.5h-11Z"]),
        "linkOut": .init(["M13 5h6v6", "M19 5l-8 8", "M17.5 14.5V17a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V8.5a2 2 0 0 1 2-2h2.5"]),

        // Rewind / refresh / sync
        "rewind": .init(["M4.5 12a7.5 7.5 0 1 0 2.3-5.4L4.5 8.8", "M4.5 4.2v4.6h4.6"]),
        "refresh": .init(["M19.5 12a7.5 7.5 0 1 1-2.3-5.4L19.5 8.8", "M19.5 4.2v4.6h-4.6"]),
        "sync": .init(["M4.5 10.5a7.5 7.5 0 0 1 13-3.2L19.5 9.5", "M19.5 5v4.5H15", "M19.5 13.5a7.5 7.5 0 0 1-13 3.2L4.5 14.5", "M4.5 19v-4.5H9"]),
        "history": .init(["M3.8 12a8.2 8.2 0 1 0 2.4-5.8L3.8 8.5", "M3.8 4.5v4h4", "M12 8v4.2l2.8 1.7"]),

        // Layout
        "ellipsis": .init([], fills: [C(5.5, 12, 1.5), C(12, 12, 1.5), C(18.5, 12, 1.5)]),
        "menu": .init(["M4.5 7h15", "M4.5 12h15", "M4.5 17h15"]),
        "filter": .init(["M4.5 7h15", "M7.5 12h9", "M10.5 17h3"]),
        "sliders": .init(["M4.5 8h8", "M17 8h2.5", "M4.5 16h2.5", "M11.5 16h8", C(14.8, 8, 2.2), C(9.2, 16, 2.2)]),
        "list": .init(["M9.5 7h10", "M9.5 12h10", "M9.5 17h10"], fills: [C(5, 7, 1.1), C(5, 12, 1.1), C(5, 17, 1.1)]),
        "grid": .init([R(4, 4, 6.5, 6.5, 2), R(13.5, 4, 6.5, 6.5, 2), R(4, 13.5, 6.5, 6.5, 2), R(13.5, 13.5, 6.5, 6.5, 2)]),
        "columns": .init([R(3.5, 5, 17, 14, 3), "M12 5v14"]),
        "layers": .init(["M12 3.8l8.5 4.4-8.5 4.4-8.5-4.4Z", "M3.5 12.2l8.5 4.4 8.5-4.4", "M3.5 16.2l8.5 4.4 8.5-4.4"]),
        "window": .init([R(3.5, 4.5, 17, 15, 3), "M3.5 9.2h17"], fills: [C(6.6, 6.9, 0.7), C(9, 6.9, 0.7)]),
        "menubar": .init([R(3, 5, 18, 14, 3), "M3 9.2h18"]),
        "menubarDown": .init([R(3, 5, 18, 14, 3), "M3 9.2h18", "M12 11.8v5.2", "M9.8 14.9L12 17l2.2-2.1"]),
        "menubarUp": .init([R(3, 5, 18, 14, 3), "M3 9.2h18", "M12 17v-5.2", "M9.8 13.9L12 11.8l2.2 2.1"]),
        "app": .init([R(4.5, 4.5, 15, 15, 4.5)]),
        "desktop": .init([R(3, 4.5, 18, 12, 3), "M9 20h6", "M12 16.5V20"]),

        // Objects
        "search": .init([C(10.5, 10.5, 6.5), "M15.4 15.4L20 20"]),
        "searchPlus": .init([C(10.5, 10.5, 6.5), "M15.4 15.4L20 20", "M7.8 10.5h5.4", "M10.5 7.8v5.4"]),
        "searchMinus": .init([C(10.5, 10.5, 6.5), "M15.4 15.4L20 20", "M7.8 10.5h5.4"]),
        "clock": .init([C(12, 12, 9), "M12 7v5.2l3.2 1.8"]),
        "timer": .init([C(12, 13.5, 7.5), "M12 13.5V9.5", "M9.5 3.5h5", "M17.2 7.2l1.3-1.3"]),
        "calendar": .init([R(4, 5.5, 16, 14.5, 3.5), "M4 10.2h16", "M8.5 3.5v3.8", "M15.5 3.5v3.8"]),
        "gear": .init([gearPath(), C(12, 12, 2.9)]),
        "trash": .init(["M4.5 7h15", "M9.5 7V5.5a1.5 1.5 0 0 1 1.5-1.5h2a1.5 1.5 0 0 1 1.5 1.5V7",
                        "M6.5 7l.8 11.2a2 2 0 0 0 2 1.8h5.4a2 2 0 0 0 2-1.8L17.5 7", "M10 11v5", "M14 11v5"]),
        "doc": .init(["M7 3.5h6.6l4.9 4.9V19a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5Z", "M13.5 3.8V8.5h4.7"]),
        "docText": .init(["M7 3.5h6.6l4.9 4.9V19a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5Z", "M13.5 3.8V8.5h4.7", "M9 13h6", "M9 16.5h6"]),
        "docDown": .init(["M7 3.5h6.6l4.9 4.9V19a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5Z", "M13.5 3.8V8.5h4.7", "M12 11.5v5", "M9.8 14.5L12 16.7l2.2-2.2"]),
        "copy": .init([R(9, 9, 11, 11.5, 2.8), "M15 9V6.8a2.3 2.3 0 0 0-2.3-2.3H6.8A2.3 2.3 0 0 0 4.5 6.8v5.9A2.3 2.3 0 0 0 6.8 15H9"]),
        "clipboard": .init([R(5, 5, 14, 15.5, 3), R(9, 3, 6, 4, 1.5), "M9 12h6", "M9 15.5h4"]),
        "link": .init(["M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1", "M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"]),
        "tag": .init(["M3.5 12.3V6a2.5 2.5 0 0 1 2.5-2.5h6.3a2.5 2.5 0 0 1 1.8.7l6.6 6.6a2.5 2.5 0 0 1 0 3.6l-6.2 6.2a2.5 2.5 0 0 1-3.6 0l-6.6-6.6a2.5 2.5 0 0 1-.8-1.8Z"],
                     fills: [C(8.3, 8.3, 1.3)]),
        "globe": .init([C(12, 12, 9), "M3.2 12h17.6", "M12 3c2.5 2.5 3.8 5.5 3.8 9S14.5 18.5 12 21c-2.5-2.5-3.8-5.5-3.8-9S9.5 5.5 12 3Z"]),
        "eye": .init(["M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12Z", C(12, 12, 3)]),
        "photo": .init([R(3.5, 4.5, 17, 15, 3), C(9, 9.8, 1.6), "M3.8 17l4.6-4.5a1.6 1.6 0 0 1 2.2 0L15 17", "M13.5 15l1.7-1.7a1.6 1.6 0 0 1 2.2 0l3.1 3.2"]),
        "film": .init([R(3.5, 5, 17, 14, 3), "M8 5v14", "M16 5v14", "M3.5 9.5H8", "M3.5 14.5H8", "M16 9.5h4.5", "M16 14.5h4.5"]),
        "video": .init([R(3, 6.5, 13, 11, 3), "M16 10.5l5-3v9l-5-3"]),
        "play": .init(["M8.5 5.8v12.4l10-6.2Z"]),
        "pause": .init(["M9 6v12", "M15 6v12"]),
        "stop": .init([R(6.5, 6.5, 11, 11, 2.5)]),
        "forward": .init(["M6.5 6.5l9 5.5-9 5.5Z", "M18.5 6v12"]),
        "record": .init([C(12, 12, 9)], fills: [C(12, 12, 3.8)]),
        "dot": .init([], fills: [C(12, 12, 8)]),
        "circle": .init([C(12, 12, 8.5)]),
        "checkbox": .init([R(4.5, 4.5, 15, 15, 4)]),
        "checkboxOn": .init([R(4.5, 4.5, 15, 15, 4), "M8.5 12.3l2.5 2.6 4.6-5.2"]),
        "bell": .init(["M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 1.5h-15Z", "M10 20.5a2.2 2.2 0 0 0 4 0"]),
        "lightbulb": .init(["M12 3.5a6 6 0 0 0-3.6 10.8c.7.6 1.1 1.4 1.1 2.2v1h5v-1c0-.8.4-1.6 1.1-2.2A6 6 0 0 0 12 3.5Z", "M9.8 20.5h4.4"]),
        "sparkles": .init(["M10 4.5c.6 3.7 1.8 4.9 5.5 5.5-3.7.6-4.9 1.8-5.5 5.5-.6-3.7-1.8-4.9-5.5-5.5 3.7-.6 4.9-1.8 5.5-5.5Z",
                           "M17.5 14.8c.3 1.8.9 2.4 2.7 2.7-1.8.3-2.4.9-2.7 2.7-.3-1.8-.9-2.4-2.7-2.7 1.8-.3 2.4-.9 2.7-2.7Z"]),
        "bubble": .init(["M5.5 5h13A2 2 0 0 1 20.5 7v8.5a2 2 0 0 1-2 2H11l-4.5 3.5v-3.5h-1a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z"]),
        "bubbleText": .init(["M5.5 5h13A2 2 0 0 1 20.5 7v8.5a2 2 0 0 1-2 2H11l-4.5 3.5v-3.5h-1a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z", "M8 10h8", "M8 13.5h5"]),
        "bubbleAlert": .init(["M5.5 5h13A2 2 0 0 1 20.5 7v8.5a2 2 0 0 1-2 2H11l-4.5 3.5v-3.5h-1a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z", "M12 8.5v3.4"],
                             fills: [C(12, 14.6, 0.9)]),
        "paperclip": .init(["M17.5 11.5l-6.2 6.2a3.5 3.5 0 0 1-5-5l7-7a2.3 2.3 0 0 1 3.3 3.3l-7 7a1.1 1.1 0 0 1-1.6-1.6l6-6"]),
        "drive": .init([R(3.5, 12, 17, 7.5, 2.5), "M3.8 12l2.2-5.9A2 2 0 0 1 7.9 4.8h8.2A2 2 0 0 1 18 6.1l2.2 5.9"], fills: [C(7.5, 15.8, 0.9)]),
        "database": .init(["M4.5 6c0-1.7 3.4-3 7.5-3s7.5 1.3 7.5 3-3.4 3-7.5 3-7.5-1.3-7.5-3Z", "M4.5 6v12c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3V6", "M4.5 12c0 1.7 3.4 3 7.5 3s7.5-1.3 7.5-3"]),
        "archive": .init([R(3.5, 4.5, 17, 4.5, 1.8), "M5 9v8.5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9", "M10 13h4"]),
        "tray": .init(["M3.5 13.5L6 6a2 2 0 0 1 1.9-1.5h8.2A2 2 0 0 1 18 6l2.5 7.5", "M3.5 13.5V17.5a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-4h-5l-1.2 2.2H9.7L8.5 13.5Z"]),
        "trayDown": .init(["M3.5 13.5V17.5a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-4h-5l-1.2 2.2H9.7L8.5 13.5Z", "M12 4v8", "M8.8 9L12 12.2 15.2 9"]),
        "share": .init(["M12 14.5V4", "M8.5 7.5L12 4l3.5 3.5", "M8 10.5H7a2 2 0 0 0-2 2V18a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5.5a2 2 0 0 0-2-2h-1"]),
        "download": .init(["M12 4v10.5", "M8.5 11L12 14.5 15.5 11", "M8 10.5H7a2 2 0 0 0-2 2V18a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5.5a2 2 0 0 0-2-2h-1"]),
        "cpu": .init([R(6.5, 6.5, 11, 11, 2.5), R(9.8, 9.8, 4.4, 4.4, 1), "M10 3.5v3", "M14 3.5v3", "M10 17.5v3", "M14 17.5v3", "M3.5 10h3", "M3.5 14h3", "M17.5 10h3", "M17.5 14h3"]),
        "memory": .init([R(3, 6.5, 18, 9.5, 2.2), "M7 16v3", "M11 16v3", "M15 16v3", "M7.5 10.2h2", "M14.5 10.2h2"]),
        "bolt": .init(["M13 3L5.5 13.5H12L11 21l7.5-10.5H12Z"]),
        "battery": .init([R(2.5, 7.5, 17, 9, 2.8), "M21.5 10.8v2.4", "M6 10.8v2.4", "M9 10.8v2.4"]),
        "leaf": .init(["M5 19c-.5-7 3-13 14.5-14.5C20.5 16 15.5 19.6 9 19", "M5 19c3-4 6-7 9.5-9"]),
        "gauge": .init(["M4.5 17a8.5 8.5 0 1 1 15 0", "M12 14.5l3.8-4.8"], fills: [C(12, 14.6, 1.1)]),
        "pulse": .init(["M3 12h4l2-5.5 3.5 11 2.5-8 1.5 2.5H21"]),
        "power": .init(["M12 3.5v8", "M7.3 6.6a7.5 7.5 0 1 0 9.4 0"]),
        "wrench": .init(["M14.8 6.2a4 4 0 0 0-5.1 5L4.7 16.2a2.1 2.1 0 0 0 3 3l5-5a4 4 0 0 0 5-5.1l-2.6 2.6-2.4-.5-.5-2.4Z"]),
        "lock": .init([R(5, 10.5, 14, 10, 3), "M8 10.5V8a4 4 0 0 1 8 0v2.5"], fills: [C(12, 15.5, 1.1)]),
        "lockOpen": .init([R(5, 10.5, 14, 10, 3), "M8 10.5V8a4 4 0 0 1 7.6-1.7"], fills: [C(12, 15.5, 1.1)]),
        "shield": .init(["M12 3.5l7 2.5v5.5c0 4.4-3 7.4-7 9-4-1.6-7-4.6-7-9V6Z"]),
        "shieldCheck": .init(["M12 3.5l7 2.5v5.5c0 4.4-3 7.4-7 9-4-1.6-7-4.6-7-9V6Z", "M8.8 12l2.4 2.4 4.2-4.6"]),
        "hand": .init(["M8 12V6.5a1.5 1.5 0 0 1 3 0V11", "M11 5a1.5 1.5 0 0 1 3 0v6", "M14 6.5a1.5 1.5 0 0 1 3 0V13", "M17 9.5a1.5 1.5 0 0 1 3 0V15a6 6 0 0 1-6 6h-1.4a6 6 0 0 1-4.8-2.4L4.6 15.4a1.6 1.6 0 0 1 2.5-2L8 14.5"]),
        "key": .init([C(8, 12, 3.8), "M11.8 12H21", "M18 12v3", "M15 12v2.4"]),
        "keyboard": .init([R(2.5, 6.5, 19, 11, 3), "M7 14.2h10"], fills: [C(6.8, 10.3, 0.8), C(10.3, 10.3, 0.8), C(13.8, 10.3, 0.8), C(17.2, 10.3, 0.8)]),
        "person": .init([C(12, 8, 3.8), "M4.8 20c.7-3.6 3.6-5.5 7.2-5.5s6.5 1.9 7.2 5.5"]),
        "people": .init([C(9, 8.5, 3.3), "M2.8 19.5c.6-3.2 3.1-4.8 6.2-4.8s5.6 1.6 6.2 4.8", C(17, 9, 2.7), "M17 14.4c2.3 0 4 1.2 4.4 3.8"]),
        "paintbrush": .init(["M4.5 19.5c2.6 0 4-1.2 4-3.2a2.3 2.3 0 0 0-2.3-2.3c-1.7 0-2.5 2-1.7 5.5Z", "M8.7 14.2L19 4a1.8 1.8 0 0 1 2.5 2.5L11.4 16.8"]),
        "wifi": .init(["M3 9.3a13 13 0 0 1 18 0", "M6 12.9a8.6 8.6 0 0 1 12 0", "M9 16.3a4.2 4.2 0 0 1 6 0"], fills: [C(12, 19.4, 1.2)]),
        "compass": .init([C(12, 12, 9), "M15.6 8.4l-2 5.2-5.2 2 2-5.2Z"]),
        "bug": .init(["M12 8.3a4.2 5.2 0 0 1 4.2 5.2 4.2 5.2 0 0 1-8.4 0A4.2 5.2 0 0 1 12 8.3Z", "M9.5 6.3L12 8.3l2.5-2", "M12 10.5v8.5", "M7.8 12.8H4", "M16.2 12.8H20", "M8.2 17.2L5 19.5", "M15.8 17.2l3.2 2.3"]),
        "cursor": .init(["M6.5 4.5l12 6.3-5.4 1.6-2 5.5Z"]),
        "target": .init([C(12, 12, 9), C(12, 12, 5)], fills: [C(12, 12, 1.5)]),
        "star": .init(["M12 3.8l2.5 5.2 5.7.8-4.1 4 1 5.7-5.1-2.7-5.1 2.7 1-5.7-4.1-4 5.7-.8Z"]),
        "heart": .init(["M12 20s-7.5-4.5-7.5-10.3A4.3 4.3 0 0 1 12 7.1a4.3 4.3 0 0 1 7.5 2.6C19.5 15.5 12 20 12 20Z"]),
        "crown": .init(["M4.2 17.5L3.6 8.2l4.9 3.9L12 6l3.5 6.1 4.9-3.9-.6 9.3Z", "M4.5 20.5h15"]),
        "trophy": .init(["M8 4.5h8v5a4 4 0 0 1-8 0Z", "M8 6H5v1.5A3 3 0 0 0 8 10.5", "M16 6h3v1.5a3 3 0 0 1-3 3", "M12 13.5V17", "M8.5 19.5h7", "M10 17h4"]),
        "coffee": .init(["M5 9.5h11v5a4.5 4.5 0 0 1-4.5 4.5h-2A4.5 4.5 0 0 1 5 14.5Z", "M16 11h1.5a2.5 2.5 0 0 1 0 5h-2", "M8.5 4.5v2", "M12 4.5v2"]),
        "chart": .init(["M5.5 19.5v-7", "M12 19.5v-14", "M18.5 19.5v-9"]),
        "sum": .init(["M17 5H7.5l5 7-5 7H17"]),
        "at": .init([C(12, 12, 3.5), "M15.5 12v1.4a2.5 2.5 0 0 0 5 0V12a8.5 8.5 0 1 0-3.4 6.8"]),
        "bold": .init(["M7.5 4.5h5.2a3.3 3.3 0 0 1 0 6.6H7.5Z", "M7.5 11.1h6.2a3.7 3.7 0 0 1 0 7.4H7.5Z"]),
        "italic": .init(["M10 4.5h7", "M7 19.5h7", "M14 4.5l-4 15"]),
        "accessibility": .init([C(12, 12, 9), "M7.5 9.8h9", "M12 9.8v3.5", "M9.8 17.5L12 13.3l2.2 4.2"]),
        "hexgrid": .init(["M12 3.5l7 4v8l-7 4-7-4v-8Z"], fills: [C(12, 12, 1.4)]),
        "branch": .init([C(7, 6, 2), C(7, 18, 2), C(17, 8, 2), "M7 8v8", "M17 10c0 4-4 4-8.5 6"]),
        "book": .init(["M5.5 4.5h10.5a2 2 0 0 1 2 2V19.5H7.5a2 2 0 0 1-2-2Z", "M5.5 17.5a2 2 0 0 1 2-2H18", "M9 8.5h5"]),
        "viewfinder": .init(["M4 8.5V6.5a2.5 2.5 0 0 1 2.5-2.5h2", "M15.5 4h2A2.5 2.5 0 0 1 20 6.5v2", "M20 15.5v2a2.5 2.5 0 0 1-2.5 2.5h-2", "M8.5 20h-2A2.5 2.5 0 0 1 4 17.5v-2", "M8.5 9.5h7", "M8.5 12h7", "M8.5 14.5h4"]),
        "personRing": .init([C(12, 12, 9), C(12, 10, 2.6), "M6.8 18.2c1.2-2 3.1-3 5.2-3s4 1 5.2 3"]),
    ]
}

// MARK: SF Symbol -> Retrace icon table

public enum RetraceIcons {
    /// `"sf.symbol.name": "glyph[:style]"`. Badge variants map to the base glyph.
    static let table: [String: String] = [
        "xmark": "xmark", "xmark.circle": "xmark:ring", "xmark.circle.fill": "xmark:disc",
        "xmark.square": "xmark:ring", "xmark.octagon.fill": "xmark:disc",
        "plus": "plus", "plus.circle": "plus:ring", "plus.circle.fill": "plus:disc",
        "plus.magnifyingglass": "searchPlus", "minus.magnifyingglass": "searchMinus",
        "minus": "minus", "minus.circle": "minus:ring", "minus.circle.fill": "minus:disc",
        "checkmark": "check", "checkmark.circle": "check:ring", "checkmark.circle.fill": "check:disc",
        "checkmark.square.fill": "checkboxOn", "checkmark.square": "checkboxOn",
        "checkmark.shield.fill": "shieldCheck", "checkmark.shield": "shieldCheck",
        "exclamationmark": "exclaim", "exclamationmark.circle": "exclaim:ring", "exclamationmark.circle.fill": "exclaim:disc",
        "exclamationmark.triangle": "warning", "exclamationmark.triangle.fill": "warning:filled",
        "exclamationmark.bubble": "bubbleAlert", "exclamationmark.bubble.fill": "bubbleAlert:filled",
        "info.circle": "info:ring", "info.circle.fill": "info:disc", "info.square": "info:ring",
        "questionmark.circle": "question:ring", "questionmark.circle.fill": "question:disc",

        "chevron.down": "chevronDown", "chevron.up": "chevronUp", "chevron.left": "chevronLeft", "chevron.right": "chevronRight",
        "arrow.right": "arrowRight", "arrow.left": "arrowLeft", "arrow.up": "arrowUp", "arrow.down": "arrowDown",
        "arrow.up.right": "arrowUpRight", "arrow.up.arrow.down": "arrowUpDown", "arrow.left.arrow.right": "arrowLeftRight",
        "arrow.up.left.and.arrow.down.right": "expand", "arrow.up.right.square": "linkOut",
        "arrow.uturn.backward": "uturn", "arrow.uturn.backward.circle.fill": "uturn:disc",
        "arrowtriangle.up.fill": "triUp", "arrowtriangle.down.fill": "triDown",
        "arrow.down.circle": "arrowDown:ring", "arrow.down.circle.fill": "arrowDown:disc",
        "arrow.down.doc": "docDown", "square.and.arrow.down": "download", "square.and.arrow.up": "share",
        "tray.and.arrow.down": "trayDown",

        "arrow.counterclockwise": "rewind", "arrow.clockwise": "refresh", "arrow.clockwise.circle": "refresh:ring",
        "restart": "refresh", "arrow.triangle.2.circlepath": "sync",
        "arrow.triangle.branch": "branch",
        "arrow.trianglehead.2.clockwise.rotate.90.circle.fill": "sync:disc",
        "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90": "sync:slashed",
        "clock.arrow.circlepath": "history", "clock.arrow.trianglehead.counterclockwise.rotate.90": "history",

        "ellipsis": "ellipsis", "ellipsis.circle": "ellipsis:ring", "line.3.horizontal": "menu",
        "line.3.horizontal.decrease": "filter", "line.3.horizontal.decrease.circle": "filter:ring",
        "slider.horizontal.3": "sliders", "list.bullet": "list", "list.bullet.rectangle": "list",
        "square.grid.2x2": "grid", "square.grid.2x2.fill": "grid:filled", "square.split.2x1.fill": "columns",
        "square.stack.3d.up.fill": "layers", "square.stack.3d.down.forward": "layers",
        "rectangle.stack": "layers", "rectangle.3.group": "grid",
        "macwindow": "window", "menubar.rectangle": "menubar",
        "menubar.arrow.down.rectangle": "menubarDown", "menubar.arrow.up.rectangle": "menubarUp",
        "app": "app", "app.fill": "app:filled", "app.dashed": "app", "app.badge": "app", "app.badge.checkmark": "app",
        "desktopcomputer": "desktop", "rectangle.inset.filled.and.person.filled": "desktop",
        "square": "checkbox", "circle": "circle", "circle.fill": "dot",

        "magnifyingglass": "search", "text.magnifyingglass": "search", "doc.text.magnifyingglass": "search",
        "rectangle.and.text.magnifyingglass": "search",
        "clock": "clock", "clock.fill": "clock:filled", "clock.badge.questionmark": "clock",
        "clock.badge.exclamationmark.fill": "clock:filled", "timelapse": "clock",
        "timer": "timer", "calendar": "calendar", "calendar.badge.clock": "calendar",
        "gearshape": "gear", "gearshape.2": "gear", "gear": "gear", "gearshape.fill": "gear:filled",
        "trash": "trash", "trash.fill": "trash:filled",
        "doc": "doc", "doc.fill": "doc:filled", "doc.text": "docText",
        "doc.on.doc": "copy", "doc.on.doc.fill": "copy:filled", "doc.on.clipboard": "clipboard",
        "link": "link", "link.badge.plus": "link",
        "tag": "tag", "tag.fill": "tag:filled", "tag.slash": "tag:slashed",
        "globe": "globe", "eye": "eye", "eye.fill": "eye:filled", "eye.slash": "eye:slashed", "eye.slash.fill": "eye:slashed",
        "eye.circle": "eye:ring",
        "photo.on.rectangle.angled": "photo", "photo.badge.plus": "photo",
        "film": "film", "film.stack": "film", "video": "video", "play.rectangle": "video",
        "play.fill": "play", "play.circle": "play:ring", "play.circle.fill": "play:disc",
        "pause.fill": "pause", "pause.circle": "pause:ring", "stop.circle": "stop:ring",
        "forward.end.fill": "forward", "record.circle": "record", "target": "target", "scope": "target",
        "bell.badge": "bell", "lightbulb": "lightbulb", "lightbulb.fill": "lightbulb:filled", "sparkles": "sparkles",
        "text.bubble": "bubbleText", "text.bubble.slash": "bubbleText:slashed", "text.book.closed": "book", "text.viewfinder": "viewfinder", "text.bubble.fill": "bubbleText:filled", "message.fill": "bubble:filled",
        "bubble.left.and.bubble.right.fill": "bubble:filled", "paperclip": "paperclip",
        "externaldrive": "drive", "externaldrive.fill": "drive:filled", "externaldrive.badge.exclamationmark": "drive",
        "externaldrive.fill.badge.xmark": "drive:filled", "internaldrive": "drive",
        "cylinder": "database", "archivebox": "archive", "tray": "tray",
        "cpu": "cpu", "memorychip": "memory", "bolt": "bolt", "bolt.fill": "bolt:filled",
        "bolt.circle.fill": "bolt:disc", "bolt.slash.fill": "bolt:slashed", "bolt.horizontal.fill": "bolt:filled",
        "battery.50": "battery", "battery.75": "battery", "leaf": "leaf", "leaf.fill": "leaf:filled",
        "gauge.with.needle": "gauge", "gauge.with.dots.needle.50percent": "gauge", "gauge.with.dots.needle.33percent": "gauge",
        "waveform.path.ecg": "pulse", "power": "power",
        "hammer": "wrench", "wrench.and.screwdriver": "wrench", "wrench.and.screwdriver.fill": "wrench",
        "lock.shield": "shield", "lock.shield.fill": "shield:filled", "lock.open.fill": "lockOpen",
        "hand.raised": "hand", "hand.point.up.braille": "accessibility", "key.horizontal": "key", "keyboard": "keyboard",
        "person.2.fill": "people", "person.crop.circle": "personRing", "paintbrush": "paintbrush",
        "wifi": "wifi", "wifi.slash": "wifi:slashed", "safari": "compass",
        "ladybug": "bug", "ant.fill": "bug", "cursorarrow": "cursor",
        "star.fill": "star:filled", "heart.fill": "heart:filled", "crown.fill": "crown:filled", "trophy.fill": "trophy:filled",
        "cup.and.saucer.fill": "coffee", "chart.bar": "chart", "sum": "sum", "at": "at", "bold": "bold", "italic": "italic",
        "accessibility": "accessibility", "circle.hexagongrid.fill": "hexgrid",
        "command": "keyboard", "archivebox.fill": "archive:filled",
    ]

    /// Parses `"glyph:style"` table entries.
    public static func spec(forSystemName name: String) -> RetraceIconSpec? {
        guard let entry = table[name] else { return nil }
        let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
        let style: RetraceIconStyle = parts.count > 1 ? (RetraceIconStyle(rawValue: parts[1]) ?? .plain) : .plain
        return RetraceIconSpec(glyph: parts[0], style: style)
    }

    public static func spec(glyph: String, style: RetraceIconStyle = .plain) -> RetraceIconSpec {
        RetraceIconSpec(glyph: glyph, style: style)
    }

    /// Glyph names that table entries reference but the library does not define.
    static func missingGlyphs() -> [String] {
        let known = Set(RetraceGlyphLibrary.art.keys)
        var missing = Set<String>()
        for name in table.keys {
            if let spec = spec(forSystemName: name), !known.contains(spec.glyph) {
                missing.insert(spec.glyph)
            }
        }
        return missing.sorted()
    }
}

// MARK: Accessibility names

extension RetraceIcons {
    private static let spokenNames: [String: String] = [
        "xmark": "Close", "plus": "Add", "minus": "Remove", "check": "Checkmark",
        "chevronDown": "Expand", "chevronUp": "Collapse", "chevronLeft": "Previous", "chevronRight": "Next",
        "arrowLeft": "Back", "arrowRight": "Forward", "arrowUp": "Up", "arrowDown": "Down",
        "rewind": "Reset", "refresh": "Refresh", "sync": "Sync", "history": "History", "uturn": "Undo",
        "ellipsis": "More", "menu": "Menu", "filter": "Filter", "sliders": "Filters", "gear": "Settings",
        "search": "Search", "searchPlus": "Zoom in", "searchMinus": "Zoom out", "trash": "Delete", "copy": "Copy",
        "share": "Share", "download": "Download", "expand": "Expand", "linkOut": "Open link",
        "eye": "Show", "play": "Play", "pause": "Pause", "stop": "Stop", "forward": "Skip to end",
        "info": "Information", "question": "Help", "exclaim": "Alert", "warning": "Warning",
        "bubbleText": "Comment", "bubble": "Comment", "bubbleAlert": "Feedback", "paperclip": "Attachment",
        "checkbox": "Unchecked", "checkboxOn": "Checked", "circle": "Not selected", "dot": "Selected",
    ]

    /// Spoken name for a spec: a curated verb for common controls, otherwise the humanized glyph name.
    static func accessibilityName(for spec: RetraceIconSpec) -> String {
        if spec.style == .slashed {
            return "\(humanized(spec.glyph)) off"
        }
        if let name = spokenNames[spec.glyph] { return name }
        return humanized(spec.glyph)
    }

    private static func humanized(_ glyph: String) -> String {
        var words = ""
        for character in glyph {
            if character.isUppercase { words += " " }
            words += String(character).lowercased()
        }
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

// MARK: Geometry

/// Resolved, 24-grid layers for one icon, ready to be transformed and drawn.
struct RetraceIconGeometry {
    var wash: CGPath?
    var disc: CGPath?
    var strokes: CGPath
    var fills: CGPath
    var ring: CGPath?
    var slash: CGPath?

    private static let lock = NSLock()
    private static var cache: [RetraceIconSpec: RetraceIconGeometry] = [:]

    static func resolve(_ spec: RetraceIconSpec) -> RetraceIconGeometry? {
        lock.lock()
        if let cached = cache[spec] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let art = RetraceGlyphLibrary.art[spec.glyph] else { return nil }
        let strokes = CGMutablePath()
        for d in art.strokes { strokes.addPath(RetraceSVGPath.parse(d)) }
        let fills = CGMutablePath()
        for d in art.fills { fills.addPath(RetraceSVGPath.parse(d)) }

        var geometry = RetraceIconGeometry(strokes: strokes, fills: fills)
        switch spec.style {
        case .plain:
            break
        case .filled:
            geometry.wash = strokes
        case .slashed:
            geometry.slash = RetraceSVGPath.parse(slashPath)
        case .ring, .disc:
            let scale: CGFloat = 0.56
            let t = CGAffineTransform(translationX: 12, y: 12).scaledBy(x: scale, y: scale).translatedBy(x: -12, y: -12)
            geometry.strokes = strokes.retraceTransformed(t)
            geometry.fills = fills.retraceTransformed(t)
            let circle = RetraceSVGPath.parse(C(12, 12, spec.style == .ring ? 9 : 9.4))
            if spec.style == .ring { geometry.ring = circle } else { geometry.disc = circle }
        }

        lock.lock()
        cache[spec] = geometry
        lock.unlock()
        return geometry
    }
}

private extension CGPath {
    func retraceTransformed(_ transform: CGAffineTransform) -> CGPath {
        var t = transform
        return copy(using: &t) ?? self
    }
}

// MARK: SVG path parser

enum RetraceSVGPath {
    static func parse(_ d: String) -> CGPath {
        var parser = Parser(Array(d.unicodeScalars))
        return parser.run()
    }

    private struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        let path = CGMutablePath()
        var cur = CGPoint.zero
        var start = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        init(_ scalars: [Unicode.Scalar]) { s = scalars }

        mutating func run() -> CGPath {
            var command: Character = "M"
            while true {
                skipSeparators()
                guard i < s.count else { break }
                let ch = Character(s[i])
                if ch.isLetter {
                    command = ch
                    i += 1
                    if command == "Z" || command == "z" {
                        path.closeSubpath()
                        cur = start
                        lastCubicControl = nil
                        lastQuadControl = nil
                        continue
                    }
                }
                execute(command)
            }
            return path
        }

        mutating func skipSeparators() {
            while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 }
        }

        mutating func number() -> CGFloat {
            skipSeparators()
            var j = i
            var seenDot = false
            if j < s.count, s[j] == "-" || s[j] == "+" { j += 1 }
            while j < s.count {
                let c = s[j]
                if c.properties.numericType != nil || (c.value >= 48 && c.value <= 57) {
                    j += 1
                } else if c == ".", !seenDot {
                    seenDot = true
                    j += 1
                } else {
                    break
                }
            }
            let text = String(String.UnicodeScalarView(s[i..<j]))
            i = j
            return CGFloat(Double(text) ?? 0)
        }

        mutating func execute(_ command: Character) {
            let relative = command.isLowercase
            let base = relative ? cur : .zero
            switch command {
            case "M", "m":
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.move(to: p)
                cur = p
                start = p
                lastCubicControl = nil
                lastQuadControl = nil
                // Subsequent coordinate pairs are implicit line-tos.
                skipSeparators()
                while i < s.count, !Character(s[i]).isLetter {
                    let q = CGPoint(x: (relative ? cur.x : 0) + number(), y: (relative ? cur.y : 0) + number())
                    path.addLine(to: q)
                    cur = q
                    skipSeparators()
                }
            case "L", "l":
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addLine(to: p)
                cur = p
                lastCubicControl = nil
                lastQuadControl = nil
            case "H", "h":
                let p = CGPoint(x: (relative ? cur.x : 0) + number(), y: cur.y)
                path.addLine(to: p)
                cur = p
                lastCubicControl = nil
                lastQuadControl = nil
            case "V", "v":
                let p = CGPoint(x: cur.x, y: (relative ? cur.y : 0) + number())
                path.addLine(to: p)
                cur = p
                lastCubicControl = nil
                lastQuadControl = nil
            case "C", "c":
                let c1 = CGPoint(x: base.x + number(), y: base.y + number())
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: p, control1: c1, control2: c2)
                cur = p
                lastCubicControl = c2
                lastQuadControl = nil
            case "S", "s":
                let c1 = lastCubicControl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: p, control1: c1, control2: c2)
                cur = p
                lastCubicControl = c2
                lastQuadControl = nil
            case "Q", "q":
                let c = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addQuadCurve(to: p, control: c)
                cur = p
                lastQuadControl = c
                lastCubicControl = nil
            case "A", "a":
                let rx = number(), ry = number(), rotation = number()
                let large = number() != 0, sweep = number() != 0
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                addArc(from: cur, to: p, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                cur = p
                lastCubicControl = nil
                lastQuadControl = nil
            default:
                i += 1 // Unknown command: skip a scalar so we always make progress.
            }
        }

        /// SVG endpoint-to-center arc conversion (SVG 1.1 implementation notes, F.6.5), emitted as cubics.
        mutating func addArc(from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                             rotation: CGFloat, large: Bool, sweep: Bool) {
            var rx = abs(rxIn), ry = abs(ryIn)
            if rx == 0 || ry == 0 || p0 == p1 {
                path.addLine(to: p1)
                return
            }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy

            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                let scale = lambda.squareRoot()
                rx *= scale
                ry *= scale
            }
            let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
            var coefficient = denominator == 0 ? 0 : (max(0, numerator / denominator)).squareRoot()
            if large == sweep { coefficient = -coefficient }
            let cxp = coefficient * rx * y1 / ry
            let cyp = -coefficient * ry * x1 / rx
            let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
            let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                let dot = ux * vx + uy * vy
                let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
                var a = acos(max(-1, min(1, dot / len)))
                if ux * vy - uy * vx < 0 { a = -a }
                return a
            }
            let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
            var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
            if !sweep && delta > 0 { delta -= 2 * .pi }
            if sweep && delta < 0 { delta += 2 * .pi }

            let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
            let step = delta / CGFloat(segments)
            let t = 4.0 / 3.0 * tan(step / 4)
            var a = theta1
            for _ in 0..<segments {
                let cosA = cos(a), sinA = sin(a)
                let cosB = cos(a + step), sinB = sin(a + step)
                func point(_ ex: CGFloat, _ ey: CGFloat) -> CGPoint {
                    CGPoint(x: cx + cosPhi * rx * ex - sinPhi * ry * ey, y: cy + sinPhi * rx * ex + cosPhi * ry * ey)
                }
                let c1 = point(cosA - t * sinA, sinA + t * cosA)
                let c2 = point(cosB + t * sinB, sinB - t * cosB)
                let end = point(cosB, sinB)
                path.addCurve(to: end, control1: c1, control2: c2)
                a += step
            }
        }
    }
}

// MARK: SwiftUI views

/// A Retrace icon. `size` is the equivalent SF Symbol point size, so `.font(.system(size: 13))` ports 1:1.
public struct RetraceIconView: View {
    let spec: RetraceIconSpec
    let size: CGFloat
    let weight: RetraceIconWeight
    /// Spoken name. `nil` uses the curated name for the glyph; pass `""` to hide a purely decorative icon.
    let label: String?

    public init(spec: RetraceIconSpec, size: CGFloat = 16, weight: RetraceIconWeight = .regular, label: String? = nil) {
        self.spec = spec
        self.size = size
        self.weight = weight
        self.label = label
    }

    private var spokenLabel: String { label ?? RetraceIcons.accessibilityName(for: spec) }

    /// Frame side for a given point size (glyphs use the central 18/24 of the grid).
    static func frame(forPointSize size: CGFloat) -> CGFloat { (size * 1.25).rounded(.up) }

    public var body: some View {
        let side = Self.frame(forPointSize: size)
        let lineWidth = max(1.0, side * weight.gridStroke / 24)
        Canvas { context, canvasSize in
            guard let geometry = RetraceIconGeometry.resolve(spec) else { return }
            let scale = canvasSize.width / 24
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            func scaled(_ path: CGPath) -> Path { Path(path).applying(transform) }
            let strokeStyle = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            if let wash = geometry.wash {
                var layer = context
                layer.opacity = 0.18
                layer.fill(scaled(wash), with: .foreground)
            }
            if let disc = geometry.disc {
                context.drawLayer { layer in
                    layer.fill(scaled(disc), with: .foreground)
                    layer.blendMode = .destinationOut
                    layer.stroke(scaled(geometry.strokes), with: .color(.black), style: strokeStyle)
                    layer.fill(scaled(geometry.fills), with: .color(.black))
                }
            } else {
                context.stroke(scaled(geometry.strokes), with: .foreground, style: strokeStyle)
                context.fill(scaled(geometry.fills), with: .foreground)
            }
            if let ring = geometry.ring {
                context.stroke(scaled(ring), with: .foreground, style: strokeStyle)
            }
            if let slash = geometry.slash {
                context.stroke(scaled(slash), with: .foreground, style: strokeStyle)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHidden(spokenLabel.isEmpty)
    }
}

/// Drop-in replacement for `Image(systemName:)`: renders the Retrace icon mapped to the SF Symbol name and
/// falls back to the SF Symbol itself when no mapping exists.
public struct RetraceSymbol: View {
    let systemName: String
    let size: CGFloat
    let weight: Font.Weight
    let label: String?

    /// - Parameter label: Spoken name for VoiceOver. Defaults to a curated name for the glyph; pass `""` for
    ///   decorative icons that sit beside text which already says the same thing.
    public init(_ systemName: String, size: CGFloat = 16, weight: Font.Weight = .regular, label: String? = nil) {
        self.systemName = systemName
        self.size = size
        self.weight = weight
        self.label = label
    }

    public var body: some View {
        if let spec = RetraceIcons.spec(forSystemName: systemName) {
            RetraceIconView(spec: spec, size: size, weight: RetraceIconWeight(weight), label: label)
        } else {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
        }
    }
}

public enum RetraceIcon {
    /// A Retrace icon by glyph name (see `RetraceGlyphLibrary`).
    public static func view(_ glyph: String, style: RetraceIconStyle = .plain, size: CGFloat = 16,
                            weight: Font.Weight = .regular) -> some View {
        RetraceIconView(spec: .init(glyph: glyph, style: style), size: size, weight: RetraceIconWeight(weight))
    }
}

// MARK: AppKit rendering (menus, status item)

extension NSImage {
    /// Template `NSImage` of the Retrace icon mapped to `systemName`, for `NSMenuItem.image` and status items.
    /// Falls back to the SF Symbol when there is no mapping.
    public static func retraceSymbol(_ systemName: String, pointSize: CGFloat = 14,
                                     weight: Font.Weight = .regular) -> NSImage? {
        guard let spec = RetraceIcons.spec(forSystemName: systemName),
              let geometry = RetraceIconGeometry.resolve(spec) else {
            let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        }
        let side = RetraceIconView.frame(forPointSize: pointSize)
        let lineWidth = max(1.0, side * RetraceIconWeight(weight).gridStroke / 24)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / 24
            ctx.scaleBy(x: scale, y: scale)
            ctx.setLineWidth(lineWidth / scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)

            if let wash = geometry.wash {
                ctx.saveGState()
                ctx.setAlpha(0.18)
                ctx.addPath(wash)
                ctx.fillPath()
                ctx.restoreGState()
            }
            if let disc = geometry.disc {
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.addPath(disc)
                ctx.fillPath()
                ctx.setBlendMode(.clear)
                ctx.addPath(geometry.strokes)
                ctx.strokePath()
                ctx.addPath(geometry.fills)
                ctx.fillPath()
                ctx.endTransparencyLayer()
            } else {
                ctx.addPath(geometry.strokes)
                ctx.strokePath()
                ctx.addPath(geometry.fills)
                ctx.fillPath()
            }
            if let ring = geometry.ring { ctx.addPath(ring); ctx.strokePath() }
            if let slash = geometry.slash { ctx.addPath(slash); ctx.strokePath() }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Retrace mark

/// The Retrace mark: a spiral that winds back to a clay dot. The dot is the design system's 12px accent circle.
public struct RetraceMarkShape: Shape {
    public init() {}

    /// Inward spiral that winds back to the dot (24-grid coordinates): the "retrace" gesture.
    static let loop: CGPath = {
        let path = CGMutablePath()
        let turns = 1.5, outer = 9.4, inner = 5.8, steps = 96
        let startAngle = -Double.pi / 2 - 0.35
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let angle = startAngle - turns * 2 * Double.pi * t
            let radius = outer + (inner - outer) * t
            let point = CGPoint(x: 12 + radius * cos(angle), y: 12 + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }()
    static let dot: CGPath = RetraceSVGPath.parse(C(12, 12, 2.9))

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let t = CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
        return Path(Self.loop).applying(t)
    }
}

public struct RetraceMarkView: View {
    let size: CGFloat
    var loopColor: Color = .retraceInk
    var dotColor: Color = .retraceAccent

    public init(size: CGFloat = 24, loopColor: Color = .retraceInk, dotColor: Color = .retraceAccent) {
        self.size = size
        self.loopColor = loopColor
        self.dotColor = dotColor
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 24
            let t = CGAffineTransform(scaleX: scale, y: scale)
            context.stroke(
                Path(RetraceMarkShape.loop).applying(t),
                with: .color(loopColor),
                style: StrokeStyle(lineWidth: max(1.2, 1.5 * scale), lineCap: .round, lineJoin: .round)
            )
            context.fill(Path(RetraceMarkShape.dot).applying(t), with: .color(dotColor))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "Retrace" in `section-title` beside the 12px accent circle, per the design system's wordmark rule.
public struct RetraceWordmark: View {
    var showsDot: Bool = true

    public init(showsDot: Bool = true) { self.showsDot = showsDot }

    public var body: some View {
        HStack(spacing: 8) {
            if showsDot {
                Circle().fill(Color.retraceAccent).frame(width: 12, height: 12)
            }
            Text("Retrace")
                .font(.retraceTitle2)
                .foregroundColor(.retraceInk)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Retrace")
    }
}

extension NSImage {
    /// Template image of the Retrace mark for the menu bar status item.
    public static func retraceMenuBarMark(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let scale = rect.width / 24
            ctx.scaleBy(x: scale, y: scale)
            ctx.setLineWidth(max(1.2, 1.7 * scale) / scale)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(RetraceMarkShape.loop)
            ctx.strokePath()
            ctx.addPath(RetraceMarkShape.dot)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Retrace"
        return image
    }
}
