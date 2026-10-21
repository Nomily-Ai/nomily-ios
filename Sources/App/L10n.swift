import Foundation

// swiftlint:disable type_body_length file_length

enum L10n {

    // MARK: - Top banner

    /// The "transcript ready" toast that slides down under the navigation bar
    /// when a background transcription finishes.
    enum Banner {
        static var transcribeDone: String {
            NSLocalizedString("banner.transcribe_done", value: "Transcript ready",
                              comment: "Top banner shown when a recording finishes transcribing")
        }
    }

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
        /// Generic back. For pages that are **not pushed** and get no system back chevron.
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

    /// PLAUD cloud sync (2026-10-21 dual-mode support).
    enum Plaud {
        static var navTitle: String { NSLocalizedString("plaud.nav_title", value: "PLAUD", comment: "Settings page title for PLAUD cloud sync") }
        static var signInHeader: String { NSLocalizedString("plaud.signin_header", value: "Sign in", comment: "PLAUD email+code sign-in section") }
        static var emailPlaceholder: String { NSLocalizedString("plaud.email", value: "PLAUD account email", comment: "") }
        static var codePlaceholder: String { NSLocalizedString("plaud.code", value: "Verification code", comment: "") }
        static var sendCode: String { NSLocalizedString("plaud.send_code", value: "Send verification code", comment: "") }
        static var codeSent: String { NSLocalizedString("plaud.code_sent", value: "Code sent — check your email.", comment: "") }
        static var signIn: String { NSLocalizedString("plaud.sign_in", value: "Sign in", comment: "") }
        static var connectedHeader: String { NSLocalizedString("plaud.connected_header", value: "PLAUD account", comment: "") }
        static var accountLabel: String { NSLocalizedString("plaud.account", value: "Email", comment: "") }
        static var syncHeader: String { NSLocalizedString("plaud.sync_header", value: "Cloud sync", comment: "") }
        static var syncNow: String { NSLocalizedString("plaud.sync_now", value: "Sync recordings now", comment: "") }
        static var syncFooter: String { NSLocalizedString("plaud.sync_footer", value: "Downloads the original audio that the official PLAUD app uploaded to the cloud. New recordings appear in the library and are transcribed with your own ASR/LLM keys.", comment: "") }
        static func syncResult(_ done: Int, _ skipped: Int) -> String {
            String(format: NSLocalizedString("plaud.sync_result", value: "Downloaded %d, already present %d", comment: "Cloud sync pass result"), done, skipped)
        }
        static var signOut: String { NSLocalizedString("plaud.sign_out", value: "Sign out", comment: "") }
        static var guideHeader: String { NSLocalizedString("plaud.guide_header", value: "How this works", comment: "") }
        static var guideAudio: String { NSLocalizedString("plaud.guide_audio", value: "Pulls the ORIGINAL audio from the PLAUD cloud — never the official transcript", comment: "") }
        static var guideKeys: String { NSLocalizedString("plaud.guide_keys", value: "Transcription and summaries always use your own ASR/LLM keys", comment: "") }
        static var guideOfficialApp: String { NSLocalizedString("plaud.guide_app", value: "The official PLAUD app keeps working untouched — nothing is unbound", comment: "") }

        // Direct connect (SDK takeover) — the primary mode (2026-10-21)
        static var addTitle: String { NSLocalizedString("plaud.add_title", value: "Add PLAUD device", comment: "Title of the add-device sheet opened from the scan page") }
        static var addRowCaption: String { NSLocalizedString("plaud.add_row_caption", value: "Direct connect — pull the original recordings", comment: "Caption on the PLAUD row in the scan page") }
        static var directHeader: String { NSLocalizedString("plaud.direct_header", value: "Direct connect (recommended)", comment: "SDK direct-connect section header") }
        static var directFooter: String { NSLocalizedString("plaud.direct_footer", value: "Scans the card over Bluetooth and pulls the ORIGINAL audio files directly — no PLAUD account involved. First takeover requires unbinding the card once in the official PLAUD app (recordings on the card are kept).", comment: "") }
        static var clientId: String { NSLocalizedString("plaud.client_id", value: "Client ID", comment: "PLAUD developer Client ID field") }
        static var clientSecret: String { NSLocalizedString("plaud.client_secret", value: "Client Secret", comment: "PLAUD developer Client Secret field") }
        static var domain: String { NSLocalizedString("plaud.domain", value: "Platform domain", comment: "PLAUD developer platform host") }
        static var devHint: String { NSLocalizedString("plaud.dev_hint", value: "One-time setup: get the Client ID and Client Secret at dev.plaud.ai. Your PLAUD app account (phone or email) is NOT involved.", comment: "") }
        static var directActivate: String { NSLocalizedString("plaud.direct_activate", value: "Activate direct connect", comment: "") }
        static var directActivated: String { NSLocalizedString("plaud.direct_activated", value: "Direct connect active", comment: "") }
        static var scan: String { NSLocalizedString("plaud.scan", value: "Scan for device", comment: "") }
        static var scanning: String { NSLocalizedString("plaud.scanning", value: "Scanning…", comment: "") }
        static var connect: String { NSLocalizedString("plaud.connect", value: "Connect", comment: "") }
        static func connectedTo(_ sn: String) -> String {
            String(format: NSLocalizedString("plaud.connected_to", value: "Connected: %@", comment: ""), sn)
        }
        static var syncFromCard: String { NSLocalizedString("plaud.sync_from_card", value: "Pull recordings from card", comment: "") }
        static var deleteAfterSync: String { NSLocalizedString("plaud.delete_after_sync", value: "Delete from card after pull", comment: "") }
        static var deactivate: String { NSLocalizedString("plaud.deactivate", value: "Deactivate direct connect", comment: "") }
        static var unbindKeep: String { NSLocalizedString("plaud.unbind_keep", value: "Unbind card (keep recordings)", comment: "Release the card so another app can pair it; recordings stay") }
        static var factoryReset: String { NSLocalizedString("plaud.factory_reset", value: "Factory reset (erase card)", comment: "Unbind AND wipe all recordings — for returns") }
        static var factoryResetTitle: String { NSLocalizedString("plaud.factory_reset_title", value: "Erase everything on the card?", comment: "") }
        static var factoryResetMsg: String { NSLocalizedString("plaud.factory_reset_msg", value: "All recordings on the card will be erased and the binding released — the card becomes like new. This cannot be undone.", comment: "") }
        static var erase: String { NSLocalizedString("plaud.erase", value: "Erase", comment: "") }
        static var released: String { NSLocalizedString("plaud.released", value: "Card released — the official PLAUD app can pair it again.", comment: "") }
        static var pairRejected: String { NSLocalizedString("plaud.pair_rejected", value: "The card refused the connection — unbind it once in the official PLAUD app (Settings → device → unbind), then retry.", comment: "") }
        static var cloudNote: String { NSLocalizedString("plaud.cloud_note", value: "Optional compatibility path. Requires a PLAUD account registered with an EMAIL (phone-number accounts are rejected). The card stays bound to the official app.", comment: "") }
        static func syncStarting(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.sync_starting", value: "Pulling %d recording(s)…", comment: ""), count)
        }
        static func syncDownloading(_ index: Int) -> String {
            String(format: NSLocalizedString("plaud.sync_downloading", value: "Transferring file %d…", comment: ""), index)
        }
        static var syncDone: String { NSLocalizedString("plaud.sync_done", value: "All recordings pulled.", comment: "") }
        static func syncFailed(_ msg: String) -> String {
            String(format: NSLocalizedString("plaud.sync_failed", value: "Pull failed: %@", comment: ""), msg)
        }
    }

    enum Settings {
        static var asrProviders: String { NSLocalizedString("settings.asr_providers", comment: "") }
        static var llmProviders: String { NSLocalizedString("settings.llm_providers", comment: "") }
        static var recordings: String { NSLocalizedString("settings.recordings", comment: "") }
        static var summarizeTemplates: String { NSLocalizedString("settings.summarize_templates", comment: "") }
        static var devicesAndLibrary: String { NSLocalizedString("settings.devices_library", comment: "") }
        static var about: String { NSLocalizedString("settings.about", comment: "") }
        static var version: String { NSLocalizedString("settings.version", comment: "") }
        static var language: String { NSLocalizedString("settings.language", comment: "") }
        static var theme: String {
            NSLocalizedString("settings.theme", value: "Theme", comment: "Colour theme row")
        }
    }

    // MARK: - Theme

    enum Theme {
        static var footer: String {
            NSLocalizedString(
                "theme.footer",
                value: "The theme controls the app's main colour — buttons, links, selection and the active state of the connection pill. The launch screen keeps Nomily's brand red, so red stays the default.",
                comment: "Colour theme picker footer"
            )
        }
    }

    // MARK: - DingTalk A1 credential import

    /// Copy for `DingTalkA1SetupView`.
    ///
    /// Every string here explains a step that **cannot** be automated away, so the wording is
    /// deliberately plain: "one secret per card, here is how you get it, here is what it does
    /// not do". Vague copy at this point reads as a request to trust a black box.
    enum A1 {
        static var title: String {
            NSLocalizedString("a1.title", value: "DingTalk A1", comment: "A1 credential page title")
        }
        static var intro: String {
            NSLocalizedString(
                "a1.intro",
                value: "Every DingTalk A1 has its own device secret. DingTalk issues it when the card is bound to an account; it can't be derived from the serial number and it is never sent over Bluetooth. So the first time, it has to be taken out of one signed-in DingTalk session — after that, listing, downloading and transcribing all happen offline, with no DingTalk involved.",
                comment: "A1 credential page intro"
            )
        }
        static var step1Title: String {
            NSLocalizedString("a1.step1.title", value: "Bind the card to your DingTalk account",
                              comment: "A1 setup step 1 title")
        }
        static var step1Body: String {
            NSLocalizedString(
                "a1.step1.body",
                value: "Bought it second-hand? Ask the seller to unbind it first, then scan the code in DingTalk to bind it yourself. Only you can do this step — it decides which account the card hands its secret to.",
                comment: "A1 setup step 1 body"
            )
        }
        static var step2Title: String {
            NSLocalizedString("a1.step2.title", value: "Open “AI Notes” once on the desktop app",
                              comment: "A1 setup step 2 title")
        }
        static var step2Body: String {
            NSLocalizedString(
                "a1.step2.body",
                value: "Any template will do. DingTalk writes the device list — secret included — into its own log on that computer.",
                comment: "A1 setup step 2 body"
            )
        }
        static var step3Title: String {
            NSLocalizedString("a1.step3.title", value: "Run one command on that Mac",
                              comment: "A1 setup step 3 title")
        }
        static var step3Body: String {
            NSLocalizedString(
                "a1.step3.body",
                value: "It turns the secret into one line of text and copies it to the clipboard.",
                comment: "A1 setup step 3 body"
            )
        }
        static var copyCommand: String {
            NSLocalizedString("a1.copy_command", value: "Copy the command", comment: "")
        }
        static var commandFooter: String {
            NSLocalizedString(
                "a1.command_footer",
                value: "The extractor only reads DingTalk's log on this Mac. It doesn't touch the card, the firmware or your DingTalk account.",
                comment: ""
            )
        }
        static var pasteSection: String {
            NSLocalizedString("a1.paste.section", value: "Paste the credential", comment: "")
        }
        static var pastePlaceholder: String {
            NSLocalizedString("a1.paste.placeholder",
                              value: "Paste what the command copied…", comment: "")
        }
        static var pasteFromClipboard: String {
            NSLocalizedString("a1.paste.from_clipboard", value: "Paste", comment: "")
        }
        static var importAction: String {
            NSLocalizedString("a1.import", value: "Import", comment: "")
        }
        static var pasteFooter: String {
            NSLocalizedString(
                "a1.paste.footer",
                value: "Accepts the one-line form, the JSON the extractor writes, or key=value lines.",
                comment: ""
            )
        }
        static var importedHeader: String {
            NSLocalizedString("a1.imported.header", value: "Imported", comment: "")
        }
        static var importedOK: String {
            NSLocalizedString("a1.imported.ok", value: "Ready — reconnect the card to use it", comment: "")
        }
        static var cardName: String { NSLocalizedString("a1.card.name", value: "Card", comment: "") }
        static var cardSN: String { NSLocalizedString("a1.card.sn", value: "Serial", comment: "") }
        static var cardSecret: String {
            NSLocalizedString("a1.card.secret", value: "Secret", comment: "")
        }
        static var cardsHeader: String {
            NSLocalizedString("a1.cards.header", value: "Cards on this phone", comment: "")
        }
        static var cardsFooter: String {
            NSLocalizedString(
                "a1.cards.footer",
                value: "The secret is kept in the iOS keychain only — never in the settings file, never uploaded anywhere. Swipe a card to remove it; the card itself is untouched.",
                comment: ""
            )
        }
        static var deleteTitle: String {
            NSLocalizedString("a1.delete.title", value: "Remove this card's credential?", comment: "")
        }
        static var deleteMessage: String {
            NSLocalizedString(
                "a1.delete.message",
                value: "Nomily will no longer be able to read this card. Recordings on the card are not affected.",
                comment: ""
            )
        }
        static var importFailed: String {
            NSLocalizedString("a1.import_failed", value: "Couldn't import that", comment: "")
        }

        // MARK: QR / deep link

        /// Button on the import page. A QR code removes the clipboard from the loop entirely,
        /// which is where "paste it from your Mac" used to fall down.
        static var scanAction: String {
            NSLocalizedString("a1.scan.action", value: "Scan QR code", comment: "")
        }
        static var scanHint: String {
            NSLocalizedString(
                "a1.scan.hint",
                value: "Point the camera at the QR code the command printed on your Mac.",
                comment: ""
            )
        }
        static var scanDenied: String {
            NSLocalizedString(
                "a1.scan.denied",
                value: "Camera access is off for Nomily. Turn it on in Settings → Nomily AI → Camera, or paste the line instead.",
                comment: ""
            )
        }
        static var scanNoCamera: String {
            NSLocalizedString("a1.scan.no_camera", value: "No camera available here.",
                              comment: "")
        }
        static var scanFailed: String {
            NSLocalizedString(
                "a1.scan.failed",
                value: "That QR code isn't a DingTalk A1 credential. Use the one printed by the extractor on your Mac.",
                comment: ""
            )
        }
        /// Shown when the app is opened from a scanned code / tapped link.
        static var importedFromLink: String {
            NSLocalizedString("a1.link.imported", value: "Credential imported",
                              comment: "")
        }
        static func importedFromLinkBody(_ name: String) -> String {
            String(format: NSLocalizedString("a1.link.imported_body",
                                             value: "%@ is ready. Go back and tap “Try again”.",
                                             comment: ""), name)
        }

        /// Row shown next to a failed read on an A1 device page — the way into this sheet
        /// without hunting through Settings.
        static var openImport: String {
            NSLocalizedString("a1.open_import", value: "Import this card's key", comment: "A1 device page error CTA")
        }

        // MARK: Per-card credential section (device info page)

        /// Header of the section on **one card's** device-info page.
        static var sectionTitle: String {
            NSLocalizedString("a1.section.title", value: "Card key", comment: "Per-card credential section header")
        }
        static var sectionFooter: String {
            NSLocalizedString(
                "a1.section.footer",
                value: "This key belongs to this card alone — it is not an app-wide setting. Another A1 needs its own. It is stored in the iOS keychain and never leaves the phone.",
                comment: "Per-card credential section footer"
            )
        }
        static var missingTitle: String {
            NSLocalizedString("a1.missing.title",
                              value: "No key on this phone yet — the card can't be read until one is imported.",
                              comment: "Per-card credential section, empty state")
        }
        static var replace: String {
            NSLocalizedString("a1.replace", value: "Replace key", comment: "Re-import a card's secret")
        }
        static var remove: String {
            NSLocalizedString("a1.remove", value: "Delete key", comment: "Remove this card's secret")
        }
        static var pasteManually: String {
            NSLocalizedString("a1.paste.manually", value: "Paste it instead", comment: "Expands an inline paste box")
        }
        static var howTo: String {
            NSLocalizedString("a1.how_to", value: "How do I get this key?", comment: "Opens the explainer page")
        }
        static func scopedTo(_ card: String) -> String {
            String(format: NSLocalizedString("a1.scoped_to", value: "For %@ only",
                                             comment: "Header line on the explainer, naming the card"), card)
        }
        /// Shown when the imported secret belongs to a different card than the one on screen.
        static func mismatch(_ importedSN: String, _ expectedTail: String) -> String {
            String(
                format: NSLocalizedString(
                    "a1.mismatch",
                    value: "Saved, but its serial ends in %@ — this card's ends in %@. If you meant this card, import that card's own key.",
                    comment: "Warning when the imported secret is for another card"
                ),
                importedSN, expectedTail
            )
        }

        /// The error `DingTalkA1Link` throws when the card connects but no credential is on
        /// file. Must name the exact place to go, because this string is all the user sees.
        static var errorNoCredential: String {
            NSLocalizedString(
                "a1.error.no_credential",
                value: "This card has no key on this phone yet. Open this card's info page → “Card key” to scan or paste it — a one-time step, after which everything runs offline.",
                comment: "A1 missing-credential error"
            )
        }

        /// `0x0133` answered 501 — the stored secret belongs to a different card.
        static var errorRejected: String {
            NSLocalizedString(
                "a1.error.rejected",
                value: "The card rejected the stored credential (501). Each card's secret works only on that card — import this card's own credential in Settings → DingTalk A1.",
                comment: "A1 credential rejected error"
            )
        }

        /// `0x0133` answered 405 — the card considers this session unauthenticated (usually a
        /// stale link after the card rebooted or connected to something else).
        static var errorNotAuthenticated: String {
            NSLocalizedString(
                "a1.error.not_authenticated",
                value: "The card says this session isn't authenticated (405). Disconnect and reconnect the card, then try again.",
                comment: "A1 session not authenticated error"
            )
        }

        /// The stored secret can't mathematically produce a token (too short).
        static var errorBadSecret: String {
            NSLocalizedString(
                "a1.error.bad_secret",
                value: "The stored credential's secret is too short to produce a token. Re-import it in Settings → DingTalk A1.",
                comment: "A1 malformed secret error"
            )
        }

        // MARK: Extractor command (editable, machine-specific by nature)

        static var commandEditorTitle: String {
            NSLocalizedString("a1.command.editor_title", value: "Extractor command", comment: "")
        }
        static var commandEditorFooter: String {
            NSLocalizedString(
                "a1.command.editor_footer",
                value: "The script ships with the Nomily tool package; point this at wherever it lives on your Mac. Example: cd <the tools folder> && python3 extract_secret_from_dingtalk_mac.py --copy",
                comment: ""
            )
        }
    }

    // MARK: - Language

    enum Language {
        static var followSystem: String { NSLocalizedString("language.follow_system", comment: "") }
        static var footer: String { NSLocalizedString("language.footer", comment: "") }
    }

    // MARK: - Setup assistant ("one-prompt deploy" for local ASR + Ollama, 2026-10-20)

    enum Setup {
        static var assistantTitle: String {
            NSLocalizedString("setup.assistant_title", value: "Copy AI Setup Prompt",
                              comment: "Row under the local-ASR / Ollama config: copies the one-shot prompt for ChatGPT / Claude Code")
        }
        static var assistantCopied: String {
            NSLocalizedString("setup.assistant_copied", value: "Copied — paste into ChatGPT or Claude Code",
                              comment: "Confirmation shown after the setup prompt lands on the pasteboard")
        }
        static var assistantHint: String {
            NSLocalizedString("setup.assistant_hint", value: "Run it on your computer; it installs local transcription + Ollama and prints the values to fill in here.",
                              comment: "What the setup prompt does, so tapping the row needs no explanation elsewhere")
        }
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
        // ★ 2026-10-18: on-device recognition + LLM summary after transcription.
        //
        // "On-device" here means **the phone's own model** (Apple Speech, offline), a third
        // thing next to "Azure" and "local server" — the latter is a whisper box on the LAN, and
        // calling both "local" made the settings page unreadable. The label says the device, the
        // footer says what it costs (nothing) and what it can't do (no translation stream).
        static var onDevice: String { NSLocalizedString("asr.on_device", comment: "") }
        static var onDeviceFooter: String { NSLocalizedString("asr.on_device_footer", comment: "") }
        static var onDeviceUnauthorized: String { NSLocalizedString("asr.on_device_unauthorized", comment: "") }
        /// Build-time misconfiguration, not a user-facing preference — see
        /// `OnDeviceASR.hasUsageDescription`. Shown instead of a SIGABRT.
        static var onDeviceNotDeclared: String { NSLocalizedString("asr.on_device_not_declared", comment: "") }
        static func onDeviceUnavailable(_ locale: String) -> String {
            String(format: NSLocalizedString("asr.on_device_unavailable", comment: ""), locale)
        }
        static func onDeviceDecodeFailed(_ detail: String) -> String {
            String(format: NSLocalizedString("asr.on_device_decode_failed", comment: ""), detail)
        }
        static var autoSummarize: String { NSLocalizedString("asr.auto_summarize", comment: "") }
        static var autoSummarizeFooter: String { NSLocalizedString("asr.auto_summarize_footer", comment: "") }
        static var liveRecordingWithoutASR: String { NSLocalizedString("asr.live_recording_without_asr", comment: "") }
        // ★ 2026-10-15: Background keep-alive toggle + transcription queue status.
        //
        // Wording rule: **never say "silent audio"**. Users don't need to know how we keep the process alive;
        // what they need to judge is "will it keep going after I switch away" and "will it drain the battery / make strange noises".
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
            value: "The app uses two ports on your server: this one for live streaming, and the one right after it for file transcription. Tap the check button to confirm both are answering. ⚠️ Plaintext LAN only (http/ws) — trusted networks or Tailscale; never a public address. For a public server use the Remote Live Server below.",
            comment: "Footer under the local ASR server section explaining the two-port probe"
        ) }
        // ---- Custom (OpenAI-compatible) ASR server ----
        static var customServer: String { NSLocalizedString(
            "asr.custom_server",
            value: "Custom Server (OpenAI-compatible)",
            comment: "Section header for the user-defined ASR provider"
        ) }
        static var customEndpoint: String { NSLocalizedString(
            "asr.custom_endpoint",
            value: "Server address",
            comment: "Placeholder for the custom ASR base URL"
        ) }
        static var customApiKey: String { NSLocalizedString(
            "asr.custom_api_key",
            value: "API key (optional)",
            comment: "Placeholder for the custom ASR bearer token"
        ) }
        static var customModel: String { NSLocalizedString(
            "asr.custom_model",
            value: "Model (default whisper-1)",
            comment: "Placeholder for the custom ASR model name"
        ) }
        static var customLoadModels: String { NSLocalizedString(
            "asr.custom_load_models",
            value: "Load model list",
            comment: "Button: fetch the model list from the custom ASR server"
        ) }
        static var customModelsManual: String { NSLocalizedString(
            "asr.custom_models_manual",
            value: "Enter manually",
            comment: "Button: abandon the fetched model list and type the name by hand"
        ) }
        static func customModelsLoaded(_ count: Int) -> String {
            String(format: NSLocalizedString(
                "asr.custom_models_loaded",
                value: "%d transcription-capable model(s) from the server",
                comment: "Caption under the custom ASR model picker"), count)
        }
        static var customModelsNone: String { NSLocalizedString(
            "asr.custom_models_none",
            value: "No usable model list from the server — type the model name manually.",
            comment: "Shown when the custom ASR server has no /models or the filter is empty"
        ) }
        static var customLanguage: String { NSLocalizedString(
            "asr.custom_language",
            value: "Language hint (optional, e.g. zh)",
            comment: "Placeholder for the custom ASR language hint"
        ) }
        static var customProbe: String { NSLocalizedString(
            "asr.custom_probe",
            value: "Test connection",
            comment: "Row label: probes the custom ASR server"
        ) }
        static var customProbeFooter: String { NSLocalizedString(
            "asr.custom_probe_footer",
            value: "Speak the OpenAI /v1/audio/transcriptions API — works with faster-whisper-server, whisper.cpp, Groq and similar. Accepts LAN http and secure remote https (a configured API key is sent with every request). File transcription only; leave the language empty for auto-detection (do not force zh on mixed speech).",
            comment: "Footer under the custom ASR section"
        ) }

        // ---- Remote live (WSS) ASR server — ★ 2026-10-20 ----
        static var remoteLive: String { NSLocalizedString(
            "asr.remote_live",
            value: "Remote Live Server (secure)",
            comment: "Section header for the remote WSS live-transcription provider"
        ) }
        static var remoteEndpoint: String { NSLocalizedString(
            "asr.remote_endpoint",
            value: "Server address (wss://…)",
            comment: "Placeholder for the remote live WSS endpoint; wss required"
        ) }
        static var remoteApiKey: String { NSLocalizedString(
            "asr.remote_api_key",
            value: "API Key (required)",
            comment: "Placeholder for the remote live bearer token; stored in the Keychain"
        ) }
        static var remoteProbe: String { NSLocalizedString(
            "asr.remote_probe",
            value: "Test connection",
            comment: "Row label: probes the remote live server via HTTPS /health"
        ) }
        static var remoteFooter: String { NSLocalizedString(
            "asr.remote_footer",
            value: "Encrypted WSS with API-key auth — for servers on the public internet. Live transcription only (file transcription uses the Custom Server above); set it as primary and keep the LAN server as fallback to fail over automatically. The key is stored in the Keychain and never logged.",
            comment: "Footer under the remote live server section"
        ) }
        static var remoteErrInvalidScheme: String { NSLocalizedString(
            "asr.remote_err_invalid_scheme",
            value: "This field needs a wss:// address — plaintext ws:// is only for the trusted-LAN server above",
            comment: "Remote live error: endpoint is not (and cannot be normalized to) wss"
        ) }
        static var remoteErrMissingKey: String { NSLocalizedString(
            "asr.remote_err_missing_key",
            value: "The remote service requires an API Key",
            comment: "Remote live error: no key configured"
        ) }
        static var remoteErrAuth: String { NSLocalizedString(
            "asr.remote_err_auth",
            value: "Authentication failed — the API Key was rejected (401/403)",
            comment: "Remote live error: server reachable but key invalid"
        ) }
        static func remoteErrHandshake(_ detail: String?) -> String {
            let base = NSLocalizedString(
                "asr.remote_err_handshake",
                value: "Server reachable, but the secure WebSocket upgrade failed — check the address and that the server speaks WSS",
                comment: "Remote live error: HTTPS reachable, WS handshake failed")
            return detail.map { "\(base) (\($0))" } ?? base
        }
        static var remoteErrTimeout: String { NSLocalizedString(
            "asr.remote_err_timeout",
            value: "Connection timed out — the server did not answer",
            comment: "Remote live error: no response within the timeout"
        ) }
        static var remoteErrServer: String { NSLocalizedString(
            "asr.remote_err_server",
            value: "The server closed the connection",
            comment: "Remote live error: stream dropped after it was up"
        ) }

        static var customProbeAuth: String { NSLocalizedString(
            "asr.custom_probe_auth",
            value: "Server reachable, but the API key was rejected (401) — check the key",
            comment: "Probe result: server answered 401/403"
        ) }
        static func customProbeHTTP(_ code: Int) -> String {
            String(format: NSLocalizedString(
                "asr.custom_probe_http",
                value: "Server answered HTTP %d — is this really an OpenAI-compatible ASR endpoint?",
                comment: "Probe reached the server but it answered with an unexpected status"
            ), code)
        }
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
        // MARK: Reasons a call fails (★ 2026-10-15)
        //
        // These used to be **hardcoded in English inside `LLMCompletionError.errorDescription`**;
        // the Chinese UI would pop up "No API key configured for the active provider." —
        // users could neither understand it nor tell where to fix it. Now everything is localised, and
        // **the channel name is included**: "No API key configured for Open Router."
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
        /// The entire chain failed. **List the reason for every channel** — reporting only the last one would
        /// send users digging into the fallback channel (local Ollama) when the real culprit is the missing key on the first channel.
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
        /// The one-line explanation shown after the primary channel died and the fallback took over. **Must say it**:
        /// the user set A but B is doing the work; without an explanation it becomes "is it even using my configuration?"
        static func fellBack(_ primary: String, _ used: String) -> String {
            String(format: NSLocalizedString("llm.fell_back",
                                             value: "%@ wasn't usable — this result came from %@.",
                                             comment: "Notice: the primary LLM provider failed and a fallback produced the result"),
                   primary, used)
        }
        /// The long transcription went through "chunk → merge".
        static func chunkedNote(_ count: Int) -> String {
            String(format: NSLocalizedString("llm.chunked_note",
                                             value: "Long transcript — processed in %d parts and merged.",
                                             comment: "Notice: the transcript was too long for one request"), count)
        }
        /// Label for the button that promotes the fallback channel to primary in one tap.
        ///
        /// ★ 2026-10-15: a health check that only "says something" isn't enough. The root cause observed in practice was
        /// `primary = openRouter` with no `api_key` in that entry — what the user actually wanted was
        /// local Ollama, and there is exactly one correct fix; making him dig through four pages to find a dropdown
        /// is pure busywork.
        static func adoptAsPrimary(_ provider: String) -> String {
            String(format: NSLocalizedString("llm.adopt_as_primary",
                                             value: "Use %@ as the primary provider",
                                             comment: "Button: switch the primary LLM provider to the given one, which is already configured"),
                   provider)
        }
        /// The entry in the Picker for "this is the current one, but it isn't fully configured".
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

        // MARK: Multi-select / batch actions / knowledge base search
        //
        // ★ 2026-10-15: The user asked for "long-press selection in the library, with batch export or deletion;
        // plus a knowledge-base search over items already transcribed to text or with a generated summary".
        //
        // ⚠️ Same as the source identifier below: always `static var` (runtime language switching) + `value:` inline
        // English fallback (the .lproj files only cover en / zh-Hans; the other 9 languages rely on it to keep
        // raw key literals from leaking into the UI).
        /// The button that enters multi-select mode.
        static var select: String {
            NSLocalizedString("library.select", value: "Select", comment: "Toolbar button: enter multi-select")
        }
        static var selectAll: String {
            NSLocalizedString("library.select_all", value: "Select All", comment: "Multi-select: select every clip")
        }
        static var deselectAll: String {
            NSLocalizedString("library.deselect_all", value: "Deselect All", comment: "Multi-select: clear the selection")
        }
        /// ★ Seventh revision, 2026-10-15: the select-all button now shows the count.
        ///
        /// The user's own words included "select-all is inconvenient to use". The old button just said "Select All"; before tapping,
        /// users had no idea how many rows it would check (especially after filtering by device or searching); only afterwards did they see below
        /// "12 selected". Moving the number onto the button makes "how many will be selected" visible at a glance.
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
        /// ★ 2026-10-20 speed revision: which clip the batch export is copying right now.
        /// The copies run in the background; without this line the user just sees a frozen
        /// spinner over a multi-GB batch and reads it as "stuck".
        static func exportProgress(_ done: Int, _ total: Int, _ title: String) -> String {
            String(
                format: NSLocalizedString("library.export_progress",
                                          value: "Exporting %d of %d: %@",
                                          comment: "Batch export progress: current index, total count, clip title"),
                done, total, title
            )
        }
        static var exportFailed: String {
            NSLocalizedString("library.export_failed", value: "Export Failed", comment: "")
        }
        /// Select-all produced nothing to copy (every selected file happened to vanish). Should be unreachable,
        /// but there **must** be a string for it: otherwise this branch would pop "Export failed" up as the **body**.
        static var exportEmpty: String {
            NSLocalizedString("library.export_empty", value: "Nothing to export.",
                              comment: "Bulk export produced no files at all")
        }
        // ★ Sixth revision, 2026-10-15: the banner for an export that's ready (finished in the background, waiting to be shared).
        //
        // The wording deliberately **avoids mentioning "background"** — users don't need to know we keep the process alive with silent audio;
        // the only two things they want confirmed are "is the last batch ready" and "what do I tap now to send it out".
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
        /// Placeholder in the search field. Deliberately omits the word "search" — the prompt must say **what range is being searched**.
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
        /// Accessibility reading for the "summary generated" badge on a list row.
        static var hasSummary: String {
            NSLocalizedString("library.has_summary", value: "Summary", comment: "Badge: clip has a generated summary")
        }
        /// Accessibility reading for the "transcription available" badge on a list row.
        ///
        /// ★ Added 2026-10-15: that green pill badge has always been there but never had a label —
        /// VoiceOver read it as just "image", which is as good as unreadable. Once the summary badge was added
        /// the two sit side by side and a missing label became all the more conspicuous.
        static var hasTranscript: String {
            NSLocalizedString("library.has_transcript", value: "Transcript",
                              comment: "Badge: clip has a transcript")
        }

        // MARK: Unread red dot / grouping by time and device (★ 2026-10-15, second round)
        //
        // Again always `static var` + `value:` inline English fallback; see the source-identifier note above for why.
        /// Accessibility reading for the unread red dot.
        static var unread: String {
            NSLocalizedString("library.unread", value: "Unread",
                              comment: "Accessibility label for the unread dot on a library row")
        }
        /// ★ (2026-10-19) Badge for clips recorded with the card's voice key (AI voice memo).
        static var voiceMemoBadge: String {
            NSLocalizedString("library.voice_memo_badge", value: "Memo",
                              comment: "Library row badge — AI voice memo from the card's voice key")
        }
        /// The section header's "how many clips from this device are still unopened".
        static func unreadCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "library.unread_count", value: "%d unread",
                    comment: "Section header: how many clips on this device are still unopened"
                ),
                count
            )
        }
        /// Accessibility reading / menu title for the device filter menu in the toolbar.
        static var filterDevices: String {
            NSLocalizedString("library.filter_devices", value: "Filter by device",
                              comment: "Toolbar menu: restrict the list to one device")
        }
        static var filterAllDevices: String {
            NSLocalizedString("library.filter_all_devices", value: "All devices", comment: "")
        }
        /// Short count ("12 items" / "12 clips"), for section headers and the filter menu.
        ///
        /// Why not reuse `Recordings.clipCount(count, size)`: that one is "12 recordings · 25 GB",
        /// too long for a section header; and the size is composed separately in the two places (the section header counts **all buckets**,
        /// the menu counts **all devices**, and neither equals the total of a single section).
        static func shortCount(_ count: Int) -> String {
            let format = count == 1
                ? NSLocalizedString("library.short_count_one", value: "%d clip",
                                    comment: "Short clip count, singular")
                : NSLocalizedString("library.short_count_other", value: "%d clips",
                                    comment: "Short clip count, plural")
            return String(format: format, count)
        }
        // MARK: Time section titles
        //
        // Older months are **not here** — that would require localised month names in 12 languages. Instead use
        // `DateFormatter`'s template format (`setLocalizedDateFormatFromTemplate("yMMMM")`)
        // and let the system assemble it per locale — word order and wording can then never be wrong.
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

        // MARK: Source Identifier — 'Who recorded this?' in the list
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

    // MARK: - Trash
    //
    // ★ 2026-10-15: The user asked for "a trash feature in Settings to protect against accidental deletion,
    // with a 30-day protection period and automatic deletion after 30 days". It lives in the phone app's Settings —
    // deletion already happens on the phone (multi-select delete in the library, delete on the detail page), and only here
    // does it cover every entry point.
    //
    // ⚠️ Again always `static var` + `value:` inline English fallback.
    enum Trash {
        /// Title of the row in Settings, and also the trash page's navigation title.
        static var title: String {
            NSLocalizedString("trash.title", value: "Recently Deleted",
                              comment: "Settings row + page title for the recycle bin")
        }
        /// The Settings row title. Kept separate from `title` so the Chinese can write "trash" out in full,
        /// while the page title can be a bit longer — they currently share the same value, but the seam is kept.
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
        /// The protection-period note at the bottom of the page.
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
        /// The "days remaining" on each row.
        static func daysLeft(_ days: Int) -> String {
            String(
                format: NSLocalizedString("trash.days_left", value: "%d days left",
                                          comment: "Recycle bin row: time before auto-delete"),
                days
            )
        }
        /// "Deleted on" (followed by the date).
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
        // The small "what's inside" tags on each trash row.
        static var artefactAudio: String {
            NSLocalizedString("trash.artefact_audio", value: "Audio", comment: "")
        }
        static var artefactTranscript: String {
            NSLocalizedString("trash.artefact_transcript", value: "Transcript", comment: "")
        }
        static var artefactSummary: String {
            NSLocalizedString("trash.artefact_summary", value: "Summary", comment: "")
        }

        // MARK: Multi-select (★ fourteenth revision 2026-10-16: user — "trash supports multi-select, select-all, restore, or delete")
        //
        // ⚠️ Always `static var` + `value:` inline English fallback (only the en / zh-Hans
        // .lproj files were added; same reason as `Library.sourceCard`).
        /// The toolbar button that enters/exits multi-select mode.
        static var select: String {
            NSLocalizedString("trash.select", value: "Select", comment: "Trash toolbar: enter multi-select mode")
        }
        /// The "Select All / Deselect All" button in multi-select mode — its label switches with the state.
        static var selectAll: String {
            NSLocalizedString("trash.select_all", value: "Select All", comment: "Trash multi-select toolbar")
        }
        static var deselectAll: String {
            NSLocalizedString("trash.deselect_all", value: "Deselect All", comment: "Trash multi-select toolbar, shown when everything is already ticked")
        }
        /// The "Restore" button at the bottom of multi-select mode.
        static func restoreSelected(_ count: Int) -> String {
            String(format: NSLocalizedString("trash.restore_selected",
                                             value: "Recover %d",
                                             comment: "Trash multi-select bottom bar; %d is how many are ticked"),
                   count)
        }
        /// The "Delete" button at the bottom of multi-select mode.
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
        /// ★ 2026-10-20: an audio interruption (call, Siri, alarm) grabbed the mic and
        /// the take could not be resumed (watchOS refuses background resume) — the take
        /// was saved with everything recorded up to the interruption.
        static var recordingInterrupted: String {
            NSLocalizedString(
                "watch.recording_interrupted",
                value: "Recording was interrupted and saved. Reopen the app to start a new take.",
                comment: "Shown when a call/Siri/alarm ended a background recording"
            )
        }
        // ★ 2026-10-20 anti-mistouch set: tap during recording is refused (hold to stop
        // is the deliberate path), and double-tap / shake stop via a confirmation.
        static var holdToStop: String {
            NSLocalizedString(
                "watch.hold_to_stop",
                value: "Long-press to end the recording",
                comment: "Hint shown when a tap lands while recording"
            )
        }
        static var stopConfirmTitle: String {
            NSLocalizedString(
                "watch.stop_confirm_title",
                value: "End this recording?",
                comment: "Confirmation after double-tap/shake while recording"
            )
        }
        static var stopConfirmMessage: String {
            NSLocalizedString(
                "watch.stop_confirm_message",
                value: "The take will be saved and sent to your iPhone.",
                comment: "Body of the stop confirmation"
            )
        }
        static var stopConfirmAction: String {
            NSLocalizedString(
                "watch.stop_confirm_action",
                value: "End",
                comment: "Destructive button in the stop confirmation"
            )
        }
        static var continueAction: String {
            NSLocalizedString(
                "watch.continue_action",
                value: "Keep recording",
                comment: "Cancel button in the stop confirmation"
            )
        }
        static var pendingHeader: String { NSLocalizedString("watch.pending_header", comment: "") }
        static var sending: String { NSLocalizedString("watch.sending", comment: "") }
        static var waiting: String { NSLocalizedString("watch.waiting", comment: "") }
        /// The "how many clips haven't been transferred yet" on the thin note at the bottom of the home screen.
        ///
        /// ★ Fourth revision, 2026-10-15: the pending-transfer list was collapsed from a long column on the home screen into a single strip at the bottom,
        /// with details pushed into their own page (otherwise it would shove the ring off-centre; see the top of `WatchRecorderView`).
        /// So this needs a **short phrase with a number**; `pendingHeader` ("Pending transfer") won't do.
        static func pendingCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "watch.pending_count", value: "%d to send",
                    comment: "Watch home: compact pill at the bottom showing how many clips are still uploading"
                ),
                count
            )
        }
        /// The "shake to start recording" toggle in Settings.
        static var shakeToRecord: String {
            NSLocalizedString("watch.shake_to_record", value: "Shake to Record",
                              comment: "Watch settings: shake the wrist to start/stop recording")
        }
        /// The explanatory line under that toggle.
        static var shakeToRecordHint: String {
            NSLocalizedString(
                "watch.shake_to_record_hint",
                value: "Shake your wrist to start, shake again to stop",
                comment: "Watch settings: explains the shake gesture"
            )
        }

        /// The "two-finger tap to start/stop recording" toggle in Settings (shown on watchOS 11+ only).
        ///
        /// ⚠️ The wording deliberately says "pinch index finger and thumb together" instead of copying Apple's "Double Tap":
        /// that's the exact gesture the user asked for, and a literal "double tap" would be confused with "tap the screen twice" —
        /// this is an **in-air** gesture, not a touch. Apple's own Chinese name for it is also "two-finger tap".
        static var pinchToRecord: String {
            NSLocalizedString("watch.pinch_to_record", value: "Double Tap to Record",
                              comment: "Watch settings: pinch index finger and thumb to start/stop recording")
        }
        /// The explanatory line under that toggle.
        static var pinchToRecordHint: String {
            NSLocalizedString(
                "watch.pinch_to_record_hint",
                value: "Tap index finger and thumb together to start, again to stop",
                comment: "Watch settings: explains the double-tap gesture"
            )
        }

        // MARK: Home screen bot (★ seventh revision 2026-10-16)
        //
        // The center of the home screen swapped the ring button for a blinking bot face. The user's words:
        // "like the Grok Bot, with two eyes... remove the recording button on the current home screen and make it a lively bot;
        // recording starts only after long-pressing its eye for 2s".
        //
        // ⚠️ The `holdToRecord` hint **cannot be skipped**. "Hold for 2 seconds" is an **invisible** interaction:
        //    without it, first-time users will tap once, find nothing happens, and give up.
        static var holdToRecord: String {
            NSLocalizedString("watch.hold_to_record", value: "Hold 2s to record",
                              comment: "Watch home: caption under the bot face, explains the long-press gesture")
        }
        /// A line read by screen readers while recording (visually the home screen shows the timer, no text).
        static var recordingBusy: String {
            NSLocalizedString("watch.recording_busy", value: "Recording",
                              comment: "Watch home: accessibility value while a take is running")
        }

        // MARK: Side swipe menus + quick menu settings (★ seventh revision 2026-10-16)
        //
        // User's words: "the 4 menus should appear by swiping left or right... the quick-recording menu bar on the watch
        // needs a place to add quick menu settings; that setting is a component you tap to add inside the watch's Wi-Fi
        // menu bar".
        /// The row in Settings, and also the title of the selection page.
        static var quickMenu: String {
            NSLocalizedString("watch.quick_menu", value: "Quick Menu",
                              comment: "Watch settings: which items show in the home screen's side menus")
        }
        static var quickMenuHint: String {
            NSLocalizedString("watch.quick_menu_hint", value: "Swipe left or right on the home screen",
                              comment: "Watch settings: subtitle explaining where these items appear")
        }
        /// The dashed entry at the bottom of the menu page.
        static var quickMenuAdd: String {
            NSLocalizedString("watch.quick_menu_add", value: "Add a shortcut",
                              comment: "Watch home: dashed entry at the bottom of a side menu")
        }
        /// Empty state when one side's menu has nothing checked.
        static var quickMenuEmpty: String {
            NSLocalizedString("watch.quick_menu_empty", value: "No shortcuts here yet",
                              comment: "Watch home: a side menu with nothing enabled")
        }
        /// Note at the bottom of the selection page. **Must make clear "where to look after checking"** — back on the home screen you have to swipe sideways
        /// to see it; without this line users will think checking did nothing.
        static var quickMenuFooter: String {
            NSLocalizedString(
                "watch.quick_menu_footer",
                value: "Enabled items appear when you swipe left or right from the home screen.",
                comment: "Watch quick-menu settings: footer explaining where the items show up"
            )
        }
        /// Empty state of the pending-transfer queue page (this page can now be reached directly from the menu, so "empty" is normal).
        static var queueEmpty: String {
            NSLocalizedString("watch.queue_empty", value: "Nothing to send",
                              comment: "Watch queue page: empty state")
        }

        // The small print under each row on the selection page. One sentence saying "what you'll see inside".
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
        // ⚠️ Always use `static var` (switches language at runtime) + provide inline English fallback via `value:`
        // (Only en / zh-Hans .lproj files were added). Reasoning is the same as for `Library.sourceCard`.
        /// Title of the top-left page. It now holds three things — **color + gradient + breathing light** —
        /// so it's called "Appearance" rather than "Color" — keeping the old name would make users think the breathing light was removed.
        ///
        /// ★ Fifth revision, 2026-10-15: the old `styleColor` ("Color") was merged in along with the breathing light;
        /// both became this; the `watch.style_color` key has been removed from both .strings files.
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
        /// Title of the "Settings" page inside the corner badge (version + restore defaults).
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

        // MARK: Transfer history (★ fifth revision 2026-10-15, top-right corner badge)
        //
        // User: "the top right is the watch's transfer history". One word per status,
        // and the words must be short — a row on the watch only fits a dozen or so characters.
        /// Title of the top-right page.
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
        /// Handed to the WatchConnectivity queue, not yet on its way.
        static var transferQueued: String {
            NSLocalizedString("watch.transfer_queued", value: "Queued", comment: "Transfer state")
        }
        /// Delivered by the system to the phone's daemon, but the phone app hasn't confirmed writing to disk.
        static var transferDelivered: String {
            NSLocalizedString("watch.transfer_delivered", value: "Waiting", comment: "Transfer state: handed to the phone, not confirmed")
        }
        /// The phone app has confirmed it's stored — only at this point is the local copy on the watch deleted.
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

        // MARK: Recording home screen (★ fourteenth revision 2026-10-16)
        //
        // ⚠️ With `value:` inline English fallback (only the en / zh-Hans .lproj files were added).
        /// The hint shown when heart rate can't be read. At that moment the wave is a **flat, motionless line**,
        /// and without an explanation it reads as "broken" (see the fourteenth-revision note at the top of `WatchVoiceWave`).
        ///
        /// ⚠️ Deliberately **short**: it shares a line with the byte count, and a long string would shrink the whole line into illegibility.
        static var notWorn: String {
            NSLocalizedString("watch.not_worn", value: "Not worn",
                              comment: "Watch recorder caption when no heart rate is available — the watch isn't being worn")
        }
    }

    // MARK: - Watch home screen expression (★ thirteenth revision 2026-10-16)

    /// The expression picker in iPhone Settings (a row in the "Apple Watch" section).
    ///
    /// ## Why the name doesn't mention color / theme
    /// This page picks **shape only** (how the eyes curve, how they tilt, how wide they open). Color is chosen on the watch's
    /// "Appearance" page and has nothing to do with this — the phone has no idea which color the watch picked
    /// (that's a watch-local preference), so previews on this page are always drawn in the foreground color, never pretending to be
    /// the color on the watch.
    ///
    /// ⚠️ Always `static var` (runtime language switching) + `value:` inline English fallback
    /// (only the en / zh-Hans .lproj files were added; same reason as `Library.sourceCard`).
    enum Face {
        /// Title of the Settings row, and the picker's page title.
        static var title: String {
            NSLocalizedString("face.title", value: "Home Face",
                              comment: "Settings row + picker title: which expression the watch's home face wears")
        }
        /// The explanation under the Settings row.
        static var rowFooter: String {
            NSLocalizedString("face.row_footer", value: "Choose the expression the watch shows on its home screen.",
                              comment: "Settings row footer: what the home face setting does")
        }
        /// The explanation at the bottom of the picker page.
        static var footer: String {
            NSLocalizedString("face.footer", value: "The face still blinks and looks around on its own. Tap it on the watch to see another expression.",
                              comment: "Face picker footer: the chosen expression is the resting face, not the only one")
        }

        // Names for the nine levels. **Short**, because they appear in list rows on both the watch and the phone.
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
        // The six expressions added in the 2026-10-19 batch (user: "more expressions, Grok-bot style").
        static var grin: String {
            NSLocalizedString("face.grin", value: "Grinning", comment: "Watch face expression: very wide smile-arc eyes")
        }
        static var blissful: String {
            NSLocalizedString("face.blissful", value: "Blissful", comment: "Watch face expression: very wide, nearly flat eyes")
        }
        static var surprised: String {
            NSLocalizedString("face.surprised", value: "Surprised", comment: "Watch face expression: tall, wide-open eyes")
        }
        static var focus: String {
            NSLocalizedString("face.focus", value: "Focused", comment: "Watch face expression: narrow, slightly lowered eyes")
        }
        static var sly: String {
            NSLocalizedString("face.sly", value: "Sly", comment: "Watch face expression: half-closed eyes tipped sharply inwards")
        }
        static var curious: String {
            NSLocalizedString("face.curious", value: "Curious", comment: "Watch face expression: tall eyes tipped slightly inwards")
        }

        // Blink pace (a three-way setting, see `BotBlinkSpeed`).
        static var blinkSlow: String {
            NSLocalizedString("face.blink_slow", value: "Slow", comment: "Blink pace option: blinks and expression changes are slower than usual")
        }
        static var blinkNormal: String {
            NSLocalizedString("face.blink_normal", value: "Normal", comment: "Blink pace option: the usual pace")
        }
        static var blinkLively: String {
            NSLocalizedString("face.blink_lively", value: "Lively", comment: "Blink pace option: blinks and expression changes are quicker than usual")
        }

        // The other face settings (colour / blink pace / auto-cycle / frame).
        static var autoCycle: String {
            NSLocalizedString("face.auto_cycle", value: "Dynamic Expressions", comment: "Toggle: the watch face changes expression on its own every few seconds")
        }
        static var autoCycleFooter: String {
            NSLocalizedString("face.auto_cycle_footer", value: "The face switches between expressions on its own. Tapping the face on the watch still changes it right away.",
                              comment: "Footer for the auto-cycle toggle")
        }
        static var blinkSpeed: String {
            NSLocalizedString("face.blink_speed", value: "Blink Pace", comment: "Section header: how quickly the eyes blink")
        }
        static var eyeColor: String {
            NSLocalizedString("face.eye_color", value: "Eye Color", comment: "Section header: the colour of the watch face's eyes")
        }
        static var followWatch: String {
            NSLocalizedString("face.follow_watch", value: "Follow Watch", comment: "Eye-color option: don't override the colour the watch itself picked")
        }
        static var frame: String {
            NSLocalizedString("face.frame", value: "Square Frame", comment: "Toggle: show a rounded-square outline around the watch face")
        }
        static var frameFooter: String {
            NSLocalizedString("face.frame_footer", value: "Draws a rounded-square border around the eyes on the watch face.",
                              comment: "Footer for the square-frame toggle")
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
        /// ★ (2026-10-20) A1-specific confirm body. The A1 protocol has no BLE unbind
        /// command, so this action removes the card **from the app** (secret, alias,
        /// ledger) and drops the link. The cloud binding inside the DingTalk account
        /// can only be removed in the official DingTalk app — say so, or the user will
        /// believe the card left their DingTalk account.
        static var unbindConfirmMessageA1: String {
            NSLocalizedString(
                "ticnote.unbind_confirm_message_a1",
                value: "This removes the card from Nomily — its key, name and ledger entry — and disconnects it. The card keeps its recordings, and the binding inside your DingTalk account can only be removed in the official DingTalk app.",
                comment: "Body of the unbind confirmation for the DingTalk A1 card"
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
        /// ★ (2026-10-19) DingTalk-style detail tabs: Transcript / AI Minutes / To-dos.
        static var tabTranscript: String { NSLocalizedString("clip_detail.tab_transcript", value: "Transcript", comment: "Detail page tab — transcript") }
        static var tabSummary: String { NSLocalizedString("clip_detail.tab_summary", value: "AI Minutes", comment: "Detail page tab — AI summary") }
        static var tabTodos: String { NSLocalizedString("clip_detail.tab_todos", value: "To-dos", comment: "Detail page tab — action items") }
        static var moreActions: String { NSLocalizedString("clip_detail.more_actions", value: "More", comment: "Detail page top-right overflow menu") }
        static var aiAskTitle: String { NSLocalizedString("clip_detail.ai_ask_title", value: "AI Q&A", comment: "Detail page — ask questions about this recording") }
        static var aiAskYou: String { NSLocalizedString("clip_detail.ai_ask_you", value: "You", comment: "Chat speaker label — user") }
        static var aiAskAssistant: String { NSLocalizedString("clip_detail.ai_ask_assistant", value: "AI", comment: "Chat speaker label — assistant") }
        static var aiAskThinking: String { NSLocalizedString("clip_detail.ai_ask_thinking", value: "Thinking…", comment: "Chat pending state") }
        static var aiAskClear: String { NSLocalizedString("clip_detail.ai_ask_clear", value: "Clear", comment: "Clear the Q&A history") }
        static var aiAskPlaceholder: String { NSLocalizedString("clip_detail.ai_ask_placeholder", value: "Ask about this recording", comment: "Chat input placeholder") }
        static var aiAskFooter: String { NSLocalizedString("clip_detail.ai_ask_footer", value: "Answers use only this recording's transcript and summary.", comment: "Chat footer — grounding") }
        static var aiAskSystem: String {
            NSLocalizedString("clip_detail.ai_ask_system",
                              value: "You are a meeting assistant. Answer strictly from the RECORDING MATERIAL provided. If it does not contain the answer, say so plainly instead of guessing, and suggest what the user could look for. Reply in the language of the question. Be concise and quote timestamps when useful.",
                              comment: "System prompt for the in-page recording Q&A")
        }
        static var todosEmpty: String { NSLocalizedString("clip_detail.todos_empty", value: "No action items in the summary.", comment: "To-dos tab when the summary has no action-item section") }
        static var todosNeedSummary: String { NSLocalizedString("clip_detail.todos_need_summary", value: "Generate a summary to collect action items here.", comment: "To-dos tab when no summary exists yet") }
        static var searchTranscript: String { NSLocalizedString("clip_detail.search_transcript", value: "Search transcript", comment: "Transcript search field placeholder") }
        static var speakerAll: String { NSLocalizedString("clip_detail.speaker_all", value: "All speakers", comment: "Speaker filter chip — clear the filter") }
        static var noTranscriptMatch: String { NSLocalizedString("clip_detail.no_transcript_match", value: "No lines match.", comment: "Transcript search/filter found nothing") }
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
        /// ★ Sixth revision, 2026-10-15: the previous export is ready; tap this row to share it.
        ///
        /// The only reason this row exists is to **save a re-run** — transcoding a large file can wait until the user
        /// switches away ("so leaving doesn't mean waiting all over again"). So the copy says "Exported" outright, not
        /// the vague "Share audio".
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
        /// Clears the staging copy (**leaves the original in the library untouched**).
        static var clearExportStaging: String { L10n.Library.clearExportStaging }
        static var mindMap: String { NSLocalizedString("clip_detail.mind_map", value: "Mind Map", comment: "Mind map view built from the summary's headings and lists") }
        static var mindMapLevel: String { NSLocalizedString("clip_detail.mind_map_level", value: "Branches", comment: "How many levels of the summary the mind map draws") }
        static var mindMapFit: String { NSLocalizedString("clip_detail.mind_map_fit", value: "Fit", comment: "Button that scales the mind map to fill the screen") }
        static var mindMapEmpty: String { NSLocalizedString("clip_detail.mind_map_empty", value: "This summary has no headings or lists to turn into a mind map.", comment: "Shown when a summary has no structure to plot") }
        static var mindMapExportFailed: String { NSLocalizedString("clip_detail.mind_map_export_failed", value: "Couldn't export the mind map.", comment: "Alert title when mind-map PNG export fails") }
        static var mindMapExpandAll: String { NSLocalizedString("clip_detail.mind_map_expand_all", value: "Expand all", comment: "Toolbar button that opens every folded branch of the mind map") }
        static var mindMapCollapseAll: String { NSLocalizedString("clip_detail.mind_map_collapse_all", value: "Collapse all", comment: "Toolbar button that folds the mind map back to its top-level branches") }
        // ---- "Image-text" poster share (DingTalk-style share card) ----
        static var shareAsImage: String {
            NSLocalizedString("clip_detail.share_as_image", value: "Share as Image",
                              comment: "Opens the summary poster sheet (image-text share)")
        }
        static var share: String {
            NSLocalizedString("poster.share", value: "Share", comment: "Poster sheet: share the rendered image")
        }
        static var posterCopy: String {
            NSLocalizedString("poster.copy", value: "Copy", comment: "Poster sheet: copy the image to the pasteboard")
        }
        static var posterCopied: String {
            NSLocalizedString("poster.copied", value: "Copied to clipboard", comment: "Toast after copying the poster image")
        }
        static var posterEmpty: String {
            NSLocalizedString("poster.empty", value: "Nothing to render — the summary is empty.",
                              comment: "Poster sheet shown when there is no summary content")
        }
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
        // ---- "Marks" pressed on the recorder card while recording ----
        static var remarks: String {
            NSLocalizedString("clip_detail.remarks", value: "Remarks",
                              comment: "Section listing the markers the recorder card dropped while recording")
        }
        static func remarksCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString("clip_detail.remarks_count", value: "%d marks",
                                          comment: "How many marks this recording has"),
                count
            )
        }
        static var remarksFooter: String {
            NSLocalizedString(
                "clip_detail.remarks_footer",
                value: "Pressed the record key on the card while it was recording — each press drops a marker at that moment. Tap one to jump there.",
                comment: "Footer under the remarks section"
            )
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
        /// The link dropped; the session is being held open while the card reconnects.
        static var reconnecting: String { NSLocalizedString("live.reconnecting", comment: "") }
        /// The longer explanation shown on the standalone "reconnecting" screen.
        static var reconnectingHint: String { NSLocalizedString("live.reconnecting_hint", comment: "") }
        /// Left-hand button of the running control bar — drops a mark on the A1 card.
        static var mark: String {
            NSLocalizedString("live.mark", value: "Mark", comment: "Button that drops a marker at the current moment")
        }
        static var markAdded: String {
            NSLocalizedString("live.mark_added", value: "Marked", comment: "Shown for a second after a mark was dropped")
        }
        /// Recording, but no recogniser attached — audio is being saved, text is not coming.
        static var asrOffline: String {
            NSLocalizedString("live.asr_offline",
                              value: "Recording only — transcription is off",
                              comment: "Hint on the running header when no ASR channel is attached")
        }
        /// Audio is flowing but no text has appeared yet (~8 s in) — usually the model loading.
        static var waitingForText: String {
            NSLocalizedString("live.waiting_for_text",
                              value: "Audio is coming in, waiting for the first words…",
                              comment: "Hint on the running header when frames arrive but no transcript yet")
        }
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
        /// Toast shown when the card's voice key started a recording and the live page auto-attached (★ 2026-10-19).
        static var voiceKeyAutoStarted: String {
            NSLocalizedString("live.voice_key_auto_started",
                              value: "Recording started with the card's key — live transcription attached automatically",
                              comment: "Voice-key linkage toast")
        }
        /// Toast shown when the voice-key recording ended (★ 2026-10-19): the clip is saved and
        /// auto-transcribe → auto-summarize turns it into an AI voice memo.
        static var voiceKeyMemoSaved: String {
            NSLocalizedString("live.voice_key_memo_saved",
                              value: "Recording saved — transcribing, the AI memo will follow",
                              comment: "Voice-key release toast (AI voice memo)")
        }
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
        /// Shown when every nearby device has already been added (★ 2026-10-20: added
        /// devices no longer appear in the scan list at all, per user request).
        static var noNewDevices: String {
            NSLocalizedString(
                "scanner.no_new_devices",
                value: "No new devices nearby. Devices you've added are managed in the device list.",
                comment: "Empty state when the scanner only sees already-added devices"
            )
        }
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
        // ★ Seventh revision, 2026-10-15: the template picker changed from "rows of text" to "a tile grid + overview page".
        //
        // User's words: "the summary templates shouldn't be plain text; suggest showing the current structure as blocks, and tapping
        // one gives an overall overview". So the tile keeps only the name (to see "what's available"), while the description and
        // the full prompt move to the overview page (to see "what it produces when tapped").
        //
        // ⚠️ All `static var` + inline English fallback: same reason as the `Library` batch —
        // the .lproj files only cover en / zh-Hans; the other 9 languages rely on `value:` to keep key literals out.
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
        // ★ 2026-10-19 DingTalk-style picker: chips + default template.
        static var chipRecommended: String {
            NSLocalizedString("summarize.chip_recommended", value: "Recommended",
                              comment: "Template page: top filter chip with the curated built-ins")
        }
        static var chipCustom: String {
            NSLocalizedString("summarize.chip_custom", value: "Custom",
                              comment: "Template page: top filter chip with the user's own templates")
        }
        static var defaultBadge: String {
            NSLocalizedString("summarize.default_badge", value: "Default",
                              comment: "Template card: marks the template that is set as default")
        }
        static var setDefault: String {
            NSLocalizedString("summarize.set_default", value: "Set as default",
                              comment: "Template page: bottom button that marks the selected template as default")
        }
        /// Title of the "what this template does" section on the overview page.
        static var templateAbout: String {
            NSLocalizedString("summarize.template_about", value: "What it produces",
                              comment: "Overview page: label above the template's one-line description")
        }
        /// Title of the full-prompt section on the overview page.
        static var templatePromptLabel: String {
            NSLocalizedString("summarize.template_prompt_label", value: "Prompt",
                              comment: "Overview page: label above the template's full prompt text")
        }
        /// The primary button at the bottom of the overview page.
        static var useTemplate: String {
            NSLocalizedString("summarize.use_template", value: "Summarize with this template",
                              comment: "Overview page: primary button that starts the summary")
        }
        /// The back button at the top-left of the overview page (this page isn't pushed, so the system shows no back chevron).
        static var backToTemplates: String {
            NSLocalizedString("summarize.back_to_templates", value: "Templates",
                              comment: "Overview page: back button, returns to the template grid")
        }
        /// Overview page subtitle (an extra info slot beyond category + item count). Currently used only for accessibility.
        static var templateOverviewTitle: String {
            NSLocalizedString("summarize.template_overview_title", value: "Template",
                              comment: "Overview page: navigation title when the template has no name")
        }
        /// Empty state when a template search finds nothing. **Must exist** — once the tile grid search comes up empty the page is blank,
        /// and users will think the page failed to load.
        static var noMatchingTemplates: String {
            NSLocalizedString("summarize.no_matching_templates",
                              value: "No templates match your search",
                              comment: "Template grid: search returned nothing")
        }
        static var truncatedWarning: String { NSLocalizedString("summarize.truncated_warning", comment: "Shown when the model hit its output cap") }
        /// Chunk progress: "chunk %1$d of %2$d". Numbers are monospaced so the row doesn't jitter when digit counts change.
        static func chunkProgress(_ done: Int, _ total: Int) -> String {
            String(format: NSLocalizedString("summarize.chunk_progress", value: "Part %1$d of %2$d",
                                             comment: "Summarize sheet: progress while a long transcript is processed in parts"),
                   done, total)
        }
        /// Pre-flight health-check notice: the primary channel is unusable, but there is a fallback.
        ///
        /// `gap` is already a complete sentence like "No API key configured for Open Router.",
        /// so this only has to append "who will serve as the fallback".
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

    // MARK: - Jobs (background task overview)

    /// The **overview** strings for the four kinds of long-running jobs (twelfth revision, 2026-10-16).
    ///
    /// This layer only solves "being visible": scheduling for summary / translation / format conversion lives in `JobQueue`,
    /// transcription still lives in `TranscriptionService`, but both appear in one list on the overview page.
    ///
    /// ⚠️ Keep the wording consistent with the `ASR.queue_*` batch: **never say "silent audio"**. What users want
    ///    to judge is "will it keep going after I switch away", not how we keep the process alive.
    enum Jobs {

        // MARK: Kinds of jobs (`JobKind.title`)

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

        // MARK: Subtitles (`Job.detail`)

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

        // MARK: Source is gone (`JobSourceMissing`)

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
        /// "This thing no longer exists". **Not** "job failed" — it's the kind that can **never succeed'',
        /// so the queue wipes it straight from the ledger instead of wasting three attempts.
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

        // MARK: Overview page

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
        /// The "you're free to go" line shown right after it's started.
        static var canLeaveHint: String {
            NSLocalizedString("jobs.can_leave_hint",
                              value: "You can leave this screen — it keeps running in the background.",
                              comment: "Shown under a running task: the user does not have to stay on the page")
        }

        // MARK: Status

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

        // MARK: Inline actions

        static var retry: String {
            NSLocalizedString("jobs.retry", value: "Try again", comment: "Job row: retry action")
        }
        static var cancel: String {
            NSLocalizedString("jobs.cancel", value: "Cancel", comment: "Job row: cancel action")
        }
        static var remove: String {
            NSLocalizedString("jobs.remove", value: "Remove", comment: "Job row: dismiss this row")
        }

        // MARK: Entry points (settings page / detail page)

        static var openQueue: String {
            NSLocalizedString("jobs.open_queue", value: "Background tasks",
                              comment: "Settings row: opens the task center")
        }
        static var openQueueFooter: String {
            NSLocalizedString("jobs.open_queue_footer",
                              value: "Summaries, translations and audio conversions carry on after you leave the app.",
                              comment: "Settings row footer: what the task center is for")
        }
        /// The light toast shown when enqueueing succeeds.
        static func enqueuedToast(_ kind: String) -> String {
            String(format: NSLocalizedString("jobs.enqueued_toast",
                                             value: "%@ added to background tasks.",
                                             comment: "Toast shown right after a task is queued"),
                   kind)
        }
    }
}

// swiftlint:enable type_body_length file_length
