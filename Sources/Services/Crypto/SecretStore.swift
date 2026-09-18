import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "secret-store")

/// Keychain storage for the app's *other* secrets — provider API keys and
/// the Wi-Fi hotspot passphrase.
///
/// The recording decryption key already lived in the Keychain
/// (`PassphraseStore`), but API keys and the hotspot PSK were plain JSON
/// fields inside `config.json`. Anything that could read the app container
/// (a file-sharing export, a backup, a support bundle) got the credentials
/// with it.
///
/// `ConfigService` swaps these values out at the persistence boundary, so
/// the in-memory `AppConfig` still carries them and every SwiftUI binding
/// keeps working unchanged — only what lands on disk differs.
///
/// Accessibility matches `PassphraseStore`: available after first unlock on
/// this device only, never synced to iCloud.
enum SecretStore {
    static let service = "com.dnote.app-secrets"

    /// Stable ids for each secret slot. Adding a provider means adding an
    /// id here and a line in `ConfigService`'s split/merge tables.
    enum Slot: String {
        case azureASRKey     = "asr.azure.key"
        case llmOpenAI       = "llm.openai.api_key"
        case llmClaude       = "llm.claude.api_key"
        case llmGemini       = "llm.gemini.api_key"
        case llmOpenRouter   = "llm.open_router.api_key"
        case llmOllama       = "llm.ollama.api_key"
        case llmCustom       = "llm.custom.api_key"
        case wifiAPPassword  = "wifi_ap.psk"
    }

    static func load(_ slot: Slot) -> String? {
        var query = baseQuery(slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Writes the value, or removes the slot when the value is nil/empty so
    /// a cleared field doesn't leave a stale credential behind.
    static func save(_ value: String?, to slot: Slot) {
        guard let value, !value.isEmpty else {
            delete(slot)
            return
        }
        let query = baseQuery(slot)
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = Data(value.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        if status != errSecSuccess {
            log.error("keychain write \(slot.rawValue, privacy: .public) failed: \(status, privacy: .public)")
        }
    }

    @discardableResult
    static func delete(_ slot: Slot) -> Bool {
        SecItemDelete(baseQuery(slot) as CFDictionary) == errSecSuccess
    }

    private static func baseQuery(_ slot: Slot) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: slot.rawValue,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
