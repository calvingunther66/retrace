import SwiftUI
import AppKit
import CryptoKit
import Shared

/// Retrace design system (Linen / Dusk)
/// Provides consistent colors, typography, spacing, elevation and components across the UI.
/// Tokens mirror the "Calvin Gunther" design system: warm paper, clay accent, serif type, hairlines, soft shadows.
public struct AppTheme {
    private init() {}
}

// MARK: - Video URL Symlink Resolver

/// Resolves extensionless video paths to stable, collision-safe `.mp4` symlink URLs.
/// Symlink file names are derived from the full normalized destination path to avoid
/// basename collisions across different sources.
enum MP4SymlinkResolver {
    static func resolveURL(for videoPath: String) -> URL? {
        if videoPath.hasSuffix(".mp4") {
            return URL(fileURLWithPath: videoPath)
        }

        let destinationPath = URL(fileURLWithPath: videoPath).standardizedFileURL.path
        let symlinkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("retrace_video_\(pathDigest(destinationPath)).mp4")

        do {
            try ensureSymlink(at: symlinkURL, destinationPath: destinationPath)
            return symlinkURL
        } catch {
            return nil
        }
    }

    private static func ensureSymlink(at symlinkURL: URL, destinationPath: String) throws {
        let fileManager = FileManager.default
        var lastError: Error?

        // Retry a small number of times to tolerate concurrent resolvers racing to create/remove the same symlink.
        for _ in 0..<3 {
            do {
                try fileManager.createSymbolicLink(
                    atPath: symlinkURL.path,
                    withDestinationPath: destinationPath
                )
                return
            } catch {
                lastError = error

                if let existingDestination = try? fileManager.destinationOfSymbolicLink(atPath: symlinkURL.path),
                   normalizedSymlinkDestination(existingDestination, symlinkURL: symlinkURL) == destinationPath {
                    return
                }

                guard fileManager.fileExists(atPath: symlinkURL.path) else {
                    continue
                }

                do {
                    try fileManager.removeItem(at: symlinkURL)
                } catch {
                    lastError = error
                    if !fileManager.fileExists(atPath: symlinkURL.path) {
                        continue
                    }
                    break
                }
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private static func normalizedSymlinkDestination(_ destination: String, symlinkURL: URL) -> String {
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL.path
        }

        return URL(
            fileURLWithPath: destination,
            relativeTo: symlinkURL.deletingLastPathComponent()
        ).standardizedFileURL.path
    }

    private static func pathDigest(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - App Icon Color Extraction

/// Storable color data for persistence
private struct StoredColor: Codable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }
}

/// Extracts and caches dominant colors from app icons (with disk persistence)
public class AppIconColorCache {
    public static let shared = AppIconColorCache()

    private var cache: [String: Color] = [:]
    private let lock = NSLock()
    private let cacheFileURL: URL
    private var diskCache: [String: StoredColor] = [:]
    private var isDirty = false
    private var pendingExtractions: Set<String> = []

    private init() {
        // Store in AppPaths.storageRoot (respects custom location)
        let retraceDir = URL(fileURLWithPath: AppPaths.expandedStorageRoot)

        // Create directory if needed
        try? FileManager.default.createDirectory(at: retraceDir, withIntermediateDirectories: true)

        cacheFileURL = retraceDir.appendingPathComponent("app_icon_colors.json")

        // Load existing cache from disk
        loadFromDisk()
    }

    /// Get the dominant color for an app's icon, with caching
    public func color(for bundleID: String) -> Color {
        lock.lock()
        if let cached = cache[bundleID] {
            lock.unlock()
            return cached
        }

        // Return from disk cache if available
        if let stored = diskCache[bundleID] {
            let color = stored.color
            cache[bundleID] = color
            lock.unlock()
            return color
        }

        // Cache miss: return deterministic fallback immediately and extract asynchronously.
        if !pendingExtractions.contains(bundleID) {
            pendingExtractions.insert(bundleID)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.extractAndCacheColor(for: bundleID)
            }
        }
        lock.unlock()
        return fallbackColor(for: bundleID)
    }

    private func extractAndCacheColor(for bundleID: String) {
        let color = extractDominantColor(for: bundleID)

        lock.lock()
        cache[bundleID] = color
        pendingExtractions.remove(bundleID)
        lock.unlock()

        // Persist asynchronously to keep extraction path non-blocking.
        saveToDiskAsync(bundleID: bundleID, color: color)
    }

    /// Extract the dominant color from an app's icon
    private func extractDominantColor(for bundleID: String) -> Color {
        // Get the app icon
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return fallbackColor(for: bundleID)
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)

        // Get a bitmap representation
        guard let tiffData = icon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return fallbackColor(for: bundleID)
        }

        // Sample the icon at a smaller size for performance
        let sampleSize = 32
        var colorCounts: [String: (count: Int, r: CGFloat, g: CGFloat, b: CGFloat)] = [:]

        for x in 0..<min(sampleSize, bitmap.pixelsWide) {
            for y in 0..<min(sampleSize, bitmap.pixelsHigh) {
                // Scale coordinates to bitmap size
                let scaledX = x * bitmap.pixelsWide / sampleSize
                let scaledY = y * bitmap.pixelsHigh / sampleSize

                guard let pixelColor = bitmap.colorAt(x: scaledX, y: scaledY) else { continue }

                // Convert to RGB
                guard let rgbColor = pixelColor.usingColorSpace(.sRGB) else { continue }

                let r = rgbColor.redComponent
                let g = rgbColor.greenComponent
                let b = rgbColor.blueComponent
                let a = rgbColor.alphaComponent

                // Skip transparent pixels
                guard a > 0.5 else { continue }

                // Skip very dark pixels (likely background/shadow)
                let brightness = (r + g + b) / 3
                guard brightness > 0.1 else { continue }

                // Skip very light/white pixels
                guard brightness < 0.95 else { continue }

                // Skip grayish pixels (low saturation)
                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                guard saturation > 0.2 else { continue }

                // Quantize colors to reduce noise (group similar colors)
                let qr = Int(r * 8) // 8 levels per channel
                let qg = Int(g * 8)
                let qb = Int(b * 8)
                let key = "\(qr),\(qg),\(qb)"

                if let existing = colorCounts[key] {
                    colorCounts[key] = (existing.count + 1, existing.r + r, existing.g + g, existing.b + b)
                } else {
                    colorCounts[key] = (1, r, g, b)
                }
            }
        }

        // Find the most common color
        guard let mostCommon = colorCounts.max(by: { $0.value.count < $1.value.count }) else {
            return fallbackColor(for: bundleID)
        }

        // Average the colors in this bucket
        let count = CGFloat(mostCommon.value.count)
        let avgR = mostCommon.value.r / count
        let avgG = mostCommon.value.g / count
        let avgB = mostCommon.value.b / count

        // Boost saturation slightly for better visibility on dark backgrounds
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        NSColor(red: avgR, green: avgG, blue: avgB, alpha: 1.0)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        // Ensure minimum saturation and brightness for visibility
        saturation = max(saturation, 0.5)
        brightness = max(brightness, 0.6)

        return Color(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
    }

    /// Fallback color when icon extraction fails (hash-based)
    private func fallbackColor(for bundleID: String) -> Color {
        let hash = bundleID.hashValue
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.7, brightness: 0.75)
    }

    // MARK: - Disk Persistence

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: cacheFileURL)
            diskCache = try JSONDecoder().decode([String: StoredColor].self, from: data)
        } catch {
            // Silently fail - will re-extract colors as needed
        }
    }

    private func saveToDiskAsync(bundleID: String, color: Color) {
        // Convert Color to StoredColor by extracting HSB components
        let nsColor = NSColor(color)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)

        let stored = StoredColor(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            self.diskCache[bundleID] = stored
            self.isDirty = true
            self.lock.unlock()

            self.flushToDiskIfNeeded()
        }
    }

    private func flushToDiskIfNeeded() {
        lock.lock()
        guard isDirty else {
            lock.unlock()
            return
        }
        let cacheToSave = diskCache
        isDirty = false
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(cacheToSave)
            try data.write(to: cacheFileURL, options: .atomic)
        } catch {
            // Silently fail - cache will be rebuilt next time
        }
    }
}

// MARK: - Tag Color Storage

/// Persists per-tag colors selected by users in Settings.
/// Colors are keyed by tag ID and fall back to a deterministic color when unset.
public enum TagColorStore {
    private static let defaults: UserDefaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
    private static let storageKey = "tagColorsByID"
    private static let lock = NSLock()
    private static var cachedHexByTagID: [Int64: String] = [:]
    private static var didLoadCache = false

    public static func color(for tag: Tag) -> Color {
        color(forTagID: tag.id, tagName: tag.name)
    }

    public static func color(forTagID tagID: TagID, tagName: String? = nil) -> Color {
        lock.lock()
        loadCacheIfNeededLocked()
        let storedHex = cachedHexByTagID[tagID.value]
        lock.unlock()

        if let storedHex, let storedColor = colorFromHex(storedHex) {
            return storedColor
        }

        return fallbackColor(forTagID: tagID, tagName: tagName)
    }

    public static func setColor(_ color: Color, for tagID: TagID) {
        let hex = hexString(from: color)
        var didChange = false

        lock.lock()
        loadCacheIfNeededLocked()

        if cachedHexByTagID[tagID.value] != hex {
            cachedHexByTagID[tagID.value] = hex
            persistLocked()
            didChange = true
        }

        lock.unlock()

        if didChange {
            NotificationCenter.default.post(name: .tagColorsDidChange, object: tagID)
        }
    }

    public static func removeColor(for tagID: TagID) {
        var didChange = false

        lock.lock()
        loadCacheIfNeededLocked()

        if cachedHexByTagID.removeValue(forKey: tagID.value) != nil {
            persistLocked()
            didChange = true
        }

        lock.unlock()

        if didChange {
            NotificationCenter.default.post(name: .tagColorsDidChange, object: tagID)
        }
    }

    public static func pruneColors(keeping validTagIDs: Set<Int64>) {
        var didChange = false

        lock.lock()
        loadCacheIfNeededLocked()

        let initialCount = cachedHexByTagID.count
        cachedHexByTagID = cachedHexByTagID.filter { validTagIDs.contains($0.key) }
        didChange = cachedHexByTagID.count != initialCount

        if didChange {
            persistLocked()
        }

        lock.unlock()

        if didChange {
            NotificationCenter.default.post(name: .tagColorsDidChange, object: nil)
        }
    }

    public static func suggestedColor(for tagName: String) -> Color {
        fallbackColor(forTagID: TagID(value: 0), tagName: tagName)
    }

    private static func loadCacheIfNeededLocked() {
        guard !didLoadCache else { return }
        defer { didLoadCache = true }

        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: String] else {
            cachedHexByTagID = [:]
            return
        }

        cachedHexByTagID = raw.reduce(into: [:]) { map, entry in
            guard let id = Int64(entry.key) else { return }
            map[id] = entry.value
        }
    }

    private static func persistLocked() {
        let serialized = cachedHexByTagID.reduce(into: [String: String]()) { map, entry in
            map[String(entry.key)] = entry.value
        }
        defaults.set(serialized, forKey: storageKey)
    }

    private static func fallbackColor(forTagID tagID: TagID, tagName: String?) -> Color {
        let normalizedName = (tagName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hashSeed = normalizedName.isEmpty ? "tag-\(tagID.value)" : "tag-\(tagID.value)-\(normalizedName)"
        let hash = stableHash(for: hashSeed)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.72, brightness: 0.88)
    }

    private static func stableHash(for input: String) -> UInt64 {
        // FNV-1a 64-bit hash for deterministic color assignment.
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func colorFromHex(_ hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6 else { return nil }
        return Color(hex: cleaned)
    }

    private static func hexString(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.systemBlue

        let red = max(0, min(255, Int((nsColor.redComponent * 255).rounded())))
        let green = max(0, min(255, Int((nsColor.greenComponent * 255).rounded())))
        let blue = max(0, min(255, Int((nsColor.blueComponent * 255).rounded())))

        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

// MARK: - Design tokens (Linen / Dusk)
//
// Every color below is adaptive: the first value is Linen (light), the second is Dusk (dark). They mirror
// `tokens.json` in the "Calvin Gunther" design system. Prefer these semantic tokens over literal colors.
//
// Roles
//   page            – window / page background
//   surface         – cards, panels, inputs, menus, popovers
//   surfaceSunken   – sidebars, table headers, inset wells
//   surfaceHover    – row / nav / ghost-button hover wash
//   ink, ink2       – primary / secondary text
//   muted           – captions and tertiary text (page and surface only)
//   border          – decorative hairlines; borderStrong – control edges (3:1)
//   accent (clay)   – the single voice: primary fills, links, focus ring, selection
//   accentWash      – quiet selected state (text on it is `ink`)
//   good / warning / critical (+ `…Bg`) – status text on its own tinted background

/// A light/dark pair of sRGB hex values.
public struct RetraceToken: Sendable {
    public let light: UInt32
    public let dark: UInt32

    public init(_ light: UInt32, _ dark: UInt32) {
        self.light = light
        self.dark = dark
    }
}

public enum RetraceTokens {
    public static let page = RetraceToken(0xF7F3EA, 0x1F1B16)
    public static let surface = RetraceToken(0xFDFBF6, 0x292420)
    public static let surfaceSunken = RetraceToken(0xEEE8DA, 0x17140F)
    public static let surfaceHover = RetraceToken(0xF2ECDF, 0x322C26)
    public static let ink = RetraceToken(0x3B352D, 0xECE4D4)
    public static let ink2 = RetraceToken(0x5F564A, 0xC3B9A5)
    public static let muted = RetraceToken(0x766D5D, 0x9D9380)
    public static let border = RetraceToken(0xE4DCCB, 0x3A342C)
    public static let borderStrong = RetraceToken(0x8F8568, 0x7D7360)
    public static let accent = RetraceToken(0xA4573A, 0xE0997A)
    public static let accentHover = RetraceToken(0x8F4A31, 0xEBAB90)
    public static let onAccent = RetraceToken(0xFFFAF2, 0x2A1A12)
    public static let accentWash = RetraceToken(0xF3E4DA, 0x3A2A22)
    public static let good = RetraceToken(0x4F6B40, 0xA9C28F)
    public static let goodBg = RetraceToken(0xE6ECDA, 0x2E3326)
    public static let warning = RetraceToken(0x7A5C14, 0xE0C27A)
    public static let warningBg = RetraceToken(0xF4EAD0, 0x38301D)
    public static let critical = RetraceToken(0x8F4030, 0xEBA08C)
    public static let criticalBg = RetraceToken(0xF3E2DA, 0x3B2722)
    public static let series1 = RetraceToken(0xA4573A, 0xE0997A)
    public static let series2 = RetraceToken(0x4F6B40, 0xA9C28F)
    public static let series3 = RetraceToken(0x4F6F86, 0x8FB0C6)
    public static let termBg = RetraceToken(0x2A2520, 0x12100D)
    public static let termInk = RetraceToken(0xE9E2D2, 0xE9E2D2)
}

extension NSColor {
    convenience init(retraceHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Appearance-adaptive color for a design token (use in AppKit menus, status items and windows).
    public static func retrace(_ token: RetraceToken, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(retraceHex: isDark ? token.dark : token.light, alpha: alpha)
        }
    }

    public static var retraceInk: NSColor { retrace(RetraceTokens.ink) }
    public static var retraceInk2: NSColor { retrace(RetraceTokens.ink2) }
    public static var retraceMuted: NSColor { retrace(RetraceTokens.muted) }
    public static var retracePage: NSColor { retrace(RetraceTokens.page) }
    public static var retraceSurface: NSColor { retrace(RetraceTokens.surface) }
    public static var retraceAccent: NSColor { retrace(RetraceTokens.accent) }
}

extension Color {
    /// Appearance-adaptive color for a design token.
    public init(_ token: RetraceToken, opacity: Double = 1) {
        self = Color(nsColor: NSColor.retrace(token, alpha: CGFloat(opacity)))
    }

    /// Adaptive color from explicit light/dark hex values with optional alpha (shadows and scrims).
    public static func retraceDynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(retraceHex: isDark ? dark : light, alpha: CGFloat(isDark ? darkAlpha : lightAlpha))
        })
    }

    // MARK: Surfaces
    public static let retracePage = Color(RetraceTokens.page)
    public static let retraceSurface = Color(RetraceTokens.surface)
    public static let retraceSurfaceSunken = Color(RetraceTokens.surfaceSunken)
    public static let retraceSurfaceHover = Color(RetraceTokens.surfaceHover)

    // MARK: Text
    public static let retraceInk = Color(RetraceTokens.ink)
    public static let retraceInk2 = Color(RetraceTokens.ink2)
    public static let retraceMuted = Color(RetraceTokens.muted)

    // MARK: Lines
    public static let retraceHairline = Color(RetraceTokens.border)
    public static let retraceBorderStrong = Color(RetraceTokens.borderStrong)

    // MARK: Accent (clay)
    // The accent is always clay. `MilestoneCelebrationManager.ColorTheme` is still persisted for compatibility
    // but no longer changes the palette: clay is the system's single voice.
    public static let retraceAccent = Color(RetraceTokens.accent)
    public static let retraceAccentHover = Color(RetraceTokens.accentHover)
    public static let retraceOnAccent = Color(RetraceTokens.onAccent)
    public static let retraceAccentWash = Color(RetraceTokens.accentWash)
    public static let retraceSubmitAccent = Color(RetraceTokens.accent)

    // MARK: Status
    public static let retraceGood = Color(RetraceTokens.good)
    public static let retraceGoodBg = Color(RetraceTokens.goodBg)
    public static let retraceWarningText = Color(RetraceTokens.warning)
    public static let retraceWarningBg = Color(RetraceTokens.warningBg)
    public static let retraceCritical = Color(RetraceTokens.critical)
    public static let retraceCriticalBg = Color(RetraceTokens.criticalBg)

    // MARK: Scrim (dims content behind modals; ink in Linen, black in Dusk, never a lightening wash)
    public static let retraceScrim = Color.retraceDynamic(light: 0x3B352D, dark: 0x000000, lightAlpha: 0.35, darkAlpha: 0.55)

    // MARK: Charts and terminal
    public static let retraceSeries1 = Color(RetraceTokens.series1)
    public static let retraceSeries2 = Color(RetraceTokens.series2)
    public static let retraceSeries3 = Color(RetraceTokens.series3)
    public static let retraceTermBg = Color(RetraceTokens.termBg)
    public static let retraceTermInk = Color(RetraceTokens.termInk)

    // MARK: Legacy names (kept so existing call sites restyle automatically)
    public static let retraceDeepBlue = Color.retracePage
    public static let retraceBrandBlue = Color.retraceAccent
    public static let retraceCard = Color.retraceSurface
    public static let retraceSecondaryColor = Color.retraceSurfaceSunken
    public static let retraceForeground = Color.retraceInk
    public static let retraceMutedForeground = Color.retraceMuted

    public static let retraceDanger = Color.retraceCritical
    public static let retraceSuccess = Color.retraceGood
    public static let retraceWarning = Color.retraceWarningText

    // MARK: Segment Colors (extracted from app icon; data, not chrome)
    public static func segmentColor(for bundleID: String) -> Color {
        AppIconColorCache.shared.color(for: bundleID)
    }

    // MARK: Semantic Colors (adapt to Linen / Dusk)
    public static let retraceBackground = Color.retracePage
    public static let retraceSecondaryBackground = Color.retraceSurface
    public static let retraceTertiaryBackground = Color.retraceSurfaceSunken

    public static let retracePrimary = Color.retraceInk
    public static let retraceSecondary = Color.retraceInk2

    public static let retraceBorder = Color.retraceHairline
    public static let retraceHover = Color.retraceSurfaceHover

    // MARK: Search Highlight (drawn over captured screenshots; stays a functional honey/clay)
    public static let retraceMatchHighlight = Color(red: 232 / 255, green: 190 / 255, blue: 80 / 255).opacity(0.45)
    public static let retraceBoundingBox = Color.retraceAccent
    public static let retraceBoundingBoxSecondary = Color.retraceSeries3
}

// MARK: - Appearance

/// Routes the Auto / Light / Dark preference to `NSApp.appearance`. Linen is light, Dusk is dark; the fullscreen
/// timeline always sits on Dusk because it floats over arbitrary screenshots.
public enum RetraceAppearance {
    private static let store = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    /// Applies the stored `theme` preference ("auto" | "light" | "dark"); defaults to following the system.
    @MainActor
    public static func applyStoredPreference() {
        // Persisted by Settings as ThemePreference raw values: "Auto" | "Light" | "Dark".
        switch store.string(forKey: "theme")?.lowercased() {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Applies an explicit preference ("Auto" | "Light" | "Dark", case-insensitive).
    @MainActor
    public static func apply(_ rawValue: String) {
        switch rawValue.lowercased() {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Dusk, for windows that must stay dark regardless of the preference.
    public static var dusk: NSAppearance? { NSAppearance(named: .darkAqua) }
}

// MARK: - Typography

/// Available font styles for the app
public enum RetraceFontStyle: String, CaseIterable, Identifiable, Sendable {
    /// Source Serif 4 + IBM Plex Mono, the design system's typefaces.
    case `default` = "default"
    case sans = "sans"
    case rounded = "rounded"
    case serif = "serif"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .default: return "Source Serif 4"
        case .sans: return "SF Pro"
        case .rounded: return "SF Pro Rounded"
        case .serif: return "New York"
        }
    }

    public var description: String {
        switch self {
        case .default: return "Warm and readable"
        case .sans: return "Clean and neutral"
        case .rounded: return "Friendly and approachable"
        case .serif: return "Classic and elegant"
        }
    }

    var design: Font.Design {
        switch self {
        case .default: return .serif
        case .sans: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        }
    }
}

/// Centralized font configuration for the entire app.
/// Font style can be changed in Settings.
public enum RetraceFont {
    /// UserDefaults key for font preference
    private static let fontStyleKey = "retraceFontStyle"

    /// Shared UserDefaults store (same as Settings uses)
    private static let settingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

    /// The current font style (persisted in UserDefaults)
    public static var currentStyle: RetraceFontStyle {
        get {
            if let rawValue = settingsStore.string(forKey: fontStyleKey),
               let style = RetraceFontStyle(rawValue: rawValue) {
                return style
            }
            return .default
        }
        set {
            settingsStore.set(newValue.rawValue, forKey: fontStyleKey)
            // Post notification so views can update
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .fontStyleDidChange, object: newValue)
            }
        }
    }

    /// The font design used throughout the app
    public static var design: Font.Design {
        currentStyle.design
    }

    private static var usesBundledFaces: Bool {
        currentStyle == .default && RetraceFontRegistry.isAvailable
    }

    /// Creates a font with the app's current design style (Source Serif 4 by default).
    public static func font(size: CGFloat, weight: Font.Weight) -> Font {
        guard usesBundledFaces else {
            return .system(size: size, weight: weight, design: design)
        }
        switch weight {
        case .semibold:
            return .custom(RetraceFontRegistry.Face.serifSemibold, fixedSize: size)
        case .bold, .heavy, .black:
            return .custom(RetraceFontRegistry.Face.serifBold, fixedSize: size)
        default:
            return .custom(RetraceFontRegistry.Face.serifRegular, fixedSize: size)
        }
    }

    /// Italic serif, for captions and metadata.
    public static func italic(size: CGFloat) -> Font {
        guard usesBundledFaces else {
            return .system(size: size, weight: .regular, design: design).italic()
        }
        return .custom(RetraceFontRegistry.Face.serifItalic, fixedSize: size)
    }

    /// Creates a monospaced font (IBM Plex Mono; ignores the global design setting)
    public static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard RetraceFontRegistry.isAvailable else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black:
            return .custom(RetraceFontRegistry.Face.monoMedium, fixedSize: size)
        default:
            return .custom(RetraceFontRegistry.Face.monoRegular, fixedSize: size)
        }
    }
}

extension Font {
    // Design-system type scale: page-title 28/600, section-title 20/600, body 15, body-sm 13.5,
    // caption 12.5 (italic for metadata), label 12/600, stat 28 mono, code 13 mono.

    // MARK: Display (Hero text, large numbers)
    public static var retraceDisplay: Font { RetraceFont.font(size: 48, weight: .semibold) }
    public static var retraceDisplay2: Font { RetraceFont.font(size: 36, weight: .semibold) }
    public static var retraceDisplay3: Font { RetraceFont.font(size: 32, weight: .semibold) }

    // MARK: Titles
    /// page-title: one per page.
    public static var retraceTitle: Font { RetraceFont.font(size: 28, weight: .semibold) }
    /// section-title: panel and modal headings.
    public static var retraceTitle2: Font { RetraceFont.font(size: 20, weight: .semibold) }
    public static var retraceTitle3: Font { RetraceFont.font(size: 17, weight: .semibold) }

    // MARK: Large Numbers (stat: mono, tabular)
    public static var retraceLargeNumber: Font { RetraceFont.mono(size: 28, weight: .medium) }
    public static var retraceMediumNumber: Font { RetraceFont.mono(size: 22, weight: .medium) }

    // MARK: Body Text
    public static var retraceHeadline: Font { RetraceFont.font(size: 17, weight: .semibold) }
    /// body: default copy.
    public static var retraceBody: Font { RetraceFont.font(size: 15, weight: .regular) }
    public static var retraceBodyMedium: Font { RetraceFont.font(size: 15, weight: .regular) }
    public static var retraceBodyBold: Font { RetraceFont.font(size: 15, weight: .semibold) }
    /// body-sm: tables, nav, buttons.
    public static var retraceCallout: Font { RetraceFont.font(size: 13.5, weight: .regular) }
    public static var retraceCalloutMedium: Font { RetraceFont.font(size: 13.5, weight: .regular) }
    public static var retraceCalloutBold: Font { RetraceFont.font(size: 13.5, weight: .semibold) }

    // MARK: Small Text
    /// caption size, upright. Use `retraceMeta` for subtitles and metadata.
    public static var retraceCaption: Font { RetraceFont.font(size: 12.5, weight: .regular) }
    public static var retraceCaptionMedium: Font { RetraceFont.font(size: 12.5, weight: .regular) }
    public static var retraceCaptionBold: Font { RetraceFont.font(size: 12.5, weight: .semibold) }
    /// caption: italic, for subtitles and metadata in `muted`.
    public static var retraceMeta: Font { RetraceFont.italic(size: 12.5) }
    /// label: form and tile labels. Pair with `.retraceLabelTracking()`.
    public static var retraceLabel: Font { RetraceFont.font(size: 12, weight: .semibold) }
    public static var retraceCaption2: Font { RetraceFont.font(size: 12, weight: .regular) }
    public static var retraceCaption2Medium: Font { RetraceFont.font(size: 12, weight: .regular) }
    public static var retraceCaption2Bold: Font { RetraceFont.font(size: 12, weight: .semibold) }

    // MARK: Tiny Text (for badges)
    public static var retraceTiny: Font { RetraceFont.font(size: 11, weight: .regular) }
    public static var retraceTinyMedium: Font { RetraceFont.font(size: 11, weight: .regular) }
    public static var retraceTinyBold: Font { RetraceFont.font(size: 11, weight: .semibold) }

    // MARK: Monospace (code: IDs, timestamps, bytes; always Plex Mono)
    public static var retraceMono: Font { RetraceFont.mono(size: 13) }
    public static var retraceMonoSmall: Font { RetraceFont.mono(size: 12) }
    public static var retraceMonoLarge: Font { RetraceFont.mono(size: 15) }
}

extension View {
    /// label tracking (0.03em at 12pt).
    public func retraceLabelTracking() -> some View {
        self.tracking(0.36)
    }
}

// MARK: - Spacing, radius, borders

extension CGFloat {
    // MARK: Spacing scale (space-1 … space-7)
    public static let space1: CGFloat = 4
    public static let space2: CGFloat = 8
    public static let space3: CGFloat = 12
    public static let space4: CGFloat = 16
    public static let space5: CGFloat = 20
    public static let space6: CGFloat = 28
    public static let space7: CGFloat = 40

    // Legacy names
    public static let spacingXS: CGFloat = 4
    public static let spacingS: CGFloat = 8
    public static let spacingM: CGFloat = 16
    public static let spacingL: CGFloat = 20
    public static let spacingXL: CGFloat = 28
    public static let spacingXXL: CGFloat = 40

    // MARK: Radius (radius-sm / md / lg / pill)
    public static let radiusSm: CGFloat = 8
    public static let radiusMd: CGFloat = 12
    public static let radiusLg: CGFloat = 18
    public static let radiusPill: CGFloat = 999

    public static let cornerRadiusS: CGFloat = 8
    public static let cornerRadiusM: CGFloat = 12
    public static let cornerRadiusL: CGFloat = 18

    public static let borderWidth: CGFloat = 1
    public static let borderWidthThick: CGFloat = 2

    public static let iconSizeS: CGFloat = 16
    public static let iconSizeM: CGFloat = 20
    public static let iconSizeL: CGFloat = 24
    public static let iconSizeXL: CGFloat = 32

    // MARK: Layout
    public static let sidebarWidth: CGFloat = 200
    public static let toolbarHeight: CGFloat = 44
    public static let timelineBarHeight: CGFloat = 80
    public static let thumbnailSize: CGFloat = 120

    // MARK: Utility
    /// Clamp value to a closed range
    public func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Shadow Styles (shadow-sm / md / lg: soft, diffuse, never hard-offset)

public enum RetraceElevation: Sendable {
    case sm, md, lg
}

private struct RetraceElevationModifier: ViewModifier {
    let elevation: RetraceElevation

    private static let tint: UInt32 = 0x3B352D

    /// Two stacked shadow layers for every elevation so the view tree keeps the same structure when a call site
    /// flips elevation on state changes (the unused layer is fully transparent).
    private var layers: (a: (l: Double, d: Double, r: CGFloat, y: CGFloat), b: (l: Double, d: Double, r: CGFloat, y: CGFloat)) {
        switch elevation {
        case .sm: return ((0.06, 0.30, 1, 1), (0, 0, 0, 0))
        case .md: return ((0.05, 0.30, 1, 1), (0.07, 0.32, 9, 6))
        case .lg: return ((0.05, 0.30, 2, 2), (0.12, 0.45, 20, 16))
        }
    }

    func body(content: Content) -> some View {
        let layers = layers
        return content
            .shadow(color: shade(light: layers.a.l, dark: layers.a.d), radius: layers.a.r, x: 0, y: layers.a.y)
            .shadow(color: shade(light: layers.b.l, dark: layers.b.d), radius: layers.b.r, x: 0, y: layers.b.y)
    }

    private func shade(light: Double, dark: Double) -> Color {
        Color.retraceDynamic(light: Self.tint, dark: 0x000000, lightAlpha: light, darkAlpha: dark)
    }
}

extension View {
    public func retraceElevation(_ elevation: RetraceElevation) -> some View {
        self.modifier(RetraceElevationModifier(elevation: elevation))
    }

    public func retraceShadowLight() -> some View { retraceElevation(.sm) }
    public func retraceShadowMedium() -> some View { retraceElevation(.md) }
    public func retraceShadowHeavy() -> some View { retraceElevation(.lg) }

    /// The design system has no glows; kept as a no-op so existing call sites compile.
    public func retraceGlow(color: Color = .retraceAccent, radius: CGFloat = 20) -> some View {
        self
    }

    /// 2px accent focus ring with 2px offset, shown when the control has keyboard focus.
    public func retraceFocusRing(cornerRadius: CGFloat = .radiusMd) -> some View {
        self.modifier(RetraceFocusRingModifier(cornerRadius: cornerRadius))
    }
}

private struct RetraceFocusRingModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                .stroke(Color.retraceAccent, lineWidth: 2)
                .padding(-4)
                .opacity(isFocused ? 1 : 0)
                .allowsHitTesting(false)
        )
    }
}

// MARK: - Matte surface (replaces glassmorphism: flat surface, hairline, soft shadow)

public struct GlassmorphismModifier: ViewModifier {
    var cornerRadius: CGFloat
    var opacity: Double

    public init(cornerRadius: CGFloat = .radiusLg, opacity: Double = 0.1) {
        self.cornerRadius = cornerRadius
        self.opacity = opacity
    }

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.retraceSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.retraceBorder, lineWidth: 1)
            )
            .retraceElevation(.sm)
    }
}

extension View {
    /// Formerly glassmorphism; now the design system's flat `surface` with a hairline.
    public func glassmorphism(cornerRadius: CGFloat = .radiusLg, opacity: Double = 0.1) -> some View {
        self.modifier(GlassmorphismModifier(cornerRadius: cornerRadius, opacity: opacity))
    }
}

// MARK: - Gradients
//
// The design system uses flat color only. These statics are kept (as two-stop gradients of one color) so
// existing call sites compile; replace them with a solid token when touching a call site.

extension LinearGradient {
    private static func flat(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color], startPoint: .top, endPoint: .bottom)
    }

    public static var retraceAccentGradient: LinearGradient { flat(.retraceAccent) }
    public static let retraceBrandGradient = flat(.retraceAccent)
    public static let retracePurpleGradient = flat(.retraceAccent)
    public static let retraceGreenGradient = flat(.retraceGood)
    public static let retraceOrangeGradient = flat(.retraceWarningText)
    public static let retraceSubtleGradient = flat(.retraceSurfaceHover)
}

// MARK: - Button Styles

public enum RetraceButtonKind: Sendable {
    case primary, secondary, ghost, danger
}

public enum RetraceButtonSize: Sendable {
    case md, sm
}

/// Design-system button: `primary` (once per view), `secondary`, `ghost`, plus `danger` for destructive actions.
public struct RetraceButtonStyle: ButtonStyle {
    let kind: RetraceButtonKind
    let size: RetraceButtonSize

    public init(_ kind: RetraceButtonKind = .secondary, size: RetraceButtonSize = .md) {
        self.kind = kind
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        RetraceButtonBody(configuration: configuration, kind: kind, size: size)
    }
}

private struct RetraceButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: RetraceButtonKind
    let size: RetraceButtonSize

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private var radius: CGFloat { size == .sm ? .radiusSm : .radiusMd }

    var body: some View {
        configuration.label
            .font(size == .sm ? .retraceCaption : .retraceCallout)
            .foregroundColor(foreground)
            .padding(.horizontal, size == .sm ? 12 : 16)
            .padding(.vertical, size == .sm ? 5 : 8)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(border, lineWidth: 1)
            )
            .shadow(color: showsShadow ? Color.retraceDynamic(light: 0x3B352D, dark: 0x000000, lightAlpha: 0.06, darkAlpha: 0.3) : .clear,
                    radius: 1, x: 0, y: 1)
            .retraceFocusRing(cornerRadius: radius)
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.18), value: isHovering)
    }

    private var showsShadow: Bool { isEnabled && isHovering && kind != .ghost && kind != .primary }

    private var foreground: Color {
        switch kind {
        case .primary: return .retraceOnAccent
        case .secondary: return .retraceInk
        case .ghost: return .retraceAccent
        case .danger: return .retraceCritical
        }
    }

    private var background: Color {
        let hovering = isEnabled && isHovering
        switch kind {
        case .primary: return hovering ? .retraceAccentHover : .retraceAccent
        case .secondary: return hovering ? .retraceSurfaceHover : .retraceSurface
        case .ghost: return hovering ? .retraceSurfaceHover : .clear
        case .danger: return hovering ? Color.retraceCriticalBg.opacity(0.7) : .retraceCriticalBg
        }
    }

    private var border: Color {
        let hovering = isEnabled && isHovering
        switch kind {
        case .primary: return hovering ? .retraceAccentHover : .retraceAccent
        case .secondary: return .retraceBorderStrong
        case .ghost: return .clear
        case .danger: return Color.retraceCritical
        }
    }
}

public struct RetracePrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        RetraceButtonStyle(.primary).makeBody(configuration: configuration)
    }
}

public struct RetraceSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        RetraceButtonStyle(.secondary).makeBody(configuration: configuration)
    }
}

public struct RetraceDangerButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        RetraceButtonStyle(.danger).makeBody(configuration: configuration)
    }
}

// MARK: - Card Style

public struct RetraceCardModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, .space4)
            .background(
                RoundedRectangle(cornerRadius: .radiusMd, style: .continuous).fill(Color.retraceSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: .radiusMd, style: .continuous).stroke(Color.retraceBorder, lineWidth: 1)
            )
            .retraceElevation(.sm)
    }
}

extension View {
    /// Card: `surface` with a `border` hairline, `radius-md` and `shadow-sm`. Cards sit on `page`, never in cards.
    public func retraceCard() -> some View {
        self.modifier(RetraceCardModifier())
    }
}

// MARK: - Hover Effect

public struct RetraceHoverModifier: ViewModifier {
    @State private var isHovered = false

    public func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.retraceHover : Color.clear)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    public func retraceHover() -> some View {
        self.modifier(RetraceHoverModifier())
    }
}

// MARK: - Timeline Scale Factor

/// Provides resolution-adaptive scaling for timeline UI elements
/// Baseline is 1080p (1920x1080) where scale = 1.0
/// Scales proportionally for larger/smaller screens
public struct TimelineScaleFactor {
    /// Reference height for scale factor 1.0 (1080p)
    private static let referenceHeight: CGFloat = 1080

    /// Minimum scale factor to prevent UI from becoming too small
    private static let minScale: CGFloat = 0.85

    /// Maximum scale factor to prevent UI from becoming too large
    private static let maxScale: CGFloat = 1.35

    /// Thread-safe cached scale factor to prevent size changes during window lifecycle
    private static var _cachedScaleFactor: CGFloat?
    private static let lock = NSLock()

    /// Calculate scale factor based on the screen where the timeline is displayed
    /// Returns cached value to prevent UI size changes during window lifecycle
    public static var current: CGFloat {
        lock.lock()
        defer { lock.unlock() }

        if let cached = _cachedScaleFactor {
            return cached
        }

        // Use the screen where the mouse is (where the timeline will open),
        // not NSScreen.main (which is always the primary display)
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return 1.0 }
        let screenHeight = screen.frame.height
        let rawScale = screenHeight / referenceHeight
        let scale = min(maxScale, max(minScale, rawScale))
        _cachedScaleFactor = scale
        return scale
    }

    /// Reset the cached scale factor (call when timeline window closes)
    public static func resetCache() {
        lock.lock()
        defer { lock.unlock() }
        _cachedScaleFactor = nil
    }

    /// Calculate scale factor for a specific screen
    public static func forScreen(_ screen: NSScreen?) -> CGFloat {
        guard let screen = screen else { return 1.0 }
        let screenHeight = screen.frame.height
        let rawScale = screenHeight / referenceHeight
        return min(maxScale, max(minScale, rawScale))
    }

    // MARK: - Timeline Tape Dimensions (scaled)

    /// Base tape height (42pt at 1080p)
    public static var tapeHeight: CGFloat { 42 * current }

    /// Block spacing between app segments
    public static var blockSpacing: CGFloat { 2 * current }

    /// App icon size within blocks
    public static var appIconSize: CGFloat { 30 * current }

    /// Minimum block width to show app icon
    public static var iconDisplayThreshold: CGFloat { 40 * current }

    /// Playhead width
    public static var playheadWidth: CGFloat { 6 * current }

    // MARK: - Control Positioning (scaled)

    /// Y offset for control buttons above tape.
    /// Raised by 10pt from baseline.
    public static var controlsYOffset: CGFloat { -65 * current }

    /// Y offset for floating search panel
    public static var searchPanelYOffset: CGFloat { -195 * current }

    /// Y offset for calendar picker
    public static var calendarPickerYOffset: CGFloat { -280 * current }

    /// X position for left controls
    public static var leftControlsX: CGFloat { 130 * current }

    /// X offset from right edge for right controls
    public static var rightControlsXOffset: CGFloat { 100 * current }

    // MARK: - Container Dimensions (scaled)

    /// Blur backdrop height
    public static var blurBackdropHeight: CGFloat { 350 * current }

    /// Bottom padding for tape
    public static var tapeBottomPadding: CGFloat { 40 * current }

    /// Offset when controls are hidden
    public static var hiddenControlsOffset: CGFloat { 150 * current }

    /// Close button Y offset when hidden
    public static var closeButtonHiddenYOffset: CGFloat { -100 * current }

    // MARK: - Button/Control Sizes (scaled)

    /// Control button size
    public static var controlButtonSize: CGFloat { 38 * current }

    /// Close button size (top-right X button)
    public static var closeButtonSize: CGFloat { 38 * current }

    /// Zoom slider width
    public static var zoomSliderWidth: CGFloat { 110 * current }

    /// Search button width
    public static var searchButtonWidth: CGFloat { 190 * current }

    // MARK: - Panel Dimensions (scaled)

    /// Floating date search panel width
    public static var searchPanelWidth: CGFloat { 420 * current }

    /// Calendar picker width
    public static var calendarPickerWidth: CGFloat { 280 * current }

    /// Calendar picker height
    public static var calendarPickerHeight: CGFloat { 340 * current }

    // MARK: - Font Sizes (scaled)

    /// Callout font size (16pt base)
    public static var fontCallout: CGFloat { 16 * current }

    /// Caption font size (14pt base)
    public static var fontCaption: CGFloat { 14 * current }

    /// Caption2 font size (12pt base)
    public static var fontCaption2: CGFloat { 12 * current }

    /// Tiny font size (11pt base)
    public static var fontTiny: CGFloat { 11 * current }

    /// Mono font size (15pt base)
    public static var fontMono: CGFloat { 15 * current }

    // MARK: - Padding/Spacing (scaled)

    /// Standard horizontal padding for buttons
    public static var buttonPaddingH: CGFloat { 12 * current }

    /// Standard vertical padding for buttons
    public static var buttonPaddingV: CGFloat { 8 * current }

    /// Larger horizontal padding
    public static var paddingH: CGFloat { 18 * current }

    /// Larger vertical padding
    public static var paddingV: CGFloat { 12 * current }

    /// Control spacing
    public static var controlSpacing: CGFloat { 14 * current }

    /// Icon spacing within buttons
    public static var iconSpacing: CGFloat { 8 * current }
}

// MARK: - Unified Menu & Popover Design System

/// Unified design system for all menus, popovers, and dialogs
/// Based on the right-click context menu design (optimal reference)
public struct RetraceMenuStyle {
    private init() {}

    // MARK: - Container Styling

    /// Background color for all menus, popovers, and dialogs
    public static let backgroundColor = Color.retraceSurface

    /// Corner radius for all containers
    public static let cornerRadius: CGFloat = 12

    /// Border color (hairline)
    public static let borderColor = Color.retraceBorder

    /// Border width
    public static let borderWidth: CGFloat = 1

    /// Shadow configuration
    public static let shadowColor = Color.retraceDynamic(light: 0x3B352D, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.5)
    public static let shadowRadius: CGFloat = 18
    public static let shadowY: CGFloat = 8

    // MARK: - Interactive Item Styling

    /// Hover background color for menu items
    public static let itemHoverColor = Color.retraceSurfaceHover

    /// Corner radius for menu items
    public static let itemCornerRadius: CGFloat = 8

    /// Horizontal padding for menu items
    public static let itemPaddingH: CGFloat = 12

    /// Vertical padding for menu items
    public static let itemPaddingV: CGFloat = 6

    /// Spacing between items
    public static let itemSpacing: CGFloat = 0

    // MARK: - Typography

    /// Font for menu item text
    public static var font: Font { RetraceFont.font(size: 13.5, weight: .regular) }

    /// Font size value (for non-SwiftUI contexts)
    public static let fontSize: CGFloat = 13.5

    /// Font for keyboard shortcut hints shown on the right side of menu rows
    /// Use default system design so symbol glyphs like "⌫" and "⌘" render cleanly.
    public static var shortcutFont: Font { RetraceFont.mono(size: 12.5) }

    /// Reserved width for the right-aligned shortcut column
    public static let shortcutColumnMinWidth: CGFloat = 38

    /// Font weight
    public static let fontWeight: Font.Weight = .regular

    /// Icon size
    public static let iconSize: CGFloat = 13

    /// Icon frame width (for alignment)
    public static let iconFrameWidth: CGFloat = 18

    /// Spacing between icon and text
    public static let iconTextSpacing: CGFloat = 10

    // MARK: - Colors

    /// Primary text color
    public static let textColor = Color.retraceInk

    /// Secondary text color (muted)
    public static let textColorMuted = Color.retraceInk2

    /// Destructive action color
    public static let destructiveColor = Color.retraceCritical

    /// Chevron color (for submenus)
    public static let chevronColor = Color.retraceMuted

    /// Chevron size
    public static let chevronSize: CGFloat = 10

    /// Action button color (used for all primary action buttons like Submit, Apply, Include)
    public static var actionBlue: Color {
        Color.retraceAccent
    }

    /// UI blue - desaturated, calmer blue for focus rings and subtle accents
    /// Same hue as brand blue but lower saturation for less visual noise
    public static let uiBlue = Color.retraceAccent

    /// Base accent color for filter control strokes (buttons and fields).
    /// Uses the lighter Retrace accent for consistent focus/hover/open outlines.
    public static var filterStrokeAccent: Color {
        Color.retraceAccent
    }

    /// Strong stroke color for hovered/focused/open filter controls.
    public static var filterStrokeStrong: Color {
        filterStrokeAccent
    }

    /// Medium stroke color for active/selected filter controls.
    public static var filterStrokeMedium: Color {
        filterStrokeAccent.opacity(0.6)
    }

    /// Subtle resting stroke color for filter controls.
    public static var filterStrokeSubtle: Color {
        Color.retraceBorderStrong
    }

    // MARK: - Search Field Styling (within menus)

    /// Search field background
    public static let searchFieldBackground = Color.retraceSurfaceSunken

    /// Search field corner radius
    public static let searchFieldCornerRadius: CGFloat = 8

    /// Search field padding
    public static let searchFieldPaddingH: CGFloat = 10
    public static let searchFieldPaddingV: CGFloat = 6

    // MARK: - Animation

    /// Standard animation duration for hover effects
    public static let hoverAnimationDuration: CGFloat = 0.1

    /// Animation for menu appearance
    public static let appearanceAnimation = Animation.easeOut(duration: 0.18)
}

// MARK: - Timeline Overlay Surface Families

/// Fullscreen timeline overlays must use one of two families:
/// glass black for transient HUD chrome, or matte dark gray for owned editors/dialogs.
public enum RetraceTimelineGlassVariant {
    case chip
    case banner
    case panel

    /// Flat `surface` (Dusk, since the timeline window is forced dark); no blur, no glass.
    var fillColor: Color { Color.retraceSurface }

    var materialOpacity: Double { 0 }

    var borderColor: Color { Color.retraceBorder }

    var shadowColor: Color {
        Color.retraceDynamic(light: 0x3B352D, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.45)
    }

    var shadowRadius: CGFloat {
        switch self {
        case .chip:
            return 8
        case .banner, .panel:
            return 16
        }
    }

    var shadowY: CGFloat {
        switch self {
        case .chip:
            return 3
        case .banner, .panel:
            return 8
        }
    }
}

public struct RetraceTimelineGlassSurface: ViewModifier {
    let variant: RetraceTimelineGlassVariant
    let cornerRadius: CGFloat
    let borderColorOverride: Color?

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(variant.fillColor)
                    .shadow(
                        color: variant.shadowColor,
                        radius: variant.shadowRadius,
                        y: variant.shadowY
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColorOverride ?? variant.borderColor, lineWidth: 1)
            )
    }
}

public struct RetraceMattePanelSurface: ViewModifier {
    let cornerRadius: CGFloat
    let addPadding: Bool

    public func body(content: Content) -> some View {
        content.retraceMenuContainer(addPadding: addPadding, cornerRadius: cornerRadius)
    }
}

// MARK: - Reusable Menu Components

/// Standardized menu button component
/// Used in context menus, popovers, and dialogs for consistent appearance
public struct RetraceMenuButton: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    var showChevron: Bool = false
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    public init(
        icon: String,
        title: String,
        shortcut: String? = nil,
        showChevron: Bool = false,
        isDestructive: Bool = false,
        isDisabled: Bool = false,
        onHoverChanged: ((Bool) -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.shortcut = shortcut
        self.showChevron = showChevron
        self.isDestructive = isDestructive
        self.isDisabled = isDisabled
        self.onHoverChanged = onHoverChanged
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: RetraceMenuStyle.iconTextSpacing) {
                RetraceSymbol(icon, size: RetraceMenuStyle.iconSize, weight: RetraceMenuStyle.fontWeight)
                    .foregroundColor(foregroundColor)
                    .frame(width: RetraceMenuStyle.iconFrameWidth)

                Text(title)
                    .font(RetraceMenuStyle.font)
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if let shortcut {
                    Text(shortcut)
                        .font(RetraceMenuStyle.shortcutFont)
                        .foregroundColor(shortcutColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: RetraceMenuStyle.shortcutColumnMinWidth, alignment: .trailing)
                        .layoutPriority(1)
                }

                if showChevron {
                    RetraceSymbol("chevron.right", size: RetraceMenuStyle.chevronSize, weight: .semibold)
                        .foregroundColor(RetraceMenuStyle.chevronColor)
                }
            }
            .padding(.horizontal, RetraceMenuStyle.itemPaddingH)
            .padding(.vertical, RetraceMenuStyle.itemPaddingV)
            .background(
                RoundedRectangle(cornerRadius: RetraceMenuStyle.itemCornerRadius)
                    .fill(isHovering && !isDisabled ? RetraceMenuStyle.itemHoverColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: RetraceMenuStyle.hoverAnimationDuration)) {
                isHovering = hovering
            }
            if hovering && !isDisabled { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
            onHoverChanged?(hovering)
        }
    }

    private var foregroundColor: Color {
        if isDisabled {
            return RetraceMenuStyle.textColorMuted.opacity(0.5)
        } else if isDestructive {
            return RetraceMenuStyle.destructiveColor
        } else {
            return isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted
        }
    }

    private var shortcutColor: Color {
        if isDisabled {
            return Color.retraceMuted.opacity(0.7)
        }
        return isHovering ? RetraceMenuStyle.textColor : RetraceMenuStyle.textColorMuted
    }
}

/// Shared UserDefaults store for accessing settings
private let menuContainerSettingsStore = UserDefaults(suiteName: "io.retrace.app") ?? .standard

/// Standardized menu container modifier
/// Applies consistent background, border, and shadow to any menu/popover content
/// Border color adapts based on user's color theme preference
public struct RetraceMenuContainer: ViewModifier {
    var addPadding: Bool = true
    var cornerRadius: CGFloat = RetraceMenuStyle.cornerRadius

    private var showColoredBorders: Bool {
        menuContainerSettingsStore.bool(forKey: "timelineColoredBorders")
    }

    private var borderColor: Color {
        guard showColoredBorders else {
            return Color.retraceBorder
        }
        let theme = MilestoneCelebrationManager.getCurrentTheme()
        return theme.controlBorderColor
    }

    public func body(content: Content) -> some View {
        Group {
            if addPadding {
                content.padding(.spacingS)
            } else {
                content
            }
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(RetraceMenuStyle.backgroundColor)
                .shadow(
                    color: RetraceMenuStyle.shadowColor,
                    radius: RetraceMenuStyle.shadowRadius,
                    y: RetraceMenuStyle.shadowY
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(borderColor, lineWidth: RetraceMenuStyle.borderWidth)
        )
    }
}

extension View {
    /// Apply standardized menu/popover container styling
    public func retraceMenuContainer(
        addPadding: Bool = true,
        cornerRadius: CGFloat = RetraceMenuStyle.cornerRadius
    ) -> some View {
        self.modifier(RetraceMenuContainer(addPadding: addPadding, cornerRadius: cornerRadius))
    }

    public func timelineGlassSurface(
        _ variant: RetraceTimelineGlassVariant,
        cornerRadius: CGFloat,
        borderColor: Color? = nil
    ) -> some View {
        self.modifier(
            RetraceTimelineGlassSurface(
                variant: variant,
                cornerRadius: cornerRadius,
                borderColorOverride: borderColor
            )
        )
    }

    public func retraceMattePanel(
        addPadding: Bool = true,
        cornerRadius: CGFloat = RetraceMenuStyle.cornerRadius
    ) -> some View {
        self.modifier(RetraceMattePanelSurface(cornerRadius: cornerRadius, addPadding: addPadding))
    }
}

/// Standardized search field for menus/popovers
public struct RetraceMenuSearchField: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

    public init(text: Binding<String>, placeholder: String = "Search...", onSubmit: (() -> Void)? = nil) {
        self._text = text
        self.placeholder = placeholder
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 8) {
            RetraceSymbol("magnifyingglass", size: 12, weight: .medium)
                .foregroundColor(.retraceMuted)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(RetraceMenuStyle.font)
                .foregroundColor(.retraceInk)
                .focused($isFocused)
                .onSubmit {
                    onSubmit?()
                }

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    RetraceSymbol("xmark.circle.fill", size: 12, weight: .medium)
                        .foregroundColor(.retraceMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, RetraceMenuStyle.searchFieldPaddingH)
        .padding(.vertical, RetraceMenuStyle.searchFieldPaddingV)
        .background(
            RoundedRectangle(cornerRadius: RetraceMenuStyle.searchFieldCornerRadius)
                .fill(RetraceMenuStyle.searchFieldBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
        }
    }
}

// MARK: - Color Extension for Hex Support
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Ping Dot View

/// A pulsating dot indicator for status display
/// Use for showing active/connected states (green) or warning/disconnected states (orange)
public struct PingDotView: View {
    let color: Color
    let size: CGFloat
    let isAnimating: Bool

    @State private var isPulsing = false

    public init(color: Color, size: CGFloat = 8, isAnimating: Bool = true) {
        self.color = color
        self.size = size
        self.isAnimating = isAnimating
    }

    public var body: some View {
        ZStack {
            if isAnimating {
                Circle()
                    .fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(isPulsing ? 2.0 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.6)
            }

            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .onAppear {
            if isAnimating {
                withAnimation(
                    Animation.easeOut(duration: 3.0)
                        .repeatForever(autoreverses: false)
                ) {
                    isPulsing = true
                }
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when the font style preference changes
    public static let fontStyleDidChange = Notification.Name("fontStyleDidChange")
    /// Posted when user-defined tag colors are updated
    public static let tagColorsDidChange = Notification.Name("tagColorsDidChange")
    /// Posted to request a force restart of the AI Visual Semantic Indexer
    public static let forceRestartSemanticIndexing = Notification.Name("forceRestartSemanticIndexing")
}

