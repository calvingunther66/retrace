import AppKit
import CoreText
import Shared

/// Registers the bundled Source Serif 4 and IBM Plex Mono faces once per process.
///
/// Dev builds run the bare SwiftPM binary, release builds run from an `.app` bundle produced by Xcode or
/// `build_and_sign.sh`, so the font files can live in several places. `register()` walks every known location
/// and registers whatever it finds; `RetraceFont` falls back to the system serif/monospaced faces if nothing
/// registers. Call `ensureRegistered()` at launch so the file I/O never happens inside a SwiftUI `body`.
public enum RetraceFontRegistry {
    static let fontFileNames = [
        "SourceSerif4-Regular.ttf",
        "SourceSerif4-Semibold.ttf",
        "SourceSerif4-Bold.ttf",
        "SourceSerif4-It.ttf",
        "IBMPlexMono-Regular.ttf",
        "IBMPlexMono-Medium.ttf",
    ]

    /// PostScript names of the registered faces.
    enum Face {
        static let serifRegular = "SourceSerif4-Regular"
        static let serifSemibold = "SourceSerif4-Semibold"
        static let serifBold = "SourceSerif4-Bold"
        static let serifItalic = "SourceSerif4-It"
        static let monoRegular = "IBMPlexMono"
        static let monoMedium = "IBMPlexMono-Medm"
    }

    /// True when the serif and mono faces are installed for this process.
    public static let isAvailable: Bool = register()

    /// Forces registration now. Idempotent and cheap after the first call.
    public static func ensureRegistered() {
        _ = isAvailable
    }

    private static func register() -> Bool {
        let fileManager = FileManager.default
        var urlsByName: [String: URL] = [:]

        for directory in candidateDirectories() {
            for name in fontFileNames where urlsByName[name] == nil {
                let url = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: url.path) {
                    urlsByName[name] = url
                }
            }
        }

        var registeredAny = false
        for (_, url) in urlsByName {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registeredAny = true
            } else if let error = error?.takeRetainedValue() {
                // Already registered (e.g. relaunch via hot reload) is not a failure.
                let code = CFErrorGetCode(error)
                if code == CTFontManagerError.alreadyRegistered.rawValue {
                    registeredAny = true
                } else {
                    Log.warning("[FONTS] Failed to register \(url.lastPathComponent): \(error)", category: .ui)
                }
            }
        }

        let ok = NSFont(name: Face.serifRegular, size: 13) != nil && NSFont(name: Face.monoRegular, size: 13) != nil
        if !ok {
            Log.warning(
                "[FONTS] Bundled fonts unavailable (registeredAny=\(registeredAny)); using system serif/monospaced fallback",
                category: .ui
            )
        }
        return ok
    }

    private static func candidateDirectories() -> [URL] {
        var directories: [URL] = []
        let main = Bundle.main

        if let resources = main.resourceURL {
            directories.append(resources.appendingPathComponent("Fonts", isDirectory: true))
            directories.append(resources)
            // SwiftPM resource bundle copied into an .app's Resources.
            directories.append(
                resources.appendingPathComponent("Retrace_Retrace.bundle/Fonts", isDirectory: true)
            )
        }

        // Bare SwiftPM executable: `Retrace_Retrace.bundle` sits next to the binary.
        directories.append(
            main.bundleURL.appendingPathComponent("Retrace_Retrace.bundle/Fonts", isDirectory: true)
        )
        directories.append(
            main.bundleURL.appendingPathComponent("Retrace_Retrace.bundle/Contents/Resources/Fonts", isDirectory: true)
        )
        if let executable = main.executableURL {
            directories.append(
                executable.deletingLastPathComponent()
                    .appendingPathComponent("Retrace_Retrace.bundle/Fonts", isDirectory: true)
            )
        }

        // Working-tree fallback for `swift run` / hot reload from the repo root.
        directories.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("UI/Fonts", isDirectory: true)
        )
        return directories
    }
}

// MARK: - AppKit font helpers

extension NSFont {
    /// Serif face for AppKit text (matches `RetraceFont.font(size:weight:)`); falls back to the system font.
    public static func retraceFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if RetraceFont.currentStyle == .default, RetraceFontRegistry.isAvailable {
            let name: String
            if weight.rawValue >= NSFont.Weight.bold.rawValue {
                name = RetraceFontRegistry.Face.serifBold
            } else if weight.rawValue >= NSFont.Weight.semibold.rawValue {
                name = RetraceFontRegistry.Face.serifSemibold
            } else {
                name = RetraceFontRegistry.Face.serifRegular
            }
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Mono face for AppKit text (matches `RetraceFont.mono(size:weight:)`); falls back to the system mono font.
    public static func retraceMono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if RetraceFontRegistry.isAvailable {
            let name = weight.rawValue >= NSFont.Weight.medium.rawValue
                ? RetraceFontRegistry.Face.monoMedium
                : RetraceFontRegistry.Face.monoRegular
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }
}
