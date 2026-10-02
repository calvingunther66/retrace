import AppKit
import SwiftUI
@testable import Retrace

/// Renders SwiftUI views offscreen to PNGs so layout and theme problems can be inspected without launching the app.
///
/// Uses `NSHostingView` inside an offscreen window (not `ImageRenderer`) so AppKit-backed controls draw for real,
/// and sets the window appearance explicitly because the Linen/Dusk tokens are dynamic `NSColor`s that resolve
/// against `NSAppearance`, not SwiftUI's `colorScheme`.
@MainActor
enum SnapshotRenderer {
    enum Scheme: String, CaseIterable {
        case light, dark

        var appearance: NSAppearance {
            NSAppearance(named: self == .light ? .aqua : .darkAqua)!
        }

        var colorScheme: ColorScheme { self == .light ? .light : .dark }
        var pageHex: UInt32 { self == .light ? RetraceTokens.page.light : RetraceTokens.page.dark }
    }

    struct Output {
        let bitmap: NSBitmapImageRep
        let url: URL?
        var pixelSize: (width: Int, height: Int) { (bitmap.pixelsWide, bitmap.pixelsHigh) }
    }

    /// Where PNGs land. Defaults to `.build/ui-gallery` under the package root; override with `RETRACE_UI_GALLERY_DIR`.
    static var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["RETRACE_UI_GALLERY_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/ui-gallery", isDirectory: true)
    }

    /// Renders `content` at a fixed `width` on the page background, with the height the content asks for.
    @discardableResult
    static func render<Content: View>(
        name: String,
        width: CGFloat,
        scheme: Scheme,
        scale: CGFloat = 2,
        padding: CGFloat = 16,
        write: Bool = true,
        @ViewBuilder content: () -> Content
    ) throws -> Output {
        let root = content()
            .padding(padding)
            .frame(width: width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.retracePage)
            .environment(\.colorScheme, scheme.colorScheme)

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = scheme.appearance
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = scheme.appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let height = max(1, ceil(hosting.fittingSize.height))
        let size = NSSize(width: width, height: height)
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale),
            pixelsHigh: Int(height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw SnapshotError.bitmapUnavailable
        }
        rep.size = size

        scheme.appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
        }

        var url: URL?
        if write {
            let directory = outputDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("\(name)-\(scheme.rawValue)-\(Int(width)).png")
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw SnapshotError.pngEncodingFailed
            }
            try png.write(to: file)
            url = file
        }
        return Output(bitmap: rep, url: url)
    }

    /// sRGB components (0...1) of the pixel at `(x, y)` in bitmap pixel coordinates.
    static func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> (r: Double, g: Double, b: Double)? {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    /// Fraction of pixels that differ from the page background, a cheap "did anything draw" signal.
    static func inkCoverage(_ rep: NSBitmapImageRep, pageHex: UInt32, tolerance: Double = 0.02) -> Double {
        let page = rgb(pageHex)
        var differing = 0
        let total = rep.pixelsWide * rep.pixelsHigh
        guard total > 0 else { return 0 }
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let p = pixel(rep, x: x, y: y) else { continue }
                if abs(p.r - page.r) > tolerance || abs(p.g - page.g) > tolerance || abs(p.b - page.b) > tolerance {
                    differing += 1
                }
            }
        }
        return Double(differing) / Double(total)
    }

    static func rgb(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    enum SnapshotError: Error {
        case bitmapUnavailable
        case pngEncodingFailed
    }
}

/// WCAG 2.x relative luminance and contrast ratio for `0xRRGGBB` values.
enum WCAGContrast {
    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
