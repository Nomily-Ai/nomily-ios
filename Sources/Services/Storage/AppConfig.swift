import CryptoKit
import Foundation

/// On-disk schema for `config.json`.
/// Extra keys from future firmware/providers round-trip through
/// `extraProviders` / the per-device `info` dictionaries so we never
/// silently drop anything the user wrote.
struct AppConfig: Codable, Equatable {
    var asrProviders: AsrProviders
    var llmProviders: LlmProviders
    var defaults: Defaults
    var minTranscribeDuration: Int
    var wifiAP: WifiAP?
    var devices: [String: DeviceRecord]
    var autoDeleteAfterTransfer: Bool
    /// ★ (2026-10-20) Default **on**, per the user: "watch / imported / card recordings should
    /// transcribe and summarize on their own". Covers every import path — watch transfers,
    /// Wi-Fi fast transfer, device-file downloads, the card transfer sheet and live-stream
    /// saves. Clips shorter than `minTranscribeDuration` are skipped by the auto path.
    var autoTranscribeAfterDownload: Bool
    /// Whether the phone's own offline model (Apple `Speech`) may be used at all.
    ///
    /// ★ (2026-10-19) Default **off**, reversed from the original reasoning below.
    ///
    /// The original reason to default to on still holds technically — it is the only provider
    /// that needs no key, no server and no network. But it also made every fresh install call
    /// into `Speech` the moment something wanted a transcript, and a build whose `Info.plist`
    /// had lost `NSSpeechRecognitionUsageDescription` (xcodegen regenerates that plist from
    /// `project.yml`) did not fail gracefully: iOS killed the process on launch, repeatedly.
    /// The owner does not use it, so it is opt-in now — explicit is better than convenient here.
    var onDeviceASREnabled: Bool
    /// Set once after the "on → off" migration above has run, so a user who turns it back on
    /// keeps that choice across launches.
    var onDeviceASROffMigrated: Bool
    /// The user's **default summary template**, keyed by `"\(category)\u{1F}\(name)"`.
    ///
    /// ★ (2026-10-19) Mirrors DingTalk's "Set as default": the summary picker pre-selects this
    /// template instead of leaving `nil` (which used to mean "scroll and pick again, every time").
    /// Not a UUID on purpose — built-in templates get fresh UUIDs every launch.
    var summaryTemplateKey: String?
    /// Run the summary job automatically as soon as a transcript lands.
    ///
    /// Default on, but the caller checks `llmProviders.configuredProviders` first: "on" means
    /// "do it when there is an AI service", never "call a service that isn't configured".
    var autoSummarizeAfterTranscription: Bool
    var localVADEnabled: Bool
    /// Background keep-alive. When on, long jobs like transcription/summary keep a loop of
    /// silent audio going after the app moves to the background to hold the process up and stop iOS suspending it (hung off `BackgroundKeeper`).
    /// Turning it off leaves only `beginBackgroundTask`'s ~30-second grace — short jobs still finish,
    /// long ones get cut. There's a switch because the user should have the right to refuse "tricking the background with silent audio".
    var backgroundKeepAliveEnabled: Bool
    /// When on, the app reconnects to the most recent device by itself after
    /// an unexpected drop (device powered off/on, out of range). When off the
    /// app stays disconnected until the user taps the connection pill.
    var autoReconnectEnabled: Bool
    /// The user has acknowledged that using a cloud transcription/LLM provider
    /// sends their audio/text to that third party (off-device). Gates the
    /// one-time consent prompt; see `usesCloudService`.
    var cloudEgressConsented: Bool
    var isDeveloperMode: Bool
    var lastSourceLang: String?
    var lastTargetLang: String?
    var lastSummaryLang: String?
    /// UI language as a BCP-47 tag (`zh-Hans`, `pt-BR`, …).
    ///
    /// **`nil` = follow the system**, and that's also the value when the user
    /// has never chosen — which is why this is optional rather than defaulting
    /// to `"en"`: defaulting to English would greet every non-English user with
    /// an English UI on first launch. Tags outside `AppLanguage.supported`
    /// resolve to English (`AppLanguage.resolve`).
    var appLanguage: String?
    /// App colour theme — `AppTheme.rawValue` (`crimson` / `graphite` / `ocean` / …).
    ///
    /// **`nil` = the default (`crimson`, the brand red)**. Stored as a bare tag for the same reason as
    /// `appLanguage` / `watchFaceStyle`: `AppConfig` is a pure disk schema living in `Sources/Services/`,
    /// and importing the UI layer's `AppTheme` (which needs SwiftUI's `Color`) here would drag SwiftUI
    /// into every target that only wants to read settings.
    var appTheme: String?
    /// The command the DingTalk A1 setup page shows for "run this on your Mac".
    ///
    /// **Machine-specific by nature** (the extractor script lives wherever the user put it), so
    /// it is user-editable and persisted; `nil` = the generic default the setup page renders.
    /// Never assume *our* path here — a build handed to someone else must not carry it.
    var a1ExtractCommand: String?
    /// The DingTalk A1 **recording mode** the user picked (`A1RecordMode.rawValue`).
    ///
    /// ★ (2026-10-19) Mirrors the card's five modes shown in DingTalk's device settings
    /// (General / Meeting / Face-to-face / AI Visual Notes / Lossless). Persisted per app because `0x0100`
    /// currently exposes **no** record-mode param — until the real key is confirmed from a
    /// live `dumpAllParams()` log, the choice is a named preset the app documents (and later
    /// applies once the key is known). `nil` = `.general` (the card's default).
    var a1RecordMode: String?
    /// Which expression the watch home-screen face shows — `BotFaceStyle.rawValue`.
    ///
    /// **`nil` = never chosen**, equivalent to `calm` (what the face looked like before the thirteenth revision).
    /// Like `appLanguage`, this stores a **bare tag**, not an enum:
    /// `AppConfig` is a pure disk schema; dragging the UI layer's enum type in would get it compiled
    /// into places that don't need it (this file is in `Sources/`, while the expression library is in
    /// `Sources/Services/Watch/`).
    ///
    /// ⚠️ This copy **exists only on the phone side**; the watch's copy is the one it stores itself after the push
    /// (see `WatchFaceStore`). Both sides are "newest version wins", so there's no sync conflict to speak of.
    var watchFaceStyle: String?
    /// The watch face's eye colour as `RRGGBB` hex (no `#`). **`nil` = follow the watch's own
    /// "Appearance" palette** — that watch-local preference stays authoritative until the user
    /// picks a colour here. ★ 2026-10-20.
    var watchEyeColor: String?
    /// Blink pace for the watch face — `BotBlinkSpeed.rawValue`. `nil` = `normal`.
    /// A bare tag, same reason as `watchFaceStyle`. ★ 2026-10-20.
    var watchBlinkSpeed: String?
    /// Whether the watch face's idle expression auto-cycles inside its square frame.
    /// `nil` = `true` (the dynamic behaviour is the default). ★ 2026-10-20.
    var watchFaceAutoCycle: Bool?
    /// Whether the rounded-square frame is drawn around the watch face. `nil` = `true`.
    var watchFaceFrame: Bool?
    /// Backlog size (in KB) above which the Wi-Fi fast-transfer button
    /// is offered on the device-files screen. 0 disables the suggestion
    /// and the button never appears.
    var fastTransferThresholdKB: Int

    static let empty = AppConfig(
        asrProviders: AsrProviders(),
        llmProviders: LlmProviders(),
        defaults: Defaults(asr: AsrDefaults(primary: "azure", fallbacks: ["local"])),
        minTranscribeDuration: 10,
        wifiAP: nil,
        devices: [:],
        autoDeleteAfterTransfer: true,
        autoTranscribeAfterDownload: true,
        onDeviceASREnabled: false,
        onDeviceASROffMigrated: true,
        autoSummarizeAfterTranscription: true,
        localVADEnabled: true,
        backgroundKeepAliveEnabled: true,
        autoReconnectEnabled: true,
        cloudEgressConsented: false,
        isDeveloperMode: false
    )

    enum CodingKeys: String, CodingKey {
        case asrProviders = "asr_providers"
        case llmProviders = "llm_providers"
        case defaults
        case minTranscribeDuration = "min_transcribe_duration"
        case wifiAP = "wifi_ap"
        case devices
        case autoDeleteAfterTransfer = "auto_delete_after_transfer"
        case autoTranscribeAfterDownload = "auto_transcribe_after_download"
        case onDeviceASREnabled = "on_device_asr_enabled"
        case onDeviceASROffMigrated = "on_device_asr_off_migrated"
        case summaryTemplateKey = "summary_template_key"
        case autoSummarizeAfterTranscription = "auto_summarize_after_transcription"
        case localVADEnabled = "local_vad_enabled"
        case backgroundKeepAliveEnabled = "background_keep_alive_enabled"
        case autoReconnectEnabled = "auto_reconnect_enabled"
        case cloudEgressConsented = "cloud_egress_consented"
        case isDeveloperMode = "developer_mode"
        case lastSourceLang = "last_source_lang"
        case lastTargetLang = "last_target_lang"
        case lastSummaryLang = "last_summary_lang"
        case appLanguage = "app_language"
        case appTheme = "app_theme"
        case a1ExtractCommand = "a1_extract_command"
        case a1RecordMode = "a1_record_mode"
        case watchFaceStyle = "watch_face_style"
        case watchEyeColor = "watch_eye_color"
        case watchBlinkSpeed = "watch_blink_speed"
        case watchFaceAutoCycle = "watch_face_auto_cycle"
        case watchFaceFrame = "watch_face_frame"
        case fastTransferThresholdKB = "fast_transfer_threshold_kb"
    }

    /// Decode with `decodeIfPresent` for new / optional keys so a
    /// `config.json` written by an older build loads
    /// cleanly instead of falling back to `.empty` and wiping every
    /// other setting the user already configured.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.asrProviders = try c.decodeIfPresent(AsrProviders.self, forKey: .asrProviders) ?? AsrProviders()
        self.llmProviders = try c.decodeIfPresent(LlmProviders.self, forKey: .llmProviders) ?? LlmProviders()
        self.defaults = try c.decodeIfPresent(Defaults.self, forKey: .defaults)
            ?? Defaults(asr: AsrDefaults(primary: "azure", fallbacks: ["local"]))
        self.minTranscribeDuration = try c.decodeIfPresent(Int.self, forKey: .minTranscribeDuration) ?? 10
        self.wifiAP = try c.decodeIfPresent(WifiAP.self, forKey: .wifiAP)
        self.devices = try c.decodeIfPresent([String: DeviceRecord].self, forKey: .devices) ?? [:]
        self.autoDeleteAfterTransfer = try c.decodeIfPresent(Bool.self, forKey: .autoDeleteAfterTransfer) ?? true
        self.autoTranscribeAfterDownload = try c.decodeIfPresent(Bool.self, forKey: .autoTranscribeAfterDownload) ?? true
        // ★ (2026-10-19) One-time "on → off" migration.
        //
        // The default flipped to off, but `decodeIfPresent` only affects *new* configs — an
        // existing `config.json` still says `true` and would keep reaching into `Speech` on
        // launch. `on_device_asr_off_migrated` makes the override happen exactly once, so a
        // user who switches it back on afterwards keeps their choice on the next launch.
        let offMigrated = try c.decodeIfPresent(Bool.self, forKey: .onDeviceASROffMigrated) ?? false
        self.onDeviceASREnabled = offMigrated
            ? (try c.decodeIfPresent(Bool.self, forKey: .onDeviceASREnabled) ?? false)
            : false
        self.summaryTemplateKey = try c.decodeIfPresent(String.self, forKey: .summaryTemplateKey)
        self.watchEyeColor = try c.decodeIfPresent(String.self, forKey: .watchEyeColor)
        self.watchBlinkSpeed = try c.decodeIfPresent(String.self, forKey: .watchBlinkSpeed)
        self.watchFaceAutoCycle = try c.decodeIfPresent(Bool.self, forKey: .watchFaceAutoCycle)
        self.watchFaceFrame = try c.decodeIfPresent(Bool.self, forKey: .watchFaceFrame)
        self.onDeviceASROffMigrated = true
        // ⚠️ The "primary pointed at ondevice" fix-up deliberately does **not** live here.
        //   At decode time the Keychain secrets have not been re-attached yet, so every cloud
        //   provider looks unconfigured and the decision would collapse to the wrong pick
        //   (measured: azure → local). `ConfigService.load` does it after the secrets are back.
        self.autoSummarizeAfterTranscription = try c.decodeIfPresent(Bool.self, forKey: .autoSummarizeAfterTranscription) ?? true
        self.localVADEnabled = try c.decodeIfPresent(Bool.self, forKey: .localVADEnabled) ?? true
        self.backgroundKeepAliveEnabled = try c.decodeIfPresent(Bool.self, forKey: .backgroundKeepAliveEnabled) ?? true
        self.autoReconnectEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoReconnectEnabled) ?? true
        self.cloudEgressConsented = try c.decodeIfPresent(Bool.self, forKey: .cloudEgressConsented) ?? false
        self.isDeveloperMode = try c.decodeIfPresent(Bool.self, forKey: .isDeveloperMode) ?? false
        self.lastSourceLang = try c.decodeIfPresent(String.self, forKey: .lastSourceLang)
        self.lastTargetLang = try c.decodeIfPresent(String.self, forKey: .lastTargetLang)
        self.lastSummaryLang = try c.decodeIfPresent(String.self, forKey: .lastSummaryLang)
        self.appLanguage = try c.decodeIfPresent(String.self, forKey: .appLanguage)
        self.appTheme = try c.decodeIfPresent(String.self, forKey: .appTheme)
        self.a1ExtractCommand = try c.decodeIfPresent(String.self, forKey: .a1ExtractCommand)
        self.a1RecordMode = try c.decodeIfPresent(String.self, forKey: .a1RecordMode)
        self.watchFaceStyle = try c.decodeIfPresent(String.self, forKey: .watchFaceStyle)
        self.fastTransferThresholdKB = try c.decodeIfPresent(Int.self, forKey: .fastTransferThresholdKB) ?? 512
    }

    init(
        asrProviders: AsrProviders,
        llmProviders: LlmProviders = LlmProviders(),
        defaults: Defaults,
        minTranscribeDuration: Int,
        wifiAP: WifiAP?,
        devices: [String: DeviceRecord],
        autoDeleteAfterTransfer: Bool,
        autoTranscribeAfterDownload: Bool = true,
        onDeviceASREnabled: Bool = false,
        onDeviceASROffMigrated: Bool = true,
        summaryTemplateKey: String? = nil,
        autoSummarizeAfterTranscription: Bool = true,
        localVADEnabled: Bool = true,
        backgroundKeepAliveEnabled: Bool = true,
        autoReconnectEnabled: Bool = true,
        cloudEgressConsented: Bool = false,
        isDeveloperMode: Bool = false,
        lastSourceLang: String? = nil,
        lastTargetLang: String? = nil,
        lastSummaryLang: String? = nil,
        appLanguage: String? = nil,
        appTheme: String? = nil,
        a1ExtractCommand: String? = nil,
        a1RecordMode: String? = nil,
        watchFaceStyle: String? = nil,
        watchEyeColor: String? = nil,
        watchBlinkSpeed: String? = nil,
        watchFaceAutoCycle: Bool? = nil,
        watchFaceFrame: Bool? = nil,
        fastTransferThresholdKB: Int = 512
    ) {
        self.asrProviders = asrProviders
        self.llmProviders = llmProviders
        self.defaults = defaults
        self.minTranscribeDuration = minTranscribeDuration
        self.wifiAP = wifiAP
        self.devices = devices
        self.autoDeleteAfterTransfer = autoDeleteAfterTransfer
        self.autoTranscribeAfterDownload = autoTranscribeAfterDownload
        self.onDeviceASREnabled = onDeviceASREnabled
        self.onDeviceASROffMigrated = onDeviceASROffMigrated
        self.summaryTemplateKey = summaryTemplateKey
        self.autoSummarizeAfterTranscription = autoSummarizeAfterTranscription
        self.localVADEnabled = localVADEnabled
        self.backgroundKeepAliveEnabled = backgroundKeepAliveEnabled
        self.autoReconnectEnabled = autoReconnectEnabled
        self.cloudEgressConsented = cloudEgressConsented
        self.isDeveloperMode = isDeveloperMode
        self.lastSourceLang = lastSourceLang
        self.lastTargetLang = lastTargetLang
        self.lastSummaryLang = lastSummaryLang
        self.appLanguage = appLanguage
        self.appTheme = appTheme
        self.a1ExtractCommand = a1ExtractCommand
        self.a1RecordMode = a1RecordMode
        self.watchFaceStyle = watchFaceStyle
        self.watchEyeColor = watchEyeColor
        self.watchBlinkSpeed = watchBlinkSpeed
        self.watchFaceAutoCycle = watchFaceAutoCycle
        self.watchFaceFrame = watchFaceFrame
        self.fastTransferThresholdKB = fastTransferThresholdKB
    }

    /// True when the active configuration would send user data to a cloud
    /// third party: Azure transcription, or a cloud LLM (openai/claude/gemini/
    /// openRouter) as the summary provider. Local ASR and Ollama stay
    /// on-device / on the user's own server and don't count. `custom` LLM is
    /// treated as non-cloud since it's usually a self-hosted endpoint.
    var usesCloudService: Bool {
        if let a = asrProviders.azure, !a.key.isEmpty, !a.region.isEmpty { return true }
        switch llmProviders.primary {
        case "openai", "claude", "gemini", "openRouter": return true
        default: return false
        }
    }

    struct AsrProviders: Codable, Equatable {
        var azure: Azure?
        var local: Local?
        /// User-defined OpenAI-compatible transcription server (2026-10-19).
        /// Feasibility was proven against a real client↔server round-trip before wiring the UI.
        var custom: Custom?
        /// ★ 2026-10-20: **remote live** service — a WSS endpoint speaking the same
        /// `/v1/listen` + raw-Opus protocol as the LAN server, but over TLS with an API
        /// key. Deliberately separate from `local` (that one is plaintext LAN-only and
        /// must never receive a public hostname) and from `custom` (file transcription
        /// only). The API key never touches disk — see `SecretStore.Slot.asrRemoteLiveKey`.
        var remoteLive: RemoteLive?

        struct RemoteLive: Codable, Equatable {
            /// `wss://host[:port][/v1/listen]`. `wss` (or `https`, auto-upgraded) only —
            /// an explicit `ws://` is rejected. `RemoteLiveASR.listenURL` normalizes.
            var endpoint: String
            /// In-memory only; extracted to the Keychain at the persistence boundary
            /// (same split/merge as the LLM keys). Required for the remote service.
            var apiKey: String?
        }

        struct Azure: Codable, Equatable {
            var key: String
            var region: String
            /// The fingerprint of the credential set used in the last "validate configuration" and its result. If the fingerprint does not match
            /// it indicates that the key/region was changed later, so that previous conclusion no longer applies.
            var verifiedFingerprint: String?
            var verifiedOK: Bool?

            /// The validation result for the current key/region; `nil` means not validated yet, or it was changed after validation.
            var verification: Bool? {
                guard let fingerprint = verifiedFingerprint,
                      fingerprint == Self.fingerprint(key: key, region: region)
                else { return nil }
                return verifiedOK
            }

            enum CodingKeys: String, CodingKey {
                case key
                case region
                case verifiedFingerprint = "verified_fingerprint"
                case verifiedOK = "verified_ok"
            }

            /// Only the fingerprint is stored, not the key itself — the configuration file is plaintext.
            static func fingerprint(key: String, region: String) -> String {
                let digest = SHA256.hash(data: Data("\(key)|\(region.lowercased())".utf8))
                return digest.map { String(format: "%02x", $0) }.joined()
            }
        }
        struct Local: Codable, Equatable {
            var host: String
            var port: Int
        }
        struct Custom: Codable, Equatable {
            /// Base URL, e.g. `http://192.168.1.10:8000` or `https://api.groq.com/openai`.
            var endpoint: String
            var apiKey: String?
            var model: String?
            /// Optional ISO-639-1 hint; empty = server-side detection.
            var language: String?

            enum CodingKeys: String, CodingKey {
                case endpoint
                case apiKey = "api_key"
                case model
                case language
            }
        }

        var hasConfiguredProvider: Bool {
            if let a = azure, !a.key.isEmpty, !a.region.isEmpty { return true }
            if let l = local, !l.host.isEmpty, l.port > 0 { return true }
            if let c = custom, !c.endpoint.isEmpty { return true }
            // ⚠️ `remoteLive` deliberately NOT counted: it serves **live** transcription
            // only, while every caller of this flag gates **file** transcription buttons.
            // Counting it would make "transcribe" tappable with no file provider behind it.
            return false
        }

        enum CodingKeys: String, CodingKey {
            case azure
            case local
            case custom
            case remoteLive = "remote_live"
        }
    }

    struct LlmProviders: Codable, Equatable {
        var primary: String?
        var openai: KeyedProvider?
        var openRouter: EndpointProvider?
        var claude: KeyedProvider?
        var gemini: KeyedProvider?
        var ollama: EndpointProvider?
        var custom: EndpointProvider?
        /// ★ 2026-10-22: one-tap presets (Qwen / DeepSeek / Doubao / Ark) keyed by
        /// `LLMPreset.id`. A dictionary instead of four named fields so adding a
        /// provider later doesn't touch the Codable shape, the secret-splitting
        /// table, `configGap`, `complete` and the picker all at once.
        ///
        /// Optional on purpose: `config.json` written by an older build has no
        /// such key, and a missing optional decodes to `nil`.
        var presets: [String: EndpointProvider]?

        init(
            primary: String? = nil,
            openai: KeyedProvider? = nil, openRouter: EndpointProvider? = nil,
            claude: KeyedProvider? = nil, gemini: KeyedProvider? = nil,
            ollama: EndpointProvider? = nil, custom: EndpointProvider? = nil,
            presets: [String: EndpointProvider]? = nil
        ) {
            self.primary = primary
            self.openai = openai; self.openRouter = openRouter
            self.claude = claude; self.gemini = gemini
            self.ollama = ollama; self.custom = custom
            self.presets = presets
        }

        struct KeyedProvider: Codable, Equatable {
            var apiKey: String
            var model: String?
            enum CodingKeys: String, CodingKey {
                case apiKey = "api_key"
                case model
            }
        }
        struct EndpointProvider: Codable, Equatable {
            var apiKey: String?
            var endpoint: String
            var model: String?
            enum CodingKeys: String, CodingKey {
                case apiKey = "api_key"
                case endpoint
                case model
            }
        }

        enum CodingKeys: String, CodingKey {
            case primary
            case openai
            case openRouter = "open_router"
            case claude
            case gemini
            case ollama
            case custom
            case presets
        }

        /// Read / write one preset slot. Creating a slot requires an endpoint, so
        /// the page can fill it from `LLMPreset` the moment the user taps an icon.
        func preset(_ id: String) -> EndpointProvider? { presets?[id] }

        mutating func setPreset(_ id: String, _ value: EndpointProvider?) {
            if let value {
                var map = presets ?? [:]
                map[id] = value
                presets = map
            } else if presets != nil {
                presets?.removeValue(forKey: id)
                if presets?.isEmpty == true { presets = nil }
            }
        }

        /// Everything the user can pick as the primary channel.
        ///
        /// Derived from `LLMProviderSpec.all` rather than a hand-written list, so
        /// the dropdown and the icon grid can never disagree about which providers
        /// exist or what they are called (they did: "OpenAI" in the dropdown,
        /// "ChatGPT" on the row above it).
        var configuredProviders: [(key: String, label: String)] {
            LLMProviderSpec.all.compactMap { spec -> (String, String)? in
                let hasKey = !(apiKeyValue(for: spec.storage) ?? "").isEmpty
                if spec.keyRequired {
                    return hasKey ? (spec.id, spec.name) : nil
                }
                // Ollama / Custom: a reachable address *is* the configuration.
                let hasEndpoint = !(endpointValue(for: spec.storage) ?? "").isEmpty
                return hasEndpoint ? (spec.id, spec.name) : nil
            }
        }

        mutating func autoSelectPrimaryIfFirst() {
            let configured = configuredProviders
            if configured.count == 1 {
                primary = configured[0].key
            }
        }
    }

    struct Defaults: Codable, Equatable {
        var asr: AsrDefaults
    }

    struct AsrDefaults: Codable, Equatable {
        var primary: String
        var fallbacks: [String]
    }

    struct WifiAP: Codable, Equatable {
        var ssid: String
        var psk: String
    }

    struct DeviceRecord: Codable, Equatable {
        var name: String
        var lastConnected: String?
        /// 32-char hex string (16 raw bytes) — the last bond_id we pushed
        /// to this peripheral via `0xA0`. Persisted so the bond can be
        /// inspected / re-sent after a reinstall or factory reset. Nil
        /// means "never paired from this app".
        var bondID: String?
        /// 6-char uppercase hex (3 raw bytes) — DEVICE_SID from the
        /// manufacturer-data advertisement (bytes 14~16 of the AD payload).
        /// Used by `reconnect(deviceSID:)` to match the same physical device
        /// across app reinstalls / new phones, where the iOS-assigned
        /// `peripheral.identifier` would change. Nil for legacy records
        /// written before the SID was captured.
        var deviceSID: String?
        /// `true` = this record is a **recorder card** (a device like TicNote that goes through `RecorderLink`),
        /// not a D·NOTE. DnoteClient-specific logic such as reconnect, battery and binding must bypass it,
        /// see `PreferredDevice.reconnect` and the branch in `RootView`.
        /// Optional + `decodeIfPresent`: old records lack this field and decode as `false`.
        var isRecorder: Bool?

        enum CodingKeys: String, CodingKey {
            case name
            case lastConnected = "last_connected"
            case bondID = "bond_id"
            case deviceSID = "device_sid"
            case isRecorder = "is_recorder"
        }

        init(name: String, lastConnected: String? = nil, bondID: String? = nil,
             deviceSID: String? = nil, isRecorder: Bool? = nil) {
            self.name = name
            self.lastConnected = lastConnected
            self.bondID = bondID
            self.deviceSID = deviceSID
            self.isRecorder = isRecorder
        }

        /// Convenience criterion: nil-safe. Recorder-card reconnect/display all go through this one entry point.
        var isRecorderDevice: Bool { isRecorder ?? false }
    }
}

// MARK: - One uniform view over the three storage shapes

/// The settings page drives ten providers through one sheet; these six accessors
/// are what makes that possible without ten copies of the same form.
///
/// ⚠️ `KeyedProvider.apiKey` is a non-optional `String` while every other shape
/// uses `String?`. The asymmetry is absorbed here and nowhere else — a caller
/// clearing the field sees `nil` either way.
extension AppConfig.LlmProviders {

    func endpointValue(for storage: LLMProviderStorage) -> String? {
        switch storage {
        case .keyed(let id):
            return LLMProviderSpec.find(id)?.defaultEndpoint
        case .endpoint(let id):
            return endpointSlot(id)?.endpoint
        case .preset(let id):
            return presets?[id]?.endpoint
        }
    }

    func apiKeyValue(for storage: LLMProviderStorage) -> String? {
        switch storage {
        case .keyed(let id):
            return keyedSlot(id)?.apiKey
        case .endpoint(let id):
            return endpointSlot(id)?.apiKey
        case .preset(let id):
            return presets?[id]?.apiKey
        }
    }

    func modelValue(for storage: LLMProviderStorage) -> String? {
        switch storage {
        case .keyed(let id):
            return keyedSlot(id)?.model
        case .endpoint(let id):
            return endpointSlot(id)?.model
        case .preset(let id):
            return presets?[id]?.model
        }
    }

    mutating func setAPIKey(_ value: String?, for storage: LLMProviderStorage) {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch storage {
        case .keyed(let id):
            var slot = keyedSlot(id) ?? .init(apiKey: "")
            slot.apiKey = trimmed
            // Empty key **and** no model means the user never configured this
            // provider — keep the entry out of `configuredProviders` entirely
            // instead of leaving a "configured, unusable" row behind.
            setKeyedSlot(id, (trimmed.isEmpty && (slot.model ?? "").isEmpty) ? nil : slot)
        case .endpoint(let id):
            var slot = endpointSlot(id) ?? .init(apiKey: nil, endpoint: LLMProviderSpec.find(id)?.defaultEndpoint ?? "")
            slot.apiKey = trimmed.isEmpty ? nil : trimmed
            if slot.endpoint.isEmpty { slot.endpoint = LLMProviderSpec.find(id)?.defaultEndpoint ?? "" }
            setEndpointSlot(id, slot)
        case .preset(let id):
            var slot = presets?[id] ?? .init(apiKey: nil, endpoint: LLMProviderSpec.find(id)?.defaultEndpoint ?? "", model: nil)
            slot.apiKey = trimmed.isEmpty ? nil : trimmed
            setPreset(id, slot)
        }
    }

    mutating func setModel(_ value: String?, for storage: LLMProviderStorage) {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch storage {
        case .keyed(let id):
            var slot = keyedSlot(id) ?? .init(apiKey: "")
            slot.model = trimmed.isEmpty ? nil : trimmed
            setKeyedSlot(id, (slot.apiKey.isEmpty && trimmed.isEmpty) ? nil : slot)
        case .endpoint(let id):
            var slot = endpointSlot(id) ?? .init(apiKey: nil, endpoint: LLMProviderSpec.find(id)?.defaultEndpoint ?? "")
            slot.model = trimmed.isEmpty ? nil : trimmed
            if slot.endpoint.isEmpty { slot.endpoint = LLMProviderSpec.find(id)?.defaultEndpoint ?? "" }
            setEndpointSlot(id, slot)
        case .preset(let id):
            var slot = presets?[id] ?? .init(apiKey: nil, endpoint: LLMProviderSpec.find(id)?.defaultEndpoint ?? "", model: nil)
            slot.model = trimmed.isEmpty ? nil : trimmed
            setPreset(id, slot)
        }
    }

    mutating func setEndpointURL(_ value: String, for storage: LLMProviderStorage) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch storage {
        case .keyed:
            // Fixed by the API; nothing to store.
            return
        case .endpoint(let id):
            var slot = endpointSlot(id) ?? .init(apiKey: nil, endpoint: "")
            slot.endpoint = trimmed
            setEndpointSlot(id, slot)
        case .preset(let id):
            var slot = presets?[id] ?? .init(apiKey: nil, endpoint: "", model: nil)
            slot.endpoint = trimmed
            setPreset(id, slot)
        }
    }

    mutating func removeProvider(for storage: LLMProviderStorage) {
        switch storage {
        case .keyed(let id):    setKeyedSlot(id, nil)
        case .endpoint(let id): setEndpointSlot(id, nil)
        case .preset(let id):   setPreset(id, nil)
        }
        if let primary, LLMProviderSpec.find(primary)?.storage == storage { self.primary = nil }
    }

    // Private plumbing: one place per shape, so the six accessors above stay
    // symmetrical and a new shape only touches this block.

    private func keyedSlot(_ id: String) -> KeyedProvider? {
        switch id {
        case "openai": return openai
        case "claude": return claude
        case "gemini": return gemini
        default:       return nil
        }
    }

    private mutating func setKeyedSlot(_ id: String, _ value: KeyedProvider?) {
        switch id {
        case "openai": openai = value
        case "claude": claude = value
        case "gemini": gemini = value
        default:       break
        }
    }

    private func endpointSlot(_ id: String) -> EndpointProvider? {
        switch id {
        case "openRouter": return openRouter
        case "ollama":     return ollama
        case "custom":     return custom
        default:           return nil
        }
    }

    private mutating func setEndpointSlot(_ id: String, _ value: EndpointProvider?) {
        switch id {
        case "openRouter": openRouter = value
        case "ollama":     ollama = value
        case "custom":     custom = value
        default:           break
        }
    }
}
