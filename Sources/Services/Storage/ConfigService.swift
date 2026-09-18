import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "config")

/// Owns the on-disk `config.json`. Published so SwiftUI bindings can mutate
/// and persist through one surface. Save is synchronous (tiny JSON blob) but
/// gated behind a debounce to avoid thrashing while a slider is dragged.
@MainActor
final class ConfigService: ObservableObject {
    @Published var config: AppConfig

    private var debounce: Task<Void, Never>?

    init() {
        var loaded = Self.loadFromDisk() ?? .empty
        // A config written by an older build still has the plaintext keys in
        // it. Take those as the source of truth once, push them into the
        // Keychain, then rewrite the file without them.
        let hadPlaintext = Self.migratePlaintextSecrets(from: loaded)
        Self.injectSecrets(into: &loaded)
        self.config = loaded
        if hadPlaintext { saveNow() }
    }

    // MARK: persistence

    /// Persist after a short coalesce window so dragging a slider writes once.
    func scheduleSave() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try Self.writeToDisk(config)
        } catch {
            log.error("Config save failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func loadFromDisk() -> AppConfig? {
        let url = StorageLocations.configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            // Secrets are re-attached by the caller from the Keychain.
            var config = try decoder.decode(AppConfig.self, from: data)
            // A local record without a host is junk: it cannot connect to any service, yet it causes the port field to show a number no one entered.
            // In older versions, typing a number into an empty port field would store `{host: "", port: 1}`.
            if let local = config.asrProviders.local, local.host.isEmpty {
                config.asrProviders.local = nil
            }
            return config
        } catch {
            log.error("Config load failed: \(String(describing: error), privacy: .public) — falling back to defaults")
            return nil
        }
    }

    // MARK: secrets

    /// API keys and the hotspot PSK live in the Keychain, not in
    /// `config.json`. These two helpers are the whole boundary: everything
    /// above them sees a normal `AppConfig` with the values present.

    private static func extractSecrets(_ config: AppConfig) -> AppConfig {
        var stripped = config
        SecretStore.save(config.asrProviders.azure?.key, to: .azureASRKey)
        SecretStore.save(config.llmProviders.openai?.apiKey, to: .llmOpenAI)
        SecretStore.save(config.llmProviders.claude?.apiKey, to: .llmClaude)
        SecretStore.save(config.llmProviders.gemini?.apiKey, to: .llmGemini)
        SecretStore.save(config.llmProviders.openRouter?.apiKey, to: .llmOpenRouter)
        SecretStore.save(config.llmProviders.ollama?.apiKey, to: .llmOllama)
        SecretStore.save(config.llmProviders.custom?.apiKey, to: .llmCustom)
        SecretStore.save(config.wifiAP?.psk, to: .wifiAPPassword)

        stripped.asrProviders.azure?.key = ""
        stripped.llmProviders.openai?.apiKey = ""
        stripped.llmProviders.claude?.apiKey = ""
        stripped.llmProviders.gemini?.apiKey = ""
        stripped.llmProviders.openRouter?.apiKey = nil
        stripped.llmProviders.ollama?.apiKey = nil
        stripped.llmProviders.custom?.apiKey = nil
        stripped.wifiAP?.psk = ""
        return stripped
    }

    private static func injectSecrets(into config: inout AppConfig) {
        if config.asrProviders.azure != nil {
            config.asrProviders.azure?.key = SecretStore.load(.azureASRKey) ?? ""
        }
        if config.llmProviders.openai != nil {
            config.llmProviders.openai?.apiKey = SecretStore.load(.llmOpenAI) ?? ""
        }
        if config.llmProviders.claude != nil {
            config.llmProviders.claude?.apiKey = SecretStore.load(.llmClaude) ?? ""
        }
        if config.llmProviders.gemini != nil {
            config.llmProviders.gemini?.apiKey = SecretStore.load(.llmGemini) ?? ""
        }
        if config.llmProviders.openRouter != nil {
            config.llmProviders.openRouter?.apiKey = SecretStore.load(.llmOpenRouter)
        }
        if config.llmProviders.ollama != nil {
            config.llmProviders.ollama?.apiKey = SecretStore.load(.llmOllama)
        }
        if config.llmProviders.custom != nil {
            config.llmProviders.custom?.apiKey = SecretStore.load(.llmCustom)
        }
        if config.wifiAP != nil {
            config.wifiAP?.psk = SecretStore.load(.wifiAPPassword) ?? ""
        }
    }

    /// Returns true when the file on disk still carried plaintext secrets,
    /// so the caller knows to rewrite it.
    private static func migratePlaintextSecrets(from config: AppConfig) -> Bool {
        let plaintext = [
            config.asrProviders.azure?.key,
            config.llmProviders.openai?.apiKey,
            config.llmProviders.claude?.apiKey,
            config.llmProviders.gemini?.apiKey,
            config.llmProviders.openRouter?.apiKey,
            config.llmProviders.ollama?.apiKey,
            config.llmProviders.custom?.apiKey,
            config.wifiAP?.psk,
        ].compactMap { $0 }.filter { !$0.isEmpty }
        guard !plaintext.isEmpty else { return false }
        log.info("migrating \(plaintext.count, privacy: .public) plaintext secret(s) out of config.json")
        _ = extractSecrets(config)
        return true
    }

    private static func writeToDisk(_ config: AppConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(extractSecrets(config))
        let url = StorageLocations.configURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: per-device metadata

    /// Upsert the per-device record keyed by the CBPeripheral identifier (so
    /// it survives firmware BT-name changes). Stamps `last_connected` on
    /// every successful connect.
    ///
    /// Pass `deviceSID` (uppercase hex from the manufacturer-data advertisement)
    /// from the scanner so future reconnects can match the same physical device
    /// even after the iOS peripheral UUID changes. Nil leaves any previously
    /// stored SID intact.
    func rememberDevice(id: String, name: String, deviceSID: String? = nil) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record = config.devices[id] ?? .init(name: name, lastConnected: nil)
        record.name = name
        record.lastConnected = iso.string(from: Date())
        if let sid = deviceSID { record.deviceSID = sid }
        config.devices[id] = record
        scheduleSave()
    }

    /// Persist (or clear) the bond_id for a known device. Creates a stub
    /// record when the peripheral hasn't been remembered yet — can happen
    /// when pairing completes before `rememberDevice` is called during
    /// the initial connect.
    func setBondID(for id: String, name: String, bondID: String?) {
        var record = config.devices[id] ?? .init(name: name)
        record.bondID = bondID
        config.devices[id] = record
        scheduleSave()
    }
}
