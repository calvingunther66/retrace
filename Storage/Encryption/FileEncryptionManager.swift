import CryptoKit
import Foundation
import Shared

/// AES-256-GCM file and buffer encryption manager
/// Integrates with Keychain-backed MasterKeyManager
/// Owner: STORAGE agent
public final class FileEncryptionManager: Sendable {
    public static let shared = FileEncryptionManager()

    /// Magic bytes header for Retrace encrypted container files
    public static let headerMagic = Data([0x52, 0x54, 0x45, 0x4E, 0x43, 0x30, 0x31, 0x00]) // "RTENC01\0"

    public init() {}

    /// Check if at-rest encryption is currently enabled
    public var isEncryptionEnabled: Bool {
        let defaults = UserDefaults(suiteName: MasterKeyManager.settingsSuiteName) ?? .standard
        return defaults.bool(forKey: "encryptionEnabled")
    }

    /// Retrieve symmetric key from MasterKeyManager
    private func getSymmetricKey() -> SymmetricKey? {
        guard let keyData = try? MasterKeyManager.loadMasterKey() else {
            return nil
        }
        return SymmetricKey(data: keyData)
    }

    /// Encrypt an in-memory data buffer with AES-256-GCM
    public func encrypt(data: Data) throws -> Data {
        guard let key = getSymmetricKey() else {
            throw StorageError.encryptionFailed(underlying: "Master encryption key not found in Keychain")
        }

        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw StorageError.encryptionFailed(underlying: "Failed to combine AES.GCM sealed box")
        }

        var output = Data()
        output.append(Self.headerMagic)
        output.append(combined)
        return output
    }

    /// Decrypt an in-memory data buffer with AES-256-GCM
    public func decrypt(data: Data) throws -> Data {
        guard isEncrypted(data: data) else {
            // If plaintext, return as-is
            return data
        }

        guard let key = getSymmetricKey() else {
            throw StorageError.decryptionFailed(underlying: "Master encryption key not found in Keychain")
        }

        let payload = data.dropFirst(Self.headerMagic.count)
        let sealedBox = try AES.GCM.SealedBox(combined: payload)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Check if data buffer has Retrace encryption header
    public func isEncrypted(data: Data) -> Bool {
        guard data.count >= Self.headerMagic.count else { return false }
        return data.prefix(Self.headerMagic.count) == Self.headerMagic
    }

    /// Encrypt a file on disk atomically
    public func encryptFile(at sourceURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let encryptedData = try encrypt(data: data)
        try encryptedData.write(to: destinationURL, options: .atomic)
    }

    /// Decrypt a file on disk to a destination
    public func decryptFile(at sourceURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        let decryptedData = try decrypt(data: data)
        try decryptedData.write(to: destinationURL, options: .atomic)
    }
}
