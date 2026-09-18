import Foundation
import Argon2Swift

/// Derives a 32-byte ChaCha20 key from a user passphrase + the device SN
/// (salt) using Argon2id, and caches the derived key in the iOS Keychain
/// per-SN.
///
/// Keychain scope:
///   kSecAttrService  = "com.dnote.encryption-key"
///   kSecAttrAccount  = <device SN>
///   kSecAttrAccessible = WhenUnlockedThisDeviceOnly
///                       (survives reboot, blocked while device locked,
///                        never restored from iCloud backup, not synced)
///
/// First launch after install ⇒ key absent ⇒ caller prompts for passphrase
/// and stores it via `derive(_:sn:)` + `save(_:sn:)`. Subsequent launches
/// read silently with `load(sn:)`. Lose the passphrase → lose the clips;
/// there is no recovery service-side. Same passphrase + same SN on a new
/// iPhone re-derives the same 32-byte key.
enum PassphraseStore {
    static let service = "com.dnote.encryption-key"

    // Tuning these or changing the salt invalidates every cached key.
    static let argon2Iterations: Int = 4
    static let argon2MemoryKiB: Int = 512 * 1024
    static let argon2Parallelism: Int = 1
    static let keyLength: Int = 32

    enum StoreError: LocalizedError {
        case emptyPassphrase
        case emptySN
        case argon2(String)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .emptyPassphrase: return "Passphrase is empty."
            case .emptySN:         return "Device serial is unknown."
            case .argon2(let m):   return "Argon2id failed: \(m)"
            case .keychain(let s): return "Keychain error \(s)."
            }
        }
    }

    // MARK: derivation

    static func derive(passphrase: String, sn: String) throws -> Data {
        guard !passphrase.isEmpty else { throw StoreError.emptyPassphrase }
        guard !sn.isEmpty          else { throw StoreError.emptySN }

        let salt = Salt(bytes: Data(sn.utf8))
        do {
            let result = try Argon2Swift.hashPasswordString(
                password: passphrase,
                salt: salt,
                iterations: argon2Iterations,
                memory: argon2MemoryKiB,
                parallelism: argon2Parallelism,
                length: keyLength,
                type: .id,
                version: .V13
            )
            return result.hashData()
        } catch {
            throw StoreError.argon2(error.localizedDescription)
        }
    }

    // MARK: Keychain CRUD

    /// Returns the cached 32-byte key for this SN, or nil if not yet set.
    static func load(sn: String) -> Data? {
        var query: [String: Any] = baseQuery(sn: sn)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        guard data.count == keyLength else { return nil }
        return data
    }

    /// Inserts or updates the 32-byte key for this SN, locked to the
    /// "device unlocked" state and never written to iCloud.
    static func save(_ key: Data, sn: String) throws {
        precondition(key.count == keyLength, "key must be \(keyLength) bytes")
        let query = baseQuery(sn: sn)
        let update: [String: Any] = [kSecValueData as String: key]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = key
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            insert[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        if status != errSecSuccess { throw StoreError.keychain(status) }
    }

    /// Removes the cached key for this SN. Returns true if a key existed.
    @discardableResult
    static func clear(sn: String) -> Bool {
        let status = SecItemDelete(baseQuery(sn: sn) as CFDictionary)
        return status == errSecSuccess
    }

    private static func baseQuery(sn: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sn,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
