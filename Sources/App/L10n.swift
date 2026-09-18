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
    }

    // MARK: - LLM

    enum LLM {
        static var activeProviderFooter: String { NSLocalizedString("llm.active_provider_footer", comment: "") }
        static var apiKey: String { NSLocalizedString("llm.api_key", comment: "") }
        static var model: String { NSLocalizedString("llm.model", comment: "") }
        static var selectModel: String { NSLocalizedString("llm.select_model", comment: "") }
        static func modelPlaceholder(_ example: String) -> String {
            String(format: NSLocalizedString("llm.model_placeholder", comment: ""), example)
        }
        static var endpointURL: String { NSLocalizedString("llm.endpoint_url", comment: "") }
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
        static var exportAsM4A: String { NSLocalizedString("clip_detail.export_as_m4a", comment: "") }
        static var exporting: String { NSLocalizedString("clip_detail.exporting", comment: "") }
        static var deleteAudio: String { NSLocalizedString("clip_detail.delete_audio", value: "Delete Audio", comment: "Deletes only the audio file, keeping transcript and summary") }
        static var deleteAudioMessage: String { NSLocalizedString("clip_detail.delete_audio_message", value: "Deletes only the audio file. The transcript and summary are kept. This can't be undone.", comment: "") }
        static var deleteTranscript: String { NSLocalizedString("clip_detail.delete_transcript", value: "Delete Transcript", comment: "Deletes only the transcript, keeping audio and summary") }
        static var deleteTranscriptMessage: String { NSLocalizedString("clip_detail.delete_transcript_message", value: "Deletes the transcript and its translation. The audio and summary are kept. This can't be undone.", comment: "") }
        static var deleteSummary: String { NSLocalizedString("clip_detail.delete_summary", value: "Delete Summary", comment: "Deletes only the summary, keeping audio and transcript") }
        static var deleteSummaryMessage: String { NSLocalizedString("clip_detail.delete_summary_message", value: "Deletes the summary and its translation. The audio and transcript are kept. This can't be undone.", comment: "") }
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
        static var clipNotInLibrary: String { NSLocalizedString("live.clip_not_in_library", comment: "") }
        static var sourceLanguage: String { NSLocalizedString("live.source_language", comment: "") }
        static var targetLanguage: String { NSLocalizedString("live.target_language", comment: "") }
        static var sameAsSource: String { NSLocalizedString("live.same_as_source", comment: "") }
        static var setupAzure: String { NSLocalizedString("live.setup_azure", comment: "") }
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
        static var truncatedWarning: String { NSLocalizedString("summarize.truncated_warning", comment: "Shown when the model hit its output cap") }
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
}

// swiftlint:enable type_body_length file_length
