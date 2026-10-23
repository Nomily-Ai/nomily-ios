import Foundation

// swiftlint:disable type_body_length file_length

enum L10n {

    // MARK: - Azure verify

    /// Reasons for Azure verification failure. Raw status codes are not user-friendly and do not indicate whether to change the key or region,
    /// so the status code is only included as secondary information in parentheses (see `LLMModelService.azureVerifyReason`).
    enum AzureVerify {
        static var badCredentials: String { NSLocalizedString("azure_verify.bad_credentials", comment: "") }
        static var regionNotFound: String { NSLocalizedString("azure_verify.region_not_found", comment: "") }
        static var rateLimited: String { NSLocalizedString("azure_verify.rate_limited", comment: "") }
        static var serviceUnavailable: String { NSLocalizedString("azure_verify.service_unavailable", comment: "") }
        static var network: String { NSLocalizedString("azure_verify.network", comment: "") }
        static var hostUnresolved: String { NSLocalizedString("azure_verify.host_unresolved", comment: "") }
        static var unexpected: String { NSLocalizedString("azure_verify.unexpected", comment: "") }
    }

    // MARK: - Privacy

    enum Privacy {
        static var cloudTitle: String { NSLocalizedString("privacy.cloud_title", value: "Data leaves your device", comment: "Cloud-egress consent title") }
        static var cloudMessage: String { NSLocalizedString("privacy.cloud_message", value: "You've set up a cloud transcription or AI provider (e.g. Azure, OpenAI). Your audio and text are sent to that third-party service to be processed. Nothing goes to a Nomily server, but the data does leave your device. For fully on-device processing, use a local ASR server and a local (Ollama) or no AI model.", comment: "Cloud-egress consent body") }
        static var cloudAgree: String { NSLocalizedString("privacy.cloud_agree", value: "I Understand, Continue", comment: "") }
        static var cloudGoLocal: String { NSLocalizedString("privacy.cloud_go_local", value: "Provider Settings", comment: "") }
    }

    // MARK: - Common

    enum Common {
        static var done: String { NSLocalizedString("common.done", comment: "") }
        static var cancel: String { NSLocalizedString("common.cancel", comment: "") }
        static var ok: String { NSLocalizedString("common.ok", comment: "") }
        static var delete: String { NSLocalizedString("common.delete", comment: "") }
        static var edit: String { NSLocalizedString("common.edit", comment: "") }
        static var save: String { NSLocalizedString("common.save", comment: "") }
        static var retry: String { NSLocalizedString("common.retry", comment: "") }
        static var close: String { NSLocalizedString("common.close", comment: "") }
        static var openSettings: String { NSLocalizedString("common.open_settings", comment: "") }
        static var tryAgain: String { NSLocalizedString("common.try_again", comment: "") }
        /// 通用返回。给那些**不是 push 进去**、系统不给返回箭头的页面用。
        static var back: String {
            NSLocalizedString("common.back", value: "Back", comment: "Generic back button")
        }
        static var none: String { NSLocalizedString("common.none", comment: "") }
        static var recording: String { NSLocalizedString("common.recording", comment: "") }
        static var keepForeground: String { NSLocalizedString("common.keep_foreground", comment: "") }
    }

    // MARK: - Tabs

    enum Tab {
        static var recordings: String { NSLocalizedString("tab.recordings", comment: "") }
        static var live: String { NSLocalizedString("tab.live", comment: "") }
        static var settings: String { NSLocalizedString("tab.settings", comment: "") }
    }

    // MARK: - Settings

    enum Settings {
        static var asrProviders: String { NSLocalizedString("settings.asr_providers", comment: "") }
        static var llmProviders: String { NSLocalizedString("settings.llm_providers", comment: "") }
        static var recordings: String { NSLocalizedString("settings.recordings", comment: "") }
        static var summarizeTemplates: String { NSLocalizedString("settings.summarize_templates", comment: "") }
        static var devicesAndLibrary: String { NSLocalizedString("settings.devices_library", comment: "") }
        static var about: String { NSLocalizedString("settings.about", comment: "") }
        static var version: String { NSLocalizedString("settings.version", comment: "") }
        static var language: String { NSLocalizedString("settings.language", comment: "") }
    }

    // MARK: - Language

    enum Language {
        static var followSystem: String { NSLocalizedString("language.follow_system", comment: "") }
        static var footer: String { NSLocalizedString("language.footer", comment: "") }
    }

    // MARK: - ASR

    enum ASR {
        static var transcription: String { NSLocalizedString("asr.transcription", comment: "") }
        static var noProviderConfigured: String { NSLocalizedString("asr.no_provider_configured", comment: "") }
        static var allProvidersUnreachable: String { NSLocalizedString("asr.all_providers_unreachable", comment: "") }
        static var azureRequiredForTranslation: String { NSLocalizedString("asr.azure_required_for_translation", comment: "") }
        static var openProviderSettings: String { NSLocalizedString("asr.open_provider_settings", comment: "") }
        static func missingCredentials(_ provider: String) -> String {
            String(format: NSLocalizedString("asr.missing_credentials", comment: ""), provider)
        }
        static var activeProvider: String { NSLocalizedString("asr.active_provider", comment: "") }
        static var autoTranscribeAfterDownload: String { NSLocalizedString("asr.auto_transcribe_after_download", comment: "") }
        static func autoTranscribeMin(_ duration: Int) -> String {
            String(format: NSLocalizedString("asr.auto_transcribe_min", comment: ""), duration)
        }
        static var autoTranscribeFooter: String { NSLocalizedString("asr.auto_transcribe_footer", comment: "") }
        static var localVAD: String { NSLocalizedString("asr.local_vad", comment: "") }
        static var localVADFooter: String { NSLocalizedString("asr.local_vad_footer", comment: "") }
        // ★ 2026-10-15：后台保活开关 + 转录队列状态。
        //
        // 文案口径：**别写"静音音频"**。用户不需要知道我们是怎么把进程顶住的，
        // 他要的判断是"切走之后还会不会继续"以及"会不会费电/出什么怪声"。
        static var backgroundKeepAlive: String { NSLocalizedString("asr.background_keep_alive", comment: "") }
        static var backgroundKeepAliveFooter: String { NSLocalizedString("asr.background_keep_alive_footer", comment: "") }
        static var queueTitle: String { NSLocalizedString("asr.queue_title", comment: "") }
        static func queueRunning(_ n: Int) -> String {
            String(format: NSLocalizedString("asr.queue_running", comment: ""), n)
        }
        static func queueWaiting(_ n: Int) -> String {
            String(format: NSLocalizedString("asr.queue_waiting", comment: ""), n)
        }
        static func queueStuck(_ n: Int) -> String {
            String(format: NSLocalizedString("asr.queue_stuck", comment: ""), n)
        }
        static func queueStuckDetail(_ name: String, _ attempts: Int, _ reason: String) -> String {
            String(format: NSLocalizedString("asr.queue_stuck_detail", comment: ""), name, attempts, reason)
        }
        static var azureSpeech: String { NSLocalizedString("asr.azure_speech", comment: "") }
        static var azurePurposeFooter: String { NSLocalizedString("asr.azure_purpose_footer", comment: "") }
        static var azureHowToGetKey: String { NSLocalizedString("asr.azure_how_to_get_key", comment: "") }
        static var localASRServer: String { NSLocalizedString("asr.local_server", comment: "") }
        static var subscriptionKey: String { NSLocalizedString("asr.subscription_key", comment: "") }
        static var region: String { NSLocalizedString("asr.region", comment: "") }
        static var host: String { NSLocalizedString("asr.host", comment: "") }
        static var port: String { NSLocalizedString("asr.port", comment: "") }
        static var noProvider: String { NSLocalizedString("asr.no_provider", comment: "") }
        static var noProviderMessage: String { NSLocalizedString("asr.no_provider_message", comment: "") }
        static var azure: String { NSLocalizedString("asr.azure", comment: "") }
        static var localServer: String { NSLocalizedString("asr.local_server_label", comment: "") }
        static var transcriptEmpty: String { NSLocalizedString("asr.transcript_empty", value: "No speech detected in this clip, so there's nothing to transcribe. Try a longer or clearer recording.", comment: "Friendly message when the ASR provider returns an empty transcript") }
        static var transcribeAuto: String { NSLocalizedString("asr.transcribe_auto", comment: "") }
        static var specifyLanguages: String { NSLocalizedString("asr.specify_languages", comment: "") }
        static var languagesFooter: String { NSLocalizedString("asr.languages_footer", comment: "") }
        static func maxLanguagesHint(_ max: Int) -> String {
            String(format: NSLocalizedString("asr.max_languages_hint", comment: ""), max)
        }
        static var multiLanguageWarning: String { NSLocalizedString("asr.multi_language_warning", comment: "") }
        /// Field-level validation for the Azure section. Shown next to the
        /// offending field instead of the provider's English error text, so
        /// the user knows which box to fill in (32i8pce).
        static var keyRequired: String { NSLocalizedString(
            "asr.key_required",
            value: "Enter your subscription key",
            comment: "Inline error under the Azure subscription-key field when it is empty"
        ) }
        static var regionRequired: String { NSLocalizedString(
            "asr.region_required",
            value: "Enter the service region",
            comment: "Inline error under the Azure region field when it is empty"
        ) }
        static var verifyFailed: String { NSLocalizedString(
            "asr.verify_failed",
            value: "Verification failed",
            comment: "Fallback message when provider verification fails without a usable reason"
        ) }
        /// Saved / verified are different states: the page auto-saves, but only
        /// a passing verification means the credentials actually work.
        static var lastVerifyFailed: String { NSLocalizedString("asr.last_verify_failed", comment: "") }
        static var statusVerified: String { NSLocalizedString("asr.status_verified", comment: "") }
        static var statusVerifying: String { NSLocalizedString("asr.status_verifying", comment: "") }
        static var statusUnverified: String { NSLocalizedString("asr.status_unverified", comment: "") }
        static var autosaveNote: String { NSLocalizedString("asr.autosave_note", comment: "") }
        static var leaveTitle: String { NSLocalizedString("asr.leave_title", comment: "") }
        static var leaveAnyway: String { NSLocalizedString("asr.leave_anyway", comment: "") }
        static var leaveIncompleteMessage: String { NSLocalizedString("asr.leave_incomplete_message", comment: "") }
        static var leaveUnverifiedMessage: String { NSLocalizedString("asr.leave_unverified_message", comment: "") }
        static var hostRequired: String { NSLocalizedString("asr.host_required", comment: "") }
        static var portInvalid: String { NSLocalizedString("asr.port_invalid", comment: "") }

        // Local server connectivity test (2026-10-13)
        //
        // Why this set: having the correct host/port doesn't mean the service is actually running — if the service isn't started,
        // the port is wrong, or the phone and server are on different subnets, none of these issues are detectable
        // before actual transcription. The English fallback is in `value:`; languages missing the translation will fall back to English instead of showing the key.
        static var localProbe: String { NSLocalizedString(
            "asr.local_probe",
            value: "Test connection",
            comment: "Row label: probes the local ASR server for reachability"
        ) }
        static var localProbeFooter: String { NSLocalizedString(
            "asr.local_probe_footer",
            value: "The app uses two ports on your server: this one for live streaming, and the one right after it for file transcription. Tap the check button to confirm both are answering.",
            comment: "Footer under the local ASR server section explaining the two-port probe"
        ) }
        static var localProbeNoHost: String { NSLocalizedString(
            "asr.local_probe_no_host",
            value: "Enter the host and port first",
            comment: "Probe result when host/port are still empty"
        ) }
        static func localProbeReachable(_ detail: String) -> String {
            String(format: NSLocalizedString(
                "asr.local_probe_reachable",
                value: "Reachable · %@",
                comment: "Probe succeeded; %@ is model / precision / threads / latency"
            ), detail)
        }
        static var localProbeTimeout: String { NSLocalizedString(
            "asr.local_probe_timeout",
            value: "Timed out — make sure the phone and the server are on the same network",
            comment: "Probe failure: connect timed out"
        ) }
        static var localProbeRefused: String { NSLocalizedString(
            "asr.local_probe_refused",
            value: "Connection refused — the server isn't running, or the port is wrong",
            comment: "Probe failure: nothing listening on that port"
        ) }
        static var localProbeBadHost: String { NSLocalizedString(
            "asr.local_probe_bad_host",
            value: "Can't resolve that host name",
            comment: "Probe failure: DNS lookup failed"
        ) }
        static var localProbeOffline: String { NSLocalizedString(
            "asr.local_probe_offline",
            value: "Network unreachable — check the address and your Wi-Fi",
            comment: "Probe failure: no usable network path"
        ) }
        static var localProbeModelLoading: String { NSLocalizedString(
            "asr.local_probe_model_loading",
            value: "model loading",
            comment: "Server reported model_state != ready, so the first transcription will be slow"
        ) }
        static func localProbeThreads(_ count: Int) -> String {
            String(format: NSLocalizedString(
                "asr.local_probe_threads",
                value: "%d threads",
                comment: "CPU thread count the server is using"
            ), count)
        }
        static func localProbeWarnBatch(_ port: Int) -> String {
            String(format: NSLocalizedString(
                "asr.local_probe_warn_batch",
                value: "⚠️ Batch port %d isn't answering — file transcription will fail",
                comment: "The live port answered but port+1 (file transcription) did not"
            ), port)
        }
        static func localProbeWarnLive(_ port: Int) -> String {
            String(format: NSLocalizedString(
                "asr.local_probe_warn_live",
                value: "⚠️ Streaming port %d isn't answering — live transcription will fail",
                comment: "The batch port answered but the live WebSocket port did not"
            ), port)
        }
    }

    // MARK: - LLM

    enum LLM {
        // MARK: 调用失败的原因（★ 2026-10-15）
        //
        // 原来这些是**英文硬编码在 `LLMCompletionError.errorDescription` 里**的，
        // 中文界面上弹出一句 "No API key configured for the active provider." ——
        // 用户既看不懂，也指不出该去哪儿补。现在全部走本地化，并且
        // **带上通道名**："Open Router 没有配置 API Key。"
        static var errorNoProvider: String {
            NSLocalizedString("llm.error.no_provider", value: "No LLM provider is selected.",
                              comment: "LLM error: no provider chosen")
        }
        static func errorNoModel(_ label: String) -> String {
            String(format: NSLocalizedString("llm.error.no_model", value: "%@ has no model selected.",
                                             comment: "LLM error: provider selected but no model"), label)
        }
        static func errorNoAPIKey(_ label: String) -> String {
            String(format: NSLocalizedString("llm.error.no_api_key", value: "%@ has no API key configured.",
                                             comment: "LLM error: cloud provider without a key"), label)
        }
        static func errorNoEndpoint(_ label: String) -> String {
            String(format: NSLocalizedString("llm.error.no_endpoint", value: "%@ has no endpoint URL.",
                                             comment: "LLM error: self-hosted provider without an endpoint"), label)
        }
        static func errorHTTP(_ code: Int, _ message: String) -> String {
            let trimmed = message.count > 400 ? String(message.prefix(400)) + "…" : message
            return String(format: NSLocalizedString("llm.error.http", value: "HTTP %d: %@",
                                                    comment: "LLM error: non-2xx response"), code, trimmed)
        }
        static func errorDecoding(_ message: String) -> String {
            String(format: NSLocalizedString("llm.error.decoding", value: "Couldn't read the response: %@",
                                             comment: "LLM error: response body did not match the expected shape"), message)
        }
        static var errorEmptyResponse: String {
            NSLocalizedString("llm.error.empty", value: "The model returned nothing.",
                              comment: "LLM error: 200 OK but empty text")
        }
        /// 整条链都失败了。**每个通道的原因都要列出来** —— 只报最后一条会
        /// 让用户去查兜底通道（本机 Ollama），而真凶是第一通道没配 Key。
        static func errorAllProvidersFailed(_ detail: String) -> String {
            String(format: NSLocalizedString("llm.error.all_failed",
                                             value: "Every LLM provider failed:\n%@",
                                             comment: "LLM error: the whole fallback chain failed; detail is one line per provider"),
                   detail)
        }
        static var errorBadEndpointURL: String {
            NSLocalizedString("llm.error.bad_url", value: "The endpoint URL isn't valid.",
                              comment: "LLM error: URL(string:) refused the endpoint")
        }
        static var errorMissingChoices: String {
            NSLocalizedString("llm.error.missing_choices", value: "The response has no choices[0].message.content.",
                              comment: "LLM error: OpenAI-compatible body shape mismatch")
        }
        static var errorMissingContent: String {
            NSLocalizedString("llm.error.missing_content", value: "The response has no content[].",
                              comment: "LLM error: Anthropic body shape mismatch")
        }
        static var errorMissingCandidates: String {
            NSLocalizedString("llm.error.missing_candidates", value: "The response has no candidates[0].content.parts.",
                              comment: "LLM error: Gemini body shape mismatch")
        }
        /// 主通道挂了、兜底顶上之后给用户的一行说明。**必须说**：
        /// 用户设的是 A，结果 B 在干活，不说明就成了"它到底用没用我的配置"。
        static func fellBack(_ primary: String, _ used: String) -> String {
            String(format: NSLocalizedString("llm.fell_back",
                                             value: "%@ wasn't usable — this result came from %@.",
                                             comment: "Notice: the primary LLM provider failed and a fallback produced the result"),
                   primary, used)
        }
        /// 长转录走了"分段 → 合并"。
        static func chunkedNote(_ count: Int) -> String {
            String(format: NSLocalizedString("llm.chunked_note",
                                             value: "Long transcript — processed in %d parts and merged.",
                                             comment: "Notice: the transcript was too long for one request"), count)
        }
        /// 一键把兜底通道扶正成主通道的按钮文案。
        ///
        /// ★ 2026-10-15：体检只"说一句"是不够的。实测到的根因是
        /// `primary = openRouter` 而那段没有 `api_key` —— 用户想用的其实是
        /// 本机 Ollama，正确的修法只有一条，让他自己去翻四个页面找一个下拉框
        /// 纯粹是折腾。
        static func adoptAsPrimary(_ provider: String) -> String {
            String(format: NSLocalizedString("llm.adopt_as_primary",
                                             value: "Use %@ as the primary provider",
                                             comment: "Button: switch the primary LLM provider to the given one, which is already configured"),
                   provider)
        }
        /// Picker 里那个"当前是它、但它没配全"的条目。
        static func unconfigured(_ provider: String) -> String {
            String(format: NSLocalizedString("llm.unconfigured",
                                             value: "%@ (not configured)",
                                             comment: "Picker entry: this is the current primary provider but it lacks credentials/endpoint"),
                   provider)
        }

        static var activeProviderFooter: String { NSLocalizedString("llm.active_provider_footer", comment: "") }
        static var apiKey: String { NSLocalizedString("llm.api_key", comment: "") }
        static var model: String { NSLocalizedString("llm.model", comment: "") }
        static var selectModel: String { NSLocalizedString("llm.select_model", comment: "") }
        static func modelPlaceholder(_ example: String) -> String {
            String(format: NSLocalizedString("llm.model_placeholder", comment: ""), example)
        }
        static var endpointURL: String { NSLocalizedString("llm.endpoint_url", comment: "") }
        /// The guide text on the right side of the row while the model list is still loading. **Clicking this row will automatically fetch the models.**
        ///
        /// Source (user quote from 2026-10-14):
        /// > "When entering the endpoint URL, clicking should automatically pop up the model selection list instead of manually typing the model name."
        ///
        /// So the default behavior is "tap to show the list"; manual entry only appears **when the list cannot be retrieved**.
        static var tapToLoadModels: String { NSLocalizedString("llm.tap_to_load_models", comment: "") }
        /// The accessibility label for the "Refresh List" button in manual mode.
        static var loadModelList: String { NSLocalizedString("llm.load_model_list", comment: "") }
        /// The endpoint is still empty. **Not** a validation failure — the user hasn't started filling it in yet, so don't scare them.
        static var noEndpoint: String { NSLocalizedString("llm.no_endpoint", comment: "") }
        /// Endpoint is set but the hostname is not visible (usually because `http://` was omitted).
        static var badEndpoint: String { NSLocalizedString("llm.bad_endpoint", comment: "") }
        /// Connected, but the server has no models. Must be distinct from "Fetch failed" —
        /// otherwise users will keep checking the network, while the issue is actually on the server.
        static var noModelsOnServer: String { NSLocalizedString("llm.no_models_on_server", comment: "") }
        /// Supplement to the system message when a fetch fails. The system message (e.g., "The Internet connection appears to be offline.") is not helpful for local endpoints; the two most likely causes are covered here.
        /// 
        static var fetchFailedHint: String { NSLocalizedString("llm.fetch_failed_hint", comment: "") }
        /// "Tap" prefix for the connectivity result. Same wording as `ASR.localProbeReachable` —
        /// The "Test" buttons on both settings pages should look and read the same.
        ///
        /// Source (user quote from 2026-10-14):
        /// > "When clicking 'ollama test', the model list appeared. Clicking should also perform a connectivity test."
        ///
        /// A tap isn't just about "getting the list"; it also **reports who the counterpart is and how fast they respond**.
        static func probeReachable(_ detail: String) -> String {
            String(format: NSLocalizedString("llm.probe_reachable", comment: ""), detail)
        }
        /// How many models the server has. The number must be localized -- it cannot be hardcoded as `"\(n) models"`,
        /// since the Chinese measure word and the English plural s both have to follow the language.
        static func probeModelCount(_ count: Int) -> String {
            String(format: NSLocalizedString("llm.probe_model_count", comment: ""), count)
        }
        static func providerPlaceholder(_ example: String) -> String {
            String(format: NSLocalizedString("llm.provider_placeholder", comment: ""), example)
        }
        static var apiKeyOptional: String { NSLocalizedString("llm.api_key_optional", comment: "") }
        static var noProvider: String { NSLocalizedString("llm.no_provider", comment: "") }
        static var noProviderMessage: String { NSLocalizedString("llm.no_provider_message", comment: "") }
    }

    // MARK: - Azure Setup Guide

    enum AzureGuide {
        static var title: String { NSLocalizedString("azure_guide.title", comment: "") }
        static func step(_ number: Int, _ name: String) -> String {
            String(format: NSLocalizedString("azure_guide.step", comment: ""), number, name)
        }
        static var step1Title: String { NSLocalizedString("azure_guide.step1_title", comment: "") }
        static var step1Item1: String { NSLocalizedString("azure_guide.step1_item1", comment: "") }
        static var step1Item2: String { NSLocalizedString("azure_guide.step1_item2", comment: "") }
        static var step2Title: String { NSLocalizedString("azure_guide.step2_title", comment: "") }
        static var step2Item1: String { NSLocalizedString("azure_guide.step2_item1", comment: "") }
        static var step2Item2: String { NSLocalizedString("azure_guide.step2_item2", comment: "") }
        static var step2Item3: String { NSLocalizedString("azure_guide.step2_item3", comment: "") }
        static var step2Item4: String { NSLocalizedString("azure_guide.step2_item4", comment: "") }
        static var step2Item5: String { NSLocalizedString("azure_guide.step2_item5", comment: "") }
        static var step2Item6: String { NSLocalizedString("azure_guide.step2_item6", comment: "") }
        static var step3Title: String { NSLocalizedString("azure_guide.step3_title", comment: "") }
        static var step3Item1: String { NSLocalizedString("azure_guide.step3_item1", comment: "") }
        static var step3Item2: String { NSLocalizedString("azure_guide.step3_item2", comment: "") }
        static var step3Item3: String { NSLocalizedString("azure_guide.step3_item3", comment: "") }
        static var freeTierTitle: String { NSLocalizedString("azure_guide.free_tier_title", comment: "") }
        static var fastTranscription: String { NSLocalizedString("azure_guide.fast_transcription", comment: "") }
        static var fastTranscriptionValue: String { NSLocalizedString("azure_guide.fast_transcription_value", comment: "") }
        static var realtimeTranscription: String { NSLocalizedString("azure_guide.realtime_transcription", comment: "") }
        static var realtimeTranscriptionValue: String { NSLocalizedString("azure_guide.realtime_transcription_value", comment: "") }
        static var speakerDiarization: String { NSLocalizedString("azure_guide.speaker_diarization", comment: "") }
        static var speakerDiarizationValue: String { NSLocalizedString("azure_guide.speaker_diarization_value", comment: "") }
        static var audioFormats: String { NSLocalizedString("azure_guide.audio_formats", comment: "") }
        static var audioFormatsValue: String { NSLocalizedString("azure_guide.audio_formats_value", comment: "") }
    }

    // MARK: - Recordings Settings

    enum RecordingsSettings {
        static var deleteAfterTransfer: String { NSLocalizedString("rec_settings.delete_after_transfer", comment: "") }
        static var deleteAfterTransferFooter: String { NSLocalizedString("rec_settings.delete_after_transfer_footer", comment: "") }
        static var decryption: String { NSLocalizedString("rec_settings.decryption", comment: "") }
        static var chachaKey: String { NSLocalizedString("rec_settings.chacha_key", comment: "") }
        static var chachaKeyFooter: String { NSLocalizedString("rec_settings.chacha_key_footer", comment: "") }
        static var wifiAP: String { NSLocalizedString("rec_settings.wifi_ap", comment: "") }
        static var ssid: String { NSLocalizedString("rec_settings.ssid", comment: "") }
        static var password: String { NSLocalizedString("rec_settings.password", comment: "") }
        static var wifiCredentialsFooter: String { NSLocalizedString("rec_settings.wifi_credentials_footer", comment: "") }
        static var wifiGenerated: String { NSLocalizedString("rec_settings.wifi_generated", comment: "") }
        static var wifiGeneratedMessage: String { NSLocalizedString("rec_settings.wifi_generated_message", comment: "") }
        static var fastTransferThreshold: String { NSLocalizedString("rec_settings.fast_transfer_threshold", comment: "") }
        static var fastTransferThresholdFooter: String { NSLocalizedString("rec_settings.fast_transfer_threshold_footer", comment: "") }
    }

    // MARK: - Devices & Library Settings

    enum DevicesLibrary {
        static var connection: String { NSLocalizedString("devices.connection", value: "Connection", comment: "Section header for connection behaviour settings") }
        static var autoReconnect: String { NSLocalizedString("devices.auto_reconnect", value: "Auto-Reconnect", comment: "Toggle: reconnect automatically after an unexpected disconnect") }
        static var autoReconnectFooter: String { NSLocalizedString("devices.auto_reconnect_footer", value: "When on, the app reconnects to your most recent device by itself after an unexpected disconnect — for example after the device is powered off and on again. When off, tap the connection pill at the top to reconnect manually.", comment: "Footer explaining both states of the auto-reconnect toggle") }
        static var knownDevices: String { NSLocalizedString("devices.known_devices", comment: "") }
        static var noDevicesYet: String { NSLocalizedString("devices.no_devices_yet", comment: "") }
        static func lastSeen(_ date: String) -> String {
            String(format: NSLocalizedString("devices.last_seen", comment: ""), date)
        }
        static var library: String { NSLocalizedString("devices.library", comment: "") }
        static var files: String { NSLocalizedString("devices.files", comment: "") }
        static var totalSize: String { NSLocalizedString("devices.total_size", comment: "") }
        static var libraryFooter: String { NSLocalizedString("devices.library_footer", comment: "") }
        static var dangerZone: String { NSLocalizedString("devices.danger_zone", comment: "") }
        static var clearAudio: String { NSLocalizedString("devices.clear_audio", comment: "") }
        static var clearAudioMessage: String { NSLocalizedString("devices.clear_audio_message", comment: "") }
        static var clearTranscripts: String { NSLocalizedString("devices.clear_transcripts", value: "Clear Transcripts", comment: "Bulk delete: transcripts only") }
        static var clearTranscriptsMessage: String { NSLocalizedString("devices.clear_transcripts_message", value: "Deletes every transcript and its translation. Audio and summaries are kept. This can't be undone.", comment: "") }
        static var clearSummaries: String { NSLocalizedString("devices.clear_summaries", value: "Clear Summaries", comment: "Bulk delete: summaries only") }
        static var clearSummariesMessage: String { NSLocalizedString("devices.clear_summaries_message", value: "Deletes every summary and its translation. Audio and transcripts are kept. This can't be undone.", comment: "") }
        static var clearAllData: String { NSLocalizedString("devices.clear_all_data", comment: "") }
        static var clearAllDataMessage: String { NSLocalizedString("devices.clear_all_data_message", comment: "") }
        static var cleanupPartialTitle: String { NSLocalizedString("devices.cleanup_partial_title", value: "Some files couldn't be deleted", comment: "Alert title when cleanup partially failed") }
        static func cleanupPartialFailure(_ count: Int) -> String {
            String(format: NSLocalizedString("devices.cleanup_partial_message", value: "%d file(s) could not be removed and are still on this phone. Try again, or free up space and retry.", comment: "Alert body when cleanup partially failed"), count)
        }
    }

    // MARK: - Recordings Tab

    enum Recordings {
        static var device: String { NSLocalizedString("recordings.device", comment: "") }
        static var librarySegment: String { NSLocalizedString("recordings.library", comment: "") }
        static var noDeviceConnected: String { NSLocalizedString("recordings.no_device", comment: "") }
        static var noDeviceMessage: String { NSLocalizedString("recordings.no_device_message", comment: "") }
        static var noClipsYet: String { NSLocalizedString("recordings.no_clips", comment: "") }
        static var noClipsMessage: String { NSLocalizedString("recordings.no_clips_message", comment: "") }
        static func clipCount(_ count: Int, _ size: String) -> String {
            let format = count == 1
                ? NSLocalizedString("recordings.clip_count_one", comment: "")
                : NSLocalizedString("recordings.clip_count_other", comment: "")
            return String(format: format, count, size)
        }
    }

    // MARK: - Library

    enum Library {
        static var importAudio: String { NSLocalizedString("library.import_audio", comment: "") }
        static var importConfirmTitle: String { NSLocalizedString("library.import_confirm_title", comment: "") }
        static var importConfirmMessage: String { NSLocalizedString("library.import_confirm_message", comment: "") }
        static var importChooseFile: String { NSLocalizedString("library.import_choose_file", comment: "") }
        static var importFailed: String { NSLocalizedString("library.import_failed", comment: "") }
        static var merge: String { NSLocalizedString("library.merge", comment: "") }
        static var merging: String { NSLocalizedString("library.merging", comment: "") }
        static var mergeFailed: String { NSLocalizedString("library.merge_failed", comment: "") }
        static var mergeConfirmTitle: String { NSLocalizedString("library.merge_confirm_title", comment: "") }
        static func mergeConfirmMessage(_ older: String, _ newer: String) -> String {
            String(format: NSLocalizedString("library.merge_confirm_message", comment: ""), older, newer)
        }
        static let recordedOnWatch = NSLocalizedString("library.recorded_on_watch", comment: "")

        // MARK: 多选 / 批量操作 / 知识库检索
        //
        // ★ 2026-10-15：用户要求"资料库支持长按选择，可以批量导出或删除；
        // 再增加一个已经转录成文本或已生成摘要的知识库检索"。
        //
        // ⚠️ 同下面的来源标识：一律 `static var`（运行时切语言）+ `value:` 内联
        // 英文兜底（.lproj 只补 en / zh-Hans，其余 9 个语言靠它挡住
        // key 字面量漏到界面上）。
        /// 进入多选模式的那颗按钮。
        static var select: String {
            NSLocalizedString("library.select", value: "Select", comment: "Toolbar button: enter multi-select")
        }
        static var selectAll: String {
            NSLocalizedString("library.select_all", value: "Select All", comment: "Multi-select: select every clip")
        }
        static var deselectAll: String {
            NSLocalizedString("library.deselect_all", value: "Deselect All", comment: "Multi-select: clear the selection")
        }
        /// ★ 2026-10-15 七改：全选按钮带上条数。
        ///
        /// 用户原话里有"全部勾选不方便人选择"。原来的按钮只说"全选"，用户点之前
        /// 不知道会勾上多少条（筛过设备、搜过词之后尤其没底）；点完才在下面看到
        /// "已选 12 条"。把数字搬到按钮上，"会选几条"一眼可见。
        static func selectAllWithCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString("library.select_all_count", value: "Select All (%d)",
                                           comment: "Multi-select: select all, with how many clips that covers"),
                count
            )
        }
        static func selectedCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "library.selected_count", value: "%d selected",
                    comment: "Multi-select: how many clips are ticked"
                ),
                count
            )
        }
        static var export: String {
            NSLocalizedString("library.export", value: "Export", comment: "Multi-select: export the ticked clips")
        }
        static var exportPreparing: String {
            NSLocalizedString("library.export_preparing", value: "Preparing export…",
                              comment: "Shown while staging files for the share sheet")
        }
        static var exportFailed: String {
            NSLocalizedString("library.export_failed", value: "Export Failed", comment: "")
        }
        /// 全选之后什么都没能拷出来（选中的文件刚好都消失了）。正常碰不到，
        /// 但**必须有**一句文案：否则这个分支会拿着"导出失败"当**正文**弹出来。
        static var exportEmpty: String {
            NSLocalizedString("library.export_empty", value: "Nothing to export.",
                              comment: "Bulk export produced no files at all")
        }
        // ★ 2026-10-15 六改：导出已就绪（后台导完、等着分享）那一条横幅。
        //
        // 文案刻意**不提"后台"** —— 用户不需要知道我们是靠静音音频把进程顶住的，
        // 他要的确认只有两件："上次那批好了没有"和"我现在点什么能把它发出去"。
        static var exportReady: String {
            NSLocalizedString("library.export_ready", value: "Your last export is ready",
                              comment: "Banner: a previously started export finished and is waiting to be shared")
        }
        static func exportReadyTitle(_ count: Int) -> String {
            String(
                format: NSLocalizedString("library.export_ready_title", value: "%d clips",
                                          comment: "Name given to a staged export: how many clips it contains"),
                count
            )
        }
        static func exportReadyFiles(_ count: Int) -> String {
            String(
                format: NSLocalizedString("library.export_ready_files", value: "%d files",
                                          comment: "How many files the staged export contains"),
                count
            )
        }
        static var exportReadyFooter: String {
            NSLocalizedString(
                "library.export_ready_footer",
                value: "The files are already on this phone — tap the row to share them. Starting a new export replaces this copy, and it's cleaned up automatically after 3 days.",
                comment: "Footer explaining the staged-export banner"
            )
        }
        static var clearExportStaging: String {
            NSLocalizedString("library.clear_export_staging", value: "Delete exported files",
                              comment: "Button: discard the staged export copies to free up space")
        }
        static var deleteSelectedTitle: String {
            NSLocalizedString("library.delete_selected_title", value: "Delete Selected Clips?",
                              comment: "Confirmation title for bulk delete")
        }
        static func deleteSelectedMessage(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "library.delete_selected_message",
                    value: "Audio, transcript and summary for %d clip(s) move to Recently Deleted. You can recover them for 30 days.",
                    comment: "Confirmation body for bulk delete"
                ),
                count
            )
        }
        static var deleting: String {
            NSLocalizedString("library.deleting", value: "Deleting…", comment: "Bulk delete in progress")
        }
        static var deleteFailed: String {
            NSLocalizedString("library.delete_failed", value: "Delete Failed", comment: "")
        }
        /// 搜索框里的提示。刻意不写"搜索"两个字 —— 提示词要说清**搜的是什么范围**。
        static var searchPrompt: String {
            NSLocalizedString("library.search_prompt", value: "Transcripts & summaries",
                              comment: "Search field placeholder — says what is searched, not just 'Search'")
        }
        static var searchScopeKnowledge: String {
            NSLocalizedString("library.search_scope_knowledge", value: "Knowledge",
                              comment: "Search scope: only clips that have a transcript or summary")
        }
        static var searchScopeAll: String {
            NSLocalizedString("library.search_scope_all", value: "All",
                              comment: "Search scope: titles/filenames as well")
        }
        static var searchEmptyTitle: String {
            NSLocalizedString("library.search_empty_title", value: "No Matches", comment: "")
        }
        static var searchEmptyMessage: String {
            NSLocalizedString(
                "library.search_empty_message",
                value: "No clip's transcript or summary contains that. Switch to All to search titles too.",
                comment: "Empty state body for the knowledge search"
            )
        }
        /// 列表行上"已生成摘要"那枚徽标的无障碍读法。
        static var hasSummary: String {
            NSLocalizedString("library.has_summary", value: "Summary", comment: "Badge: clip has a generated summary")
        }
        /// 列表行上"已有转录"那枚徽标的无障碍读法。
        ///
        /// ★ 2026-10-15 补：那颗绿气泡徽标一直在，但从来没挂过 label ——
        /// VoiceOver 读到它只是一句"image"，等于没读。加了摘要徽标之后
        /// 两颗并排出现，缺一个更显眼。
        static var hasTranscript: String {
            NSLocalizedString("library.has_transcript", value: "Transcript",
                              comment: "Badge: clip has a transcript")
        }

        // MARK: 未读红点 / 按时间与设备归类（★ 2026-10-15 第二轮）
        //
        // 同样一律 `static var` + `value:` 内联英文兜底，理由见上面来源标识那段。
        /// 未读红点的无障碍读法。
        static var unread: String {
            NSLocalizedString("library.unread", value: "Unread",
                              comment: "Accessibility label for the unread dot on a library row")
        }
        /// 分节头上"这台设备还有几条没打开"。
        static func unreadCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "library.unread_count", value: "%d unread",
                    comment: "Section header: how many clips on this device are still unopened"
                ),
                count
            )
        }
        /// 工具栏里那个设备筛选菜单的无障碍读法 / 菜单标题。
        static var filterDevices: String {
            NSLocalizedString("library.filter_devices", value: "Filter by device",
                              comment: "Toolbar menu: restrict the list to one device")
        }
        static var filterAllDevices: String {
            NSLocalizedString("library.filter_all_devices", value: "All devices", comment: "")
        }
        /// 短计数（"12 条" / "12 clips"），给分节头和筛选菜单用。
        ///
        /// 为什么不复用 `Recordings.clipCount(count, size)`：那个是"12 条录音 · 25 GB"，
        /// 放在分节头里太长；而且大小在这两处是分开拼的（分节头要算**桶总数**，
        /// 菜单要算**设备总数**，两者都不等于单个分节的合计）。
        static func shortCount(_ count: Int) -> String {
            let format = count == 1
                ? NSLocalizedString("library.short_count_one", value: "%d clip",
                                    comment: "Short clip count, singular")
                : NSLocalizedString("library.short_count_other", value: "%d clips",
                                    comment: "Short clip count, plural")
            return String(format: format, count)
        }
        // MARK: 时间分节的标题
        //
        // 更早的月份**不在这里** —— 那要 12 个语言的本地化月名，直接用
        // `DateFormatter` 的模板化格式（`setLocalizedDateFormatFromTemplate("yMMMM")`）
        // 让系统按区域拼，语序和用词都不会错。
        static var bucketToday: String {
            NSLocalizedString("library.bucket_today", value: "Today", comment: "Time section header")
        }
        static var bucketYesterday: String {
            NSLocalizedString("library.bucket_yesterday", value: "Yesterday", comment: "Time section header")
        }
        static var bucketThisWeek: String {
            NSLocalizedString("library.bucket_this_week", value: "This week", comment: "Time section header")
        }
        static var bucketThisMonth: String {
            NSLocalizedString("library.bucket_this_month", value: "This month", comment: "Time section header")
        }

        // MARK: 来源标识 —— 列表里"这条是谁录的"
        //
        // ⚠️ Always use `static var` instead of `static let`: this file supports **runtime language switching**
        // (see the comment in the `Watch` section — `static let` permanently caches the first language).
        // `recordedOnWatch` is a legacy `static let`; do not copy it.
        //
        // ⚠️ All include an inline English `value:` fallback: `.lproj` only has entries for en / zh-Hans,
        // so for the other 9 languages the bundle won't find the key and will **fall back to the key literal** (on the UI
        // this would show up as something like "library.source_card"). The inline value prevents this fallback,
        // and makes adding only en + zh-Hans a safe incremental change.
        /// Fallback name for the recorder card. It gets overridden when a user alias or card name is available.
        static var sourceCard: String {
            NSLocalizedString(
                "library.source_card",
                value: "Recorder card",
                comment: "Fallback unit name for a card recording when the device has no readable name"
            )
        }
        /// Apple Watch (proper noun, do not translate).
        static var sourceWatch: String {
            NSLocalizedString(
                "library.source_watch",
                value: "Apple Watch",
                comment: "Short chip label for a recording that came from the watch"
            )
        }
        /// Segments left by real-time transcription on this device.
        static var sourcePhone: String {
            NSLocalizedString(
                "library.source_phone",
                value: "This iPhone",
                comment: "Short chip label for a live-transcription clip saved on the phone"
            )
        }
        /// Files imported by the user.
        static var sourceImported: String {
            NSLocalizedString(
                "library.source_imported",
                value: "Imported",
                comment: "Short chip label for an audio file the user imported"
            )
        }
        /// Accessibility label for the source identifier, e.g., "Source: TicNote-3N9H".
        static func sourceAccessibility(_ source: String) -> String {
            String(
                format: NSLocalizedString(
                    "library.source_accessibility",
                    value: "Source: %@",
                    comment: "VoiceOver label for the per-clip source badge"
                ),
                source
            )
        }
    }

    // MARK: - 回收站
    //
    // ★ 2026-10-15：用户要求"在设置里面增加一个回收站的功能防止误删，
    // 30 天的保护期，30 天后自动删除"。放在手机 App 的设置里 ——
    // 删除动作本来就发生在手机上（资料库多选删、详情页删），只有放这儿
    // 才盖得住所有入口。
    //
    // ⚠️ 同样一律 `static var` + `value:` 内联英文兜底。
    enum Trash {
        /// 设置页里那一行的标题，也是回收站页的导航标题。
        static var title: String {
            NSLocalizedString("trash.title", value: "Recently Deleted",
                              comment: "Settings row + page title for the recycle bin")
        }
        /// 设置页那行标题。跟 `title` 分开是为了让中文能写全"回收站"，
        /// 而页面标题也能长一点 —— 目前两者同值，留着这个口子。
        static var settingsRow: String {
            NSLocalizedString("trash.settings_row", value: "Recently Deleted", comment: "")
        }
        static var emptyTitle: String {
            NSLocalizedString("trash.empty_title", value: "Nothing Deleted", comment: "")
        }
        static var emptyMessage: String {
            NSLocalizedString("trash.empty_message",
                              value: "Recordings you delete are kept here first.",
                              comment: "Empty state for the recycle bin")
        }
        /// 页面底部的保护期说明。
        static func retentionFooter(_ days: Int) -> String {
            String(
                format: NSLocalizedString(
                    "trash.retention_footer",
                    value: "Items are kept for %d days, then deleted automatically.",
                    comment: "Recycle bin footer explaining the retention window"
                ),
                days
            )
        }
        /// 每条上的"还剩几天"。
        static func daysLeft(_ days: Int) -> String {
            String(
                format: NSLocalizedString("trash.days_left", value: "%d days left",
                                          comment: "Recycle bin row: time before auto-delete"),
                days
            )
        }
        /// "删除于"（后面跟日期）。
        static var deletedOn: String {
            NSLocalizedString("trash.deleted_on", value: "Deleted",
                              comment: "Prefix before the deletion date on a trash row")
        }
        static var restore: String {
            NSLocalizedString("trash.restore", value: "Recover", comment: "Swipe action")
        }
        static var deleteForever: String {
            NSLocalizedString("trash.delete_forever", value: "Delete Now",
                              comment: "Swipe action: remove from the recycle bin for good")
        }
        static var deleteForeverTitle: String {
            NSLocalizedString("trash.delete_forever_title", value: "Delete Now?",
                              comment: "Confirmation title for permanently deleting one item")
        }
        static var deleteForeverMessage: String {
            NSLocalizedString("trash.delete_forever_message",
                              value: "This item will be removed for good. This can't be undone.",
                              comment: "Confirmation body for permanently deleting one item")
        }
        static var emptyAll: String {
            NSLocalizedString("trash.empty_all", value: "Delete All", comment: "")
        }
        static var emptyAllTitle: String {
            NSLocalizedString("trash.empty_all_title", value: "Empty Recently Deleted?",
                              comment: "")
        }
        static func emptyAllMessage(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "trash.empty_all_message",
                    value: "%d item(s) will be removed for good. This can't be undone.",
                    comment: "Confirmation body for emptying the whole recycle bin"
                ),
                count
            )
        }
        static var restoreFailedTitle: String {
            NSLocalizedString("trash.restore_failed_title", value: "Couldn't Recover", comment: "")
        }
        static var restoreFailedMessage: String {
            NSLocalizedString("trash.restore_failed_message",
                              value: "The files for this item are no longer in Recently Deleted.",
                              comment: "")
        }
        // 回收站每行上那几枚"里面有什么"的小标签。
        static var artefactAudio: String {
            NSLocalizedString("trash.artefact_audio", value: "Audio", comment: "")
        }
        static var artefactTranscript: String {
            NSLocalizedString("trash.artefact_transcript", value: "Transcript", comment: "")
        }
        static var artefactSummary: String {
            NSLocalizedString("trash.artefact_summary", value: "Summary", comment: "")
        }

        // MARK: 多选（★ 2026-10-16 十四改：用户"回收站支持多选全选选择恢复或者是删除"）
        //
        // ⚠️ 一律 `static var` + 带 `value:` 内联英文兜底（只补 en / zh-Hans 两份
        // .lproj，理由同 `Library.sourceCard`）。
        /// 工具栏里进/出多选模式的那个按钮。
        static var select: String {
            NSLocalizedString("trash.select", value: "Select", comment: "Trash toolbar: enter multi-select mode")
        }
        /// 多选模式下"全选 / 全不选"那颗按钮 —— 文案随状态切。
        static var selectAll: String {
            NSLocalizedString("trash.select_all", value: "Select All", comment: "Trash multi-select toolbar")
        }
        static var deselectAll: String {
            NSLocalizedString("trash.deselect_all", value: "Deselect All", comment: "Trash multi-select toolbar, shown when everything is already ticked")
        }
        /// 多选模式底部那颗"恢复"。
        static func restoreSelected(_ count: Int) -> String {
            String(format: NSLocalizedString("trash.restore_selected",
                                             value: "Recover %d",
                                             comment: "Trash multi-select bottom bar; %d is how many are ticked"),
                   count)
        }
        /// 多选模式底部那颗"删除"。
        static func deleteSelected(_ count: Int) -> String {
            String(format: NSLocalizedString("trash.delete_selected",
                                             value: "Delete %d",
                                             comment: "Trash multi-select bottom bar; %d is how many are ticked"),
                   count)
        }
        static var deleteSelectedTitle: String {
            NSLocalizedString("trash.delete_selected_title", value: "Delete for Good?",
                              comment: "Confirmation title for permanently deleting the ticked items")
        }
        static func deleteSelectedMessage(_ count: Int) -> String {
            String(format: NSLocalizedString("trash.delete_selected_message",
                                             value: "%d item(s) will be removed for good. This can't be undone.",
                                             comment: "Confirmation body; %d is how many are ticked"),
                   count)
        }
    }

    // MARK: - Apple Watch
    //
    // Also compiled into the watch target — see `project.yml`.

    enum Watch {
        static var recorderTitle: String { NSLocalizedString("watch.recorder_title", comment: "") }
        static var ready: String { NSLocalizedString("watch.ready", comment: "") }
        static var record: String { NSLocalizedString("watch.record", comment: "") }
        static var stop: String { NSLocalizedString("watch.stop", comment: "") }
        static var micDenied: String { NSLocalizedString("watch.mic_denied", comment: "") }
        static func recordFailed(_ reason: String) -> String {
            String(format: NSLocalizedString("watch.record_failed", comment: ""), reason)
        }
        static var pendingHeader: String { NSLocalizedString("watch.pending_header", comment: "") }
        static var sending: String { NSLocalizedString("watch.sending", comment: "") }
        static var waiting: String { NSLocalizedString("watch.waiting", comment: "") }
        /// 首页底部那条细提示上的"还有几条没传走"。
        ///
        /// ★ 2026-10-15 四改：待传列表从首页一列长列表收成底部一条，
        /// 详情点进独立一页（不然它会把圆环顶偏，见 `WatchRecorderView` 顶部）。
        /// 所以这里需要一个**带数字的短句**，`pendingHeader`（"待传输"）不行。
        static func pendingCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "watch.pending_count", value: "%d to send",
                    comment: "Watch home: compact pill at the bottom showing how many clips are still uploading"
                ),
                count
            )
        }
        /// 设置里的"摇一摇开始录音"开关。
        static var shakeToRecord: String {
            NSLocalizedString("watch.shake_to_record", value: "Shake to Record",
                              comment: "Watch settings: shake the wrist to start/stop recording")
        }
        /// 上面那个开关底下的一行说明。
        static var shakeToRecordHint: String {
            NSLocalizedString(
                "watch.shake_to_record_hint",
                value: "Shake your wrist to start, shake again to stop",
                comment: "Watch settings: explains the shake gesture"
            )
        }

        /// 设置里的"双指互点开/关录音"开关（watchOS 11+ 才显示）。
        ///
        /// ⚠️ 文案刻意写"食指与拇指捏合"而不是照搬 Apple 的 "Double Tap"：
        /// 用户点名要的就是这个动作，而中文里的"双击"会和"点屏幕两下"混淆 ——
        /// 这是**隔空**动作，不是触摸。Apple 自己的中文叫法也是"双指互点"。
        static var pinchToRecord: String {
            NSLocalizedString("watch.pinch_to_record", value: "Double Tap to Record",
                              comment: "Watch settings: pinch index finger and thumb to start/stop recording")
        }
        /// 上面那个开关底下的一行说明。
        static var pinchToRecordHint: String {
            NSLocalizedString(
                "watch.pinch_to_record_hint",
                value: "Tap index finger and thumb together to start, again to stop",
                comment: "Watch settings: explains the double-tap gesture"
            )
        }

        // MARK: 首页 Bot（★ 2026-10-16 七改）
        //
        // 首页正中从圆环按钮换成了一张会眨眼的 Bot 脸。用户原话：
        // "类似 Grok Bot 一样，两个眼睛……把当前首页的录音按钮去掉改成 bot 一样
        // 生动的，通过长按点击它的眼睛 2s 才开始录音"。
        //
        // ⚠️ `holdToRecord` 这行提示**不能省**。"长按 2 秒"是一个**隐形**的交互：
        //    没有它，第一次用的人只会戳一下、发现没反应、然后放弃。
        static var holdToRecord: String {
            NSLocalizedString("watch.hold_to_record", value: "Hold 2s to record",
                              comment: "Watch home: caption under the bot face, explains the long-press gesture")
        }
        /// 录音中给读屏软件念的一句（视觉上首页显示的是计时，没有字）。
        static var recordingBusy: String {
            NSLocalizedString("watch.recording_busy", value: "Recording",
                              comment: "Watch home: accessibility value while a take is running")
        }

        // MARK: 两侧滑动菜单 + 快捷菜单设置（★ 2026-10-16 七改）
        //
        // 用户原话："4 个菜单需要往左或者往右滑在出现……需要在手表的快捷录音的
        // 手表的菜单栏里面出现可以添加快捷的菜单设置，这个设置是在手表的 wifi
        // 那个菜单栏里面进行点击添加的组件"。
        /// 设置页里那一行，也是勾选页的标题。
        static var quickMenu: String {
            NSLocalizedString("watch.quick_menu", value: "Quick Menu",
                              comment: "Watch settings: which items show in the home screen's side menus")
        }
        static var quickMenuHint: String {
            NSLocalizedString("watch.quick_menu_hint", value: "Swipe left or right on the home screen",
                              comment: "Watch settings: subtitle explaining where these items appear")
        }
        /// 菜单页底部那个虚线入口。
        static var quickMenuAdd: String {
            NSLocalizedString("watch.quick_menu_add", value: "Add a shortcut",
                              comment: "Watch home: dashed entry at the bottom of a side menu")
        }
        /// 一侧菜单一项都没勾时的空态。
        static var quickMenuEmpty: String {
            NSLocalizedString("watch.quick_menu_empty", value: "No shortcuts here yet",
                              comment: "Watch home: a side menu with nothing enabled")
        }
        /// 勾选页底部说明。**必须讲清"勾完去哪看"** —— 勾完回首页是要往旁边滑
        /// 才看得到的，不讲这一句，用户会以为勾了没生效。
        static var quickMenuFooter: String {
            NSLocalizedString(
                "watch.quick_menu_footer",
                value: "Enabled items appear when you swipe left or right from the home screen.",
                comment: "Watch quick-menu settings: footer explaining where the items show up"
            )
        }
        /// 待传队列页的空态（这一页现在能从菜单直接进来，"空"是常态）。
        static var queueEmpty: String {
            NSLocalizedString("watch.queue_empty", value: "Nothing to send",
                              comment: "Watch queue page: empty state")
        }

        // 勾选页里每一行底下的小字。一句话说清"点进去能看到什么"。
        static var menuHintAppearance: String {
            NSLocalizedString("watch.menu_hint_appearance", value: "Colour, gradient and breathing",
                              comment: "Watch quick menu: what the Appearance page holds")
        }
        static var menuHintHistory: String {
            NSLocalizedString("watch.menu_hint_history", value: "Which recordings reached the phone",
                              comment: "Watch quick menu: what the Transfers page holds")
        }
        static var menuHintLanguage: String {
            NSLocalizedString("watch.menu_hint_language", value: "Language used on the watch",
                              comment: "Watch quick menu: what the Language page holds")
        }
        static var menuHintSettings: String {
            NSLocalizedString("watch.menu_hint_settings", value: "Gestures, version, reset",
                              comment: "Watch quick menu: what the Settings page holds")
        }
        static var menuHintQueue: String {
            NSLocalizedString("watch.menu_hint_queue", value: "Clips still waiting to upload",
                              comment: "Watch quick menu: what the queue page holds")
        }
        static var menuHintAbout: String {
            NSLocalizedString("watch.menu_hint_about", value: "Build number on the watch",
                              comment: "Watch quick menu: what the version page holds")
        }

        // MARK: Ring appearance (directly called on the watch face)
        //
        // ⚠️ 一律 `static var`（运行时切语言）+ 带 `value:` 内联英文兜底
        // （只补了 en / zh-Hans 两份 .lproj）。理由同 `Library.sourceCard`。
        /// 左上那一页的标题。它现在装的是**颜色 + 渐变 + 呼吸灯**三样，
        /// 所以叫"外观"而不是"颜色" —— 沿用旧名字会让用户以为呼吸灯被删了。
        ///
        /// ★ 2026-10-15 五改：原来的 `styleColor`（"颜色"）随呼吸灯并进来
        /// 一起改成了这个；`watch.style_color` 这个键已从两份 .strings 移除。
        static var styleAppearance: String {
            NSLocalizedString("watch.style_appearance", value: "Appearance",
                              comment: "Corner menu: colour + gradient + breathing, merged into one page")
        }
        /// The "Breathing" item in the menu.
        static var styleBreathing: String {
            NSLocalizedString("watch.style_breathing", value: "Breathing", comment: "Ring style menu: pulsing glow")
        }
        /// The "Reset to Default" item in the menu.
        static var styleReset: String {
            NSLocalizedString("watch.style_reset", value: "Reset", comment: "Ring style menu: restore the default look")
        }
        /// 角标里"设置"那一页的标题（版本 + 恢复默认）。
        static var menuSettings: String {
            NSLocalizedString("watch.menu_settings", value: "Settings", comment: "Corner menu: settings page title")
        }
        static var styleBreathingOff: String {
            NSLocalizedString("watch.style_breathing_off", value: "Off", comment: "Breathing speed: none")
        }
        static var styleBreathingSlow: String {
            NSLocalizedString("watch.style_breathing_slow", value: "Slow", comment: "Breathing speed: slow")
        }
        static var styleBreathingMedium: String {
            NSLocalizedString("watch.style_breathing_medium", value: "Medium", comment: "Breathing speed: medium")
        }
        static var styleBreathingFast: String {
            NSLocalizedString("watch.style_breathing_fast", value: "Fast", comment: "Breathing speed: fast")
        }

        // MARK: 传输记录（★ 2026-10-15 五改，右上角角标）
        //
        // 用户："右上角就是手表的传输记录"。四个状态各一个词，
        // 词要短 —— 表上一行只放得下十来个字。
        /// 右上角那一页的标题。
        static var transferHistory: String {
            NSLocalizedString("watch.transfer_history", value: "Transfers",
                              comment: "Corner menu: history of clips handed to the iPhone")
        }
        static var transferEmpty: String {
            NSLocalizedString("watch.transfer_empty", value: "No recordings sent yet",
                              comment: "Transfer history: empty state")
        }
        static var transferClear: String {
            NSLocalizedString("watch.transfer_clear", value: "Clear History",
                              comment: "Transfer history: toolbar button that empties the log")
        }
        /// 已交进 WatchConnectivity 队列，还没出门。
        static var transferQueued: String {
            NSLocalizedString("watch.transfer_queued", value: "Queued", comment: "Transfer state")
        }
        /// 系统已投给手机守护进程，但手机 App 还没确认写盘。
        static var transferDelivered: String {
            NSLocalizedString("watch.transfer_delivered", value: "Waiting", comment: "Transfer state: handed to the phone, not confirmed")
        }
        /// 手机 App 已确认入库 —— 只有到这一步，手表上的本地副本才会删掉。
        static var transferStored: String {
            NSLocalizedString("watch.transfer_stored", value: "Saved", comment: "Transfer state: confirmed written by the iPhone app")
        }
        static var transferFailed: String {
            NSLocalizedString("watch.transfer_failed", value: "Failed", comment: "Transfer state")
        }

        // These must remain computed: runtime language switching swaps the
        // bundle, while a static let would cache the first language forever.
        static var settingsTitle: String { NSLocalizedString("watch.settings_title", comment: "") }
        static var statusInstalled: String { NSLocalizedString("watch.status_installed", comment: "") }
        static var statusConnected: String { NSLocalizedString("watch.status_connected", comment: "") }
        static var statusNotInstalled: String { NSLocalizedString("watch.status_not_installed", comment: "") }
        static var statusNoWatch: String { NSLocalizedString("watch.status_no_watch", comment: "") }
        static var statusUnsupported: String { NSLocalizedString("watch.status_unsupported", comment: "") }
        static var statusChecking: String { NSLocalizedString("watch.status_checking", comment: "") }
        static var hintInstalled: String { NSLocalizedString("watch.hint_installed", comment: "") }
        static var hintNotInstalled: String { NSLocalizedString("watch.hint_not_installed", comment: "") }
        static var hintNoWatch: String { NSLocalizedString("watch.hint_no_watch", comment: "") }
        static var hintUnsupported: String { NSLocalizedString("watch.hint_unsupported", comment: "") }
        static var hintChecking: String { NSLocalizedString("watch.hint_checking", comment: "") }

        // Phone-side live status row on the Recordings tab.
        static var statusRecording: String { NSLocalizedString("watch.status_recording", comment: "") }
        static var statusTransferring: String { NSLocalizedString("watch.status_transferring", comment: "") }
        static var statusOutOfRange: String { NSLocalizedString("watch.status_out_of_range", comment: "") }
    }

    // MARK: - 手表首页表情（★ 2026-10-16 十三改）

    /// iPhone 设置里的那个表情选择器（"Apple Watch"那一区里的一行）。
    ///
    /// ## 为什么名字里不带颜色 / 主题
    /// 这一页选的**只有形状**（眼睛怎么弯、怎么斜、睁多大）。颜色是手表上
    /// "外观"那一页选的，跟这里无关 —— 手机根本不知道手表选了哪个颜色
    /// （那是手表本地偏好），所以这一页的预览一律用前景色画，不假装是
    /// 表上那个颜色。
    ///
    /// ⚠️ 一律 `static var`（运行时切语言）+ 带 `value:` 内联英文兜底
    /// （只补了 en / zh-Hans 两份 .lproj，理由同 `Library.sourceCard`）。
    enum Face {
        /// 设置页那一行的标题，也是选择器的页标题。
        static var title: String {
            NSLocalizedString("face.title", value: "Home Face",
                              comment: "Settings row + picker title: which expression the watch's home face wears")
        }
        /// 设置页那一行下面的说明。
        static var rowFooter: String {
            NSLocalizedString("face.row_footer", value: "Choose the expression the watch shows on its home screen.",
                              comment: "Settings row footer: what the home face setting does")
        }
        /// 选择器页底部的说明。
        static var footer: String {
            NSLocalizedString("face.footer", value: "The face still blinks and looks around on its own. Tap it on the watch to see another expression.",
                              comment: "Face picker footer: the chosen expression is the resting face, not the only one")
        }

        // 九档的名字。**短**，因为它们在表上和手机上都是列表行里的词。
        static var calm: String {
            NSLocalizedString("face.calm", value: "Calm", comment: "Watch face expression: the default, plain eyes")
        }
        static var happy: String {
            NSLocalizedString("face.happy", value: "Happy", comment: "Watch face expression: eyes curving up into a smile")
        }
        static var sad: String {
            NSLocalizedString("face.sad", value: "Sad", comment: "Watch face expression: eyes drooping downwards")
        }
        static var wide: String {
            NSLocalizedString("face.wide", value: "Wide", comment: "Watch face expression: eyes opened wide")
        }
        static var squint: String {
            NSLocalizedString("face.squint", value: "Squint", comment: "Watch face expression: eyes narrowed to a slit")
        }
        static var angry: String {
            NSLocalizedString("face.angry", value: "Angry", comment: "Watch face expression: eyes slanting inwards")
        }
        static var shy: String {
            NSLocalizedString("face.shy", value: "Shy", comment: "Watch face expression: flat, wide eyes tipped inwards")
        }
        static var listen: String {
            NSLocalizedString("face.listen", value: "Listening", comment: "Watch face expression: tall narrow eyes")
        }
        static var scan: String {
            NSLocalizedString("face.scan", value: "Scanning", comment: "Watch face expression: very narrow tall slits")
        }
    }

    // MARK: - Device Files

    enum DeviceFiles {
        static var deleteRecording: String { NSLocalizedString("device_files.delete_recording", comment: "") }
        static func deleteRecordingMessage(_ name: String) -> String {
            String(format: NSLocalizedString("device_files.delete_recording_message", comment: ""), name)
        }
        static var operationFailed: String { NSLocalizedString("device_files.operation_failed", comment: "") }
        static var readingFileList: String { NSLocalizedString("device_files.reading_file_list", comment: "") }
        static var deviceIsRecording: String { NSLocalizedString("device_files.device_is_recording", comment: "") }
        static var recordingUnavailableMessage: String { NSLocalizedString("device_files.recording_unavailable_message", comment: "") }
        static var stopRecording: String { NSLocalizedString("device_files.stop_recording", comment: "") }
        static var couldntReadDevice: String { NSLocalizedString("device_files.couldnt_read_device", comment: "") }
        static var noRecordingsOnDevice: String { NSLocalizedString("device_files.no_recordings", comment: "") }
        static var noRecordingsMessage: String { NSLocalizedString("device_files.no_recordings_message", comment: "") }
        static var fastTransferWifi: String { NSLocalizedString("device_files.fast_transfer_wifi", comment: "") }
        static func pending(_ size: String) -> String {
            String(format: NSLocalizedString("device_files.pending", comment: ""), size)
        }
        static var transcribing: String { NSLocalizedString("device_files.transcribing", comment: "") }
        static func transcriptDone(_ filename: String) -> String {
            String(format: NSLocalizedString("device_files.transcript_done", comment: ""), filename)
        }
        static var transferInProgress: String { NSLocalizedString("device_files.transfer_in_progress", comment: "") }
        static var cancelTransferToSwitch: String { NSLocalizedString("device_files.cancel_transfer_to_switch", comment: "") }
        static var cancelAndSwitch: String { NSLocalizedString("device_files.cancel_and_switch", comment: "") }
        static func downloadBeforeTranscribe(_ filename: String) -> String {
            String(
                format: NSLocalizedString(
                    "device_files.download_before_transcribe",
                    value: "Download and decrypt %@ before transcribing.",
                    comment: "Alert body when a device row is transcribed before its audio exists locally"
                ),
                filename
            )
        }
        static func transcribeFailed(_ filename: String, _ reason: String) -> String {
            String(
                format: NSLocalizedString(
                    "device_files.transcribe_failed",
                    value: "Couldn't transcribe %1$@: %2$@",
                    comment: "Alert body when transcription of a device recording fails"
                ),
                filename, reason
            )
        }
        static func deleteFailed(_ reason: String) -> String {
            String(
                format: NSLocalizedString(
                    "device_files.delete_failed",
                    value: "Couldn't delete the recording: %@",
                    comment: "Alert body when deleting a recording off the device fails"
                ),
                reason
            )
        }
    }

    // MARK: - TicNote Card (Recording Card Page)
    //
    // ⚠️ All entries here use `value:` to provide English defaults. Currently only en / zh-Hans
    //    .strings files are filled out; for other languages, missing keys fall back to the English here —— a pure improvement over the previous state where
    //    all languages displayed English, not a regression.
    //    (The risk of machine-translating eight languages is greater than leaving them in English: mistranslations go live and are invisible on the UI.)

    enum TicNoteCard {
        static var connecting: String {
            NSLocalizedString("ticnote.connecting", value: "Connecting…", comment: "")
        }
        /// The text shown during automatic reconnection after a disconnection.
        ///
        /// ★ Why this text must exist (and not just a spinner): The user's original comment was
        /// "*The current connection is not smooth and requires continuous clicking to reconnect*" — the reason he kept clicking is **the interface says nothing**,
        /// so "reconnecting" looks exactly the same as "clicking is useless". By stating the status,
        /// the user's correct action changes from "click again" to "wait for it".
        static var reconnecting: String {
            NSLocalizedString(
                "ticnote.reconnecting",
                value: "Reconnecting to the card…",
                comment: "Shown while the app retries a dropped recorder link on its own"
            )
        }
        /// Explanation shown when reconnecting to the Nth attempt. `n` starts from 1.
        static func reconnectingAttempt(_ n: Int) -> String {
            String(
                format: NSLocalizedString(
                    "ticnote.reconnecting_attempt",
                    value: "Reconnecting… (attempt %d)",
                    comment: "Recorder auto-reconnect progress; %d is the attempt number"
                ),
                n
            )
        }
        /// Explanation shown after disconnection and before reconnection (reconnection is handled by the app; no user action required).
        static var linkDropped: String {
            NSLocalizedString(
                "ticnote.link_dropped",
                value: "The card disconnected. It will reconnect on its own.",
                comment: "Card dropped the BLE link; a background retry loop is running"
            )
        }
        /// Explanation of the **fast path** for reconnection: initiate a connection directly to the known peripheral without scanning.
        ///
        /// ★ Why this sentence deserves its own entry: the card's broadcast interval can be measured up to **152 seconds**
        ///   (2026-10-09 probe measurement), and the fast path skips the waiting-for-broadcast step.
        ///   The two routes differ by an order of magnitude in latency, and the user sees "this time it returned quickly" and
        ///   "this time it waited a long time" must be distinguishable, otherwise the user will think "the software is flaky".
        static var reconnectingFastPath: String {
            NSLocalizedString(
                "ticnote.reconnecting_fast",
                value: "Trying the card we already know…",
                comment: "Recorder auto-reconnect is using the cached peripheral, no scan"
            )
        }
        /// Explanation of the **scanning path** for reconnection — at this point, we are waiting for the card to broadcast, which can be slow.
        static var reconnectingScanning: String {
            NSLocalizedString(
                "ticnote.reconnecting_scanning",
                value: "Waiting for the card to announce itself — it may be asleep.",
                comment: "Recorder auto-reconnect fell back to scanning; the card's advertise interval can be minutes"
            )
        }
        /// ★ Wi‑Fi fast transfer failed, add a line encouraging users to **take action**.
        ///
        /// Why this deserves its own line: The typical failure on this path is "iOS reports joining the hotspot, then nothing happens,"
        /// and its most likely cause is that **Local Network permission** is turned off — that toggle is in
        /// Settings → Privacy & Security → Local Network, and looks exactly the same as "card unresponsive,"
        /// so the user would never think to check it. Saying just "timeout" is equivalent to saying nothing.
        static var wifiFailedHint: String {
            NSLocalizedString(
                "ticnote.wifi_failed_hint",
                value: "If this keeps failing, check Settings → Privacy & Security → Local Network and make sure Nomily AI is allowed.",
                comment: "Appended to a Wi-Fi fast-transfer failure; local network permission is the usual silent cause"
            )
        }
        static var readingRecordings: String {
            NSLocalizedString("ticnote.reading_recordings", value: "Reading recordings…", comment: "")
        }
        static func recordingCount(_ count: Int) -> String {
            String(format: NSLocalizedString("ticnote.recording_count", value: "%d recordings", comment: "Header above the card's recording list"), count)
        }
        /// Explanation for the list **pausing refresh** while recording.
        ///
        /// ⚠️ Oct 10, 2026: Revised wording: previously, `recordingsSection` would **push the entire list aside** while recording,
        ///    leaving only this sentence — so users (who I thought were stuck during recording) would see
        ///    "Card is recording" and **not see any progress** during "import/transfer". Now the list is **preserved** (each row disabled),
        ///    and this text is downgraded to a footer, so the copy must no longer say "to read the file list" (the list is right there).
        static var recordingInProgress: String {
            NSLocalizedString("ticnote.recording_in_progress", value: "Recording is in progress. The list stops refreshing until you stop.", comment: "Footer under the recording list while the card is recording")
        }
        static var noRecordingsYet: String {
            NSLocalizedString("ticnote.no_recordings_yet", value: "This card has no recordings yet.", comment: "")
        }
        /// ★ "Transferring Recording" — the title of the **transfer status row** on the page (added 2026-10-10).
        ///
        /// User's original message: "Shouldn't it say 'Recording is being transferred'? Why does it prompt 'Card is recording', along with transfer progress, etc.?"
        ///
        /// Transfer (import) and recording are two **different** things, the copy must be separated:
        ///   · Recording → `recordingOnCard`("Card is recording")+ stopwatch, red;
        ///   · Transfer → this line + percentage + channel.
        /// Previously, transfer only had a thin progress bar **inline**, and if that line was out of view, there was not a single character.
        static var transferring: String {
            NSLocalizedString("ticnote.transferring", value: "Transferring recording…", comment: "Page-level status row shown while a recording is being downloaded from the card")
        }
        static var wifiFooter: String {
            NSLocalizedString("ticnote.wifi_footer", value: "Over Wi-Fi the card pushes the file in one go.", comment: "")
        }
        static var bleFooter: String {
            NSLocalizedString("ticnote.ble_footer", value: "Over Bluetooth a large file takes a long time — the card transfers about 9 KB/s, which is roughly real time.", comment: "")
        }
        static var recordingOnCard: String {
            NSLocalizedString("ticnote.recording_on_card", value: "Recording on the card", comment: "")
        }
        static var startStopHint: String {
            NSLocalizedString("ticnote.start_stop_hint", value: "Start and stop from the button next to the Device / Library switch.", comment: "")
        }
        static var fastTransfer: String {
            NSLocalizedString("ticnote.fast_transfer", value: "Fast transfer", comment: "")
        }
        static var fastTransferSubtitle: String {
            NSLocalizedString("ticnote.fast_transfer_subtitle", value: "Use the card's own Wi-Fi instead of Bluetooth.", comment: "")
        }
        static var fastTransferUnavailable: String {
            NSLocalizedString("ticnote.fast_transfer_unavailable", value: "Fast transfer unavailable", comment: "")
        }
        static func fastTransferPending(_ count: Int) -> String {
            String(format: NSLocalizedString("ticnote.fast_transfer_pending", value: "Transfer %d recording(s) over the card's Wi-Fi", comment: "Bottom button that bulk-transfers undownloaded recordings"), count)
        }
        static var fastTransferRunning: String {
            NSLocalizedString("ticnote.fast_transfer_running", value: "Transferring…", comment: "")
        }
        static var wifiFellBack: String {
            NSLocalizedString("ticnote.wifi_fell_back", value: "Fast transfer became unavailable; fell back to Bluetooth.", comment: "")
        }
        /// Why does the bottom Wi‑Fi fast‑transfer button **pop up**.
        ///
        /// It is hidden by default (only appears when "audio has been recorded + there are still undownloaded items on the card", see
        /// `RecorderSheet.refreshWifiFallback`), so we first clarify the reason —— otherwise users might feel
        /// this button pops up out of nowhere.
        ///
        /// ⚠️ The copy must not include "Bluetooth not finished" (2026-10-10 third revision): the current trigger condition is unrelated to Bluetooth success,
        ///    which would make users think their transfer failed.
        static var wifiFallbackHint: String {
            NSLocalizedString("ticnote.wifi_fallback_hint",
                              value: "Recorded. The card's own Wi-Fi is much faster than Bluetooth for long clips.",
                              comment: "Shown above the Wi-Fi fast-transfer button, which appears once something has been recorded and the card still holds undownloaded recordings")
        }
        static func savedAs(_ name: String) -> String {
            String(format: NSLocalizedString("ticnote.saved_as", value: "Saved as %@", comment: ""), name)
        }
        static func savedToLibrary(_ name: String) -> String {
            String(format: NSLocalizedString("ticnote.saved_to_library", value: "Saved to the library: %@", comment: ""), name)
        }
        static var autoTransferring: String {
            NSLocalizedString("ticnote.auto_transferring", value: "Auto-transferring the recording you just made…", comment: "Banner shown while the recording that just finished is transferred automatically")
        }
        static func transferIncomplete(_ detail: String) -> String {
            String(format: NSLocalizedString("ticnote.err_transfer_incomplete", value: "Transfer incomplete — %@", comment: ""), detail)
        }
        static func unexpectedData(_ detail: String) -> String {
            String(format: NSLocalizedString("ticnote.err_unexpected_data", value: "Device sent something unexpected — %@", comment: ""), detail)
        }
        static func notSupported(_ detail: String) -> String {
            String(format: NSLocalizedString("ticnote.err_not_supported", value: "Not supported — %@", comment: ""), detail)
        }
        static var disconnected: String {
            NSLocalizedString("ticnote.err_disconnected", value: "The card disconnected.", comment: "")
        }
        static var notResponding: String {
            NSLocalizedString("ticnote.err_not_responding", value: "The card stopped responding.", comment: "")
        }
        static var cancelled: String {
            NSLocalizedString("ticnote.err_cancelled", value: "Cancelled.", comment: "")
        }
        /// Toggle for auto-deleting card recordings after transfer. Reuse the already-translated keys from D·NOTE (semantics are identical).
        static var deleteAfterTransfer: String { RecordingsSettings.deleteAfterTransfer }
        static var deleteAfterTransferFooter: String { RecordingsSettings.deleteAfterTransferFooter }
        static var deletedFromCard: String {
            NSLocalizedString("ticnote.deleted_from_card", value: "Deleted from the card.", comment: "")
        }
        static var deleteFailedFromCard: String {
            NSLocalizedString("ticnote.delete_failed_from_card", value: "Couldn't delete it from the card — the recording is safe on your phone.", comment: "")
        }
        static var battery: String {
            NSLocalizedString("ticnote.battery", value: "Battery", comment: "Device info row")
        }
        /// The **Charging status** row title in "Device Details".
        static var chargeState: String {
            NSLocalizedString("ticnote.charge_state", value: "Charging status",
                              comment: "Device info row: is the card on external power")
        }
        /// The card explicitly reports "Charging". **Do not** use it as a fallback for unknown states — see `TicNoteBatteryReading`.
        static var charging: String {
            NSLocalizedString("ticnote.charging", value: "Charging",
                              comment: "Charging status value")
        }
        /// The card explicitly reports "not charging".
        static var notCharging: String {
            NSLocalizedString("ticnote.not_charging", value: "Not charging",
                              comment: "Charging status value")
        }
        static var serialNumber: String {
            NSLocalizedString("ticnote.serial_number", value: "Serial number", comment: "Device info row")
        }
        static var model: String {
            NSLocalizedString("ticnote.model", value: "Model", comment: "Device info row")
        }
        static var transferPrefs: String {
            NSLocalizedString("ticnote.transfer_prefs", value: "Transfer preferences", comment: "Section header in the card info sheet")
        }
        static var transferPrefsFooter: String {
            NSLocalizedString("ticnote.transfer_prefs_footer", value: "Only affects recordings transferred over Bluetooth or Wi-Fi by this app. Recordings that fail to transfer are never deleted.", comment: "")
        }
        static var cardSettings: String {
            NSLocalizedString("ticnote.card_settings", value: "Card settings", comment: "Section header: the card's own 0x08 settings")
        }
        static var notReadYet: String {
            NSLocalizedString("ticnote.not_read_yet", value: "Not read yet.", comment: "")
        }
        static var recordScene: String {
            NSLocalizedString("ticnote.record_scene", value: "Record scene", comment: "")
        }
        static var recordMode: String {
            NSLocalizedString("ticnote.record_mode", value: "Record mode", comment: "")
        }
        static var recordingLED: String {
            NSLocalizedString("ticnote.recording_led", value: "Recording LED", comment: "")
        }
        static var rowData: String {
            NSLocalizedString("ticnote.row_data", value: "Row data", comment: "")
        }
        static var micMode: String {
            NSLocalizedString("ticnote.mic_mode", value: "Mic mode", comment: "")
        }
        static var ledOff: String {
            NSLocalizedString("ticnote.led_off", value: "Off", comment: "")
        }
        static func ledOn(_ value: Int) -> String {
            String(format: NSLocalizedString("ticnote.led_on", value: "On (%d)", comment: ""), value)
        }

        // // MARK: - Wi-Fi Fast Transfer popup page (added 2026-10-12, shape aligned with V05E's `FastTransferSheet`)

        /// The title of the sheet. It refers to the same action as the sticky button below, but the user sees a **page**—
        /// This is the explicit wording requested by the user: "A page will pop up, then go to Wi-Fi Fast Transfer".
        static var ftTitle: String {
            NSLocalizedString("ticnote.ft_title", value: "Wi-Fi Fast Transfer", comment: "Title of the fast-transfer sheet")
        }
        /// Total of N items to transfer.
        static func ftFilesCount(_ count: Int) -> String {
            String(format: NSLocalizedString("ticnote.ft_files_count", value: "%d recording(s)", comment: "Section header in the fast-transfer sheet listing the queued recordings"), count)
        }
        static var ftStagePreparing: String {
            NSLocalizedString("ticnote.ft_stage_preparing", value: "Preparing…", comment: "")
        }
        static var ftStageRunning: String {
            NSLocalizedString("ticnote.ft_stage_running", value: "Transferring over the card's Wi-Fi…", comment: "")
        }
        /// The step between two items in a batch: the card has just finished serving the previous round and is switching back to Bluetooth.
        static var ftStageRelinking: String {
            NSLocalizedString("ticnote.ft_stage_relinking", value: "Reconnecting to the card…", comment: "Between two files the card leaves its hotspot and comes back on Bluetooth")
        }
        static var ftStageStopping: String {
            NSLocalizedString("ticnote.ft_stage_stopping", value: "Stopping…", comment: "")
        }
        static var ftStageDone: String {
            NSLocalizedString("ticnote.ft_stage_done", value: "All recordings transferred.", comment: "")
        }
        static func ftStagePartial(_ failed: Int) -> String {
            String(format: NSLocalizedString("ticnote.ft_stage_partial", value: "Finished with %d recording(s) not transferred.", comment: "Fast transfer finished but some files failed"), failed)
        }
        static var ftStageCancelled: String {
            NSLocalizedString("ticnote.ft_stage_cancelled", value: "Stopped.", comment: "")
        }
        /// An interruption caused by moving to the background — this is **mandatory**: iOS will suspend the App,
        /// and the connection to the hotspot will drop. When the user returns, they shouldn't just see "stopped halfway" without knowing why.
        static var ftStageInterrupted: String {
            NSLocalizedString("ticnote.ft_stage_interrupted", value: "The transfer was interrupted because the app went to the background.", comment: "")
        }
        static var ftStatusPending: String {
            NSLocalizedString("ticnote.ft_status_pending", value: "Waiting", comment: "")
        }
        static var ftStatusSaved: String {
            NSLocalizedString("ticnote.ft_status_saved", value: "Saved to the library", comment: "")
        }
        static var ftStatusSkipped: String {
            NSLocalizedString("ticnote.ft_status_skipped", value: "Skipped", comment: "")
        }
        static var ftStatusDeleted: String {
            NSLocalizedString("ticnote.ft_status_deleted", value: "Deleted from the card", comment: "Appended to a row that finished and whose original was removed from the card")
        }
        /// The "keep foreground" hint. Besides sharing the same string with V05E (`L10n.Common.keepForeground`),
        /// here we add a sentence explaining **why** — just saying "keep foreground" doesn't tell the user why.
        static var ftKeepForeground: String {
            NSLocalizedString("ticnote.ft_keep_foreground", value: "Keep this screen open until it finishes. iOS stops the transfer if the app goes to the background.", comment: "Hint inside the fast-transfer sheet")
        }
        static var ftStart: String {
            NSLocalizedString("ticnote.ft_start", value: "Start transfer", comment: "")
        }
        static var ftStop: String {
            NSLocalizedString("ticnote.ft_stop", value: "Stop", comment: "")
        }
        static var ftClose: String {
            NSLocalizedString("ticnote.ft_close", value: "Done", comment: "")
        }
        static func ftProgressLabel(_ index: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("ticnote.ft_progress_label", value: "%d of %d", comment: "Position in the fast-transfer queue"), index, total)
        }
        static func ftRetryFailed(_ count: Int) -> String {
            String(format: NSLocalizedString("ticnote.ft_retry_failed", value: "Retry %d failed", comment: "Toolbar button in the fast-transfer sheet"), count)
        }
        /// A honest note to the user before fast transfer starts: this process **requires modifying the system Wi-Fi**.
        static var ftWifiNotice: String {
            NSLocalizedString("ticnote.ft_wifi_notice", value: "Your iPhone will briefly join the card's own Wi-Fi network and switch back when done.", comment: "Explains what the fast transfer does to the phone's Wi-Fi")
        }
        /// Number of seconds to wait, displayed below the stage title. `%d` is the number of seconds already waited.
        ///
        /// Source (2026-10-14 user quote): Fast transfer is "not smooth"... [No feedback during wait].
        /// The hotspot join window itself is 45 s — during this time the UI must show some activity,
        /// otherwise the only judgment the user can make is "it's frozen" and then tap it away.
        static func ftWaitingElapsed(_ seconds: Int) -> String {
            String(format: NSLocalizedString(
                "ticnote.ft_waiting_elapsed",
                value: "%d s elapsed",
                comment: "Ticking counter shown while the sheet waits for the card's hotspot"
            ), seconds)
        }
        /// Proactively notify users about the upcoming iOS system prompt asking whether to join the Wi-Fi network.
        ///
        /// That popup **cannot be bypassed** (due to `NEHotspotConfigurationManager`'s behavior).
        /// But a "sudden popup" and a "prior notice" feel very different to users — in the former case, users often mistakenly tap "Cancel",
        /// causing the entire chain to fail, making it look like the feature is broken.
        static var ftHotspotPromptNotice: String {
            NSLocalizedString(
                "ticnote.ft_hotspot_prompt_notice",
                value: "Next, iOS will ask whether to join the card's Wi-Fi network. Tap Join — cancelling it stops the transfer.",
                comment: "Pre-announces the unavoidable system hotspot-join prompt"
            )
        }

        // MARK: - Multi-Select

        static var select: String {
            NSLocalizedString("ticnote.select", value: "Select", comment: "Enters multi-select mode on the card's recording list")
        }
        static var selectAll: String {
            NSLocalizedString("ticnote.select_all", value: "Select all", comment: "")
        }
        static var deselectAll: String {
            NSLocalizedString("ticnote.deselect_all", value: "Deselect all", comment: "")
        }
        static func selectedCount(_ count: Int) -> String {
            String(format: NSLocalizedString("ticnote.selected_count", value: "%d selected", comment: ""), count)
        }
        static func fastTransferSelected(_ count: Int) -> String {
            String(format: NSLocalizedString("ticnote.fast_transfer_selected", value: "Transfer %d selected over Wi-Fi", comment: "Bottom button while in multi-select mode"), count)
        }

        // MARK: - Storage usage (added 2026-10-12, cmd 0x06)

        /// "Used Storage" — same colleague name as the official card device page's `myNewDevice_Capacity` / `storage_used`.
        static var storage: String {
            NSLocalizedString("ticnote.storage", value: "Storage used", comment: "Device info row: how much of the card is taken")
        }
        /// The right side of the "Usage" row (the `"117 MB / 58.2 GB"` part is constructed by code; this only provides the semantic explanation for the slash in the middle).
        static var storageFree: String {
            NSLocalizedString("ticnote.storage_free", value: "Free", comment: "Label for the card's remaining space")
        }
        /// Not yet read (separated from "—": one means "not asked", the other means "card not provided").
        static var storageNotRead: String {
            NSLocalizedString("ticnote.storage_not_read", value: "Not read yet", comment: "Storage row before the card has been asked")
        }
        static var storageFooter: String {
            NSLocalizedString(
                "ticnote.storage_footer",
                value: "Reported by the card itself (command 0x06). The used figure is total minus free.",
                comment: "Footer under the storage row"
            )
        }

        // MARK: - Microphone gain (added 2026-10-12, write direction 0x08)

        /// "Microphone gain" — the l10n key for the official card's device page is exactly this one (`myNewDevice_Mic` / `myDevice_mkfeng`).
        static var micGain: String {
            NSLocalizedString("ticnote.mic_gain", value: "Microphone gain", comment: "Device info row: the card's own mic gain setting")
        }
        /// The card's currently **self-reported** pickup mode value (not the same field as the two above; see store comments).
        static func micGainCardReports(_ value: Int) -> String {
            String(format: NSLocalizedString(
                "ticnote.mic_gain_card_reports",
                value: "The card reports %d",
                comment: "Shown when the value the card reports is not one of the two gain settings we can write; %d is the raw byte"
            ), value)
        }
        static var micGainNotRead: String {
            NSLocalizedString("ticnote.mic_gain_not_read", value: "Read the card first", comment: "Microphone gain section before the card's settings have been read")
        }
        /// Toast for successful write (the official copy pool's `myDevice_setdbsucc` corresponds to "Settings saved").
        static var micGainSaved: String {
            NSLocalizedString("ticnote.mic_gain_saved", value: "Saved to the card.", comment: "Toast after the card acknowledged the new microphone gain")
        }
        static var micGainFailed: String {
            NSLocalizedString("ticnote.mic_gain_failed", value: "The card did not accept the new gain.", comment: "Shown when the card never answered the settings write")
        }
        /// Toast line for writes in progress (added 2026-10-12, to work with 'tap to write').
        static var micGainApplying: String {
            NSLocalizedString("ticnote.mic_gain_applying", value: "Applying…", comment: "Shown while the microphone gain write is in flight")
        }
        /// ⚠️ No longer referenced (since 2026-10-12, gain changes are applied on click, so there is no longer a separate Apply button).
        ///    The key is retained in case we need to fall back to the old interaction of "select first, then click Apply".
        static var micGainApply: String {
            NSLocalizedString("ticnote.mic_gain_apply", value: "Apply", comment: "Button that writes the selected microphone gain to the card")
        }
        static var micGainFooter: String {
            NSLocalizedString(
                "ticnote.mic_gain_footer",
                value: "Written with the card's settings command (0x08), which carries the current settings plus the new gain. The card does not report the gain back, so this screen shows what you last set.",
                comment: "Footer under the microphone gain section"
            )
        }

        // MARK: - Rename (added 2026-10-12, App-side alias)

        /// "Name" — the key for that row on the official card device page is `myDevice_deviceName`.
        static var deviceName: String {
            NSLocalizedString("ticnote.device_name", value: "Name", comment: "Device info row: what we call this card")
        }
        static var renameTitle: String {
            NSLocalizedString("ticnote.rename_title", value: "Rename this card", comment: "Alert title for renaming a card")
        }
        static var renamePlaceholder: String {
            NSLocalizedString("ticnote.rename_placeholder", value: "Card name", comment: "Placeholder inside the rename text field")
        }
        static var renameSave: String { L10n.Common.save }
        static var renameCancel: String { L10n.Common.cancel }
        /// Consistent with the official limit ("Name is too long (max 20 characters)" from the copy pool).
        static var renameTooLong: String {
            NSLocalizedString("ticnote.rename_too_long", value: "That name is too long (20 characters max).", comment: "Validation message in the rename alert")
        }
        static var renameRestore: String {
            NSLocalizedString("ticnote.rename_restore", value: "Use the card's own name", comment: "Clears the local alias and falls back to the name the card advertises")
        }
        static var renameEmpty: String {
            NSLocalizedString("ticnote.rename_empty", value: "Enter a name first.", comment: "Validation message when the rename field is empty")
        }
        /// The rule itself (written in the footer). The limit matches the official one: 20 characters.
        static var renameLimit: String {
            NSLocalizedString("ticnote.rename_limit", value: "Up to 20 characters.", comment: "Rule shown under the rename row, matching the card's own name limit")
        }
        static var renameFooter: String {
            NSLocalizedString(
                "ticnote.rename_footer",
                value: "Kept on this phone and applied to this card only — other cards keep their own names. The card's own Bluetooth name is not changed.",
                comment: "Footer under the rename row: the alias is local and per-card"
            )
        }

        // MARK: - Unbind device (2026-10-12 added, cmd 0x05)

        static var unbind: String {
            NSLocalizedString("ticnote.unbind", value: "Unbind this card", comment: "Destructive row at the bottom of the card info sheet")
        }
        static var unbindConfirmTitle: String {
            NSLocalizedString("ticnote.unbind_confirm_title", value: "Unbind this card?", comment: "")
        }
        /// Confirm the main text. **deliberately different from the official wording** — the official writes "Unbinding will clear all device data",
        /// But that describes its entire cloud process; we only send the card its own unbind command, without deleting recordings.
        /// The copy must state what we actually do, otherwise users will think the recordings are gone.
        static var unbindConfirmMessage: String {
            NSLocalizedString(
                "ticnote.unbind_confirm_message",
                value: "The card is released so it can be paired again, and this app forgets it. Recordings on the card are not deleted — transfer them first if you want to keep them.",
                comment: "Body of the unbind confirmation. Deliberately does not promise to erase recordings"
            )
        }
        static var unbindConfirmAction: String {
            NSLocalizedString("ticnote.unbind_confirm_action", value: "Unbind", comment: "Confirm button in the unbind alert")
        }
        static var unbinding: String {
            NSLocalizedString("ticnote.unbinding", value: "Unbinding…", comment: "Shown while the unbind command is being sent")
        }
        static var unbindSuccess: String {
            NSLocalizedString("ticnote.unbind_success", value: "Unbound. The card has been removed from this app.", comment: "")
        }
        static var unbindFailed: String {
            NSLocalizedString("ticnote.unbind_failed", value: "Couldn't unbind the card.", comment: "")
        }
        static var unbindOffline: String {
            NSLocalizedString(
                "ticnote.unbind_offline",
                value: "The card is offline. Reconnect it and try again — the card itself has to hear this command.",
                comment: "Shown when unbind is attempted with no live link"
            )
        }
    }

    // MARK: - File Save States

    enum FileSave {
        static func savedPlain(_ filename: String) -> String {
            String(format: NSLocalizedString("file_save.saved_plain", comment: ""), filename)
        }
        static func decrypted(_ filename: String) -> String {
            String(format: NSLocalizedString("file_save.decrypted", comment: ""), filename)
        }
        static func wrappedFrames(_ filename: String) -> String {
            String(format: NSLocalizedString("file_save.wrapped_frames", comment: ""), filename)
        }
        static func decryptedWrapped(_ filename: String) -> String {
            String(format: NSLocalizedString("file_save.decrypted_wrapped", comment: ""), filename)
        }
        static func saved(_ filename: String) -> String {
            String(format: NSLocalizedString("file_save.saved", comment: ""), filename)
        }
        static func decryptFailed(_ message: String) -> String {
            String(format: NSLocalizedString("file_save.decrypt_failed", comment: ""), message)
        }
        static var wavWithoutHeader: String { NSLocalizedString("file_save.wav_without_header", comment: "") }
    }

    // MARK: - Clip Detail

    enum ClipDetail {
        static var opusPlaybackUnsupported: String { NSLocalizedString("clip_detail.opus_playback_unsupported", value: "This system version can't play Opus recordings — playback needs iOS 17 or later. Transcription is unaffected. To listen now, share the file out via AirDrop or the Files app.", comment: "Shown in the player when an Opus clip can't be played on iOS 16") }
        static var transcript: String { NSLocalizedString("clip_detail.transcript", comment: "") }
        static var transcribing: String { NSLocalizedString("clip_detail.transcribing", comment: "") }
        static var providerFallback: String { NSLocalizedString("clip_detail.provider_fallback", comment: "") }
        static var viewFullTranscript: String { NSLocalizedString("clip_detail.view_full_transcript", comment: "") }
        static var transcribe: String { NSLocalizedString("clip_detail.transcribe", comment: "") }
        static var retranscribe: String { NSLocalizedString("clip_detail.retranscribe", comment: "") }
        static var retranscribeMessage: String { NSLocalizedString("clip_detail.retranscribe_message", comment: "") }
        static var summary: String { NSLocalizedString("clip_detail.summary", comment: "") }
        static var viewFullSummary: String { NSLocalizedString("clip_detail.view_full_summary", comment: "") }
        static var summarize: String { NSLocalizedString("clip_detail.summarize", comment: "") }
        static var transcribeFirst: String { NSLocalizedString("clip_detail.transcribe_first", comment: "") }
        static var translation: String { NSLocalizedString("clip_detail.translation", comment: "") }
        static var viewFullTranslation: String { NSLocalizedString("clip_detail.view_full_translation", comment: "") }
        static var translate: String { NSLocalizedString("clip_detail.translate", comment: "") }
        static var translating: String { NSLocalizedString("clip_detail.translating", comment: "") }
        static var translatedSummary: String { NSLocalizedString("clip_detail.translated_summary", comment: "") }
        static var viewFullTranslatedSummary: String { NSLocalizedString("clip_detail.view_full_translated_summary", comment: "") }
        static var export: String { NSLocalizedString("clip_detail.export", comment: "") }
        static var exportAudio: String { NSLocalizedString("clip_detail.export_audio", value: "Export Audio", comment: "Menu row that opens the audio format choices") }
        static var exportAsM4A: String { NSLocalizedString("clip_detail.export_as_m4a", comment: "") }
        static var exportAsWAV: String { NSLocalizedString("clip_detail.export_as_wav", value: "Export as WAV (PCM)", comment: "WAV export option — uncompressed audio") }
        static var exportFormatFooter: String { NSLocalizedString("clip_detail.export_format_footer", value: "M4A is compressed and plays anywhere. WAV is uncompressed — larger, but it's the format transcription and editing tools expect.", comment: "Footer explaining the two audio export formats") }
        static var exporting: String { NSLocalizedString("clip_detail.exporting", comment: "") }
        /// ★ 2026-10-15 六改：上次那一份已经导好了，点这一行去分享。
        ///
        /// 这一行存在的唯一理由是**省掉一次重跑** —— 大文件转码能等到用户
        /// 切走（"防止退出需要重新等待"）。所以文案直接说"已导出"，而不是
        /// 含糊的"分享音频"。
        static var exportReady: String {
            NSLocalizedString("clip_detail.export_ready", value: "Exported — tap to share",
                              comment: "Row shown when this clip's export already finished and is waiting to be shared")
        }
        static func exportReadyFiles(_ count: Int) -> String {
            String(
                format: NSLocalizedString("clip_detail.export_ready_files", value: "%d file(s)",
                                          comment: "How many files the staged export contains"),
                count
            )
        }
        /// 清掉中转副本（**不动**资料库里的原件）。
        static var clearExportStaging: String { L10n.Library.clearExportStaging }
        static var mindMap: String { NSLocalizedString("clip_detail.mind_map", value: "Mind Map", comment: "Mind map view built from the summary's headings and lists") }
        static var mindMapLevel: String { NSLocalizedString("clip_detail.mind_map_level", value: "Branches", comment: "How many levels of the summary the mind map draws") }
        static var mindMapFit: String { NSLocalizedString("clip_detail.mind_map_fit", value: "Fit", comment: "Button that scales the mind map to fill the screen") }
        static var mindMapEmpty: String { NSLocalizedString("clip_detail.mind_map_empty", value: "This summary has no headings or lists to turn into a mind map.", comment: "Shown when a summary has no structure to plot") }
        static var mindMapExportFailed: String { NSLocalizedString("clip_detail.mind_map_export_failed", value: "Couldn't export the mind map.", comment: "Alert title when mind-map PNG export fails") }
        static var mindMapExpandAll: String { NSLocalizedString("clip_detail.mind_map_expand_all", value: "Expand all", comment: "Toolbar button that opens every folded branch of the mind map") }
        static var mindMapCollapseAll: String { NSLocalizedString("clip_detail.mind_map_collapse_all", value: "Collapse all", comment: "Toolbar button that folds the mind map back to its top-level branches") }
        static var deleteAudio: String { NSLocalizedString("clip_detail.delete_audio", value: "Delete Audio", comment: "Deletes only the audio file, keeping transcript and summary") }
        static var deleteAudioMessage: String { NSLocalizedString("clip_detail.delete_audio_message", value: "The audio file moves to Recently Deleted. The transcript and summary are kept. You can recover it for 30 days.", comment: "") }
        static var deleteTranscript: String { NSLocalizedString("clip_detail.delete_transcript", value: "Delete Transcript", comment: "Deletes only the transcript, keeping audio and summary") }
        static var deleteTranscriptMessage: String { NSLocalizedString("clip_detail.delete_transcript_message", value: "The transcript and its translation move to Recently Deleted. The audio and summary are kept. You can recover them for 30 days.", comment: "") }
        static var deleteSummary: String { NSLocalizedString("clip_detail.delete_summary", value: "Delete Summary", comment: "Deletes only the summary, keeping audio and transcript") }
        static var deleteSummaryMessage: String { NSLocalizedString("clip_detail.delete_summary_message", value: "The summary and its translation move to Recently Deleted. The audio and transcript are kept. You can recover them for 30 days.", comment: "") }
        static var deleteIndependentFooter: String { NSLocalizedString("clip_detail.delete_independent_footer", value: "Audio, transcript and summary are deleted independently — removing one leaves the others untouched.", comment: "") }
        static func speaker(_ id: String) -> String {
            String(format: NSLocalizedString("clip_detail.speaker", comment: ""), id)
        }
    }

    // MARK: - Device Sheet

    enum Device {
        static var couldntUpdate: String { NSLocalizedString("device.couldnt_update", comment: "") }
        static var eraseAllRecordings: String { NSLocalizedString("device.erase_all_recordings", comment: "") }
        static var eraseMessage: String { NSLocalizedString("device.erase_message", comment: "") }
        static var formatStorage: String { NSLocalizedString("device.format_storage", comment: "") }
        static var formatting: String { NSLocalizedString("device.formatting", comment: "") }
        static var restoreFactory: String { NSLocalizedString("device.restore_factory", comment: "") }
        static var restoreMessage: String { NSLocalizedString("device.restore_message", comment: "") }
        static var factoryReset: String { NSLocalizedString("device.factory_reset", comment: "") }
        static var resetting: String { NSLocalizedString("device.resetting", comment: "") }
        static var powerOff: String { NSLocalizedString("device.power_off", comment: "") }
        static var powerOffMessage: String { NSLocalizedString("device.power_off_message", comment: "") }
        static var shutDown: String { NSLocalizedString("device.shut_down", comment: "") }
        static var shuttingDown: String { NSLocalizedString("device.shutting_down", comment: "") }
        static func connectedMTU(_ mtu: Int) -> String {
            String(format: NSLocalizedString("device.connected_mtu", comment: ""), mtu)
        }
        static func storageUsed(_ used: String, _ total: String) -> String {
            String(format: NSLocalizedString("device.storage_used", comment: ""), used, total)
        }
        static var identity: String { NSLocalizedString("device.identity", comment: "") }
        static var bluetoothName: String { NSLocalizedString("device.bluetooth_name", comment: "") }
        static var serial: String { NSLocalizedString("device.serial", comment: "") }
        static var firmware: String { NSLocalizedString("device.firmware", comment: "") }
        static var btMAC: String { NSLocalizedString("device.bt_mac", comment: "") }
        static var deviceTime: String { NSLocalizedString("device.device_time", comment: "") }
        static var audio: String { NSLocalizedString("device.audio", comment: "") }
        static var noiseCancel: String { NSLocalizedString("device.noise_cancel", comment: "") }
        static var noiseCancelHint: String { NSLocalizedString("device.noise_cancel_hint", comment: "") }
        static var saveRawWAV: String { NSLocalizedString("device.save_raw_wav", comment: "") }
        static var saveRawWAVHint: String { NSLocalizedString("device.save_raw_wav_hint", comment: "") }
        static var vad: String { NSLocalizedString("device.vad", comment: "") }
        static var vadHint: String { NSLocalizedString("device.vad_hint", comment: "") }
        static var micGain: String { NSLocalizedString("device.mic_gain", comment: "") }
        static var micGainHint: String { NSLocalizedString("device.mic_gain_hint", comment: "") }
        static var noiseReduction: String { NSLocalizedString("device.noise_reduction", comment: "") }
        static var noiseReductionHint: String { NSLocalizedString("device.noise_reduction_hint", comment: "") }
        static var behavior: String { NSLocalizedString("device.behavior", comment: "") }
        static var ledIndicator: String { NSLocalizedString("device.led_indicator", comment: "") }
        static var vibration: String { NSLocalizedString("device.vibration", comment: "") }
        static var usbDriveMode: String { NSLocalizedString("device.usb_drive_mode", comment: "") }
        static var usbDriveModeHint: String { NSLocalizedString("device.usb_drive_mode_hint", comment: "") }
        static var autoPowerOff: String { NSLocalizedString("device.auto_power_off", comment: "") }
        static var savingIdleOff: String { NSLocalizedString("device.saving_idle_off", comment: "") }
        static var savingName: String { NSLocalizedString("device.saving_name", value: "Saving name…", comment: "Busy pill while the new Bluetooth device name is being written") }
        static var unbindAndRemove: String { NSLocalizedString("device.unbind_and_remove", value: "Unbind and Remove Device", comment: "Danger-zone action: unbind the device and erase this binding's footprint") }
        static var unbindAndRemoveMessage: String { NSLocalizedString("device.unbind_and_remove_message", value: "This turns off the device's encryption, deletes the recordings stored on the device, unbinds it, and removes it from your paired devices. This can't be undone.", comment: "Confirmation body for unbind-and-remove") }
        static var unbindingAndRemoving: String { NSLocalizedString("device.unbinding_and_removing", value: "Removing device…", comment: "Busy pill while unbind-and-remove runs") }
        static var dangerZone: String { NSLocalizedString("device.danger_zone", comment: "") }
        static var dangerZoneFooter: String { NSLocalizedString("device.danger_zone_footer", comment: "") }
        static var connection: String { NSLocalizedString("device.connection", comment: "") }
        static var disconnect: String { NSLocalizedString("device.disconnect", comment: "") }
        static var never: String { NSLocalizedString("device.never", comment: "") }
        static func customIdleOff(_ seconds: UInt32) -> String {
            String(format: NSLocalizedString("device.custom_idle_off", comment: ""), seconds)
        }
    }

    // MARK: - Device Encryption (v1.47)

    enum DeviceEncryption {
        static var sectionHeader: String { NSLocalizedString(
            "device_encryption.section_header",
            value: "Device encryption",
            comment: "Settings section header for v1.47 on-device ChaCha20 toggle"
        ) }
        static var toggleLabel: String { NSLocalizedString(
            "device_encryption.toggle_label",
            value: "Encrypt recordings on device",
            comment: "Settings toggle label"
        ) }
        static var footer: String { NSLocalizedString(
            "device_encryption.footer",
            value: "When enabled, the device encrypts every recording with a ChaCha20 key that this app also stores. Turning off requires the matching key.",
            comment: "Footer explaining the encryption toggle"
        ) }
        static var missingKeyError: String { NSLocalizedString(
            "device_encryption.missing_key_error",
            value: "Can't disable — no ChaCha20 key on file to match the device's.",
            comment: "Shown when the user tries to disable encryption without a stored key"
        ) }
        static var stateRow: String { NSLocalizedString(
            "device_encryption.state_row",
            value: "On-device encryption",
            comment: "Read-only row label showing the firmware's encryption state"
        ) }
        static var stateOn: String { NSLocalizedString(
            "device_encryption.state_on",
            value: "ON",
            comment: "State chip when device-side encryption is enabled"
        ) }
        static var stateOff: String { NSLocalizedString(
            "device_encryption.state_off",
            value: "OFF",
            comment: "State chip when device-side encryption is disabled"
        ) }
        static var firmwareFooter: String { NSLocalizedString(
            "device_encryption.firmware_footer",
            value: "This firmware (v1.50) auto-enables encryption at bind time and refuses to disable it. Recordings are encrypted under whatever 32-byte key was last written via 0xA2. Use \"Set passphrase\" above so this app can decrypt them.",
            comment: "Footer below the read-only state row explaining the v1.50 firmware constraint"
        ) }
    }

    // MARK: - Developer mode (hidden toggle behind the version-tap easter egg)

    enum DeveloperMode {
        static var statusOn: String { NSLocalizedString(
            "developer_mode.status_on",
            value: "Developer mode is on",
            comment: "Footer chip in the About section when dev mode is active"
        ) }
        static var toastEnabled: String { NSLocalizedString(
            "developer_mode.toast_enabled",
            value: "Developer mode enabled",
            comment: "Toast after the 7th version tap toggles dev mode ON"
        ) }
        static var toastDisabled: String { NSLocalizedString(
            "developer_mode.toast_disabled",
            value: "Developer mode disabled",
            comment: "Toast after the 7th version tap toggles dev mode OFF"
        ) }
        static func tapsToEnable(_ remaining: Int) -> String {
            String(format: NSLocalizedString(
                "developer_mode.taps_to_enable",
                value: "%d more taps to enable developer mode",
                comment: "Hint shown after a few version taps when dev mode is off"
            ), remaining)
        }
        static func tapsToDisable(_ remaining: Int) -> String {
            String(format: NSLocalizedString(
                "developer_mode.taps_to_disable",
                value: "%d more taps to disable developer mode",
                comment: "Hint shown after a few version taps when dev mode is on"
            ), remaining)
        }
    }

    // MARK: - Encryption passphrase / onboarding (v1.50)

    enum EncryptionOnboarding {
        // Settings — "Encryption passphrase" section
        static var sectionHeader: String { NSLocalizedString("encryption.section_header", value: "Encryption passphrase", comment: "Settings section header for the user passphrase") }
        static var sectionFooter: String { NSLocalizedString("encryption.section_footer", value: "Derived via Argon2id with the device serial as salt. Stored in the iOS Keychain, scoped to this device. Losing the passphrase makes encrypted recordings unrecoverable. Cross-iPhone recovery: enter the same passphrase on the new phone.", comment: "Footer for the passphrase section") }
        static var localKey: String { NSLocalizedString("encryption.local_key", value: "Local key", comment: "Row label for the per-device Keychain key state") }
        static var configured: String { NSLocalizedString("encryption.configured", value: "configured", comment: "State chip when a local key is present") }
        static var missing: String { NSLocalizedString("encryption.missing", value: "missing", comment: "State chip when no local key is present") }
        static var setButton: String { NSLocalizedString("encryption.set_button", value: "Set passphrase…", comment: "Settings button to open the Set passphrase sheet") }
        static var verifyButton: String { NSLocalizedString("encryption.verify_button", value: "Verify device passphrase…", comment: "Settings button when the device is already encrypted — the flow verifies the passphrase rather than choosing one") }
        static var rotateButton: String { NSLocalizedString("encryption.rotate_button", value: "Rotate (overwrite device key)…", comment: "Settings button to open the Rotate sheet") }
        static var clearButton: String { NSLocalizedString("encryption.clear_button", value: "Clear local key", comment: "Settings button to delete this iPhone's Keychain entry for the device") }

        // Sheet — title + fields + actions
        static var sheetTitleSet: String { NSLocalizedString("encryption.sheet.title_set", value: "Set passphrase", comment: "Sheet title for Set mode") }
        static var sheetTitleVerify: String { NSLocalizedString("encryption.sheet.title_verify", value: "Verify passphrase", comment: "Sheet title for Set mode when the device is already encrypted") }
        static var sheetTitleRotate: String { NSLocalizedString("encryption.sheet.title_rotate", value: "Rotate key", comment: "Sheet title for Rotate mode") }
        static var passphraseField: String { NSLocalizedString("encryption.field.passphrase", value: "Passphrase", comment: "SecureField placeholder") }
        static var confirmField: String { NSLocalizedString("encryption.field.confirm", value: "Confirm", comment: "SecureField placeholder for confirmation") }
        static var actionSave: String { NSLocalizedString("encryption.action.save", value: "Save", comment: "Primary button — device-not-encrypted Set flow") }
        static var actionVerifyAndSave: String { NSLocalizedString("encryption.action.verify_save", value: "Verify & save", comment: "Primary button — device-encrypted Set flow") }
        static var actionRotate: String { NSLocalizedString("encryption.action.rotate", value: "Rotate", comment: "Primary button — Rotate flow") }
        static var actionCancel: String { NSLocalizedString("encryption.action.cancel", value: "Cancel", comment: "Sheet cancel button") }
        static var working: String { NSLocalizedString("encryption.progress.working", value: "Working…", comment: "Generic progress label fallback") }

        // Sheet — context-aware footer copy
        static var footerRotate: String { NSLocalizedString("encryption.footer.rotate", value: "Rotate writes a brand-new key to the device. Every existing encrypted recording on the device becomes permanently undecryptable. Use this only when you're taking ownership of a pre-owned device or have forgotten the old passphrase.", comment: "Footer when the user is rotating") }
        static var footerSetEncrypted: String { NSLocalizedString("encryption.footer.set_encrypted", value: "This device is encrypted. We'll record a short probe clip, download it, and trial-decrypt with the passphrase you typed. The probe is auto-deleted afterwards.", comment: "Footer when Set will verify against an existing encrypted clip") }
        static var footerSetUnencrypted: String { NSLocalizedString("encryption.footer.set_unencrypted", value: "Saves the locally-derived key to the iOS Keychain. The device isn't touched — pick a strong passphrase and enable encryption from the Device sheet when you're ready.", comment: "Footer when Set is saving a dormant key (device encryption off)") }

        // Progress messages (shared between Verifier + Sheet)
        static var progressDeriving: String { NSLocalizedString("encryption.progress.deriving", value: "Deriving key…", comment: "Argon2id step") }
        static var progressRecording: String { NSLocalizedString("encryption.progress.recording", value: "Recording a short probe clip…", comment: "Verify step 1") }
        static var progressStopping: String { NSLocalizedString("encryption.progress.stopping", value: "Stopping recording…", comment: "Verify step 2") }
        static var progressLocating: String { NSLocalizedString("encryption.progress.locating", value: "Locating probe clip…", comment: "Verify step 3") }
        static var progressDownloading: String { NSLocalizedString("encryption.progress.downloading", value: "Downloading probe…", comment: "Verify step 4") }
        static var progressVerifying: String { NSLocalizedString("encryption.progress.verifying", value: "Verifying…", comment: "Verify step 5") }
        static var progressWritingKey: String { NSLocalizedString("encryption.progress.writing_key", value: "Writing key to device…", comment: "Rotate step 2") }
        static var probeOverlaySubtitle: String { NSLocalizedString("encryption.progress.probe_subtitle", value: "Recording a short probe to verify the passphrase. The probe is auto-deleted.", comment: "Caption under the spinner during verify") }
        static var progressCheckingDevice: String { NSLocalizedString("encryption.progress.checking_device", value: "Checking what's on the device…", comment: "Rotate step 1 — counting at-risk recordings") }

        // Rotate confirmation
        static var rotateConfirmTitle: String { NSLocalizedString("encryption.rotate_confirm.title", value: "Rotate the device key?", comment: "Confirmation alert title before rotating") }
        static func rotateConfirmMessage(_ count: Int) -> String {
            if count == 0 {
                return NSLocalizedString("encryption.rotate_confirm.message_empty", value: "The device has no recordings left, so nothing will be lost. Write down the new passphrase — it's the only way to open recordings made from now on, and there is no recovery.", comment: "Rotate confirmation, nothing at risk")
            }
            return String(format: NSLocalizedString("encryption.rotate_confirm.message", value: "%d recording(s) are still on the device. They were made with the old key and will become permanently unreadable — download them first if you want to keep them. Write down the new passphrase: it's the only way to open recordings made from now on, and there is no recovery.", comment: "Rotate confirmation, N recordings at risk"), count)
        }

        // Mismatch alert
        static var mismatchTitle: String { NSLocalizedString("encryption.mismatch.title", value: "Passphrase didn't match", comment: "Alert title when probe verify fails") }
        static var mismatchMessage: String { NSLocalizedString("encryption.mismatch.message", value: "The probe clip didn't decrypt with that passphrase. Double-check it and try again. If you've truly forgotten it, use \"Rotate\" to overwrite the device key — but that permanently destroys every existing encrypted recording on the device.", comment: "Alert body explaining retry + rotate") }
        static var mismatchTryAgain: String { NSLocalizedString("encryption.mismatch.try_again", value: "Try again", comment: "Alert button to retry") }

        // Inline errors
        static var errorDeviceNotConnected: String { NSLocalizedString("encryption.error.device_not_connected", value: "Device not connected.", comment: "Error: Rotate attempted with no connection") }
        static var errorConnectFirst: String { NSLocalizedString("encryption.error.connect_first", value: "Connect the device first — the passphrase needs to be verified against a real recording.", comment: "Error: Set attempted with no connection while device encryption is on") }
        static var errorProbeNotFound: String { NSLocalizedString("encryption.error.probe_not_found", value: "Couldn't find the probe recording on the device.", comment: "VerifyError.noFreshClip") }
        static func errorDeviceBusy(_ details: String) -> String {
            String(format: NSLocalizedString("encryption.error.device_busy", value: "Device wouldn't record: %@", comment: "VerifyError.deviceBusy with inner message"), details)
        }

        // Banner shown on the Device tab when device is encrypted but no key is set locally
        static var bannerTitle: String { NSLocalizedString("encryption.banner.title", value: "Device is encrypted", comment: "Onboarding banner title") }
        static var bannerMessage: String { NSLocalizedString("encryption.banner.message", value: "Set the passphrase to unlock recordings on this iPhone. If you've forgotten it, rotate the key (this erases existing encrypted recordings on the device).", comment: "Onboarding banner body") }
        static var bannerCTA: String { NSLocalizedString("encryption.banner.cta", value: "Set passphrase…", comment: "Onboarding banner button") }

        // Calm variant of the banner: device encrypted, but nothing on it yet
        // (the normal state right after binding a new V05).
        static var bannerSetupTitle: String { NSLocalizedString("encryption.banner.setup_title", value: "Set a passphrase for this device", comment: "Onboarding banner title, nothing at risk") }
        static var bannerSetupMessage: String { NSLocalizedString("encryption.banner.setup_message", value: "This device encrypts its recordings. Set a passphrase now and everything you record will open on this iPhone. There are no recordings on the device yet, so nothing is at risk.", comment: "Onboarding banner body, nothing at risk") }

        // Offered when Set can't verify against an empty device — adopting the
        // typed passphrase is lossless there.
        static var adoptTitle: String { NSLocalizedString("encryption.adopt.title", value: "Use this passphrase for the device?", comment: "Alert title offering to write the typed passphrase to an empty device") }
        static var adoptMessage: String { NSLocalizedString("encryption.adopt.message", value: "The device is using a key this iPhone doesn't have — normal for a device you've just bound. It holds no recordings, so writing your passphrase to it loses nothing. Write the passphrase down: it's the only way to open recordings made from now on, and there is no recovery.", comment: "Alert body for the adopt offer") }
        static var adoptAction: String { NSLocalizedString("encryption.adopt.action", value: "Use this passphrase", comment: "Confirm button for the adopt offer") }

        static var firstBindNote: String { NSLocalizedString("encryption.first_bind_note", value: "This Nomi's firmware encrypts everything it records, so a passphrase is required. It is never stored and cannot be recovered — write it down. The app won't start a recording until it is set.", comment: "Shown at the top of the passphrase sheet opened right after first pairing") }
        static var cannotRevealNote: String { NSLocalizedString("encryption.cannot_reveal_note", value: "The passphrase itself is never stored — only the key derived from it — so it can't be shown here. If you've forgotten it, use Rotate to set a new one.", comment: "Settings note explaining the passphrase can't be displayed") }

        // Download alerts (RecordingsView writeAndDecrypt)
        static func downloadFailedKeyMissing(_ name: String) -> String {
            String(format: NSLocalizedString("encryption.download.key_missing", value: "%@: this recording is encrypted, but no passphrase is set on this iPhone. Open Settings → Encryption passphrase → Set passphrase… to unlock it.", comment: "Alert when an encrypted file arrives with no local key"), name)
        }
        static func downloadFailedWrongKey(_ name: String, _ details: String) -> String {
            String(format: NSLocalizedString("encryption.download.wrong_key", value: "%1$@: couldn't decrypt — the passphrase doesn't match this recording. Open Settings → Encryption passphrase, clear the current one, and set the correct passphrase. (Details: %2$@)", comment: "Alert when an encrypted file fails to decrypt"), name, details)
        }
    }

    // MARK: - Pairing (v1.47 binding)

    enum Pairing {
        static var title: String { NSLocalizedString(
            "pairing.title",
            value: "Pair this Nomi?",
            comment: "Alert title when the device reports itself as unpaired after connect"
        ) }
        static func message(_ deviceName: String) -> String {
            String(
                format: NSLocalizedString(
                    "pairing.message",
                    value: "%@ needs to be paired with this app before it can record. You can unpair any time from the Device screen.",
                    comment: "Alert body for pairing request. %@ = device name"
                ),
                deviceName
            )
        }
        static var pair: String { NSLocalizedString(
            "pairing.pair", value: "Pair", comment: "Confirm pairing button") }
        /// Button that takes the user from a blocked action (record, live) to
        /// the Device screen's pairing entry, instead of leaving them in a
        /// dead-end alert (qhgmvqf4).
        static var goPair: String { NSLocalizedString(
            "pairing.go_pair",
            value: "Pair now",
            comment: "Button that navigates to the device pairing entry"
        ) }
        static var paired: String { NSLocalizedString(
            "pairing.paired", value: "Paired", comment: "Bond status row label when bound") }
        static var notPaired: String { NSLocalizedString(
            "pairing.not_paired", value: "Not paired", comment: "Bond status row label when unbound") }
        static var unpair: String { NSLocalizedString(
            "pairing.unpair", value: "Unpair this Nomi", comment: "Danger-zone button to remove the bond") }
        static var unpairMessage: String { NSLocalizedString(
            "pairing.unpair_message",
            value: "Unpair removes the device's pairing with this app. You'll need to pair again before recording.",
            comment: "Danger-zone confirmation dialog body"
        ) }
        static var unpairing: String { NSLocalizedString(
            "pairing.unpairing", value: "Unpairing…", comment: "Bottom pill while unpair is in flight") }
        static var pairingNow: String { NSLocalizedString(
            "pairing.pairing_now", value: "Pairing…", comment: "Bottom pill while pair is in flight") }
        static var pairStatus: String { NSLocalizedString(
            "pairing.status", value: "Pairing", comment: "Identity row label for bond status") }
    }

    // MARK: - Live

    enum Live {
        static var noDeviceConnected: String { NSLocalizedString("live.no_device", comment: "") }
        static var noDeviceMessage: String { NSLocalizedString("live.no_device_message", comment: "") }
        static var viewInLibrary: String { NSLocalizedString("live.view_in_library", comment: "") }
        /// After stopping recording **auto-save failed**, but when there are still bytes on hand, that button (user 2026-10-12 request).
        static var saveToLibrary: String { NSLocalizedString("live.save_to_library", comment: "") }
        /// The counterpart of the button above: this time it has already been auto-saved to the database, say it explicitly.
        static var savedToLibrary: String { NSLocalizedString("live.saved_to_library", comment: "") }
        static var clipNotInLibrary: String { NSLocalizedString("live.clip_not_in_library", comment: "") }
        static var sourceLanguage: String { NSLocalizedString("live.source_language", comment: "") }
        static var targetLanguage: String { NSLocalizedString("live.target_language", comment: "") }
        static var sameAsSource: String { NSLocalizedString("live.same_as_source", comment: "") }
        static var setupAzure: String { NSLocalizedString("live.setup_azure", comment: "") }
        /// ★ 2026-10-14: Local ASR + on-device LLM soft warning on this path.
        ///
        /// The semantics are deliberately written as "Transcription unchanged, just no translation", because this prompt **must not** let users
        /// think real-time transcription is broken — the transcription itself is fully normal, only half the content is missing.
        static var translateUnavailable: String { NSLocalizedString("live.translate_unavailable", comment: "") }
        static var switchLanguage: String { NSLocalizedString("live.switch_language", comment: "") }
        static var continueButton: String { NSLocalizedString("live.continue", comment: "") }
        static var listening: String { NSLocalizedString("live.listening", comment: "") }
        static var tapMicToStart: String { NSLocalizedString("live.tap_mic_to_start", comment: "") }
        static var searchLanguages: String { NSLocalizedString("live.search_languages", comment: "") }
        static func transcribeOnly(_ lang: String) -> String {
            String(format: NSLocalizedString("live.transcribe_only", comment: ""), lang)
        }
        static func translatePair(_ from: String, _ to: String) -> String {
            String(format: NSLocalizedString("live.translate_pair", comment: ""), from, to)
        }
        static var streaming: String { NSLocalizedString("live.streaming", comment: "") }
        static var ready: String { NSLocalizedString("live.ready", comment: "") }
        static var paused: String { NSLocalizedString("live.paused", comment: "") }
        static var repairTitle: String { NSLocalizedString("live.repair_title", comment: "") }
        static var repairMessage: String { NSLocalizedString("live.repair_message", comment: "") }
        static var repairMessageAttached: String { NSLocalizedString("live.repair_message_attached", comment: "") }
        static var repairNotPlayable: String { NSLocalizedString("live.repair_not_playable", comment: "") }
        static var repairReplace: String { NSLocalizedString("live.repair_replace", comment: "") }
        static var repairKeep: String { NSLocalizedString("live.repair_keep", comment: "") }
        static var repairDownloading: String { NSLocalizedString("live.repair_downloading", comment: "") }
        static var repairSucceeded: String { NSLocalizedString("live.repair_succeeded", comment: "") }
        static func repairFailed(_ msg: String) -> String {
            String(format: NSLocalizedString("live.repair_failed", comment: ""), msg)
        }
        static var repairManualTransfer: String { NSLocalizedString("live.repair_manual_transfer", comment: "") }
        static var startUnknownTitle: String { NSLocalizedString("live.start_unknown_title", comment: "") }
        static var startUnknownMessage: String { NSLocalizedString("live.start_unknown_message", comment: "") }
        static var startAnyway: String { NSLocalizedString("live.start_anyway", comment: "") }
        static var attachNoUpload: String { NSLocalizedString("live.attach_no_upload", comment: "") }
        /// Want to take over the "recording" line on the device, but the device is not recording at all (TicNote).
        static var attachNotRecording: String { NSLocalizedString(
            "live.attach_not_recording",
            value: "The device is not recording. Start a recording first, then attach.",
            comment: "Attach was requested while the recorder was idle"
        ) }
        /// Cannot obtain any usable session ID — without it we cannot request audio fragments from the card.
        static var noSessionID: String { NSLocalizedString(
            "live.no_session_id",
            value: "The device did not report a recording session id, so real-time streaming is unavailable for this recording.",
            comment: "No session id could be derived for the live pull"
        ) }
    }

    // MARK: - Scanner

    enum Scanner {
        static var scan: String { NSLocalizedString("scanner.scan", comment: "") }
        static var scanAgain: String { NSLocalizedString("scanner.scan_again", comment: "") }
        static var connectionFailed: String { NSLocalizedString("scanner.connection_failed", comment: "") }
        static var bluetoothUnavailable: String { NSLocalizedString("scanner.bluetooth_unavailable", comment: "") }
        static var lookingForDevices: String { NSLocalizedString("scanner.looking_for_devices", comment: "") }
        static var lookingMessage: String { NSLocalizedString("scanner.looking_message", comment: "") }
        static var sectionAvailable: String { NSLocalizedString("scanner.section_available", comment: "") }
        static var sectionAdded: String { NSLocalizedString("scanner.section_added", comment: "") }
        static var addedBadge: String { NSLocalizedString("scanner.added_badge", comment: "") }
        static var wakeAndRetry: String { NSLocalizedString(
            "scanner.wake_and_retry",
            value: "Device not found. Press and hold the device button for 1 second to wake it, then try again.",
            comment: "Manual reconnect timed out because a sleeping known device was not advertising"
        ) }
    }

    // MARK: - Connection Pill

    enum Pill {
        static var addDevice: String { NSLocalizedString("pill.add_device", comment: "") }
    }

    // MARK: - Fast Transfer

    enum FastTransfer {
        static var title: String { NSLocalizedString("fast_transfer.title", comment: "") }
        static var status: String { NSLocalizedString("fast_transfer.status", comment: "") }
        static var apCredentials: String { NSLocalizedString("fast_transfer.ap_credentials", comment: "") }
        static func filesCount(_ count: Int) -> String {
            String(format: NSLocalizedString("fast_transfer.files_count", comment: ""), count)
        }
        static var pendingStatus: String { NSLocalizedString("fast_transfer.pending", comment: "") }
        static var saved: String { NSLocalizedString("fast_transfer.saved", comment: "") }
        static var cancelled: String { NSLocalizedString("fast_transfer.cancelled", comment: "") }
        static var backgroundInterrupted: String { NSLocalizedString("fast_transfer.background_interrupted", comment: "") }
        static var stageReady: String { NSLocalizedString("fast_transfer.stage_ready", comment: "") }
        static var stageStopping: String { NSLocalizedString("fast_transfer.stage_stopping", comment: "") }
        static var stageStartingAP: String { NSLocalizedString("fast_transfer.stage_starting_ap", comment: "") }
        static func stagePollingAP(_ attempt: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("fast_transfer.stage_polling_ap", comment: ""), attempt, total)
        }
        static var stageJoiningWifi: String { NSLocalizedString("fast_transfer.stage_joining_wifi", comment: "") }
        static var stageJoinFailed: String { NSLocalizedString("fast_transfer.stage_join_failed", comment: "") }
        static var stageConnecting: String { NSLocalizedString("fast_transfer.stage_connecting", comment: "") }
        static var stageListing: String { NSLocalizedString("fast_transfer.stage_listing", comment: "") }
        static var stageDownloading: String { NSLocalizedString("fast_transfer.stage_downloading", comment: "") }
        static var stageCleanup: String { NSLocalizedString("fast_transfer.stage_cleanup", comment: "") }
        static var stageDone: String { NSLocalizedString("fast_transfer.stage_done", comment: "") }
        static var stageStopped: String { NSLocalizedString("fast_transfer.stage_stopped", comment: "") }
        static var hintPolling: String { NSLocalizedString("fast_transfer.hint_polling", comment: "") }
        static var hintJoining: String { NSLocalizedString("fast_transfer.hint_joining", comment: "") }
        static var hintJoinFailed: String { NSLocalizedString("fast_transfer.hint_join_failed", comment: "") }
        static var tcpUnreachable: String { NSLocalizedString("fast_transfer.tcp_unreachable", comment: "") }
        static var apStillOn: String { NSLocalizedString("fast_transfer.ap_still_on", comment: "") }
        static var hintConnecting: String { NSLocalizedString("fast_transfer.hint_connecting", comment: "") }
        static var apNotBroadcasting: String { NSLocalizedString("fast_transfer.ap_not_broadcasting", comment: "") }
        static var invalidPSK: String { NSLocalizedString("fast_transfer.invalid_psk", comment: "") }
        static func decodeFailed(_ name: String) -> String {
            String(format: NSLocalizedString("fast_transfer.decode_failed", comment: ""), name)
        }
    }

    // MARK: - Summarize

    enum Summarize {
        static var chooseTemplate: String { NSLocalizedString("summarize.choose_template", comment: "") }
        static var summarizing: String { NSLocalizedString("summarize.summarizing", comment: "") }
        static var error: String { NSLocalizedString("summarize.error", comment: "") }
        static func summarizingWith(_ provider: String) -> String {
            String(format: NSLocalizedString("summarize.summarizing_with", comment: ""), provider)
        }
        static var searchTemplates: String { NSLocalizedString("summarize.search_templates", comment: "") }
        // ★ 2026-10-15 七改：模板选择页从"一行行文字"改成"块状网格 + 概览页"。
        //
        // 用户原话："摘要模板里面不要直接文字，建议按照块显示当前结构，然后点击
        // 进去就是一个总体的概览"。所以块上只留名字（看清"有哪些"），说明与
        // 提示词全文挪进概览页（看"点下去会产出什么"）。
        //
        // ⚠️ 全部 `static var` + 内联英文兜底：同 `Library` 段那批的理由 ——
        // .lproj 只补 en / zh-Hans，其余 9 个语言靠 `value:` 挡住 key 字面量。
        static func templateCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString("summarize.template_count", value: "%d templates",
                                          comment: "Template grid: how many templates are in this category"),
                count
            )
        }
        static var builtInBadge: String {
            NSLocalizedString("summarize.builtin_badge", value: "Built-in",
                              comment: "Template card/overview: shipped with the app")
        }
        static var customBadge: String {
            NSLocalizedString("summarize.custom_badge", value: "Mine",
                              comment: "Template card/overview: created by the user")
        }
        /// 概览页里"这个模板是干什么的"那一段的标题。
        static var templateAbout: String {
            NSLocalizedString("summarize.template_about", value: "What it produces",
                              comment: "Overview page: label above the template's one-line description")
        }
        /// 概览页里提示词全文那一段的标题。
        static var templatePromptLabel: String {
            NSLocalizedString("summarize.template_prompt_label", value: "Prompt",
                              comment: "Overview page: label above the template's full prompt text")
        }
        /// 概览页底部的主按钮。
        static var useTemplate: String {
            NSLocalizedString("summarize.use_template", value: "Summarize with this template",
                              comment: "Overview page: primary button that starts the summary")
        }
        /// 概览页左上角的返回（这一页不是 push 进去的，系统不给返回箭头）。
        static var backToTemplates: String {
            NSLocalizedString("summarize.back_to_templates", value: "Templates",
                              comment: "Overview page: back button, returns to the template grid")
        }
        /// 概览页副标题（分类 + 条数之外的补充信息位）。目前只在无障碍里用。
        static var templateOverviewTitle: String {
            NSLocalizedString("summarize.template_overview_title", value: "Template",
                              comment: "Overview page: navigation title when the template has no name")
        }
        /// 模板搜不到东西时的空态。**必须有** —— 块状网格搜空之后整页是白的，
        /// 用户会以为页面加载坏了。
        static var noMatchingTemplates: String {
            NSLocalizedString("summarize.no_matching_templates",
                              value: "No templates match your search",
                              comment: "Template grid: search returned nothing")
        }
        static var truncatedWarning: String { NSLocalizedString("summarize.truncated_warning", comment: "Shown when the model hit its output cap") }
        /// 分段进度："第 %1$d/%2$d 段"。数字用等宽，免得位数变化时那行在抖。
        static func chunkProgress(_ done: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("summarize.chunk_progress", value: "Part %1$d of %2$d",
                                             comment: "Summarize sheet: progress while a long transcript is processed in parts"),
                   done, total)
        }
        /// 开工前的体检提示：主通道不能用，但有兜底。
        ///
        /// `gap` 已经是"Open Router 没有配置 API Key。"这样一句完整的话，
        /// 所以这里只负责把"将会用谁兜底"接上去。
        static func preflightFallback(_ gap: String, _ fallback: String) -> String {
            String(format: NSLocalizedString("summarize.preflight_fallback",
                                             value: "%1$@ It will fall back to %2$@.",
                                             comment: "Summarize sheet: the active provider is unusable, a fallback will be used"), gap, fallback)
        }
        static var addTemplate: String { NSLocalizedString("summarize.add_template", comment: "") }
        static var clone: String { NSLocalizedString("summarize.clone", comment: "") }
        static var category: String { NSLocalizedString("summarize.category", comment: "") }
        static var pickExisting: String { NSLocalizedString("summarize.pick_existing", comment: "") }
        static var new: String { NSLocalizedString("summarize.new", comment: "") }
        static var name: String { NSLocalizedString("summarize.name", comment: "") }
        static var templateName: String { NSLocalizedString("summarize.template_name", comment: "") }
        static var prompt: String { NSLocalizedString("summarize.prompt", comment: "") }
        static var newTemplate: String { NSLocalizedString("summarize.new_template", comment: "") }
        static var editTemplate: String { NSLocalizedString("summarize.edit_template", comment: "") }
        static func copyName(_ name: String) -> String {
            String(format: NSLocalizedString("summarize.copy_name", comment: ""), name)
        }
        static var newCategoryName: String { NSLocalizedString("summarize.new_category_name", comment: "") }
        static var outputLanguage: String { NSLocalizedString("summarize.output_language", comment: "") }
        static var sameAsTranscript: String { NSLocalizedString("summarize.same_as_transcript", comment: "") }
        static var restoreDefaults: String { NSLocalizedString("summarize.restore_defaults", comment: "") }
        static var restoreDefaultsTitle: String { NSLocalizedString("summarize.restore_defaults_title", comment: "") }
        static var restoreDefaultsMessage: String { NSLocalizedString("summarize.restore_defaults_message", comment: "") }
        static var deleteTitle: String { NSLocalizedString("summarize.delete_title", comment: "") }
        static func deleteMessage(_ name: String) -> String {
            String(format: NSLocalizedString("summarize.delete_message", comment: ""), name)
        }
    }

    // MARK: - Template Categories

    enum TemplateCategory {
        static var meetingNotes: String { NSLocalizedString("template_cat.meeting_notes", comment: "") }
        static var actionItems: String { NSLocalizedString("template_cat.action_items", comment: "") }
        static var generalSummary: String { NSLocalizedString("template_cat.general_summary", comment: "") }
        static var professional: String { NSLocalizedString("template_cat.professional", comment: "") }
        static var academic: String { NSLocalizedString("template_cat.academic", comment: "") }
        static var creative: String { NSLocalizedString("template_cat.creative", comment: "") }
    }

    // MARK: - Template Names

    enum TemplateName {
        static var formalMinutes: String { NSLocalizedString("template.formal_minutes", comment: "") }
        static var structuredMinutes: String { NSLocalizedString("template.structured_minutes", comment: "") }
        static var executiveBrief: String { NSLocalizedString("template.executive_brief", comment: "") }
        static var keyTakeaways: String { NSLocalizedString("template.key_takeaways", comment: "") }
        static var taskExtraction: String { NSLocalizedString("template.task_extraction", comment: "") }
        static var decisionLog: String { NSLocalizedString("template.decision_log", comment: "") }
        static var conciseSummary: String { NSLocalizedString("template.concise_summary", comment: "") }
        static var detailedNotes: String { NSLocalizedString("template.detailed_notes", comment: "") }
        static var qaFormat: String { NSLocalizedString("template.qa_format", comment: "") }
        static var clientMeetingRecap: String { NSLocalizedString("template.client_meeting_recap", comment: "") }
        static var oneOnOneSummary: String { NSLocalizedString("template.one_on_one_summary", comment: "") }
        static var statusUpdate: String { NSLocalizedString("template.status_update", comment: "") }
        static var lectureNotes: String { NSLocalizedString("template.lecture_notes", comment: "") }
        static var researchDiscussion: String { NSLocalizedString("template.research_discussion", comment: "") }
        static var brainstormSynthesis: String { NSLocalizedString("template.brainstorm_synthesis", comment: "") }
        static var interviewSummary: String { NSLocalizedString("template.interview_summary", comment: "") }
    }

    // MARK: - Jobs（后台任务总览）

    /// 四类长任务的**总览**文案（2026-10-16 十二改）。
    ///
    /// 这一层只解决"看得见"：摘要 / 翻译 / 格式转换的调度在 `JobQueue`，
    /// 转录仍在 `TranscriptionService`，但两者在总览页里摆进同一个列表。
    ///
    /// ⚠️ 文案口径与 `ASR.queue_*` 那批保持一致：**别写"静音音频"**。用户要的
    ///    判断是"我切走之后它还会不会继续"，不是我们怎么把进程顶住的。
    enum Jobs {

        // MARK: 活的种类（`JobKind.title`）

        static var kindTranscribe: String {
            NSLocalizedString("jobs.kind_transcribe", value: "Transcription",
                              comment: "Task list: an ASR transcription job")
        }
        static var kindSummarize: String {
            NSLocalizedString("jobs.kind_summarize", value: "Summary",
                              comment: "Task list: a summary-generation job")
        }
        static var kindTranslate: String {
            NSLocalizedString("jobs.kind_translate", value: "Translation",
                              comment: "Task list: a translation job")
        }
        static var kindExport: String {
            NSLocalizedString("jobs.kind_export", value: "Audio export",
                              comment: "Task list: an audio format-conversion job")
        }

        // MARK: 副标题（`Job.detail`）

        static func detailTranslatedTranscript(_ language: String) -> String {
            String(format: NSLocalizedString("jobs.detail_translated_transcript",
                                             value: "Transcript → %@",
                                             comment: "Task list subtitle: translating the transcript into this language"),
                   language)
        }
        static func detailTranslatedSummary(_ language: String) -> String {
            String(format: NSLocalizedString("jobs.detail_translated_summary",
                                             value: "Summary → %@",
                                             comment: "Task list subtitle: translating the summary into this language"),
                   language)
        }

        // MARK: 源头不见了（`JobSourceMissing`）

        static var sourcePrompt: String {
            NSLocalizedString("jobs.source_prompt", value: "The summary prompt",
                              comment: "JobSourceMissing subject: the job recorded no prompt")
        }
        static var sourceLanguage: String {
            NSLocalizedString("jobs.source_language", value: "The target language",
                              comment: "JobSourceMissing subject: the job recorded no target language")
        }
        static var sourceFormat: String {
            NSLocalizedString("jobs.source_format", value: "The export format",
                              comment: "JobSourceMissing subject: the job recorded no export format")
        }
        static var sourceAudio: String {
            NSLocalizedString("jobs.source_audio", value: "The audio file",
                              comment: "JobSourceMissing subject: the recording's audio is gone")
        }
        static var sourceTranscript: String {
            NSLocalizedString("jobs.source_transcript", value: "The transcript",
                              comment: "JobSourceMissing subject: the transcript is gone")
        }
        static var sourceSummary: String {
            NSLocalizedString("jobs.source_summary", value: "The summary",
                              comment: "JobSourceMissing subject: the summary is gone")
        }
        /// "这东西已经不在了"。**不是**"任务失败" —— 它是**永远不会成功**的那
        /// 一种，所以队列直接把它从台账里抹掉，不会白试三次。
        static func sourceMissing(_ what: String) -> String {
            String(format: NSLocalizedString("jobs.source_missing",
                                             value: "%@ is no longer available.",
                                             comment: "Shown when a queued task's source file has been deleted"),
                   what)
        }
        static var noRunner: String {
            NSLocalizedString("jobs.no_runner", value: "This kind of task isn't supported in this build.",
                              comment: "Internal error: no runner registered for a job kind")
        }

        // MARK: 总览页

        static var pageTitle: String {
            NSLocalizedString("jobs.page_title", value: "Background tasks",
                              comment: "Task center: navigation title")
        }
        static var empty: String {
            NSLocalizedString("jobs.empty",
                              value: "Nothing here right now. Summaries, translations and audio conversions you start will show up on this page.",
                              comment: "Task center: empty state")
        }
        static var sectionActive: String {
            NSLocalizedString("jobs.section_active", value: "In progress",
                              comment: "Task center: section header for unfinished jobs")
        }
        static var sectionFinished: String {
            NSLocalizedString("jobs.section_finished", value: "Finished",
                              comment: "Task center: section header for finished jobs")
        }
        static var clearFinished: String {
            NSLocalizedString("jobs.clear_finished", value: "Clear finished",
                              comment: "Task center: button that removes finished rows")
        }
        static var footer: String {
            NSLocalizedString("jobs.footer",
                              value: "These tasks keep running when you switch away or lock your phone. If the app is closed, they pick up again the next time you open it.",
                              comment: "Task center: explanation of background continuation")
        }
        /// 发起之后那句"你可以走了"。
        static var canLeaveHint: String {
            NSLocalizedString("jobs.can_leave_hint",
                              value: "You can leave this screen — it keeps running in the background.",
                              comment: "Shown under a running task: the user does not have to stay on the page")
        }

        // MARK: 状态

        static var statusWaiting: String {
            NSLocalizedString("jobs.status_waiting", value: "Waiting", comment: "Job status chip")
        }
        static var statusRunning: String {
            NSLocalizedString("jobs.status_running", value: "Running", comment: "Job status chip")
        }
        static var statusDone: String {
            NSLocalizedString("jobs.status_done", value: "Done", comment: "Job status chip")
        }
        static var statusGaveUp: String {
            NSLocalizedString("jobs.status_gave_up", value: "Gave up",
                              comment: "Job status chip: exhausted its retries")
        }
        static func attempts(_ attempts: Int, _ max: Int) -> String {
            String(format: NSLocalizedString("jobs.attempts", value: "Attempt %1$d of %2$d",
                                             comment: "Job row: how many tries have been used"),
                   attempts, max)
        }
        static func progress(_ done: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("jobs.progress", value: "Part %1$d of %2$d",
                                             comment: "Job row: chunked progress"),
                   done, total)
        }

        // MARK: 行内操作

        static var retry: String {
            NSLocalizedString("jobs.retry", value: "Try again", comment: "Job row: retry action")
        }
        static var cancel: String {
            NSLocalizedString("jobs.cancel", value: "Cancel", comment: "Job row: cancel action")
        }
        static var remove: String {
            NSLocalizedString("jobs.remove", value: "Remove", comment: "Job row: dismiss this row")
        }

        // MARK: 入口（设置页 / 详情页）

        static var openQueue: String {
            NSLocalizedString("jobs.open_queue", value: "Background tasks",
                              comment: "Settings row: opens the task center")
        }
        static var openQueueFooter: String {
            NSLocalizedString("jobs.open_queue_footer",
                              value: "Summaries, translations and audio conversions carry on after you leave the app.",
                              comment: "Settings row footer: what the task center is for")
        }
        /// 入队成功的轻提示。
        static func enqueuedToast(_ kind: String) -> String {
            String(format: NSLocalizedString("jobs.enqueued_toast",
                                             value: "%@ added to background tasks.",
                                             comment: "Toast shown right after a task is queued"),
                   kind)
        }
    }
}

// swiftlint:enable type_body_length file_length
