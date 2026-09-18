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
    var autoTranscribeAfterDownload: Bool
    var localVADEnabled: Bool
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
        autoTranscribeAfterDownload: false,
        localVADEnabled: true,
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
        case localVADEnabled = "local_vad_enabled"
        case autoReconnectEnabled = "auto_reconnect_enabled"
        case cloudEgressConsented = "cloud_egress_consented"
        case isDeveloperMode = "developer_mode"
        case lastSourceLang = "last_source_lang"
        case lastTargetLang = "last_target_lang"
        case lastSummaryLang = "last_summary_lang"
        case appLanguage = "app_language"
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
        self.autoTranscribeAfterDownload = try c.decodeIfPresent(Bool.self, forKey: .autoTranscribeAfterDownload) ?? false
        self.localVADEnabled = try c.decodeIfPresent(Bool.self, forKey: .localVADEnabled) ?? true
        self.autoReconnectEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoReconnectEnabled) ?? true
        self.cloudEgressConsented = try c.decodeIfPresent(Bool.self, forKey: .cloudEgressConsented) ?? false
        self.isDeveloperMode = try c.decodeIfPresent(Bool.self, forKey: .isDeveloperMode) ?? false
        self.lastSourceLang = try c.decodeIfPresent(String.self, forKey: .lastSourceLang)
        self.lastTargetLang = try c.decodeIfPresent(String.self, forKey: .lastTargetLang)
        self.lastSummaryLang = try c.decodeIfPresent(String.self, forKey: .lastSummaryLang)
        self.appLanguage = try c.decodeIfPresent(String.self, forKey: .appLanguage)
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
        autoTranscribeAfterDownload: Bool = false,
        localVADEnabled: Bool = true,
        autoReconnectEnabled: Bool = true,
        cloudEgressConsented: Bool = false,
        isDeveloperMode: Bool = false,
        lastSourceLang: String? = nil,
        lastTargetLang: String? = nil,
        lastSummaryLang: String? = nil,
        appLanguage: String? = nil,
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
        self.localVADEnabled = localVADEnabled
        self.autoReconnectEnabled = autoReconnectEnabled
        self.cloudEgressConsented = cloudEgressConsented
        self.isDeveloperMode = isDeveloperMode
        self.lastSourceLang = lastSourceLang
        self.lastTargetLang = lastTargetLang
        self.lastSummaryLang = lastSummaryLang
        self.appLanguage = appLanguage
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

        var hasConfiguredProvider: Bool {
            if let a = azure, !a.key.isEmpty, !a.region.isEmpty { return true }
            if let l = local, !l.host.isEmpty, l.port > 0 { return true }
            return false
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

        init(
            primary: String? = nil,
            openai: KeyedProvider? = nil, openRouter: EndpointProvider? = nil,
            claude: KeyedProvider? = nil, gemini: KeyedProvider? = nil,
            ollama: EndpointProvider? = nil, custom: EndpointProvider? = nil
        ) {
            self.primary = primary
            self.openai = openai; self.openRouter = openRouter
            self.claude = claude; self.gemini = gemini
            self.ollama = ollama; self.custom = custom
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
        }

        var configuredProviders: [(key: String, label: String)] {
            var result: [(String, String)] = []
            if let p = openRouter, p.apiKey != nil, !p.apiKey!.isEmpty { result.append(("openRouter", "Open Router")) }
            if let p = openai, !p.apiKey.isEmpty { result.append(("openai", "OpenAI")) }
            if let p = claude, !p.apiKey.isEmpty { result.append(("claude", "Claude")) }
            if let p = gemini, !p.apiKey.isEmpty { result.append(("gemini", "Gemini")) }
            if let p = ollama, !p.endpoint.isEmpty { result.append(("ollama", "Ollama")) }
            if let p = custom, !p.endpoint.isEmpty { result.append(("custom", "Custom")) }
            return result
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

        enum CodingKeys: String, CodingKey {
            case name
            case lastConnected = "last_connected"
            case bondID = "bond_id"
            case deviceSID = "device_sid"
        }

        init(name: String, lastConnected: String? = nil, bondID: String? = nil, deviceSID: String? = nil) {
            self.name = name
            self.lastConnected = lastConnected
            self.bondID = bondID
            self.deviceSID = deviceSID
        }
    }
}
