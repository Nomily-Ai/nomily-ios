import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "config")

/// Owns the on-disk `config.json`. Published so SwiftUI bindings can mutate
/// and persist through one surface. Save is synchronous (tiny JSON blob) but
/// gated behind a debounce to avoid thrashing while a slider is dragged.
@MainActor
final class ConfigService: ObservableObject {
    @Published var config: AppConfig {
        didSet { syncBackgroundKeeper() }
    }

    private var debounce: Task<Void, Never>?

    /// Mirrors the "background keep-alive" switch to `BackgroundKeeper`.
    ///
    /// Hung off `didSet` rather than "after a successful disk write": this switch must take effect **immediately** —
    /// when the user turns it off, even if a transcription is running right then, that silent audio should stop at once
    /// (that's exactly what turning it off means). The disk-write side has a 250 ms debounce, too long to wait for.
    ///
    /// Note: `didSet` **doesn't** fire for the assignment in `init`, so on a cold launch
    /// `TranscriptionService.init` syncs it once more; otherwise an "it was already off last time"
    /// state would only take effect after the user touches a setting once.
    private func syncBackgroundKeeper() {
        BackgroundKeeper.shared.audioKeepAliveEnabled = config.backgroundKeepAliveEnabled
    }

    init() {
        var loaded = Self.loadFromDisk() ?? .empty
        // A config written by an older build still has the plaintext keys in
        // it. Take those as the source of truth once, push them into the
        // Keychain, then rewrite the file without them.
        let hadPlaintext = Self.migratePlaintextSecrets(from: loaded)
        Self.injectSecrets(into: &loaded)
        // ★ (2026-10-19) The on-device switch is now opt-in; if the saved primary still names it,
        //   point the picker at something that can actually run. This has to happen **after**
        //   `injectSecrets`, otherwise Azure looks unconfigured (its key lives in the Keychain)
        //   and the choice collapses to whatever else was lying around.
        let repointedPrimary = Self.repointPrimaryOffOnDevice(&loaded)
        self.config = loaded
        if hadPlaintext || repointedPrimary { saveNow() }
        // Mirror the persisted palette so `Color.appAccent` is correct from the first frame,
        // not from the first time someone opens the theme picker.
        AppThemeRuntime.tag = loaded.appTheme
    }

    /// The one way to change the palette.
    ///
    /// Bundling "write config → mirror into `AppThemeRuntime` → save immediately" prevents the
    /// bug this split would otherwise produce: a UI that shows the new colour while
    /// `config.json` still holds the old one, so the theme reverts on the next launch.
    func applyTheme(_ tag: String?) {
        config.appTheme = tag
        AppThemeRuntime.tag = tag
        saveNow()
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

    /// Point `defaults.asr.primary` away from `ondevice` while the feature is switched off.
    ///
    /// - Returns: `true` when it actually changed something (the caller then persists).
    ///
    /// Called only after the Keychain secrets are back, so "is Azure configured?" is a real
    /// question here — the same order the settings page uses.
    private static func repointPrimaryOffOnDevice(_ config: inout AppConfig) -> Bool {
        guard !config.onDeviceASREnabled,
              config.defaults.asr.primary.lowercased() == "ondevice"
        else { return false }
        let azureUsable = config.asrProviders.azure.map { !$0.key.isEmpty && !$0.region.isEmpty } ?? false
        let localUsable = config.asrProviders.local.map { !$0.host.isEmpty && $0.port > 0 } ?? false
        config.defaults.asr.primary = azureUsable ? "azure" : (localUsable ? "local" : "")
        // `Logger` interpolation is an escaping autoclosure — it cannot capture the `inout`.
        let chosen = config.defaults.asr.primary
        log.info("on-device ASR is off — primary moved off it to \(chosen, privacy: .public)")
        return true
    }

    private static func loadFromDisk() -> AppConfig? {
        let url = StorageLocations.configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            // ★ (2026-10-19) The "on-device speech off" migration runs inside
            //   `AppConfig.init(from:)`, which only changes the **in-memory** value. Without this
            //   check the file keeps saying `true` and the migration re-runs on every launch —
            //   harmless but invisible, and it would silently undo a deliberate re-enable if the
            //   flag ever came back missing. Detect "the file does not have the marker yet" and
            //   write the migrated config back once.
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let hadMigrationMarker = (raw?["on_device_asr_off_migrated"] as? Bool) ?? false
            // Secrets are re-attached by the caller from the Keychain.
            var config = try decoder.decode(AppConfig.self, from: data)
            // A local record without a host is junk: it cannot connect to any service, yet it causes the port field to show a number no one entered.
            // In older versions, typing a number into an empty port field would store `{host: "", port: 1}`.
            if let local = config.asrProviders.local, local.host.isEmpty {
                config.asrProviders.local = nil
            }
            if !hadMigrationMarker {
                // ⛔ Never `writeToDisk(config)` here: at load time secrets have **not** been
                //   re-attached yet, and `extractSecrets` would happily save `nil` over every
                //   Keychain item — one launch and the Azure key is gone. Rewriting the raw
                //   dictionary is the safe form: the file never held secrets in the first place.
                persistMigration(raw: raw, migrated: config, url: url)
            }
            return config
        } catch {
            log.error("Config load failed: \(String(describing: error), privacy: .public) — falling back to defaults")
            return nil
        }
    }

    /// Write the one-time "on-device speech off" migration back to disk, touching only the keys
    /// it owns. Everything else in the file (devices, endpoints, model choices) is preserved
    /// byte-for-byte, and no secret is read or written.
    private static func persistMigration(raw: [String: Any]?, migrated: AppConfig, url: URL) {
        guard var dict = raw else { return }
        dict["on_device_asr_off_migrated"] = true
        dict["on_device_asr_enabled"] = migrated.onDeviceASREnabled
        if var defaults = dict["defaults"] as? [String: Any],
           var asr = defaults["asr"] as? [String: Any] {
            asr["primary"] = migrated.defaults.asr.primary
            defaults["asr"] = asr
            dict["defaults"] = defaults
        }
        guard let out = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        do {
            try out.write(to: url, options: .atomic)
            log.info("persisted the one-time on-device ASR migration")
        } catch {
            log.error("persisting the on-device ASR migration failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: secrets

    /// API keys and the hotspot PSK live in the Keychain, not in
    /// `config.json`. These two helpers are the whole boundary: everything
    /// above them sees a normal `AppConfig` with the values present.

    private static func extractSecrets(_ config: AppConfig) -> AppConfig {
        var stripped = config
        SecretStore.save(config.asrProviders.azure?.key, to: .azureASRKey)
        SecretStore.save(config.asrProviders.custom?.apiKey, to: .asrCustomKey)
        SecretStore.save(config.asrProviders.remoteLive?.apiKey, to: .asrRemoteLiveKey)
        SecretStore.save(config.llmProviders.openai?.apiKey, to: .llmOpenAI)
        SecretStore.save(config.llmProviders.claude?.apiKey, to: .llmClaude)
        SecretStore.save(config.llmProviders.gemini?.apiKey, to: .llmGemini)
        SecretStore.save(config.llmProviders.openRouter?.apiKey, to: .llmOpenRouter)
        SecretStore.save(config.llmProviders.ollama?.apiKey, to: .llmOllama)
        SecretStore.save(config.llmProviders.custom?.apiKey, to: .llmCustom)
        SecretStore.save(config.wifiAP?.psk, to: .wifiAPPassword)

        stripped.asrProviders.azure?.key = ""
        stripped.asrProviders.custom?.apiKey = nil
        stripped.asrProviders.remoteLive?.apiKey = nil
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
        if config.asrProviders.custom != nil {
            config.asrProviders.custom?.apiKey = SecretStore.load(.asrCustomKey)
        }
        if config.asrProviders.remoteLive != nil {
            config.asrProviders.remoteLive?.apiKey = SecretStore.load(.asrRemoteLiveKey)
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
            config.asrProviders.custom?.apiKey,
            config.asrProviders.remoteLive?.apiKey,
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
    func rememberDevice(id: String, name: String, deviceSID: String? = nil,
                        isRecorder: Bool = false) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var record = config.devices[id] ?? .init(name: name, lastConnected: nil)
        record.name = name
        record.lastConnected = iso.string(from: Date())
        if let sid = deviceSID { record.deviceSID = sid }
        // Only ever set to true, never actively revert: old callers that omit this parameter must not wipe an existing flag.
        if isRecorder { record.isRecorder = true }
        config.devices[id] = record
        scheduleSave()
    }

    /// Whether this ledger entry is a recorder card (a `RecorderLink` device such as TicNote).
    /// Returns `false` for a nonexistent record -- callers have usually already checked `devices[id] != nil`.
    func isRecorderRecord(_ id: String) -> Bool {
        config.devices[id]?.isRecorderDevice ?? false
    }

    /// Drop a ledger entry. Used when a card is **released/unbound** (PLAUD
    /// hand-back, recorder unbind): the device no longer belongs to this
    /// install, so keeping a row for it would be a lie in the device list.
    func forgetDevice(id: String) {
        guard config.devices.removeValue(forKey: id) != nil else { return }
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
