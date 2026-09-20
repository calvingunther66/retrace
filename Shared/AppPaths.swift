import Foundation

/// Centralized app paths and identifiers
/// Single source of truth for all path constants used across the app
public enum AppPaths {

    // MARK: - Base Paths

    /// Default root storage path for all app data (tilde expanded)
    public static let defaultStorageRoot = NSString(string: "~/Library/Application Support/Retrace").expandingTildeInPath

    /// Default Rewind/MemoryVault storage root path (tilde expanded)
    public static let defaultRewindStorageRoot = NSString(string: "~/Library/Application Support/com.memoryvault.MemoryVault").expandingTildeInPath

    /// Default Rewind database path
    public static let defaultRewindDBPath = "\(defaultRewindStorageRoot)/db-enc.sqlite3"

    /// Root storage path for all app data (respects custom location if set)
    public static var storageRoot: String {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        return defaults.string(forKey: "customRetraceDBLocation") ?? defaultStorageRoot
    }

    /// Expanded storage root path (tilde resolved)
    public static var expandedStorageRoot: String {
        NSString(string: storageRoot).expandingTildeInPath
    }

    // MARK: - Database

    /// Database file path (respects custom location if set)
    public static var databasePath: String {
        "\(storageRoot)/retrace.db"
    }

    /// Rewind/MemoryVault storage root (respects custom location if set)
    /// `customRewindDBLocation` stores a folder path. Legacy file-path values are normalized.
    public static var rewindStorageRoot: String {
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        if let customLocation = defaults.string(forKey: "customRewindDBLocation") {
            let normalized = NSString(string: customLocation).expandingTildeInPath
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: normalized, isDirectory: &isDirectory), !isDirectory.boolValue {
                // Backward compatibility for older file-based setting values.
                return (normalized as NSString).deletingLastPathComponent
            }

            let lastComponent = (normalized as NSString).lastPathComponent.lowercased()
            if lastComponent.hasSuffix(".sqlite3") || lastComponent.hasSuffix(".db") {
                // Handle legacy values that point to a DB file that is no longer present.
                return (normalized as NSString).deletingLastPathComponent
            }
            return normalized
        }
        return defaultRewindStorageRoot
    }

    /// Expanded Rewind storage root path (tilde resolved)
    public static var expandedRewindStorageRoot: String {
        NSString(string: rewindStorageRoot).expandingTildeInPath
    }

    /// Rewind database path (db-enc.sqlite3 under rewindStorageRoot)
    public static var rewindDBPath: String {
        return "\(rewindStorageRoot)/db-enc.sqlite3"
    }

    /// Rewind chunks path (respects custom location if set)
    public static var rewindChunksPath: String {
        "\(rewindStorageRoot)/chunks"
    }

    /// Rewind rewind.db path (unencrypted database used for ID offset)
    public static var rewindUnencryptedDBPath: String {
        "\(rewindStorageRoot)/rewind.db"
    }

    // MARK: - Storage Directories

    /// Video segments storage path
    public static let segmentsPath = "\(storageRoot)/segments"

    /// Temp files path
    public static let tempPath = "\(storageRoot)/temp"

    /// Models directory path
    public static let modelsPath = "\(storageRoot)/models"

    // MARK: - Keychain

    /// Keychain service identifier for database encryption
    public static let keychainService = "com.retrace.database"

    /// Keychain account for SQLCipher key
    public static let keychainAccount = "sqlcipher-key"

    // MARK: - Logging

    /// Log subsystem identifier
    public static let logSubsystem = "io.retrace.app"

    // MARK: - Bundled Helpers

    /// Resolves the bundled `RetraceAppleScriptHelper`, used in place of the bare
    /// `/usr/bin/osascript` binary to run AppleScript. `/usr/bin/osascript` has no
    /// Info.plist, so when it sends an Apple Event, LaunchServices/RunningBoard has
    /// no way to know it should be treated as non-interactive, and a transient Dock
    /// icon appears for it. The bundled helper declares itself non-interactive via
    /// `NSApplication.setActivationPolicy(.prohibited)` before doing anything else
    /// (see `Capture/AppleScriptHelper/main.swift`), which avoids that Dock tile.
    /// Returns `nil` so callers can fall back to plain osascript when the app
    /// bundle is missing the helper (older/incomplete bundles, some dev builds).
    public static func appleScriptHelperExecutableURL() -> URL? {
        let bundledURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/Helpers/RetraceAppleScriptHelper")
        if FileManager.default.isExecutableFile(atPath: bundledURL.path) {
            return bundledURL
        }

        #if DEBUG
        let devCandidate = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("RetraceAppleScriptHelper")
        if FileManager.default.isExecutableFile(atPath: devCandidate.path) {
            return devCandidate
        }
        #endif

        return nil
    }
}
