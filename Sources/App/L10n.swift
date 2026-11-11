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
        // ★ 2026-10-29 (饭耳移植 · 规格 #10 隐私话术系统化) — rendered by
        // `PrivacyNote`; claims must match actual behaviour, see that file.
        static var storageNote: String { NSLocalizedString("privacy.storage", comment: "") }
        static var cloudNote: String { NSLocalizedString("privacy.cloud", comment: "") }
        static var backupNote: String { NSLocalizedString("privacy.backup", comment: "") }
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
        /// ★ 2026-11-03 十一轮：长按复制回答用（Nomi 问答页）。
        static var copyText: String { NSLocalizedString("common.copy", value: "Copy", comment: "Copy to clipboard") }
    }

    // MARK: - Tabs

    enum Tab {
        static var recordings: String { NSLocalizedString("tab.recordings", comment: "") }
        static var live: String { NSLocalizedString("tab.live", comment: "") }
        static var settings: String { NSLocalizedString("tab.settings", comment: "") }
        /// ★ 2026-11-03 十轮：底部第四个标签——问自己的录音（个人知识库问答）。
        static var nomily: String { NSLocalizedString("tab.nomily", comment: "") }
    }

    // MARK: - Nomi 问答（★ 2026-11-03 十轮）

    enum Nomily {
        /// 系统提示词。三条纪律：只依据材料 / 标注来源 / 不编造。
        /// 与单条录音页的 `ClipDetail.aiAskSystem` 是两套：那边只有一条录音的上下文，
        /// 这边是"从全库检索出来的几条材料"，纪律必须更严。
        static var system: String {
            NSLocalizedString("nomily.system", value: """
            You are Nomily, the assistant for the user's personal voice-note library. Answer the question using ONLY the library material below. Rules:
            1. Cite which recordings support each claim, by their date and title, e.g. (11-02 产品周会).
            2. If the material does not contain the answer, say so plainly — never invent recordings, quotes, or dates.
            3. For to-do questions, list only commitments that actually appear in the material, with owner and deadline when stated.
            4. Answer in the language of the question. Be concise: short paragraphs or a tight list, no filler.
            5. Material snippets are truncated; treat them as excerpts, not complete transcripts.
            """, comment: "System prompt for the library-wide Nomi Q&A tab")
        }
        static var tagline: String {
            NSLocalizedString("nomily.tagline", value: "问你的录音，像问一个助理",
                              comment: "Nomi tab: hero headline on the empty state")
        }
        static var explain: String {
            NSLocalizedString("nomily.explain", value: "Nomi 会在你的录音库里检索相关内容再回答，回答里会注明出自哪天的哪条录音。找不到的会直说，不会编。",
                              comment: "Nomi tab: one-line explanation of how answering works")
        }
        static var placeholder: String {
            NSLocalizedString("nomily.placeholder", value: "问问你的录音、待办、约定…",
                              comment: "Nomi tab: input field placeholder")
        }
        static var noMatch: String {
            NSLocalizedString("nomily.no_match", value: "录音库里没有找到和这个问题相关的内容。可以换个说法再问一次。",
                              comment: "Nomi tab: nothing in the library matched the question")
        }
        static var thinking: String {
            NSLocalizedString("nomily.thinking", value: "Nomi 正在翻你的录音…",
                              comment: "Nomi tab: while the answer is being generated")
        }
        static var clear: String {
            NSLocalizedString("nomily.clear", value: "清空会话",
                              comment: "Nomi tab: accessibility label for the reset button")
        }
        /// ★ 2026-11-04 十三轮：回答卡片头部右侧的覆盖数（客户端算，不走模型）。
        static func coverage(_ count: Int) -> String {
            String(format: NSLocalizedString("nomily.coverage", value: "Based on %d recordings",
                                             comment: "Nomily answer card: how many recordings the retrieval covered"), count)
        }
        /// 回答卡片脚注的默认句（模型没给 note 时用）。
        static var defaultNote: String {
            NSLocalizedString("nomily.default_note", value: "Excerpts from library recordings, not full transcripts.",
                              comment: "Nomily answer card: default footnote")
        }
        /// 提问组上方的时间戳。
        static var today: String {
            NSLocalizedString("nomily.today", value: "Today", comment: "Nomily chat: timestamp prefix")
        }
        static var yesterday: String {
            NSLocalizedString("nomily.yesterday", value: "Yesterday", comment: "Nomily chat: timestamp prefix")
        }
        /// ★ 2026-11-03 十一轮：空态里的「最近问过」分组标题（历史提问落盘后显示）。
        static var recentTitle: String {
            NSLocalizedString("nomily.recent_title", value: "最近问过",
                              comment: "Nomi tab: header of the recent-questions list")
        }
        /// ★ 2026-11-03 十一轮：回答请求 90s 超时的说明——上一版请求挂住时页面永远转圈。
        static var timeout: String {
            NSLocalizedString("nomily.timeout", value: "回答超时了。请检查网络或 LLM 配置后再试一次。",
                              comment: "Nomi tab: the answer request timed out")
        }
        // MARK: ★ 2026-11-05 十四轮：空态卡片（待办 / 最近记录）与快捷提问
        /// 待办卡标题。
        static var cardTodos: String {
            NSLocalizedString("nomily.card_todos", value: "待办",
                              comment: "Nomi empty state: header of the open to-dos card")
        }
        static func cardOverdue(_ count: Int) -> String {
            String(format: NSLocalizedString("nomily.card_overdue", value: "%d 条已过期",
                                             comment: "Nomi to-dos card: red count past its MM-dd deadline"), count)
        }
        static func cardOthers(_ count: Int) -> String {
            String(format: NSLocalizedString("nomily.card_others", value: "%d 条等别人",
                                             comment: "Nomi to-dos card: grey count assigned to someone else"), count)
        }
        /// 最近记录卡标题。
        static var cardRecent: String {
            NSLocalizedString("nomily.card_recent", value: "最近记录",
                              comment: "Nomi empty state: header of the recent recordings card")
        }
        /// 点某条录音卡时直接发出的提问；%@ = 录音标题。
        static func suggestRecording(_ title: String) -> String {
            String(format: NSLocalizedString("nomily.suggest_recording", value: "《%@》这条录音讲了什么？",
                                             comment: "Nomi quick question; %@ = the recording's title"), title)
        }
        /// 待办卡底部按钮 / 快捷胶囊：汇总追问待办。
        static var suggestTodos: String {
            NSLocalizedString("nomily.suggest_todos", value: "我的待办还有哪些没做？",
                              comment: "Nomi quick question: open to-dos across the library")
        }
    }

    // MARK: - Settings

    /// PLAUD cloud sync (2026-10-21 dual-mode support).
    /// 任务八 · 8.1 — "find my card", the pure-App half that needs no firmware.
    ///
    /// Copy rules baked into these strings:
    /// · never promise a city-wide locator — BLE is 10–30 m, say so where the
    ///   button is, not in a footnote;
    /// · "beep" is offered but visibly disabled, with the reason in the row
    ///   (the card has no buzzer command in its SDK at all — 8.2 waits on
    ///   firmware, and a greyed row that explains itself beats a hidden one).
    enum Find {
        static var header: String {
            NSLocalizedString("find.header", value: "Find card",
                              comment: "Section header on the PLAUD device page: BLE find-my-card")
        }
        /// Header once a card is registered ("Find PLAUD NotePin"). Kept separate
        /// from `header` because the section is now shared by every recorder and
        /// the fallback must not promise a card name we don't have.
        static func headerFor(_ card: String) -> String {
            String(format: NSLocalizedString("find.header_for", value: "Find %@",
                                             comment: "Section header; %@ = the card's name or alias"),
                   card)
        }
        /// Notification title when a connected card drops out of range.
        static var title: String {
            NSLocalizedString("find.title", value: "Card left behind",
                              comment: "Local notification title when the card disconnects unexpectedly")
        }
        static func dropBody(_ card: String) -> String {
            String(format: NSLocalizedString("find.drop_body", value: "%@ went out of range. That is where you last had it.",
                                             comment: "Local notification body; %@ = card name"),
                   card)
        }
        /// Same alert, different cause: the phone stopped listening, not the card
        /// walked away (2026-10-22 "通知我，包含手机蓝牙直接关闭").
        static func bluetoothOffBody(_ card: String) -> String {
            String(format: NSLocalizedString("find.bluetooth_off_body",
                                             value: "%@ was disconnected because Bluetooth is off on this iPhone. That is where you last had it.",
                                             comment: "Local notification body when the iPhone's Bluetooth was switched off; %@ = card name"),
                   card)
        }
        /// Row action under the map thumbnail. Apple Maps on purpose — one map
        /// everywhere, no regional third-party app to fall back to.
        static var openInMaps: String {
            NSLocalizedString("find.open_in_maps", value: "Open in Maps",
                              comment: "Opens the last-seen coordinate in Apple Maps")
        }
        static var thisCard: String {
            // Was "your PLAUD card". The finder now serves every recorder, so a
            // TicNote user must not be told their DingTalk A1 is a PLAUD card.
            NSLocalizedString("find.this_card", value: "your card",
                              comment: "Fallback card name in the drop notification")
        }
        static var lastSeenHeader: String {
            NSLocalizedString("find.last_seen_header", value: "Last seen",
                              comment: "Sub-header: when/where the card was last connected")
        }
        static var lastSeenNever: String {
            NSLocalizedString("find.last_seen_never", value: "No record yet — it fills in the first time the card disconnects.",
                              comment: "Shown before the first disconnect was ever recorded")
        }
        static var placeUnknown: String {
            NSLocalizedString("find.place_unknown", value: "Location not recorded",
                              comment: "No coarse location for the last disconnect (permission denied or no fix)")
        }
        static var placeDenied: String {
            NSLocalizedString("find.place_denied", value: "Allow location access to remember where the card was left.",
                              comment: "Location permission missing for the find-my-card feature")
        }
        static var radarHeader: String {
            NSLocalizedString("find.radar_header", value: "Proximity",
                              comment: "Sub-header: live RSSI signal-strength meter")
        }
        static var start: String {
            NSLocalizedString("find.start", value: "Start looking",
                              comment: "Button that starts the BLE proximity scan")
        }
        static var stop: String {
            NSLocalizedString("find.stop", value: "Stop",
                              comment: "Button that stops the BLE proximity scan")
        }
        static var scanning: String {
            NSLocalizedString("find.scanning", value: "Scanning… walk around slowly.",
                              comment: "Shown while the RSSI scan is running but no advertisement landed yet")
        }
        /// 0 = unknown, 1 = far, 2 = near, 3 = very near (see `PlaudCardFinder.Proximity`).
        static func tier(_ level: Int) -> String {
            switch level {
            case 3:
                return NSLocalizedString("find.tier_very_near", value: "Very close — check pockets and bags.",
                                         comment: "RSSI tier: about arm's length")
            case 2:
                return NSLocalizedString("find.tier_near", value: "Getting warmer — keep going.",
                                         comment: "RSSI tier: same room")
            case 1:
                return NSLocalizedString("find.tier_far", value: "Weak signal — still far.",
                                         comment: "RSSI tier: same floor at best")
            default:
                return NSLocalizedString("find.tier_unknown", value: "No signal from the card.",
                                         comment: "RSSI tier: nothing heard in the last 3 s")
            }
        }
        static var hint: String {
            NSLocalizedString("find.hint", value: "Bluetooth reaches roughly 10–30 m indoors. This finds a card under a cushion or in a bag — it is not a city-wide locator, and the card never beacons to strangers.",
                              comment: "Honest limits of the BLE find feature; deliberately in the UI, not a footnote")
        }
        // MARK: Notification honesty (★ 2026-10-22)
        static var notifyDenied: String {
            NSLocalizedString("find.notify_denied",
                              value: "Notifications are off for this app, so the drop alert can't sound. Turn them on in Settings.",
                              comment: "Shown when the user has denied notification permission")
        }
        static var openSystemSettings: String {
            NSLocalizedString("find.open_settings", value: "Open Settings", comment: "")
        }
        static var sendTestAlert: String {
            NSLocalizedString("find.test_alert", value: "Send a test alert", comment: "Button: prove the notification channel works")
        }
        static var testAlertBody: String {
            NSLocalizedString("find.test_alert_body",
                              value: "If you can hear this, the drop alert will work too.",
                              comment: "Body of the test notification")
        }

        // MARK: History (★ 2026-10-22)
        static func historyHeader(_ count: Int) -> String {
            String(format: NSLocalizedString("find.history_header", value: "Where it was before (%d)", comment: "Disclosure label; %d = number of records"), count)
        }
        static func historyMore(_ count: Int) -> String {
            String(format: NSLocalizedString("find.history_more", value: "and %d older", comment: ""), count)
        }
        static var clearHistory: String {
            NSLocalizedString("find.clear_history", value: "Clear this history", comment: "")
        }

        static var notifyToggle: String {
            NSLocalizedString("find.notify_toggle", value: "Notify me when the card drops",
                              comment: "Toggle: local notification on unexpected disconnect")
        }
        // ⛔ Legacy (2026-10-22): the "make the card beep" row was **deleted** from
        //    the page ("如果让卡片响铃无法达到就把这个删除"). These three strings are
        //    kept only so a rollback of that decision doesn't need re-translation —
        //    nothing references them.
        static var soundRow: String {
            NSLocalizedString("find.sound_row", value: "Make the card beep",
                              comment: "Would-be row for a buzzer command; disabled, see the reason")
        }
        static var soundUnavailable: String {
            NSLocalizedString("find.sound_unavailable", value: "Needs a firmware command the card does not have yet (task 8.2).",
                              comment: "Why the beep row is greyed out")
        }
        static var soundWhyLocked: String {
            NSLocalizedString("find.sound_why_locked",
                              value: "Why it's locked: the PLAUD SDK has no buzzer command at all. Its full settings table (20 entries) contains only FIND_MY — the Apple Find My pairing — and the device-manager class exposes 537 methods, none of which ring, buzz or vibrate. There is literally nothing to send to the card, so the App can't invent the sound; the card's firmware would have to grow a command first (task 8.2). Until then, use the last-seen place above, and the proximity meter once the card is disconnected.",
                              comment: "Alert body explaining why the beep row is locked; must stay factual and quote the evidence")
        }
    }

    enum Plaud {
        // ★ 2026-10-22: pause/resume on the live page + "recording preempted a transfer".
        static var pauseRecord: String { NSLocalizedString("plaud.pause_record", value: "Pause", comment: "Pause the take that is running on the card") }
        static var resumeRecord: String { NSLocalizedString("plaud.resume_record", value: "Resume", comment: "Resume a paused take") }
        static var pausedHint: String { NSLocalizedString("plaud.paused_hint", value: "Paused — the take is still open on the card.", comment: "Shown under the controls while paused") }
        static var syncPreemptedByRecord: String { NSLocalizedString("plaud.sync_preempted", value: "Transfer paused for the recording — it resumes after you stop.", comment: "A running transfer was stopped so the live audio stream could open") }
        /// The card accepted the recording but never pushed audio. Said out loud
        /// because "listening…" with no text for ten minutes is indistinguishable
        /// from a rendering bug — and the take itself is unaffected either way.
        static var liveNoStream: String { NSLocalizedString("plaud.live_no_stream", value: "The card isn't sending live audio, so there's no real-time text. The recording itself is unaffected — it will be transcribed when you stop.", comment: "PCM never arrived; live subtitle unavailable") }
        static var pauseFailed: String { NSLocalizedString("plaud.pause_failed", value: "The card didn't pause. It may be busy transferring — try again in a moment.", comment: "Pause command went unanswered twice") }
        static var resumeFailed: String { NSLocalizedString("plaud.resume_failed", value: "The card didn't resume. Tap 继续 again — if it still refuses, stop the take and start a new one.", comment: "Resume command went unanswered twice") }
        /// The card seals the file on pause and opens a new one on resume, so a
        /// take with pauses is several clips. Say the count instead of letting the
        /// user discover it later on the recordings list.
        static func segmentHint(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.segment_hint", value: "%d clips so far — pausing closes a clip and resuming opens a new one.", comment: "Take is split across several files because of pauses; %d = count"), count)
        }
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
        // ★ 2026-10-21 (6th round): cloud mode is now a first-class mode, not a
        // compatibility footnote.
        static var cloudHeader: String { NSLocalizedString("plaud.cloud_header", value: "Cloud mode (pull from PLAUD cloud)", comment: "Second mode under direct connect") }
        static var cloudRecordings: String { NSLocalizedString("plaud.cloud_recordings", value: "In the cloud", comment: "How many recordings the account holds online") }
        static func cloudRecordingsCount(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.cloud_recordings_count", value: "%d clip(s)", comment: ""), count)
        }
        static var pullFromCloud: String { NSLocalizedString("plaud.pull_from_cloud", value: "Pull recordings from cloud", comment: "") }
        static func cloudProgress(_ index: Int, _ total: Int, _ name: String) -> String {
            String(format: NSLocalizedString("plaud.cloud_progress", value: "%d/%d · %@", comment: "Cloud pull progress; %d index, %d total, %@ file name"), index, total, name)
        }
        static var cloudModeFooter: String { NSLocalizedString("plaud.cloud_mode_footer", value: "Cloud mode uses no Bluetooth: sign in with the PLAUD account the official app uses, and pull what it already uploaded. The card keeps working with the official app — but a recording only shows up here after that app has synced it.", comment: "") }
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
        // ★ 2026-10-22: keys are asked exactly once and then live in the local
        // store - the add-device page goes straight to scanning. This row is
        // the way back in when the partner account changes.
        static var changeKeys: String { NSLocalizedString("plaud.change_keys", value: "Change keys (Client ID / Secret)", comment: "Re-open the credential form after the first setup") }
        static var keysStoredHint: String { NSLocalizedString("plaud.keys_stored_hint", value: "Keys are saved on this phone — connecting never asks for them again. Use “Change keys” only when switching to a different PLAUD developer app.", comment: "") }
        // ★ Recording mode (official-app parity, 2026-10-22): the 电池电量 page's
        // three modes, mapped to the card's BatteryMode common setting.
        static var batteryModeHeader: String { NSLocalizedString("plaud.bm_header", value: "Recording mode", comment: "High performance / adaptive / long battery life picker") }
        static var batteryMode: String { NSLocalizedString("plaud.bm_label", value: "Mode", comment: "") }
        static var bmHigh: String { NSLocalizedString("plaud.bm_high", value: "High performance mode", comment: "") }
        static var bmAdaptive: String { NSLocalizedString("plaud.bm_adaptive", value: "Adaptive mode", comment: "") }
        static var bmEndurance: String { NSLocalizedString("plaud.bm_endurance", value: "Long battery life mode", comment: "") }
        static var bmHighDesc: String { NSLocalizedString("plaud.bm_high_desc", value: "On-device AI beamforming picks up voices clearly within 5 m and focuses on speech.", comment: "Official app copy") }
        static var bmAdaptiveDesc: String { NSLocalizedString("plaud.bm_adaptive_desc", value: "Switches between high performance and long battery life automatically. Below 20% battery it falls back to long battery life to extend recording.", comment: "Official app copy") }
        static var bmEnduranceDesc: String { NSLocalizedString("plaud.bm_endurance_desc", value: "Optimised processing still picks up speech clearly within 3 m while lowering power draw.", comment: "Official app copy") }
        static func bmEstimate(_ pct: Int, _ hours: Double) -> String {
            String(format: NSLocalizedString("plaud.bm_estimate", value: "Battery %d%% — about %.1f hours of recording left (high performance).", comment: "%d = battery %%, %.1f = hours"), pct, hours)
        }
        static var bmUnread: String { NSLocalizedString("plaud.bm_unread", value: "Mode not read yet — connect the card to read it.", comment: "") }
        static var bmNeedConnect: String { NSLocalizedString("plaud.bm_need_connect", value: "Connect the card to switch modes.", comment: "") }
        static var batteryModeUnsupported: String { NSLocalizedString("plaud.bm_unsupported", value: "This card's firmware does not support recording modes.", comment: "") }
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
        // ★ 2026-10-26 ("卡上有 56.6MB 但是卡上没有一条录音"): wipe the card's files
        // WITHOUT dropping the binding — the narrow version of 恢复出厂.
        static var clearCardFiles: String { NSLocalizedString("plaud.clear_card_files", value: "Erase recordings on card", comment: "Delete every file on the card, keep the binding") }
        static var clearCardFilesConfirmTitle: String { NSLocalizedString("plaud.clear_card_files_title", value: "Erase every recording on the card?", comment: "") }
        static var clearCardFilesConfirmAction: String { NSLocalizedString("plaud.clear_card_files_action", value: "Erase", comment: "") }
        static var clearCardFilesConfirmMsg: String { NSLocalizedString("plaud.clear_card_files_msg", value: "Only the card is wiped — the binding stays, and recordings already in the library are untouched.", comment: "") }
        static func cardSpaceOrphaned(_ value: String) -> String {
            String(format: NSLocalizedString("plaud.card_space_orphaned", value: "The card reports %@ used but lists no files — leftover data inside the card. Try erasing the card, or format it on the device.", comment: "%@ = size like 56.6 MB"), value)
        }
        // ★ 2026-10-26: feedback for 清空卡片录音 — running / freed / (residue) honest.
        static var clearCardRunning: String { NSLocalizedString("plaud.clear_card_running", value: "Erasing card…", comment: "") }
        static func clearCardFreed(_ value: String) -> String {
            String(format: NSLocalizedString("plaud.clear_card_freed", value: "Card erased — %@ reclaimed.", comment: "%@ = size"), value)
        }
        static func clearCardDone(_ value: String) -> String {
            String(format: NSLocalizedString("plaud.clear_card_done", value: "Erase sent. Card still reports %@ used — that is leftover below the card's file index; only Factory reset or formatting the card itself can reclaim it.", comment: "%@ = size"), value)
        }
        static var factoryResetTitle: String { NSLocalizedString("plaud.factory_reset_title", value: "Erase everything on the card?", comment: "") }
        static var factoryResetMsg: String { NSLocalizedString("plaud.factory_reset_msg", value: "All recordings on the card will be erased and the binding released — the card becomes like new. This cannot be undone.", comment: "") }
        static var erase: String { NSLocalizedString("plaud.erase", value: "Erase", comment: "") }
        static var released: String { NSLocalizedString("plaud.released", value: "Card released — the official PLAUD app can pair it again.", comment: "") }
        // ★ 2026-10-21 (8th round): one purpose-built exit — "switching back to
        // the official app" is unbind + erase + the three steps nobody guesses
        // (quit Nomily, forget the OS pairing, then pair in the official app).
        static var handoverHeader: String { NSLocalizedString("plaud.handover_header", value: "Switch back to the official app", comment: "Section header for handing the card back to PLAUD's own app") }
        static var handover: String { NSLocalizedString("plaud.handover", value: "Hand back to the official app (unbind + erase card)", comment: "Hands the card back: releases our binding and wipes the card") }
        static var handoverConfirmTitle: String { NSLocalizedString("plaud.handover_confirm_title", value: "Hand the card back to the official app?", comment: "") }
        static var handoverConfirmMsg: String { NSLocalizedString("plaud.handover_confirm_msg", value: "This releases Nomily's binding and erases every recording on the card — it goes back to factory state, so the official PLAUD app can pair it like a new card. Erased recordings cannot be recovered; pull anything you need first.", comment: "") }
        static var handoverConfirmAction: String { NSLocalizedString("plaud.handover_confirm_action", value: "Unbind and erase", comment: "") }
        static var handoverDone: String { NSLocalizedString("plaud.handover_done", value: "Handed back — binding released, card erased.", comment: "") }
        // ★ 2026-10-27: the hand-back now reports what the CARD answered
        // instead of claiming success the moment the button was tapped.
        static var releasing: String { NSLocalizedString("plaud.releasing", value: "Handing the card back… keep it close to the phone.", comment: "In-flight hand-back, waiting for the card's depair ack") }
        static func handoverRejected(_ status: Int) -> String {
            String(format: NSLocalizedString("plaud.handover_rejected", value: "The card REFUSED the release (status %d). If privacy mode is on, switch it off on the card first — the firmware forbids unbinding while it is enabled. Then try again.", comment: "The card answered depair with a non-zero status"), status)
        }
        static var handoverUnconfirmed: String { NSLocalizedString("plaud.handover_unconfirmed", value: "Release command sent, but the card did not answer. If the card's used space already dropped to almost nothing, it DID run the wipe and release — Nomily will not reconnect it any more, so go ahead and pair it in the official app. If that still fails, come back and tap Reconnect.", comment: "No depair ack within the watchdog window") }
        static var handoverStep1: String { NSLocalizedString("plaud.handover_step1", value: "① Swipe Nomily away (a full quit, not just background) — otherwise our Bluetooth link still holds the card.", comment: "") }
        static var handoverStep2: String { NSLocalizedString("plaud.handover_step2", value: "② Settings → Bluetooth: if a PLAUD entry is still listed, tap ⓘ and Forget This Device.", comment: "") }
        static var handoverStep3: String { NSLocalizedString("plaud.handover_step3", value: "③ Open the official PLAUD app → Add device → scan and pair. Wake the card with a short press first.", comment: "") }
        static var handoverFooter: String { NSLocalizedString("plaud.handover_footer", value: "A card can be bound to one app at a time — that is why the official app cannot see it while Nomily holds it. To come back later, just scan and pair again; your Client ID / Secret stay saved.", comment: "") }
        // ★ Device recovery (9th round): the card refuses every app — ours
        // ("无法匹配") and the official one. Documented escape: force-clear
        // handshake with each historical client id, then wipe.
        static var recoveryButton: String { NSLocalizedString("plaud.recovery_button", value: "Rescue card (locked out of every app)", comment: "Device recovery: force-clear the on-device lock and erase the card") }
        static var recoveryConfirmTitle: String { NSLocalizedString("plaud.recovery_confirm_title", value: "Rescue the card?", comment: "") }
        static var recoveryConfirmMsg: String { NSLocalizedString("plaud.recovery_confirm_msg", value: "Nomily will force-clear the ownership lock on the card and erase everything on it, leaving factory state that the official PLAUD app (China or global) can bind like a new card. Use this when no app can connect to the card any more. Erased recordings cannot be recovered.", comment: "") }
        static var recoveryConfirmAction: String { NSLocalizedString("plaud.recovery_confirm_action", value: "Rescue and erase", comment: "") }
        static var recoveryRunning: String { NSLocalizedString("plaud.recovery_running", value: "Rescuing… keep the card close to the phone.", comment: "") }
        static var recoveryDone: String { NSLocalizedString("plaud.recovery_done", value: "Rescued — lock cleared and card erased. The official PLAUD app can now bind it like a new card.", comment: "") }
        static var recoveryFailed: String { NSLocalizedString("plaud.recovery_failed", value: "Rescue failed — the card rejected every key Nomily has. Contact PLAUD support with the SN above.", comment: "") }
        // ★ Official-app parity (2026-10-21): scan-first flow + card controls
        static var scanNearby: String { NSLocalizedString("plaud.scan_nearby", value: "Scan for nearby cards", comment: "Scan action for PLAUD cards (no key needed)") }
        static func cardSelected(_ name: String) -> String {
            String(format: NSLocalizedString("plaud.card_selected", value: "Selected: %@ — activate below to connect", comment: ""), name)
        }
        static var cardGone: String { NSLocalizedString("plaud.card_gone", value: "The selected card is out of range — scan again.", comment: "") }
        /// ★ 2026-10-22: a switch with no visible progress is indistinguishable from
        /// a tap that did nothing, which is exactly how the bug was reported.
        static func switching(_ card: String) -> String {
            String(format: NSLocalizedString("plaud.switching", value: "Switching to %@…", comment: "Card switch in progress; %@ = card name"), card)
        }
        static func switchFailed(_ card: String) -> String {
            String(format: NSLocalizedString("plaud.switch_failed", value: "Couldn't reach %@ — wake the card and try again.", comment: "Card switch gave up after 15 s; %@ = card name"), card)
        }
        /// ★ 2026-10-22: the phone's own radio went off, so the card is fine and
        /// the link is not. Saying "out of range" here would send the user off to
        /// search for a card that is sitting on the desk.
        static var bluetoothOff: String {
            NSLocalizedString("plaud.bluetooth_off", value: "Bluetooth is off — turn it back on to reach the card.",
                              comment: "Shown when the iPhone's Bluetooth was switched off while a card was connected")
        }
        static var recordingNow: String { NSLocalizedString("plaud.recording_now", value: "Card is recording", comment: "") }
        static var stopRecord: String { NSLocalizedString("plaud.stop_record", value: "Stop recording", comment: "") }
        static var startRecord: String { NSLocalizedString("plaud.start_record", value: "Start recording", comment: "") }
        static var disconnect: String { NSLocalizedString("plaud.disconnect", value: "Disconnect", comment: "") }
        static var charging: String { NSLocalizedString("plaud.charging", value: "Charging", comment: "") }
        // ★ 2026-10-21: card history + device-list rows
        static var cardRecordings: String { NSLocalizedString("plaud.card_recordings", value: "Recordings on card", comment: "How many recordings the card currently holds") }
        static func cardRecordingsCount(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.card_recordings_count", value: "%d clip(s)", comment: "History count on the card; %d = number"), count)
        }
        static var historyUnknown: String { NSLocalizedString("plaud.history_unknown", value: "Not read yet", comment: "Shown when the card's recording count hasn't been read") }
        static var refresh: String { NSLocalizedString("plaud.refresh", value: "Refresh", comment: "Re-read the card's state / recording count") }
        static var stateConnected: String { NSLocalizedString("plaud.state_connected", value: "Connected", comment: "") }
        static var stateDisconnected: String { NSLocalizedString("plaud.state_disconnected", value: "Not connected", comment: "") }
        static var reconnect: String { NSLocalizedString("plaud.reconnect", value: "Reconnect", comment: "Re-bind a card we have paired with before") }
        static var notConnected: String { NSLocalizedString("plaud.not_connected", value: "Connect the card first.", comment: "") }
        static var connectingThenRecord: String { NSLocalizedString("plaud.connecting_then_record", value: "Connecting to the card — recording starts as soon as it answers.", comment: "Feedback after tapping record while the card is asleep") }
        static var liveTranscript: String { NSLocalizedString("plaud.live_transcript", value: "Live transcript", comment: "On-device live transcription of the card's audio") }
        static var liveBadge: String { NSLocalizedString("plaud.live_badge", value: "Live", comment: "Small badge next to the live transcript title while the card is recording") }
        static var liveWaiting: String { NSLocalizedString("plaud.live_waiting", value: "Listening — text shows up after the first sentence.", comment: "Live transcript placeholder while the engine has not produced any text yet") }
        static var liveIdle: String { NSLocalizedString("plaud.live_idle", value: "Nothing transcribed yet. Text appears here while the card records.", comment: "Live transcript placeholder when no take has been transcribed") }
        /// Shown right after a take ends: the live words are gone from the panel
        /// on purpose (Plaud / vobot clear the live view when the take stops).
        static var liveTakeEnded: String { NSLocalizedString("plaud.live_take_ended", value: "This take has ended, so its live text is cleared — it is saved with the recording once the file lands.", comment: "Live panel after a take stopped: the text belongs to the recording now") }
        static var liveExpand: String { NSLocalizedString("plaud.live_expand", value: "Full transcript", comment: "Open the live transcript full screen") }
        static var liveCollapse: String { NSLocalizedString("plaud.live_collapse", value: "Minimise", comment: "Close the floating recording stage and keep recording in the background") }
        /// The in-app bookmark button on the stage / live page — drops a marker
        /// line into the live transcript at the moment it is pressed.
        static var liveAddMark: String { NSLocalizedString("plaud.live_add_mark", value: "Mark", comment: "Button that inserts a bookmark into the live transcript while recording") }
        static var liveCopy: String { NSLocalizedString("plaud.live_copy", value: "Copy", comment: "Copy the live transcript") }
        static var liveCopied: String { NSLocalizedString("plaud.live_copied", value: "Copied", comment: "Confirmation after copying the live transcript") }
        static var liveNeedsPermission: String { NSLocalizedString("plaud.live_needs_permission", value: "Live transcription needs Speech Recognition permission — allow it in Settings → Nomily, or the card still records without text.", comment: "Live transcript unavailable: speech permission missing") }
        static var liveModelMissing: String { NSLocalizedString("plaud.live_model_missing", value: "The offline speech model for this language isn't installed on this iPhone, so live text is off. The recording itself is unaffected.", comment: "Live transcript unavailable: on-device model not installed") }
        static var liveNeedConnect: String { NSLocalizedString("plaud.live_need_connect", value: "Connect the card and the live transcript appears here.", comment: "Live tab, PLAUD card paired but not connected") }
        /// A bookmark line inside the transcript / saved text. `%@` = mm:ss.
        static func liveMarkLine(_ clock: String) -> String {
            String(format: NSLocalizedString("plaud.live_mark_line", value: "Mark · %@", comment: "Bookmark marker inside the live transcript; %@ = mm:ss"), clock)
        }
        static var liveSaved: String { NSLocalizedString("plaud.live_saved", value: "Saved to the library", comment: "The live transcript has been written next to the pulled clip") }
        static var liveSavePending: String { NSLocalizedString("plaud.live_save_pending", value: "The transcript is saved as soon as the card's file lands in the library.", comment: "Live transcript waits for the export to finish") }
        static var liveSaveAction: String { NSLocalizedString("plaud.live_save_action", value: "Save to library", comment: "Button that pulls the card's file so the transcript can be attached") }
        static var liveSaveNeedsClip: String { NSLocalizedString("plaud.live_save_needs_clip", value: "The transcript is kept with the recording — stop the take to save both.", comment: "Save to library pressed while still recording") }
        /// Which engine is producing the text, shown next to the panel title.
        static func liveEngine(_ name: String) -> String {
            switch name {
            case "azure":
                return NSLocalizedString("plaud.live_engine_azure", value: "Azure", comment: "Live transcript engine: Azure Speech")
            case "ondevice":
                return NSLocalizedString("plaud.live_engine_ondevice", value: "On-device", comment: "Live transcript engine: Apple's offline recogniser")
            case "custom":
                return ASR.customServer
            default:
                return name
            }
        }
        static func liveAzureFailed(_ message: String) -> String {
            String(format: NSLocalizedString("plaud.live_azure_failed", value: "Azure live transcription stopped: %@", comment: "Live transcript error from Azure; %@ = reason"), message)
        }
        /// ★ 2026-10-23: the Aliyun real-time engine has its own wording — a
        /// token/quota/network failure there is not an "Azure" problem.
        static func liveAliyunFailed(_ message: String) -> String {
            String(format: NSLocalizedString("plaud.live_aliyun_failed", value: "Aliyun live transcription stopped: %@", comment: "Live transcript error from Aliyun; %@ = reason"), message)
        }
        /// ★ 2026-11-04: 自定义端点是分段请求（每 5 s 一次），失败原因必须
        /// 原样报出来 —— "HTTP 400" 之外用户看不到任何线索。
        static func liveCustomFailed(_ message: String) -> String {
            String(format: NSLocalizedString("plaud.live_custom_failed", value: "Custom ASR server stopped: %@", comment: "Live transcript error from the user's own OpenAI-compatible endpoint; %@ = reason"), message)
        }
        static var liveAzureFellBack: String { NSLocalizedString("plaud.live_azure_fell_back", value: "Azure dropped out — continuing with on-device recognition.", comment: "Automatic fallback after Azure failed mid-take") }
        static var cardFiles: String { NSLocalizedString("plaud.card_files", value: "Recordings on the card", comment: "Home device segment: the card's own file list") }
        static var cardFilesEmpty: String { NSLocalizedString("plaud.card_files_empty", value: "No recordings on the card.", comment: "") }
        static var recordingPaused: String { NSLocalizedString("plaud.recording_paused", value: "Paused", comment: "") }
        static var pullThisFile: String { NSLocalizedString("plaud.pull_this_file", value: "Pull", comment: "Download one recording from the card") }
        static func recordingElapsed(_ text: String) -> String {
            String(format: NSLocalizedString("plaud.recording_elapsed", value: "Recording · %@", comment: "Live recording clock on the card row; %@ = mm:ss"), text)
        }
        static var recordSpaceFull: String { NSLocalizedString("plaud.record_space_full", value: "The card refused: storage is full.", comment: "") }
        static var recordUDisk: String { NSLocalizedString("plaud.record_udisk", value: "The card is in U-disk mode — leave that mode first.", comment: "") }
        static var recordHardware: String { NSLocalizedString("plaud.record_hardware", value: "The card reported a hardware error.", comment: "") }
        static var recordBusy: String { NSLocalizedString("plaud.record_busy", value: "The card is busy — try again in a moment.", comment: "") }
        static var recordWrongMode: String { NSLocalizedString("plaud.record_wrong_mode", value: "The card is not in recording mode.", comment: "") }
        static func recordFailed(_ status: Int) -> String {
            String(format: NSLocalizedString("plaud.record_failed", value: "The card refused to record (code %d).", comment: ""), status)
        }
        static var deviceDetailTitle: String { NSLocalizedString("plaud.device_detail_title", value: "PLAUD card", comment: "Navigation title of the PLAUD device page") }
        // ★ 2026-10-21 (2nd round): delete-on-card + bookmark ("打点") sync
        static var deleteFromCard: String { NSLocalizedString("plaud.delete_from_card", value: "Delete from card", comment: "Row action: erase one recording on the card") }
        static var deleteFromCardTitle: String { NSLocalizedString("plaud.delete_from_card_title", value: "Delete this recording from the card?", comment: "") }
        static var deleteFromCardMsg: String { NSLocalizedString("plaud.delete_from_card_msg", value: "It is erased from the card and cannot be recovered. Pull it first if you want to keep it.", comment: "") }
        static var savedToLibrary: String { NSLocalizedString("plaud.saved_to_library", value: "Pulled", comment: "This recording is already in the library") }
        static var marksTitle: String { NSLocalizedString("plaud.marks_title", value: "Marks", comment: "Bookmarks pressed on the card while recording") }
        static func marksCount(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.marks_count", value: "%d mark(s)", comment: "How many bookmarks a recording carries; %d = number"), count)
        }
        static var marksLive: String { NSLocalizedString("plaud.marks_live", value: "Marks this recording", comment: "Live count of marks pressed during the current recording") }
        static var marksWaiting: String { NSLocalizedString("plaud.marks_waiting", value: "Press the card's key to add one", comment: "Shown while recording and no mark has been reported yet") }
        static var marksAfterStop: String { NSLocalizedString("plaud.marks_after_stop", value: "The card reports marks when the take ends", comment: "This firmware ignores the live mark query, so the count appears after stopping") }
        static var recordingNowOnCard: String { NSLocalizedString("plaud.recording_now_on_card", value: "Recording on the card — the list refreshes when it stops.", comment: "") }
        // ★ 2026-10-21 (3rd round): device info behind the pill tap, transfer prefs, progress
        static var transferHeader: String { NSLocalizedString("plaud.transfer_header", value: "Transfer", comment: "Section title for transfer settings / progress") }
        static var deleteAfterSyncFooter: String { NSLocalizedString("plaud.delete_after_sync_footer", value: "Once a recording has been pulled into the library it is erased from the card. Off = the card keeps its copy.", comment: "") }
        static var deviceInfoHint: String { NSLocalizedString("plaud.device_info_hint", value: "Shows the card's serial number, firmware, battery, storage and connection actions.", comment: "Accessibility hint for the row that opens device info") }
        static var downloadingSingle: String { NSLocalizedString("plaud.downloading_single", value: "Transferring…", comment: "Progress caption while one recording is being pulled") }
        // ★ 2026-10-21 (4th round): rename + storage bar
        static var deviceInfoHeader: String { NSLocalizedString("plaud.device_info_header", value: "Device", comment: "Section header for the card's name row in device info") }
        static var deviceName: String { NSLocalizedString("plaud.device_name", value: "Name", comment: "The card's display name") }
        static var serialNumber: String { NSLocalizedString("plaud.serial_number", value: "Serial number", comment: "The card's product SN shown in device info") }
        static var copySN: String { NSLocalizedString("plaud.copy_sn", value: "Copy serial number", comment: "") }
        static var rename: String { NSLocalizedString("plaud.rename", value: "Rename", comment: "Rename the card as it appears in the app") }
        static var renameMessage: String { NSLocalizedString("plaud.rename_message", value: "Only changes the name in this app — the card itself is untouched. Leave it empty to go back to the model name.", comment: "") }
        static func storageUsed(_ value: String) -> String {
            String(format: NSLocalizedString("plaud.storage_used", value: "Used %@", comment: "Storage bar label; %@ = size like 1.2 GB"), value)
        }
        static func storageLeft(_ value: String) -> String {
            String(format: NSLocalizedString("plaud.storage_left", value: "Free %@", comment: "Storage bar label; %@ = size like 58.4 GB"), value)
        }
        // ★ 2026-10-21 (5th round): multi-select on the card's recording list
        static var selectFiles: String { NSLocalizedString("plaud.select_files", value: "Select", comment: "Enter multi-select mode on the card's recording list") }
        static func selectedFilesCount(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.selected_files_count", value: "%d selected", comment: "Multi-select footer; %d = how many recordings are ticked"), count)
        }
        static func selectAllFilesCount(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.select_all_files", value: "Select all (%d)", comment: "Multi-select footer; %d = how many recordings the card holds"), count)
        }
        static var deselectAllFiles: String { NSLocalizedString("plaud.deselect_all_files", value: "Deselect all", comment: "Multi-select footer: clear the ticked recordings") }
        static func pullSelected(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.pull_selected", value: "Pull %d", comment: "Multi-select action: download the ticked recordings; %d = count"), count)
        }
        static func deleteSelected(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.delete_selected", value: "Delete %d", comment: "Multi-select action: erase the ticked recordings from the card; %d = count"), count)
        }
        static var deleteSelectedTitle: String { NSLocalizedString("plaud.delete_selected_title", value: "Delete the selected recordings from the card?", comment: "") }
        static func deleteSelectedMessage(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.delete_selected_message", value: "%d recording(s) will be erased from the card and cannot be recovered. Pull them first if you want to keep a copy.", comment: ""), count)
        }
        // ★ 2026-10-21 (6th round): transfer watchdog / retry feedback
        static func queuedBehindTransfer(_ added: Int, _ queued: Int) -> String {
            String(format: NSLocalizedString("plaud.queued_behind_transfer", value: "Added %d to the transfer queue (%d waiting).", comment: "Feedback when a pull is tapped while another transfer is still running"), added, queued)
        }
        static var syncStalledReset: String { NSLocalizedString("plaud.sync_stalled_reset", value: "The last transfer stalled — reset, starting again.", comment: "") }
        static var syncCancelled: String { NSLocalizedString("plaud.sync_cancelled", value: "Transfer stopped.", comment: "") }
        static func syncSkipped(_ remaining: Int) -> String {
            String(format: NSLocalizedString("plaud.sync_skipped", value: "One file timed out and was skipped (%d left).", comment: ""), remaining)
        }
        static func syncDoneWithSkips(_ count: Int) -> String {
            String(format: NSLocalizedString("plaud.sync_done_with_skips", value: "Done — %d file(s) timed out. Tap a row to retry.", comment: ""), count)
        }
        static func syncFailedOne(_ message: String) -> String {
            String(format: NSLocalizedString("plaud.sync_failed_one", value: "Skipped one file: %@", comment: ""), message)
        }
        static var stopTransfer: String { NSLocalizedString("plaud.stop_transfer", value: "Stop", comment: "Stop the running card transfer") }

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
        // MARK: Settings groups (★ 2026-10-22, Apple-style grouping)
        static var groupCapture: String { NSLocalizedString("settings.group.capture", value: "Recording", comment: "Settings group: capture + transcription") }
        static var groupGenerate: String { NSLocalizedString("settings.group.generate", value: "Text generation", comment: "Settings group: LLM + templates") }
        static var groupLibrary: String { NSLocalizedString("settings.group.library", value: "Library and tasks", comment: "Settings group: devices, trash, job queue") }
        static var groupGeneral: String { NSLocalizedString("settings.group.general", value: "General", comment: "Settings group: language, theme") }
        static var recordings: String { NSLocalizedString("settings.recordings", comment: "") }
        static var summarizeTemplates: String { NSLocalizedString("settings.summarize_templates", comment: "") }
        static var devicesAndLibrary: String { NSLocalizedString("settings.devices_library", comment: "") }
        static var about: String { NSLocalizedString("settings.about", comment: "") }
        static var version: String { NSLocalizedString("settings.version", comment: "") }
        static var language: String { NSLocalizedString("settings.language", comment: "") }
        static var theme: String {
            NSLocalizedString("settings.theme", value: "Theme", comment: "Colour theme row")
        }
        /// ★ 2026-11-02: replays the first-launch onboarding walkthrough.
        static var usageGuide: String {
            NSLocalizedString("settings.usage_guide", value: "Usage guide",
                              comment: "Settings row: replay the first-launch walkthrough")
        }
        /// ★ 2026-11-02（用户："开屏的欢迎页我如何才能再次体验"）：该行的副标题，
        /// 明确它同时重播欢迎页。
        static var usageGuideDetail: String {
            NSLocalizedString("settings.usage_guide_detail", value: "Replay the welcome screen and the tour",
                              comment: "Settings row subtitle: replays the welcome sheet as well")
        }

        // ★ 2026-11-06（用户两次反馈"找不到入口"）：设置页顶部搜索。
        static var searchPlaceholder: String {
            NSLocalizedString("settings.search_placeholder", value: "Search settings",
                              comment: "Settings search field placeholder")
        }
        static var searchEmpty: String {
            NSLocalizedString("settings.search_empty", value: "Nothing matches — try a shorter word",
                              comment: "Settings search: no results")
        }
        static var searchHint: String {
            NSLocalizedString("settings.search_hint", value: "Finds entries by name, not switch values",
                              comment: "Settings search footer: what is indexed")
        }

        // ★ 2026-11-03（用户："设置的最上角增加一个横条…引导用户去购买 Vobot V05E"）：
        // 设置页顶部的购买横幅。
        // ★ 同日措辞修正（用户："要写最适配的录音卡硬件，而不是配套的——配套则是官方的 app"）：
        //   「配套」会被读成"官方配对硬件"，实际卖点是"和本 App 最适配"。
        static var buyBannerTitle: String {
            NSLocalizedString("settings.buy_banner_title", value: "Vobot V05E Recorder Card",
                              comment: "Settings top banner: recommended hardware name")
        }
        static var buyBannerSubtitle: String {
            NSLocalizedString("settings.buy_banner_subtitle",
                              value: "The recorder card that fits Nomily best — on Amazon",
                              comment: "Settings top banner subtitle: best-matched hardware, where to buy")
        }
    }

    // MARK: - 免责声明 / 使用须知（★ 2026-11-03）

    /// 首启同意页与「关于 → 免责声明」共用的一套文案。
    ///
    /// ⚠️ 和 `Welcome` 一样走 `Bundle.systemString`（**系统语言**），不走 App 内语言：
    ///    这一页出现在用户做任何语言选择之前，跟着系统走才合理。
    enum Consent {
        static var title: String {
            Bundle.systemString("consent.title", value: "Before you start")
        }
        static var subtitle: String {
            Bundle.systemString(
                "consent.subtitle",
                value: "Nomily records sound and turns it into text with AI models. Please read the three points below — they are the terms you agree to when you tap Accept."
            )
        }
        static var recordingTitle: String {
            Bundle.systemString("consent.recording.title", value: "Recording other people")
        }
        static var recordingBody: String {
            Bundle.systemString(
                "consent.recording.body",
                value: "You are responsible for how you record. Get the consent of everyone in the room where the law requires it, and never use Nomily for surveillance or any unlawful purpose. Nomily cannot know whether a given recording is legal where you are."
            )
        }
        static var aiTitle: String {
            Bundle.systemString("consent.ai.title", value: "AI output can be wrong")
        }
        static var aiBody: String {
            Bundle.systemString(
                "consent.ai.body",
                value: "Transcripts, summaries, chapters and to-dos are generated by models and may be inaccurate, incomplete or made up. Check anything important yourself, and never treat AI output as the only basis for legal, medical or financial decisions."
            )
        }
        static var dataTitle: String {
            Bundle.systemString("consent.data.title", value: "Your audio, your providers")
        }
        static var dataBody: String {
            Bundle.systemString(
                "consent.data.body",
                value: "When you turn on a cloud speech or language service, your audio and text are sent to the provider you configured, under their terms. Your API keys and recordings stay yours: Nomily has no server of its own and does not collect them."
            )
        }
        static var accept: String {
            Bundle.systemString("consent.accept", value: "Accept and continue")
        }
        static var decline: String {
            Bundle.systemString("consent.decline", value: "Do not accept")
        }
        static var declinedNote: String {
            Bundle.systemString(
                "consent.declined.note",
                value: "Nomily needs this agreement before it can record or transcribe. You can read it again any time in Settings › About."
            )
        }
        static var legalTitle: String {
            Bundle.systemString("consent.legal.title", value: "Terms of use")
        }
        static var aboutRow: String {
            Bundle.systemString("consent.about.row", value: "Disclaimer & terms of use")
        }
        static var statusLabel: String {
            Bundle.systemString("consent.status.label", value: "Agreement")
        }
        static var statusAccepted: String {
            Bundle.systemString("consent.status.accepted", value: "Accepted")
        }
        static var statusPending: String {
            Bundle.systemString("consent.status.pending", value: "Not yet accepted")
        }
        /// 手表端只有一句（用户："手表只放短提示"）。
        static var watchHint: String {
            Bundle.systemString(
                "consent.watch.hint",
                value: "Record only with everyone's consent. AI transcripts can be wrong."
            )
        }
    }

    // MARK: - First-run guide (★ 2026-11-02, 流程式)

    /// ★ 2026-11-02（用户："首次用户使用需要弹出用户引导…会展示三条示例介绍需要跟随
    /// 当前语言切换进行切换"）：首启欢迎页——介绍三条示例，再交给流程式引导。
    /// ★ 同日补充（用户："这个开屏需要跟随手机系统的语言进行设置"）：这一整套文案
    /// **跟手机系统语言**、不跟 App 内语言选择——开屏发生在用户做任何选择之前。
    enum Welcome {
        // ★ 全部走 `Bundle.systemString`（系统语言），不走 `NSLocalizedString`——
        //   开屏要跟手机系统语言，见 `Bundle.systemLanguage` 的说明。
        static var title: String {
            Bundle.systemString("welcome.title", value: "Welcome to Nomily")
        }
        static var subtitle: String {
            Bundle.systemString("welcome.subtitle",
                                value: "Your pocket AI recorder — recording, transcription, AI summaries and cloud backup in one place.")
        }
        static var samplesHeader: String {
            Bundle.systemString("welcome.samples_header", value: "Three samples are already in your library")
        }
        static var sampleGuideTitle: String {
            Bundle.systemString("welcome.sample_guide_title", value: "How to use Nomily AI")
        }
        static var sampleGuideBody: String {
            Bundle.systemString("welcome.sample_guide_body", value: "Three steps: record → transcribe → organise")
        }
        static var sampleWelcomeTitle: String {
            Bundle.systemString("welcome.sample_welcome_title", value: "Welcome to Nomily AI")
        }
        static var sampleWelcomeBody: String {
            Bundle.systemString("welcome.sample_welcome_body", value: "Read this first — what Nomily can do for you")
        }
        static var sampleMeetingTitle: String {
            Bundle.systemString("welcome.sample_meeting_title", value: "Product Weekly (sample)")
        }
        static var sampleMeetingBody: String {
            Bundle.systemString("welcome.sample_meeting_body",
                                value: "A full sample recording: transcript, summary, action items and outline")
        }
        static var footer: String {
            Bundle.systemString("welcome.footer",
                                value: "You can replay the walkthrough anytime from Settings → Usage guide.")
        }
        static var start: String {
            Bundle.systemString("welcome.start", value: "Get started")
        }
    }

    /// 流程式首用引导：卡片浮在真实页面上（见 FirstRunGuide.swift），
    /// 整页式 onboarding 已按用户要求移除。
    enum Guide {
        static var stepOf: String {
            NSLocalizedString("guide.step_of", value: "Step %d of %d", comment: "Guide card: step counter, args = current, total")
        }
        static var skip: String {
            NSLocalizedString("guide.skip", value: "Skip tour", comment: "Guide card: leave the whole tour")
        }
        static var next: String {
            NSLocalizedString("guide.next", value: "Next", comment: "Guide card: advance button (no primary action on this step)")
        }
        static var later: String {
            NSLocalizedString("guide.later", value: "Got it — next", comment: "Guide card: advance button when the step has a primary action")
        }
        static var actionConnect: String {
            NSLocalizedString("guide.action.connect", value: "Connect a device", comment: "Guide step 1 primary button: opens the scanner")
        }
        static var actionGo: String {
            NSLocalizedString("guide.action.go", value: "Take me there", comment: "Guide card primary button: deep-links into the module")
        }
        static var titleConnect: String {
            NSLocalizedString("guide.title.connect", value: "Connect a recorder", comment: "")
        }
        static var bodyConnect: String {
            NSLocalizedString("guide.body.connect",
                              value: "Tap the device dot in the top-left corner to scan for your recorder bean or card — or just record with the iPhone microphone.",
                              comment: "")
        }
        static var titleLive: String {
            NSLocalizedString("guide.title.live", value: "Live transcription", comment: "")
        }
        static var bodyLive: String {
            NSLocalizedString("guide.body.live",
                              value: "The Live tab turns speech into captions in real time — open it from the bottom tab bar whenever you need it.",
                              comment: "")
        }
        static var titleASR: String {
            NSLocalizedString("guide.title.asr", value: "Set up transcription", comment: "")
        }
        static var bodyASR: String {
            NSLocalizedString("guide.body.asr",
                              value: "Transcription uses your own API key. Pick a vendor — every sheet has a get-the-key guide with a direct console link.",
                              comment: "")
        }
        static var titleLLM: String {
            NSLocalizedString("guide.title.llm", value: "Set up AI summaries", comment: "")
        }
        static var bodyLLM: String {
            NSLocalizedString("guide.body.llm",
                              value: "Summaries are written by an AI model you choose. Pick one and paste its key — the signup link is right in the form.",
                              comment: "")
        }
        static var titleBackup: String {
            NSLocalizedString("guide.title.backup", value: "Back up to your cloud", comment: "")
        }
        static var bodyBackup: String {
            NSLocalizedString("guide.body.backup",
                              value: "Recording & Transcription → WebDAV backup: transcripts upload themselves to Nutstore, Nextcloud or any WebDAV drive, one folder per recording.",
                              comment: "")
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
        static var pasteTitle: String {
            NSLocalizedString("setup.paste_title", value: "Paste AI Setup Result",
                              comment: "Row next to the copy row: parses the NOMILY-SETUP block the desktop AI printed and auto-fills the config")
        }
        static var pasteHint: String {
            NSLocalizedString("setup.paste_hint", value: "Copy the NOMILY-SETUP block (or the four values) the AI printed, then tap here.",
                              comment: "Tells the user what to paste")
        }
        static var pasteEmpty: String {
            NSLocalizedString("setup.paste_empty", value: "Clipboard is empty — copy the AI's result first.",
                              comment: "Nothing on the pasteboard when the paste row is tapped")
        }
        static var pasteNotFound: String {
            NSLocalizedString("setup.paste_not_found", value: "No setup values found in the clipboard text.",
                              comment: "The pasted text carried no recognizable asr_host/llm_base_url lines")
        }
        static func pasteDone(_ what: String) -> String {
            String(format: NSLocalizedString("setup.paste_done", value: "Filled in: %@", comment: "What the paste actually wrote, e.g. 'ASR 192.168.1.5:12300 · Ollama http://…'"), what)
        }
    }

    // MARK: - Profile (称呼, 2026-10-28 · FanEar spec §3.2)

    enum Profile {
        static var userName: String {
            NSLocalizedString("profile.user_name", value: "Your Name for the AI", comment: "Settings row: how the AI addresses the user / labels their own speech")
        }
        static var userNamePlaceholder: String {
            NSLocalizedString("profile.user_name_placeholder", value: "e.g. Angel", comment: "Placeholder in the user-name field")
        }
        static var footer: String {
            NSLocalizedString("profile.footer", value: "Rides along with every AI summary: the model knows who the recording belongs to and can mark their own speech as “Name (me)”.",
                              comment: "What the user name is used for")
        }
        static var save: String {
            NSLocalizedString("profile.save", value: "Save", comment: "Confirm button next to the user-name field")
        }
    }

    // MARK: - Social (★ 2026-10-29 用户反馈入口：X / 小红书)

    enum Social {
        static var xHomepage: String {
            NSLocalizedString("social.x", value: "Nomily on X", comment: "Link row to the X (Twitter) homepage")
        }
        static var xiaohongshuHomepage: String {
            NSLocalizedString("social.rednote", value: "Nomily on 小红书", comment: "Link row to the Xiaohongshu (RED) homepage")
        }
        static var discordCommunity: String {
            NSLocalizedString("social.discord", value: "Nomily community on Discord", comment: "Link row to the Discord community")
        }
        /// ★ 2026-10-30：底部第四枚图标——支持邮箱（mailto 唤起系统邮件）。
        static var supportEmail: String {
            NSLocalizedString("social.email", value: "Email us (nomily@geekis.com)", comment: "Icon that opens a mail draft to the support address")
        }
    }

    // MARK: - Diagnostics export (★ 2026-10-30 一键导出诊断报告)

    enum Diagnostics {
        static var export: String {
            NSLocalizedString("diag.export", value: "Export Diagnostics Report", comment: "Button that bundles the run log + device info into a shareable file")
        }
        static var share: String {
            NSLocalizedString("diag.share", value: "Share Diagnostics Report", comment: "ShareLink for the generated diagnostics file")
        }
        static var footer: String {
            NSLocalizedString("diag.footer", value: "The report contains the run log and device info only — no recordings, transcripts or keys. Email it to nomily@geekis.com when something misbehaves.", comment: "Footer under the diagnostics export row")
        }
    }

    // MARK: - Storage usage (★ 2026-10-30 本地/NAS/iCloud 占用大小)

    enum StorageUsage {
        static var title: String { NSLocalizedString("storage.title", comment: "") }
        static var local: String { NSLocalizedString("storage.local", comment: "") }
        static var localHeader: String { NSLocalizedString("storage.local_header", comment: "") }
        static var localFooter: String { NSLocalizedString("storage.local_footer", comment: "") }
        static var webdav: String { NSLocalizedString("storage.webdav", comment: "") }
        static var serverHeader: String { NSLocalizedString("storage.server_header", comment: "") }
        static var webdavFooter: String { NSLocalizedString("storage.webdav_footer", comment: "") }
        static var folder: String { NSLocalizedString("storage.folder", comment: "") }
        static var folderHeader: String { NSLocalizedString("storage.folder_header", comment: "") }
        static var folderFooter: String { NSLocalizedString("storage.folder_footer", comment: "") }
        static var notConfigured: String { NSLocalizedString("storage.not_configured", comment: "") }
        static func unavailable(_ reason: String) -> String {
            String(format: NSLocalizedString("storage.unavailable", comment: ""), reason)
        }
        static func fileCount(_ n: Int) -> String {
            String(format: NSLocalizedString("storage.file_count", comment: ""), n)
        }

        // ★ 2026-10-30 二稿（用户："按照块状显示，设备与资料库，显示统计那个设备
        // 记录时长还有手表的，多一点图表动效"）：块状卡片用到的文案。
        static var totalLabel: String {
            NSLocalizedString("storage.total_label", value: "Used across every location", comment: "Storage page: caption under the big total number")
        }
        static var sourcesHeader: String {
            NSLocalizedString("storage.sources_header", value: "Devices & library", comment: "Storage page: card grid header for per-source usage")
        }
        static var locationsHeader: String {
            NSLocalizedString("storage.locations_header", value: "Locations", comment: "Storage page: card list header for local / NAS / iCloud")
        }
        static var emptySources: String {
            NSLocalizedString("storage.empty_sources", value: "No recordings on this iPhone yet.", comment: "Storage page: empty state for the per-source cards")
        }
        static var refreshing: String {
            NSLocalizedString("storage.refreshing", value: "Measuring…", comment: "Storage page: shown while the scan is running")
        }
        static var durationUnknown: String {
            NSLocalizedString("storage.duration_unknown", value: "Duration not measured yet", comment: "Storage page: source card when no clip has a cached duration")
        }
        static func durationHM(_ h: Int, _ m: Int) -> String {
            String(format: NSLocalizedString("storage.duration_hm", value: "%dh %dm recorded", comment: "Storage page: recorded time, hours and minutes"), h, m)
        }
        static func durationM(_ m: Int) -> String {
            String(format: NSLocalizedString("storage.duration_m", value: "%dm recorded", comment: "Storage page: recorded time, minutes only"), m)
        }
        static func durationS(_ s: Int) -> String {
            String(format: NSLocalizedString("storage.duration_s", value: "%ds recorded", comment: "Storage page: recorded time, seconds only"), s)
        }
        static var footnote: String {
            NSLocalizedString(
                "storage.footnote",
                value: "Every number is measured on disk: local bytes scanned in audio_clips/, NAS bytes read back from the server with PROPFIND, iCloud bytes read through the folder bookmark. Recording time comes from the library's duration cache — clips not yet played or scanned show no duration.",
                comment: "Storage page footnote explaining how the figures are measured")
        }
    }

    // MARK: - Watch recap settings (★ 2026-10-30 回顾摘要接进手机设置)

    enum Recap {
        static var title: String {
            NSLocalizedString("recap.title", value: "Recap", comment: "Apple Watch settings section: the wrist recap digest")
        }
        static var toggle: String {
            NSLocalizedString("recap.toggle", value: "Send recaps to Apple Watch", comment: "Toggle: push summary digests to the watch")
        }
        static var footer: String {
            NSLocalizedString(
                "recap.footer",
                value: "Each finished summary appears on the watch with its key points and to-dos. Tap a to-do there and it lands in this iPhone's Reminders app.",
                comment: "Footer explaining the wrist recap and the tap-to-sync to-dos")
        }
    }

    // MARK: - Reminders sync (★ 2026-10-29 待办同步到系统提醒事项)

    enum Reminders {
        static var toggle: String {
            NSLocalizedString("reminders.toggle", value: "Sync to-dos to Reminders", comment: "Toggle that pushes recording to-dos into the iOS Reminders app")
        }
        static var footer: String {
            NSLocalizedString("reminders.footer", value: "After turning this on, every to-do in a recording's summary is added to the iPhone's Reminders app (checking it in Nomily also checks it there). Regenerated summaries only add new items — removed ones stay in Reminders.", comment: "Footer under the reminders sync toggle")
        }
        static var denied: String {
            NSLocalizedString("reminders.denied", value: "Reminders access was declined. Enable it in Settings to sync.", comment: "Shown when reminders permission is denied")
        }
        static var openSettings: String {
            NSLocalizedString("reminders.open_settings", value: "Open Settings", comment: "Button that opens the app's system settings page")
        }
        static var sourceNote: String {
            NSLocalizedString("reminders.source_note", value: "From the Nomily recording “%@”", comment: "Notes field of a reminder created from a recording's to-dos; %@ = recording name")
        }
        static var syncedBadge: String {
            NSLocalizedString("reminders.synced_badge", value: "Synced to Reminders", comment: "Small status line under a recording's to-do list")
        }
        /// ★ 2026-10-30（用户："同步到手机待办这个是同步到手机的提醒事项方便查看需要做的事情"）：
        /// 待办列表底部的常驻说明——不是"刚才新建了几条"的瞬时提示，而是告诉用户
        /// **去哪儿能看到还剩什么要做**。
        static var listFooter: String {
            NSLocalizedString("reminders.list_footer",
                              value: "These to-dos are in the iPhone Reminders app — open Reminders to see what's left.",
                              comment: "Persistent footnote under a recording's to-do list while reminders sync is on")
        }
    }

    // MARK: - Token usage (每日用量热力图, 2026-10-28 · FanEar spec §1.2)

    enum TokenUsage {
        static var title: String {
            NSLocalizedString("token.title", value: "AI Usage", comment: "Settings row + page title for the daily token heatmap")
        }
        static var dailyUsage: String {
            NSLocalizedString("token.daily_usage", value: "Daily usage", comment: "Heatmap section header on the LLM page")
        }
        static var today: String { NSLocalizedString("token.today", value: "Today", comment: "Heatmap summary card") }
        static var thisMonth: String { NSLocalizedString("token.this_month", value: "This month", comment: "Heatmap summary card") }
        static var less: String { NSLocalizedString("token.less", value: "Less", comment: "Heatmap legend, left end") }
        static var more: String { NSLocalizedString("token.more", value: "More", comment: "Heatmap legend, right end") }
        static var noUse: String {
            NSLocalizedString("token.no_use", value: "No AI use on this day.", comment: "Tapping an empty day cell")
        }
        static var footer: String {
            NSLocalizedString("token.footer", value: "Estimated tokens (characters × 0.62) for trend only — not a billing figure. Counts AI summaries and chapter outlines.",
                              comment: "Honest caveat under the heatmap")
        }
        static func detail(_ tokens: String, _ calls: Int) -> String {
            String(format: NSLocalizedString("token.detail", value: "About %@ tokens · %d AI calls", comment: "Day detail line: estimated tokens and number of completions"), tokens, calls)
        }
    }

    // MARK: - Vocabulary (常用词, 2026-10-28 · FanEar spec §1.4)

    enum Vocabulary {
        static var title: String {
            NSLocalizedString("vocab.title", value: "Custom Vocabulary", comment: "Settings row + editor page title")
        }
        // ★ 2026-10-29 (截图 5 布局)：搜索 / 用量卡 / 频率来源 / 挖掘。
        static var searchPlaceholder: String {
            NSLocalizedString("vocab.search", value: "Search vocabulary", comment: "Search field at the top of the vocabulary editor")
        }
        static func usedCount(_ used: Int, _ limit: Int) -> String {
            String(format: NSLocalizedString("vocab.used_count", value: "%d of %d used", comment: "Usage card headline"), used, limit)
        }
        static var usageNote: String {
            NSLocalizedString("vocab.usage_note",
                              value: "On-device transcription does not use the vocabulary; it is handed to the LLM when summarizing.",
                              comment: "Usage card explanatory line")
        }
        static func autoAdded(_ n: Int) -> String {
            String(format: NSLocalizedString("vocab.auto_added", value: "Auto-added %d in the last 7 days", comment: "Recent auto-mined words line"), n)
        }
        static var seeSources: String {
            NSLocalizedString("vocab.see_sources", value: "Sources", comment: "Button to view where auto-added words came from")
        }
        static var autoTag: String {
            NSLocalizedString("vocab.auto_tag", value: "Auto", comment: "Badge on auto-mined vocabulary entries")
        }
        // ★ 2026-11-02（用户："常用词汇要支持选择删除多选"）：多选删除。
        static var select: String {
            NSLocalizedString("vocab.select", value: "Select", comment: "Enter multi-select mode in the vocabulary editor")
        }
        static func selectedHeader(_ n: Int) -> String {
            String(format: NSLocalizedString("vocab.selected_header", value: "%d selected", comment: "Header of the word list in multi-select mode"), n)
        }
        static var selectAll: String {
            NSLocalizedString("vocab.select_all", value: "Select all", comment: "Multi-select: select every (filtered) word")
        }
        static var deselectAll: String {
            NSLocalizedString("vocab.deselect_all", value: "Deselect all", comment: "Multi-select: clear the selection")
        }
        static func deleteSelected(_ n: Int) -> String {
            String(format: NSLocalizedString("vocab.delete_selected", value: "Delete selected (%d)", comment: "Destructive button in multi-select mode"), n)
        }
        static func confirmDeleteSelected(_ n: Int) -> String {
            String(format: NSLocalizedString("vocab.confirm_delete_selected", value: "Delete %d selected words? This cannot be undone.", comment: "Confirmation before batch-deleting vocabulary"), n)
        }
        static func deletedCount(_ n: Int) -> String {
            String(format: NSLocalizedString("vocab.deleted_selected", value: "Deleted %d words", comment: "Notice after batch deletion"), n)
        }
        static func sourceLine(_ sources: String) -> String {
            String(format: NSLocalizedString("vocab.source_line", value: "From: %@", comment: "Per-entry source clips line"), sources)
        }
        static func sourceTotal(_ n: Int) -> String {
            String(format: NSLocalizedString("vocab.source_total", value: "Seen %d times in total", comment: "Total occurrences in the sources sheet"), n)
        }
        static var sourcesHeader: String {
            NSLocalizedString("vocab.sources_header", value: "Source recordings", comment: "Header of the sources sheet list")
        }
        static var sourcesTitle: String {
            NSLocalizedString("vocab.sources_title", value: "Sources", comment: "Sources sheet title")
        }
        static var promptFooter: String {
            NSLocalizedString("vocab.prompt_footer",
                              value: "Given to the transcription service and the LLM as hints — they are nudged to recognize these words, never forced to replace others with them.",
                              comment: "Footer under the word list (semantic boundary, kept verbatim)")
        }
        static var mineButton: String {
            NSLocalizedString("vocab.mine", value: "Extract from past transcripts", comment: "Button to run the vocabulary miner over all transcripts")
        }
        static var miningStarted: String {
            NSLocalizedString("vocab.mining_started", value: "Mining in the background — new words will appear with an Auto tag.", comment: "Notice after starting the miner")
        }
        static var addField: String {
            NSLocalizedString("vocab.add_field", value: "Add a word (name / product / jargon)", comment: "Text field placeholder in the vocabulary editor")
        }
        static var importButton: String {
            NSLocalizedString("vocab.import", value: "Import from Clipboard", comment: "Bulk import button")
        }
        static var exportButton: String {
            NSLocalizedString("vocab.export", value: "Copy All to Clipboard", comment: "Export button")
        }
        static var importFooter: String {
            NSLocalizedString("vocab.import_footer", value: "One word per line; commas (, ，、;) also split. Hints only — the AI is never forced to replace other words with these.",
                              comment: "Import format + the semantic promise from the spec")
        }
        static var exported: String {
            NSLocalizedString("vocab.exported", value: "Copied — paste anywhere to back up.", comment: "After export to clipboard")
        }
        static var pasteEmpty: String {
            NSLocalizedString("vocab.paste_empty", value: "Clipboard is empty.", comment: "Import with nothing on the pasteboard")
        }
        static var importNone: String {
            NSLocalizedString("vocab.import_none", value: "No new words found in the text.", comment: "Import found nothing to add (all duplicates/empty)")
        }
        static var full: String {
            NSLocalizedString("vocab.full", value: "The list is full (2000 words max).", comment: "Adding beyond the cap")
        }
        static func duplicate(_ word: String) -> String {
            NSLocalizedString("vocab.duplicate", value: "Already in the list.", comment: "Adding a word that exists")
        }
        static func imported(_ n: Int) -> String {
            String(format: NSLocalizedString("vocab.imported", value: "Added %d new words.", comment: "Bulk import result"), n)
        }
        static func countFooter(_ used: Int, _ limit: Int) -> String {
            String(format: NSLocalizedString("vocab.count_footer", value: "%d / %d words. These ride along with every AI summary as hints, never as forced replacements.", comment: "Usage counter footer"), used, limit)
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
        // ★ 2026-10-22: Aliyun wired into file transcription — picker label plus
        // the two async-task outcomes that need their own words.
        static var aliyun: String {
            NSLocalizedString("asr.aliyun", value: "Aliyun Speech",
                              comment: "ASR provider picker: Aliyun file transcription")
        }
        static func stillRunning(_ minutes: Int) -> String {
            String(format: NSLocalizedString("asr.still_running",
                    value: "The cloud task is still processing after %d minutes. It was NOT resubmitted (that would bill the audio twice) — retry later from the job list.",
                    comment: "Aliyun async task past the wait cap; %d is the minutes waited"), minutes)
        }
        static func taskFailed(_ detail: String) -> String {
            String(format: NSLocalizedString("asr.task_failed",
                    value: "The vendor's recognition task failed: %@",
                    comment: "Aliyun SubmitTask/GetTaskResult reported a task failure; %@ carries the server's reason"), detail)
        }
        static var activeProvider: String { NSLocalizedString("asr.active_provider", comment: "") }
        // ★ 2026-10-23 ("实时转写要支持选择已经配置好的 ASR"): live captions get their
        // own engine choice — batch-only vendors cannot stream audio.
        static var liveEngine: String {
            NSLocalizedString("asr.live_engine", value: "Live engine",
                              comment: "Settings picker: which ASR runs live captions")
        }
        static var liveEngineAuto: String {
            NSLocalizedString("asr.live_engine_auto", value: "Automatic (follow the order above)",
                              comment: "Live engine picker: no explicit choice")
        }
        static var liveEngineFooter: String {
            NSLocalizedString("asr.live_engine_footer",
                              value: "Only engines that can stream audio are listed. Aliyun has a real-time WebSocket endpoint, so it works live too; Baidu, Tencent, Google and the other cloud vendors are batch file APIs and cannot do live captions. Your custom server is listed as well: it has no streaming socket, so captions arrive in ~5-second slices instead of word by word. Automatic picks the first stream-capable service from the order above.",
                              comment: "Explains why the live picker is shorter than the transcription picker")
        }
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
        // ★ 2026-11-02：SenseVoice 本机模型（下载后可作转写引擎）。
        static var senseVoice: String { NSLocalizedString("asr.sensevoice", comment: "") }
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
        /// ★ 2026-11-04: 实时链路里主引擎没出字就死了、换了下一个顶上时，**必须明说**。
        /// "徽章悄悄从自定义变成 Azure"正是用户投诉"设置没生效"的形状。
        /// `reason` 探不到（大多数 provider 关闭时不带错误）就整段省略，不写"未知错误"。
        static func liveFellBack(from failed: String, to next: String, reason: String?) -> String {
            let from = engineDisplayName(failed)
            let to = engineDisplayName(next)
            guard let reason, !reason.isEmpty else {
                return String(format: NSLocalizedString("asr.live_fell_back", value: "%@ failed to produce text — switched to %@", comment: "Live engine fell back; 1st = failed engine, 2nd = replacement"), from, to)
            }
            return String(format: NSLocalizedString("asr.live_fell_back_reason", value: "%@ failed (%@) — switched to %@", comment: "Live engine fell back with a reason; 1st = failed engine, 2nd = reason, 3rd = replacement"), from, reason, to)
        }
        /// 实时引擎的显示名：provider key → 人话。custom/local/remote 都有中文名，
        /// 裸 key（"custom failed — switched to azure"）读起来像调试日志。
        private static func engineDisplayName(_ key: String) -> String {
            switch key.lowercased() {
            case "custom": return customServer
            case "azure": return azure
            case "aliyun": return aliyun
            case "local": return localServer
            case "remote": return remoteLive
            case "ondevice": return NSLocalizedString("asr.engine.ondevice", value: "On-device", comment: "Live engine name")
            case "azuretranslate": return azure
            case "sensevoice": return NSLocalizedString("asr.engine.sensevoice", value: "Built-in model", comment: "File transcription fallback engine")
            default: return key
            }
        }
        // ★ 2026-10-15: Background keep-alive toggle + transcription queue status.
        //
        // Wording rule: **never say "silent audio"**. Users don't need to know how we keep the process alive;
        // what they need to judge is "will it keep going after I switch away" and "will it drain the battery / make strange noises".
        static var backgroundKeepAlive: String { NSLocalizedString("asr.background_keep_alive", comment: "") }
        static var backgroundKeepAliveFooter: String { NSLocalizedString("asr.background_keep_alive_footer", comment: "") }
        // ★ 2026-11-06（后台保活·用户引导与被杀善后）
        static var lowPowerWarning: String {
            NSLocalizedString("asr.low_power_warning",
                              value: "Low Power Mode is on — iOS kills background audio sooner. Plug in or turn it off for long recordings.",
                              comment: "Settings: warning shown under the keep-alive toggle while Low Power Mode is enabled")
        }
        static var killedAlertTitle: String {
            NSLocalizedString("asr.killed_alert_title",
                              value: "A task was interrupted last time",
                              comment: "Cold-launch alert: the app was terminated in the background with jobs running")
        }
        static var killedAlertBody: String {
            NSLocalizedString("asr.killed_alert_body",
                              value: "iOS closed Nomily in the background while a job was running. Anything unfinished has been re-queued — to lower the risk, avoid swiping the app away and turn off Low Power Mode.",
                              comment: "Cold-launch alert body explaining the kill and how to avoid it")
        }
        // MARK: ★ 2026-11-06 后台保护指南页（设置 → 后台保护指南）
        static var bgpRow: String {
            NSLocalizedString("asr.bgp_row", value: "Background Protection Guide",
                              comment: "Settings row that opens the background protection guide")
        }
        static var bgpTitle: String {
            NSLocalizedString("asr.bgp_title", value: "Background Protection",
                              comment: "Title of the background protection guide page")
        }
        static var bgpIntro: String {
            NSLocalizedString("asr.bgp_intro", value: "iOS has no always-on whitelist like Android, but the switches below are everything the system allows. Nomily also warns you within a minute if it is ever closed mid-job.",
                              comment: "Intro text of the background protection guide")
        }
        static var bgpRefreshTitle: String {
            NSLocalizedString("asr.bgp_refresh_title", value: "Background App Refresh",
                              comment: "Guide row: the Background App Refresh check")
        }
        static var bgpRefreshOk: String {
            NSLocalizedString("asr.bgp_refresh_ok", value: "Allowed — long jobs can keep running after you switch away.",
                              comment: "Guide: background refresh is enabled")
        }
        static var bgpRefreshDenied: String {
            NSLocalizedString("asr.bgp_refresh_denied", value: "Off for Nomily — background jobs get interrupted.",
                              comment: "Guide: background refresh is denied for this app")
        }
        static var bgpRefreshRestricted: String {
            NSLocalizedString("asr.bgp_refresh_restricted", value: "Restricted by the system (Low Power Mode or Screen Time).",
                              comment: "Guide: background refresh is restricted globally")
        }
        static var bgpOpenSettings: String {
            NSLocalizedString("asr.bgp_open_settings", value: "Open Settings",
                              comment: "Guide: button that opens this app's page in the system Settings")
        }
        static var bgpRefreshManual: String {
            NSLocalizedString("asr.bgp_refresh_manual", value: "If the toggle is dimmed: Settings → General → Background App Refresh, and turn the master switch on first.",
                              comment: "Guide: path to the global Background App Refresh switch")
        }
        static var bgpLowPowerTitle: String {
            NSLocalizedString("asr.bgp_lowpower_title", value: "Low Power Mode",
                              comment: "Guide row: the Low Power Mode check")
        }
        static var bgpLowPowerOn: String {
            NSLocalizedString("asr.bgp_lowpower_on", value: "On — iOS cuts background audio much sooner. Charge the phone or turn it off (Settings → Battery) for long recordings.",
                              comment: "Guide: low power mode is on")
        }
        static var bgpLowPowerOff: String {
            NSLocalizedString("asr.bgp_lowpower_off", value: "Off — no extra risk to background jobs.",
                              comment: "Guide: low power mode is off")
        }
        static var bgpNotifyTitle: String {
            NSLocalizedString("asr.bgp_notify_title", value: "Interruption Alerts",
                              comment: "Guide row: the kill-guard notification permission")
        }
        static var bgpNotifyOn: String {
            NSLocalizedString("asr.bgp_notify_on", value: "Allowed — you will be warned within a minute if iOS ever closes the app mid-job.",
                              comment: "Guide: notifications are authorized")
        }
        static var bgpNotifyOff: String {
            NSLocalizedString("asr.bgp_notify_off", value: "Not decided yet — tap to allow interruption alerts.",
                              comment: "Guide: notification permission not determined")
        }
        static var bgpNotifyDenied: String {
            NSLocalizedString("asr.bgp_notify_denied", value: "Denied — enable it to be warned when a job is interrupted.",
                              comment: "Guide: notification permission denied")
        }
        static var bgpNotifyAuthorize: String {
            NSLocalizedString("asr.bgp_notify_authorize", value: "Open Settings to Allow",
                              comment: "Guide: button to open Settings for notifications")
        }
        static var bgpKeeperTitle: String {
            NSLocalizedString("asr.bgp_keeper_title", value: "In-App Silent Keep-Alive",
                              comment: "Guide row: the in-app silent keep-alive toggle")
        }
        static var bgpKeeperOn: String {
            NSLocalizedString("asr.bgp_keeper_on", value: "On (recommended) — recording and transcription keep running after you switch away.",
                              comment: "Guide: keep-alive enabled")
        }
        static var bgpKeeperOff: String {
            NSLocalizedString("asr.bgp_keeper_off", value: "Off — background jobs stop about 30 seconds after you switch away.",
                              comment: "Guide: keep-alive disabled")
        }
        static var bgpLimitNote: String {
            NSLocalizedString("asr.bgp_limit_note", value: "Honest note: iOS can still close any app under extreme memory pressure — no setting can forbid that. When it happens, Nomily posts an interruption alert within a minute and re-queues unfinished work.",
                              comment: "Guide: closing note about the limits of background protection")
        }
        // MARK: ★ 2026-11-06 权限体检弹窗（蓝牙没开 / 麦克风被拒 / 通知被拒…）
        static var permAlertTitle: String {
            NSLocalizedString("asr.perm_alert_title", value: "A permission is off",
                              comment: "Alert title when a needed permission is disabled")
        }
        static var permMicDenied: String {
            NSLocalizedString("asr.perm_mic_denied", value: "Microphone access was denied — recording cannot work. Enable it in Settings → Nomily AI.",
                              comment: "Permission alert: microphone denied")
        }
        static var permBtDenied: String {
            NSLocalizedString("asr.perm_bt_denied", value: "Bluetooth permission was denied — recorders cannot connect. Enable it in Settings → Nomily AI.",
                              comment: "Permission alert: Bluetooth permission denied")
        }
        static var permBtOff: String {
            NSLocalizedString("asr.perm_bt_off", value: "Bluetooth is off — recorders cannot connect. Turn it on from Control Center or Settings.",
                              comment: "Permission alert: Bluetooth radio is off")
        }
        static var permNotifDenied: String {
            NSLocalizedString("asr.perm_notif_denied", value: "Notifications are off — you won't be alerted if a background job is interrupted. Enable them in Settings → Notifications.",
                              comment: "Permission alert: notification permission denied")
        }
        static var permGoSettings: String {
            NSLocalizedString("asr.perm_go_settings", value: "Open Settings",
                              comment: "Permission alert: button to open the app's system settings page")
        }
        static var permAck: String {
            NSLocalizedString("asr.perm_ack", value: "Got it",
                              comment: "Permission alert: dismiss button")
        }
        // MARK: ★ 2026-11-06 后台保护指南新增行（蓝牙 / 麦克风 / 手表连接）
        static var bgpBtTitle: String {
            NSLocalizedString("asr.bgp_bt_title", value: "Bluetooth",
                              comment: "Guide row: Bluetooth permission and radio state")
        }
        static var bgpBtOn: String {
            NSLocalizedString("asr.bgp_bt_on", value: "On — recorders can connect.",
                              comment: "Guide: Bluetooth is powered on")
        }
        static var bgpBtOff: String {
            NSLocalizedString("asr.bgp_bt_off", value: "Bluetooth is off — turn it on from Control Center or Settings.",
                              comment: "Guide: Bluetooth radio is off")
        }
        static var bgpBtDenied: String {
            NSLocalizedString("asr.bgp_bt_denied", value: "Permission denied for Nomily — enable Bluetooth for this app in Settings.",
                              comment: "Guide: Bluetooth permission denied")
        }
        static var bgpBtUnknown: String {
            NSLocalizedString("asr.bgp_bt_unknown", value: "Checking…",
                              comment: "Guide: Bluetooth state not known yet")
        }
        static var bgpMicTitle: String {
            NSLocalizedString("asr.bgp_mic_title", value: "Microphone",
                              comment: "Guide row: microphone permission")
        }
        static var bgpMicOk: String {
            NSLocalizedString("asr.bgp_mic_ok", value: "Allowed — recording can use the mic.",
                              comment: "Guide: microphone permission granted")
        }
        static var bgpMicDenied: String {
            NSLocalizedString("asr.bgp_mic_denied", value: "Denied — recording cannot work without it.",
                              comment: "Guide: microphone permission denied")
        }
        static var bgpWatchTitle: String {
            NSLocalizedString("asr.bgp_watch_title", value: "Apple Watch Link",
                              comment: "Guide row: Apple Watch connection status")
        }
        static var bgpWatchNotPaired: String {
            NSLocalizedString("asr.bgp_watch_notpaired", value: "No Apple Watch paired. Pair one in the iPhone Watch app to record from the wrist.",
                              comment: "Guide: no watch paired")
        }
        static var bgpWatchBtOff: String {
            NSLocalizedString("asr.bgp_watch_btoff", value: "Bluetooth is off — the watch cannot sync.",
                              comment: "Guide: watch can't sync because Bluetooth is off")
        }
        static var bgpWatchReachable: String {
            NSLocalizedString("asr.bgp_watch_reachable", value: "Connected — watch recordings sync automatically.",
                              comment: "Guide: watch is reachable")
        }
        static var bgpWatchUnreachable: String {
            NSLocalizedString("asr.bgp_watch_unreachable", value: "Paired but not nearby (or asleep). It reconnects automatically when you raise the wrist or open the app — normal, not a fault.",
                              comment: "Guide: watch paired but not reachable")
        }
        static var nightlyTranscribe: String { NSLocalizedString("asr.nightly_transcribe", comment: "") }
        static var nightlyTranscribeFooter: String { NSLocalizedString("asr.nightly_transcribe_footer", comment: "") }
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
        /// ★ 2026-10-22 (后台任务里的「已放弃」): the old text was a raw English
        /// sentence naming the config key — a user reading the task centre has no
        /// idea what `min_transcribe_duration` is. Say the actual setting's name
        /// and both ways out.
        static func clipTooShort(_ duration: Double, _ minimum: Double) -> String {
            String(format: NSLocalizedString("asr.clip_too_short", value: "This clip is only %.1f s — shorter than the %.0f s minimum for automatic transcription. Lower the minimum in Settings → Recording, or open the clip and tap Transcribe (manual runs ignore the minimum).", comment: "Auto path skipped a clip below minTranscribeDuration; first %f = clip seconds, second %f = configured minimum"),
                   duration, minimum)
        }
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
        // ★ 2026-11-04（用户："要的就是这个百炼的兼容"）：同一个自定义服务下的两种接口形态。
        static var customShape: String { NSLocalizedString(
            "asr.custom_shape",
            value: "API shape",
            comment: "Picker label: which transcription API the custom server speaks"
        ) }
        static var customShapeWhisper: String { NSLocalizedString(
            "asr.custom_shape_whisper",
            value: "OpenAI / Whisper (/audio/transcriptions)",
            comment: "Custom ASR shape: the standard OpenAI transcription endpoint"
        ) }
        static var customShapeBailian: String { NSLocalizedString(
            "asr.custom_shape_bailian",
            value: "Alibaba Bailian (qwen3-asr-flash)",
            comment: "Custom ASR shape: Bailian's chat/completions with input_audio"
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
            comment: "Label for the custom ASR language picker"
        ) }
        // ★ 2026-10-30：语言提示从自由文本改成 Picker（掺韩语等幻觉的根治项）。
        static var customLanguageAuto: String { NSLocalizedString(
            "asr.custom_language_auto",
            value: "Auto detect",
            comment: "Custom ASR language picker — let the server decide"
        ) }
        static var customLanguageZh: String { NSLocalizedString(
            "asr.custom_language_zh", value: "中文", comment: "Custom ASR language picker option") }
        static var customLanguageEn: String { NSLocalizedString(
            "asr.custom_language_en", value: "English", comment: "Custom ASR language picker option") }
        static var customLanguageJa: String { NSLocalizedString(
            "asr.custom_language_ja", value: "日本語", comment: "Custom ASR language picker option") }
        static var customLanguageKo: String { NSLocalizedString(
            "asr.custom_language_ko", value: "한국어", comment: "Custom ASR language picker option") }
        static var customLanguageYue: String { NSLocalizedString(
            "asr.custom_language_yue", value: "粤语", comment: "Custom ASR language picker option") }
        static var customLanguageFooter: String { NSLocalizedString(
            "asr.custom_language_footer",
            value: "Transcribing Chinese audio but seeing Korean or gibberish lines? That is the server's auto language detection going off on noise — pin the language here to fix it. Aliyun file ASR decides language by the model configured in its NLS project.",
            comment: "Footer under the custom ASR section explaining why pinning the language matters"
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
        /// ★ 2026-11-02: reasoning model spent the whole output budget on thinking —
        /// no answer body was written. Never show the raw thinking as the result.
        static var errorReasoningNoContent: String {
            NSLocalizedString("llm.error.reasoning_no_content",
                              value: "This model spent its whole output budget on thinking and wrote no answer — try again, or switch to a non-reasoning model in Settings.",
                              comment: "LLM error: reasoning_content present but content empty")
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

        // MARK: 推理力度（★ 2026-11-06 · 饭耳 1.0 移植 P1-4）

        static var effortTitle: String {
            NSLocalizedString("llm.effort_title", value: "Reasoning Effort",
                              comment: "LLM settings: title of the reasoning-effort picker")
        }
        static var effortAuto: String {
            NSLocalizedString("llm.effort_auto", value: "Auto", comment: "Reasoning effort: leave it to the model")
        }
        static var effortLow: String {
            NSLocalizedString("llm.effort_low", value: "Fast", comment: "Reasoning effort: low")
        }
        static var effortMedium: String {
            NSLocalizedString("llm.effort_medium", value: "Balanced", comment: "Reasoning effort: medium")
        }
        static var effortHigh: String {
            NSLocalizedString("llm.effort_high", value: "Deep", comment: "Reasoning effort: high")
        }
        static var effortAutoHint: String {
            NSLocalizedString("llm.effort_auto_hint", value: "Don't send the parameter — keeps the widest compatibility.",
                              comment: "Reasoning effort hint: auto")
        }
        static var effortLowHint: String {
            NSLocalizedString("llm.effort_low_hint", value: "Answer sooner. Good for short recordings and live questions.",
                              comment: "Reasoning effort hint: low")
        }
        static var effortMediumHint: String {
            NSLocalizedString("llm.effort_medium_hint", value: "A middle ground for everyday summaries.",
                              comment: "Reasoning effort hint: medium")
        }
        static var effortHighHint: String {
            NSLocalizedString("llm.effort_high_hint", value: "Think longer. Better for long meetings and messy transcripts.",
                              comment: "Reasoning effort hint: high")
        }
        static var effortFooter: String {
            NSLocalizedString("llm.effort_footer",
                              value: "Sent as reasoning_effort to OpenAI-compatible models that support it (o-series, gpt-5 family, some relays). If a model rejects the request with HTTP 400, switch back to Auto — that means it doesn't know this parameter.",
                              comment: "LLM settings: footer under the reasoning-effort picker")
        }

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

        // MARK: One-tap presets (★ 2026-10-22)
        //
        // The whole point of this section is "tap an icon, the address is already
        // right". Every string below has to keep that promise: an empty address,
        // or a field the user has to go look up, defeats it.
        static var presetHeader: String {
            NSLocalizedString("llm.preset.header", value: "One-tap providers",
                              comment: "Section header: Qwen / DeepSeek / Doubao icon grid")
        }
        static var presetFooter: String {
            NSLocalizedString("llm.preset.footer",
                              value: "Tap an icon — the endpoint is filled in for you. All you add is the API key and a model. Doubao and Volcengine Ark are the same host: Ark serves the Doubao models.",
                              comment: "Explains why the endpoint field is pre-filled")
        }
        static var presetReady: String {
            NSLocalizedString("llm.preset.ready", value: "Ready",
                              comment: "Preset row status: key and model both set")
        }
        static var presetNeedsKey: String {
            NSLocalizedString("llm.preset.needs_key", value: "Add API key",
                              comment: "Preset row status: endpoint set, key still missing")
        }
        static var presetConsole: String {
            NSLocalizedString("llm.preset.console", value: "Get a key at",
                              comment: "Label before the console URL where the API key comes from")
        }
        static var presetEndpointFilled: String {
            NSLocalizedString("llm.preset.endpoint_filled", value: "Endpoint (already filled in)",
                              comment: "Endpoint field label on the preset sheet")
        }
        static var fetchNeedsKey: String {
            NSLocalizedString("llm.fetch.needs_key",
                              value: "Add the API key first — the model list is fetched with it.",
                              comment: "Shown when tapping Fetch models with no key configured")
        }
        static var fetchNeedsEndpoint: String {
            NSLocalizedString("llm.fetch.needs_endpoint",
                              value: "Fill in the endpoint address first.",
                              comment: "Shown when tapping Fetch models with an empty endpoint")
        }
        static var presetFetchModels: String {
            NSLocalizedString("llm.preset.fetch_models", value: "Fetch available models",
                              comment: "Button that asks the provider for its model list")
        }
        static var presetBuiltinHint: String {
            NSLocalizedString("llm.preset.builtin_hint",
                              value: "This provider has no model-list endpoint — these are the built-in common models.",
                              comment: "Shown when the model list came from LLMPreset instead of the network")
        }
        static var presetManualModel: String {
            NSLocalizedString("llm.preset.manual_model", value: "Type a model name",
                              comment: "Switch the model row to a free-text field (Ark endpoint ids)")
        }
        static var presetRemove: String {
            NSLocalizedString("llm.preset.remove", value: "Remove this provider",
                              comment: "Deletes the preset's endpoint, key and model")
        }
        static var presetNeedsModel: String {
            NSLocalizedString("llm.preset.needs_model", value: "Pick a model",
                              comment: "Provider row status: key is fine, no model chosen yet")
        }
        static var notConfigured: String {
            NSLocalizedString("llm.not_configured", value: "Not set up",
                              comment: "Provider row: no endpoint and no model yet")
        }

        // MARK: Provider grid (★ 2026-10-22, every provider in one grid)
        //
        // One section, no 国内/国外 split: 2026-10-22 "不要分国内外，直接都按照模型加入进去".
        // Which vendor is Chinese is not a distinction the app acts on — the
        // endpoint, the key and the model are the same three fields either way.
        // ★ 2026-10-29 (截图布局): addProvider/providersSection/currentModelCard 等。
        static var addProvider: String {
            NSLocalizedString("llm.add_provider", value: "Add provider", comment: "Row + page title for picking an unconfigured provider")
        }
        static var providersSection: String {
            NSLocalizedString("llm.providers_section", value: "Providers", comment: "Section header above the configured provider list")
        }
        static var summarizeUsing: String {
            NSLocalizedString("llm.summarize_using", value: "Summarizing with", comment: "Current-model card caption")
        }
        static var switchModel: String {
            NSLocalizedString("llm.switch_model", value: "Switch", comment: "Menu button on the current-model card")
        }
        static var noModelPicked: String {
            NSLocalizedString("llm.no_model", value: "No model yet", comment: "Current-model card when a provider has no model chosen")
        }
        static var customGroup: String {
            NSLocalizedString("llm.custom_group", value: "Custom", comment: "Section header for the bring-your-own-endpoint row")
        }
        static var customSubtitle: String {
            NSLocalizedString("llm.custom_subtitle",
                              value: "Any OpenAI-compatible address — one address can serve many models",
                              comment: "Custom provider row subtitle (screenshot wording)")
        }
        static var keychainFooter: String {
            NSLocalizedString("llm.keychain_footer",
                              value: "Keys are stored in this phone's Keychain and are sent only to the address you enter — never to us.",
                              comment: "Footer under the provider lists (screenshot wording)")
        }
        static var noKeySignup: String {
            NSLocalizedString("llm.no_key_signup", value: "No key yet? Sign up", comment: "Direct link to the provider's key-signup page, shown while the key field is empty")
        }
        /// ★ 2026-11-02: the same link, relabelled once a key exists — the console is
        /// where you renew, rotate and inspect usage, so the door shouldn't close.
        static var consoleManage: String {
            NSLocalizedString("llm.console_manage", value: "Manage keys in the console",
                              comment: "Direct link to the provider's key page, shown when a key is already set")
        }
        static var gridTitle: String {
            NSLocalizedString("llm.grid.title", value: "Providers",
                              comment: "Section header for the single provider list (no domestic/overseas split)")
        }
        static var gridFooter: String {
            NSLocalizedString("llm.grid.footer",
                              value: "Tap one to configure it — the address is already filled in, you add a key and pick a model. Only models that can actually write a transcript summary are listed; embedding, speech and image models are filtered out.",
                              comment: "Explains the icon grid and the chat-only model filter")
        }
        static var endpointFixedByAPI: String {
            NSLocalizedString("llm.endpoint_fixed", value: "This address is fixed by the vendor's API.",
                              comment: "Shown when the endpoint field is read-only")
        }

        // MARK: Custom endpoint protocol (★ 2026-11-04)

        static var protocolTitle: String {
            NSLocalizedString("llm.protocol.title", value: "Protocol",
                              comment: "Picker label: which wire format a custom endpoint speaks")
        }
        static var protocolOpenAI: String {
            NSLocalizedString("llm.protocol.openai", value: "OpenAI compatible",
                              comment: "Custom endpoint speaks /chat/completions")
        }
        static var protocolAnthropic: String {
            NSLocalizedString("llm.protocol.anthropic", value: "Anthropic compatible",
                              comment: "Custom endpoint speaks the Anthropic Messages API")
        }
        static var protocolOpenAIHint: String {
            NSLocalizedString(
                "llm.protocol.openai_hint",
                value: "Any OpenAI-compatible address works. A version segment is optional: …/v1 and …/compatible-mode/v1 are used as-is, a bare host gets /v1 appended. Relays, self-hosted vLLM, LM Studio and workspace endpoints all fit.",
                comment: "Footnote under the protocol picker for the OpenAI option"
            )
        }
        static var protocolAnthropicHint: String {
            NSLocalizedString(
                "llm.protocol.anthropic_hint",
                value: "For endpoints that speak the Anthropic Messages API (…/v1/messages, or a workspace's …/apps/anthropic). The API key is sent as x-api-key.",
                comment: "Footnote under the protocol picker for the Anthropic option"
            )
        }
        static var modelSearch: String {
            NSLocalizedString("llm.model_search", value: "Filter models",
                              comment: "Search field above a long model list (OpenRouter lists hundreds)")
        }
        static var chatOnlyNote: String {
            NSLocalizedString("llm.chat_only_note",
                              value: "Only chat-capable models are listed — embedding, TTS, image and moderation models are hidden, because choosing one only fails later inside a summary.",
                              comment: "Why the fetched model list is shorter than the vendor's own list")
        }
        static var noChatModels: String {
            NSLocalizedString("llm.no_chat_models",
                              value: "This provider returned no chat-capable models.",
                              comment: "Fetch succeeded but every model was filtered out")
        }
        static var useCuratedModels: String {
            NSLocalizedString("llm.use_curated_models", value: "Back to the built-in list",
                              comment: "Switch the model row back from free text to the curated picker")
        }

        // MARK: Connectivity + latency probe (★ 2026-10-22)
        static var testSection: String {
            NSLocalizedString("llm.test.section", value: "Connection",
                              comment: "Section header for the connectivity/latency test")
        }
        static var testButton: String {
            NSLocalizedString("llm.test.button", value: "Test connection and latency",
                              comment: "Runs one 1-token chat request and reports the round trip")
        }
        static var testRunning: String {
            NSLocalizedString("llm.test.running", value: "Testing…", comment: "")
        }
        static func testOK(_ ms: Int) -> String {
            String(format: NSLocalizedString("llm.test.ok", value: "Connected · %d ms",
                                             comment: "Probe succeeded; %d is the round-trip time"), ms)
        }
        static func testBand(_ ms: Int) -> String {
            let comment = "Latency band, shown after the ms figure"
            switch ms {
            case ..<800:
                return NSLocalizedString("llm.test.band.fast", value: "fast", comment: comment)
            case ..<2000:
                return NSLocalizedString("llm.test.band.normal", value: "normal", comment: comment)
            case ..<5000:
                return NSLocalizedString("llm.test.band.slow", value: "slow", comment: comment)
            default:
                return NSLocalizedString("llm.test.band.very_slow", value: "very slow", comment: comment)
            }
        }
        static var testNote: String {
            NSLocalizedString("llm.test.note",
                              value: "Sends one real chat request capped at 1 token, and times the round trip — the wait before the model starts answering. A pass means the key, the address and the model all work together; a failure names which one it was.",
                              comment: "Explains what the probe does and what a result means")
        }
        static var testNeedKey: String {
            NSLocalizedString("llm.test.need_key", value: "Add the API key first", comment: "")
        }
        static var testNeedModel: String {
            NSLocalizedString("llm.test.need_model", value: "Pick a model first", comment: "")
        }
        static var testBadEndpoint: String {
            NSLocalizedString("llm.test.bad_endpoint", value: "The address isn't a valid URL", comment: "")
        }
        static var testTimeout: String {
            NSLocalizedString("llm.test.timeout",
                              value: "No answer in time — the host is unreachable, or the model is too slow for summarising",
                              comment: "")
        }
        static var testUnreachable: String {
            NSLocalizedString("llm.test.unreachable",
                              value: "Can't reach this host — check the address, or whether the phone is online",
                              comment: "")
        }
        static var testUnexpectedBody: String {
            NSLocalizedString("llm.test.unexpected_body",
                              value: "The address answered, but not with a chat completion — it's probably not this provider's API",
                              comment: "HTTP 2xx with a body that has no completion in it")
        }
        static func testHTTP(_ code: Int) -> String {
            String(format: NSLocalizedString("llm.test.http", value: "The provider refused the request (HTTP %d)",
                                             comment: ""), code)
        }
        static var latencyChip: String {
            NSLocalizedString("llm.latency.chip", value: "measured", comment: "Suffix of the ms figure on a provider row")
        }
    }

    // MARK: - Cloud ASR vendors (★ 2026-10-22)

    /// Settings copy for the six catalogue-driven ASR vendors.
    enum ASRCloud {
        static var title: String {
            NSLocalizedString("asr.cloud.title", value: "Cloud services",
                              comment: "Section header: Azure / Google / AWS / Deepgram / AssemblyAI / Gladia / IBM Watson")
        }
        /// ★ 2026-10-22: Azure sits at the top of this list now, and the one thing
        /// that matters about it is that it is the only vendor **wired into the
        /// engine** — otherwise the list reads as "seven equivalent options".
        static var azureWired: String {
            NSLocalizedString("asr.cloud.azure_wired", value: "Wired into transcription",
                              comment: "Badge on the Azure row: its credentials actually drive the transcription pipeline")
        }
        static var needsVerify: String {
            NSLocalizedString("asr.cloud.needs_verify", value: "Verify", comment: "Azure row: key present but never verified")
        }
        static var credentials: String {
            NSLocalizedString("asr.cloud.credentials", value: "Credentials", comment: "Section header inside the Azure sheet")
        }
        /// ★ 2026-11-06（饭耳 1.0 移植 P0-2）：选型决策树。
        ///
        /// 云厂商一排十行，每行都写着"约 X 元/小时"，用户仍然不知道该选谁——
        /// 缺的不是数据，是**一句话指路**。这段就是那句话，按"说什么话"分流，
        /// 而不是按"哪家便宜"分流：方言/外语的人先试免费的，普通话会议才建议上云。
        static var decisionGuide: String {
            NSLocalizedString("asr.cloud.decision_guide",
                              value: "Not sure which one? Mandarin meetings → Alibaba Bailian (≈¥0.1/h, Chinese CER 2.25%). Cantonese or other dialects/languages → try the free on-device SenseVoice first, and only go cloud if that falls short. Just want a quick read → Apple's built-in engine (free, one language at a time).",
                              comment: "ASR vendor decision tree shown under the cloud list")
        }
        static var footer: String {
            NSLocalizedString("asr.cloud.footer",
                              value: "Tap a vendor to add its credentials. The test button signs a real request to that vendor and measures the round trip — a pass means the credentials work on this network, and it costs no audio quota.",
                              comment: "Explains what the cloud ASR rows do and what the probe proves")
        }
        static var testButton: String {
            NSLocalizedString("asr.cloud.test", value: "Test credentials and latency", comment: "")
        }
        static var testRunning: String {
            NSLocalizedString("asr.cloud.testing", value: "Testing…", comment: "")
        }
        static var testNote: String {
            NSLocalizedString("asr.cloud.test_note",
                              value: "One authenticated read-only request. Nothing is uploaded and no audio is transcribed.",
                              comment: "")
        }
        static func ok(_ ms: Int) -> String {
            String(format: NSLocalizedString("asr.cloud.ok", value: "Credentials work · %d ms",
                                             comment: "Probe passed; %d is the round trip"), ms)
        }
        static func modelCount(_ count: Int) -> String {
            String(format: NSLocalizedString("asr.cloud.model_count", value: "%d models", comment: ""), count)
        }
        static func http(_ code: Int) -> String {
            String(format: NSLocalizedString("asr.cloud.http", value: "The vendor rejected the request (HTTP %d)", comment: ""), code)
        }
        static func missingField(_ name: String) -> String {
            String(format: NSLocalizedString("asr.cloud.missing", value: "%@ is empty", comment: ""), name)
        }
        static var badEndpoint: String {
            NSLocalizedString("asr.cloud.bad_endpoint", value: "The address isn't a valid URL", comment: "")
        }
        /// Baidu/腾讯 answer 200 with an error object when the key is wrong —
        /// that is "rejected credentials", not "no answer".
        static var badCredentials: String {
            NSLocalizedString("asr.cloud.bad_credentials", value: "The credentials were rejected — check the key and the permissions",
                              comment: "Probe got an authenticated-but-rejected answer (HTTP 200 + error body)")
        }
        static var timeout: String {
            NSLocalizedString("asr.cloud.timeout", value: "No answer in time — unreachable, or the region is wrong", comment: "")
        }
        static var unreachable: String {
            NSLocalizedString("asr.cloud.unreachable", value: "Can't reach this host — check the address or the network", comment: "")
        }
        static var model: String {
            NSLocalizedString("asr.cloud.model", value: "Model", comment: "")
        }
        static var fetchModels: String {
            NSLocalizedString("asr.cloud.fetch_models", value: "Fetch this account's models", comment: "")
        }
        static var manualModel: String {
            NSLocalizedString("asr.cloud.manual_model", value: "Type a model name", comment: "")
        }
        static var ready: String {
            NSLocalizedString("asr.cloud.ready", value: "Ready", comment: "Credentials + model are set")
        }
        static var needsKey: String {
            NSLocalizedString("asr.cloud.needs_key", value: "Add credentials", comment: "")
        }
        static var needsModel: String {
            NSLocalizedString("asr.cloud.needs_model", value: "Pick a model", comment: "")
        }
        static var remove: String {
            NSLocalizedString("asr.cloud.remove", value: "Remove this vendor", comment: "")
        }
        static var notWired: String {
            NSLocalizedString("asr.cloud.not_wired",
                              value: "Credentials are checked against the real API. Transcription through this vendor isn't wired into the engine yet — Azure and the local/remote servers still do the actual work.",
                              comment: "Honest scope note: probe works, transcription routing does not")
        }
        /// ★ 2026-10-22: Aliyun joins Azure as a wired vendor — the sheet says so
        /// instead of the not-wired note above.
        static var aliyunWired: String {
            NSLocalizedString("asr.cloud.aliyun_wired",
                              value: "Wired into transcription: audio is staged in your own OSS bucket (private), a 2-hour presigned link is handed to Aliyun, and the result is fetched back. Nothing is kept afterwards.",
                              comment: "Scope note on the Aliyun sheet: what transcription through this vendor actually does")
        }
        /// ★ 2026-11-02: tappable console door on every ASR cloud sheet — the footer
        /// text says *where* to go, this is the actual link to open.
        static var openConsole: String {
            NSLocalizedString("asr.cloud.open_console", value: "Open the console to get a key",
                              comment: "Link row above the credential fields: opens the vendor's key/console page")
        }
        /// Capability chip in the price line ("≈ ¥0.3/hour · speaker separation").
        static var diarization: String {
            NSLocalizedString("asr.cloud.diarization", value: "speaker separation",
                              comment: "Meta line chip: the vendor supports speaker diarization")
        }
        /// Prefix before the verdict chip ("Verdict: Recommended · best for Chinese").
        static var recommendationPrefix: String {
            NSLocalizedString("asr.cloud.recommendation_prefix", value: "Verdict: %@",
                              comment: "Prefix before the vendor verdict; %@ is the verdict itself")
        }
        static func field(_ id: String, fallback: String) -> String {
            NSLocalizedString("asr.cloud.field.\(id)", value: fallback, comment: "Credential field label")
        }
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

    // ★ 2026-10-29 (饭耳移植 · 规格 §3.1 定时录音)
    enum TimedRecording {
        static var title: String { NSLocalizedString("timed.title", comment: "") }
        static var enable: String { NSLocalizedString("timed.enable", comment: "") }
        static var enableFooter: String { NSLocalizedString("timed.enable_footer", comment: "") }
        static var start: String { NSLocalizedString("timed.start", comment: "") }
        static var end: String { NSLocalizedString("timed.end", comment: "") }
        // ★ 2026-10-30：fillFromSleep/sleepFilled/sleepMissing 已随 HealthKit 预填移除。
        /// ★ 2026-10-30：start 命令已发出（手表端抬腕进 App 后才会真正开录）。
        static var watchCommandSent: String { NSLocalizedString("timed.watch_command_sent", comment: "") }
        /// ★ 2026-10-30：发了 start 但表端心跳一直说没在录。
        static var watchNotRecording: String { NSLocalizedString("timed.watch_not_recording", comment: "") }
        /// ★ 2026-10-30：stop 命令已发出。
        static var watchStopped: String { NSLocalizedString("timed.watch_stopped", comment: "") }
        static var recording: String { NSLocalizedString("timed.recording", comment: "") }
        // ★ 2026-11-02（用户："例如一直录，跟设置一个时间段录制"）：模式选择。
        static var modeAlways: String { NSLocalizedString("timed.mode_always", comment: "") }
        static var modeWindow: String { NSLocalizedString("timed.mode_window", comment: "") }
        static var modeRow: String { NSLocalizedString("timed.mode_row", comment: "") }
        static var recordingAlwaysOn: String { NSLocalizedString("timed.recording_always_on", comment: "") }
        static var missedTitle: String { NSLocalizedString("timed.missed_title", comment: "") }
        static var missedBody: String { NSLocalizedString("timed.missed_body", comment: "") }
        static var footer: String { NSLocalizedString("timed.footer", comment: "") }
    }

    // ★ 2026-11-02（用户："应该是数据与存储位置，保存路径是这台 iPhone 或者
    // iCloud，然后才是 NAS，然后就是文件夹 app"）：存储落点总枢纽页文案。
    enum StorageLocations {
        static var title: String { NSLocalizedString("storage.locations.title", comment: "") }
        /// ★ 2026-11-09：自动上传范围（哪些录音转写完自动送到目的地）。
        static var uploadScope: String {
            NSLocalizedString("storage.locations.upload_scope", value: "Auto Upload",
                              comment: "Storage locations: picker for which recordings upload automatically")
        }
        static var scopeAll: String {
            NSLocalizedString("storage.locations.scope_all", value: "Every Recording",
                              comment: "Upload scope: all recordings upload right after transcription")
        }
        static var scopeWithSummary: String {
            NSLocalizedString("storage.locations.scope_with_summary", value: "Only With Summaries",
                              comment: "Upload scope: a recording uploads once its summary is ready")
        }
        static var scopeManual: String {
            NSLocalizedString("storage.locations.scope_manual", value: "Manual Only",
                              comment: "Upload scope: nothing uploads automatically; use the sync-now button")
        }
        static var uploadScopeFooter: String {
            NSLocalizedString("storage.locations.upload_scope_footer",
                              value: "Applies to automatic uploads to NAS (WebDAV) and the Files/iCloud folder. \u{201C}Sync Now\u{201D} always sends everything, whatever this is set to.",
                              comment: "Footer explaining the upload scope picker")
        }
        static var sectionHeader: String { NSLocalizedString("storage.locations.header", comment: "") }
        static var iphone: String { NSLocalizedString("storage.locations.iphone", comment: "") }
        static var iphoneDesc: String { NSLocalizedString("storage.locations.iphone_desc", comment: "") }
        static var icloud: String { NSLocalizedString("storage.locations.icloud", comment: "") }
        static var icloudDesc: String { NSLocalizedString("storage.locations.icloud_desc", comment: "") }
        static var nas: String { NSLocalizedString("storage.locations.nas", comment: "") }
        static var nasDesc: String { NSLocalizedString("storage.locations.nas_desc", comment: "") }
        static var folder: String { NSLocalizedString("storage.locations.folder", comment: "") }
        static var folderDesc: String { NSLocalizedString("storage.locations.folder_desc", comment: "") }
        static var footer: String { NSLocalizedString("storage.locations.footer", comment: "") }
    }

    // ★ 2026-11-02（用户："增加一个下载使用 SenseVoice 的语音转文字的下载"）：
    // SenseVoice 本机模型管理页文案。
    enum SenseVoice {
        static var title: String { NSLocalizedString("sensevoice.title", comment: "") }
        static var name: String { NSLocalizedString("sensevoice.name", comment: "") }
        static var desc: String { NSLocalizedString("sensevoice.desc", comment: "") }
        static var footer: String { NSLocalizedString("sensevoice.footer", comment: "") }
        static var sectionHeader: String { NSLocalizedString("sensevoice.section_header", comment: "") }
        static var sectionFooter: String { NSLocalizedString("sensevoice.section_footer", comment: "") }
        static var manageHeader: String { NSLocalizedString("sensevoice.manage_header", comment: "") }
        /// ★ 2026-11-02：手工导入（隔空投送 / 文件 App），镜像全被挡时的兜底。
        static var importModel: String { NSLocalizedString("sensevoice.import_model", comment: "") }
        static var importHint: String { NSLocalizedString("sensevoice.import_hint", comment: "") }
        static var importIncomplete: String { NSLocalizedString("sensevoice.import_incomplete", comment: "") }
        static var download: String { NSLocalizedString("sensevoice.download", comment: "") }
        static var sizeHint: String { NSLocalizedString("sensevoice.size_hint", comment: "") }
        static var downloading: String { NSLocalizedString("sensevoice.downloading", comment: "") }
        static var downloadingHint: String { NSLocalizedString("sensevoice.downloading_hint", comment: "") }
        static var statusRow: String { NSLocalizedString("sensevoice.status_row", comment: "") }
        static func ready(_ size: String) -> String {
            String(format: NSLocalizedString("sensevoice.ready", comment: ""), size)
        }
        static var readyShort: String { NSLocalizedString("sensevoice.ready_short", comment: "") }
        static var deleteModel: String { NSLocalizedString("sensevoice.delete", comment: "") }
        static var failed: String { NSLocalizedString("sensevoice.failed", comment: "") }
        static var failedShort: String { NSLocalizedString("sensevoice.failed_short", comment: "") }
        static var retry: String { NSLocalizedString("sensevoice.retry", comment: "") }
        static var notDownloaded: String { NSLocalizedString("sensevoice.not_downloaded", comment: "") }
    }

    // ★ 2026-11-02（用户："不会获取 APIkey……新增一个不会开通？复制提示词
    // 跟粘贴结果，参考饭耳的这个快引导"）：Key 快引导页文案。
    enum KeyWizard {
        static var title: String { NSLocalizedString("keywizard.title", comment: "") }
        static var intro: String { NSLocalizedString("keywizard.intro", comment: "") }
        static var step1: String { NSLocalizedString("keywizard.step1", comment: "") }
        static var step2: String { NSLocalizedString("keywizard.step2", comment: "") }
        static var copyPrompt: String { NSLocalizedString("keywizard.copy_prompt", comment: "") }
        static var copied: String { NSLocalizedString("keywizard.copied", comment: "") }
        static var apply: String { NSLocalizedString("keywizard.apply", comment: "") }
        static var notFound: String { NSLocalizedString("keywizard.not_found", comment: "") }
        static var unknownField: String { NSLocalizedString("keywizard.unknown_field", comment: "") }
        static var footer: String { NSLocalizedString("keywizard.footer", comment: "") }
        static var openWizard: String { NSLocalizedString("keywizard.open", comment: "") }
        static var promptHead: String { NSLocalizedString("keywizard.prompt.head", comment: "") }
        static var promptConsole: String { NSLocalizedString("keywizard.prompt.console", comment: "") }
        static var promptSingle: String { NSLocalizedString("keywizard.prompt.single", comment: "") }
        static var promptMulti: String { NSLocalizedString("keywizard.prompt.multi", comment: "") }
        static var promptTail: String { NSLocalizedString("keywizard.prompt.tail", comment: "") }
    }

    // ★ 2026-10-29 (饭耳移植 · 规格 §2.3 文件 App 导出路线)
    enum FolderExport {
        static var title: String { NSLocalizedString("folder.title", comment: "") }
        static var destination: String { NSLocalizedString("folder.destination", comment: "") }
        static var pickFolder: String { NSLocalizedString("folder.pick", comment: "") }
        static var noFolder: String { NSLocalizedString("folder.none", comment: "") }
        static var clearFolder: String { NSLocalizedString("folder.clear", comment: "") }
        static var pickFooter: String { NSLocalizedString("folder.pick_footer", comment: "") }
        // ★ 2026-11-02：iCloud 指引（免签名方案）+ 占用统计。
        static var icloudHint: String {
            NSLocalizedString("folder.icloud_hint",
                              value: "Recommended: pick a folder in iCloud Drive (the picker opens there by default) — everything written is cloud-synced automatically, and follows your Apple ID to a new phone.",
                              comment: "Footer hint above the picker footer: why iCloud")
        }
        static var usage: String {
            NSLocalizedString("folder.usage", value: "Space used", comment: "LabeledContent title: folder usage stats")
        }
        static var usageEmpty: String {
            NSLocalizedString("folder.usage.empty", value: "Empty", comment: "Usage row: no files in the folder yet")
        }
        static var usageFormat: String {
            NSLocalizedString("folder.usage.format", value: "%@ · %d files",
                              comment: "Usage row: args = total size, file count")
        }
        static var syncAudio: String { NSLocalizedString("folder.sync_audio", comment: "") }
        static var syncAudioFooter: String { NSLocalizedString("folder.sync_audio_footer", comment: "") }
        static var exportNow: String { NSLocalizedString("folder.export_now", comment: "") }
        static var exportFooter: String { NSLocalizedString("folder.export_footer", comment: "") }
        static var notPicked: String { NSLocalizedString("folder.not_picked", comment: "") }
        static var bookmarkFailed: String { NSLocalizedString("folder.bookmark_failed", comment: "") }
        static func reportAll(_ copied: Int, _ skipped: Int) -> String {
            String(format: NSLocalizedString("folder.report_all", comment: ""), copied, skipped)
        }
        static func reportFailures(_ copied: Int, _ skipped: Int, _ failures: Int, _ first: String) -> String {
            String(format: NSLocalizedString("folder.report_failures", comment: ""), copied, skipped, failures, first)
        }
        // ★ 2026-10-30：自动备份（转写完成即写入所选文件夹 = 自动上传 iCloud）。
        static var auto: String { NSLocalizedString("folder.auto", comment: "") }
        static var autoFooter: String { NSLocalizedString("folder.auto_footer", comment: "") }
        static var autoOn: String { NSLocalizedString("folder.auto_on", comment: "") }
    }

    // ★ 2026-10-30：备份引导（设置页两个备份入口的"怎么选"说明）。
    enum Backup {
        static var guideTitle: String { NSLocalizedString("backup.guide_title", comment: "") }
        static var guideBody: String { NSLocalizedString("backup.guide_body", comment: "") }
    }

    // ★ 2026-10-30（用户："设置最顶部加入关于 Nomily"）：关于页文案。
    enum About {
        static var title: String { NSLocalizedString("about.title", value: "About Nomily", comment: "About page navigation title") }
        static var socialHeader: String { NSLocalizedString("about.social_header", value: "Official social media", comment: "Section header of the official account links") }
        static var legalHeader: String { NSLocalizedString("about.legal_header", value: "Legal", comment: "Section header of terms / privacy") }
        static var xRow: String { NSLocalizedString("about.row_x", value: "X (Official: Nomily)", comment: "Row label of the X account link") }
        static var xiaohongshuRow: String { NSLocalizedString("about.row_xiaohongshu", value: "Xiaohongshu", comment: "Row label of the Xiaohongshu link") }
        static var discordRow: String { NSLocalizedString("about.row_discord", value: "Discord Community", comment: "Row label of the Discord invite link") }
        static var githubRow: String { NSLocalizedString("about.row_github", value: "GitHub (Open Source)", comment: "Row label of the GitHub project link") }
        static var emailRow: String { NSLocalizedString("about.row_email", value: "Email Us (nomily@geekis.com)", comment: "Row label of the support email link") }
        static var terms: String { NSLocalizedString("about.terms", value: "Terms of Service", comment: "Row label of the terms of service") }
        static var privacy: String { NSLocalizedString("about.privacy", value: "Privacy Policy", comment: "Row label of the privacy policy") }
    }

    // ★ 2026-10-29 (饭耳移植 · 规格 §2.3 WebDAV 存储分层)
    enum WebDAV {
        static var title: String { NSLocalizedString("webdav.title", comment: "") }
        // ★ 2026-11-02（用户："需要增加引导如何获取对应的账号密码而不是登录密码"）：
        // 连接区页脚的凭据引导。
        static var credentialGuide: String {
            NSLocalizedString("webdav.credential_guide",
                              value: "Username & password here are the WebDAV service credentials: on Synology/QNAP/UGREEN/fnOS they are the same as your NAS account (after WebDAV is enabled); for Nutstore and Nextcloud you MUST create an app password in their web settings — the login password gets rejected.",
                              comment: "Footer guide above the preset hint: where the WebDAV username/password come from")
        }
        static var preset: String { NSLocalizedString("webdav.preset", comment: "") }
        static var presetUnpicked: String { NSLocalizedString("webdav.preset_unpicked", comment: "") }
        static var serverType: String { NSLocalizedString("webdav.server_type", comment: "") }
        static var host: String { NSLocalizedString("webdav.host", comment: "") }
        /// ★ 2026-10-30（用户："端口要支持输入而不是+−这样方式"）：Stepper 换文本框。
        static var portField: String { NSLocalizedString("webdav.port_field", comment: "") }
        /// ★ 2026-10-30：极空间等 NAS 的 HTTPS 用自签证书，默认握手会被拒。
        static var allowSelfSigned: String { NSLocalizedString("webdav.allow_self_signed", comment: "") }
        /// 端口非法（空/越界）时的提示。
        static var badPort: String { NSLocalizedString("webdav.bad_port", comment: "") }
        /// ★ 2026-10-30：极空间把"目录不可访问"也报成 401——根目录认证通过时
        /// 换这套话，免得用户以为密码错了。
        static var pathDenied: String { NSLocalizedString("webdav.path_denied", comment: "") }
        static var pathMissing: String { NSLocalizedString("webdav.path_missing", comment: "") }
        /// 连接成功且自动定位到了个人空间目录。
        static func testOkDiscovered(_ ms: Int, _ space: String) -> String {
            String(format: NSLocalizedString("webdav.test_ok_discovered", comment: ""), ms, space)
        }
        static var https: String { NSLocalizedString("webdav.https", comment: "") }
        static var username: String { NSLocalizedString("webdav.username", comment: "") }
        static var password: String { NSLocalizedString("webdav.password", comment: "") }
        static var basePath: String { NSLocalizedString("webdav.base_path", comment: "") }
        static var basePathFooter: String { NSLocalizedString("webdav.base_path_footer", comment: "") }
        static var connection: String { NSLocalizedString("webdav.connection", comment: "") }
        static var syncAudio: String { NSLocalizedString("webdav.sync_audio", comment: "") }
        static var syncAudioFooter: String { NSLocalizedString("webdav.sync_audio_footer", comment: "") }
        static var test: String { NSLocalizedString("webdav.test", comment: "") }
        static func testOk(_ ms: Int) -> String {
            String(format: NSLocalizedString("webdav.test_ok", comment: ""), ms)
        }
        static var syncNow: String { NSLocalizedString("webdav.sync_now", comment: "") }
        static var syncNowFooter: String { NSLocalizedString("webdav.sync_now_footer", comment: "") }
        static var notConfigured: String { NSLocalizedString("webdav.not_configured", comment: "") }
        // ★ 2026-10-30：设置页行尾状态（未配置时的灰字提示）。
        static var unconfigured: String { NSLocalizedString("webdav.unconfigured", comment: "") }
        /// ★ 2026-10-30：类型选择弹层的引导语。
        static var setupFooter: String { NSLocalizedString("webdav.setup_footer", comment: "") }

        // MARK: 多账户（★ 2026-11-09 · 用户："选择 nas 或者其他都是用的同一个，
        // 没有区分每个品牌跟配置，都是点击出现的 NC 的配置"）

        static var savedServers: String {
            NSLocalizedString("webdav.saved_servers", value: "Saved Servers",
                              comment: "WebDAV sheet: header of the saved-accounts list")
        }
        static var addServer: String {
            NSLocalizedString("webdav.add_server", value: "Add a Server",
                              comment: "WebDAV sheet: header of the brand-preset list")
        }
        static var inUse: String {
            NSLocalizedString("webdav.in_use", value: "In use",
                              comment: "WebDAV sheet: tag on the account that automatic backup targets")
        }
        static var setActive: String {
            NSLocalizedString("webdav.set_active", value: "Use This Server for Backup",
                              comment: "WebDAV edit page: make this account the active backup target")
        }
        static var setActiveDone: String {
            NSLocalizedString("webdav.set_active_done", value: "This server is now the backup target.",
                              comment: "WebDAV edit page: confirmation after switching the active account")
        }
        static var removeServer: String {
            NSLocalizedString("webdav.remove_server", value: "Remove This Server",
                              comment: "WebDAV edit page: delete this saved account")
        }
        static var accountsFooter: String {
            NSLocalizedString("webdav.accounts_footer",
                              value: "Every server keeps its own host, account and password — adding a second NAS no longer overwrites the first. Backup and sync go to the server marked In use; switch any time from this page.",
                              comment: "WebDAV sheet: footer explaining multi-account behaviour")
        }
        /// 存储位置页 NAS 行的「共 N 台」。
        static func serverCount(_ n: Int) -> String {
            String(format: NSLocalizedString("webdav.server_count", value: "%d servers", comment: "Storage locations: how many WebDAV accounts are saved"), n)
        }
        /// 服务器上的待办清单文件名（与摘要.md 同目录）。
        static var remoteTodos: String {
            NSLocalizedString("webdav.remote.todos", value: "To-dos.md",
                              comment: "Remote file name on the server: the to-do list extracted from the summary")
        }
        static func reportAll(_ uploaded: Int, _ skipped: Int) -> String {
            String(format: NSLocalizedString("webdav.report_all", comment: ""), uploaded, skipped)
        }
        static func reportFailures(_ uploaded: Int, _ skipped: Int, _ failures: Int, _ first: String) -> String {
            String(format: NSLocalizedString("webdav.report_failures", comment: ""), uploaded, skipped, failures, first)
        }
        // ★ 2026-11-02：服务器文件夹浏览选择器（目录可选，不固定）。
        static var browseFolders: String { NSLocalizedString("webdav.browse_folders", comment: "") }
        static var resetFolder: String { NSLocalizedString("webdav.reset_folder", comment: "") }
        static var useThisFolder: String { NSLocalizedString("webdav.use_this_folder", comment: "") }
        static var parentFolder: String { NSLocalizedString("webdav.parent_folder", comment: "") }
        static var subfolders: String { NSLocalizedString("webdav.subfolders", comment: "") }
        static var noSubfolders: String { NSLocalizedString("webdav.no_subfolders", comment: "") }
        static var pickFolder: String { NSLocalizedString("webdav.pick_folder", comment: "") }
        static var pickFolderFooter: String { NSLocalizedString("webdav.pick_folder_footer", comment: "") }
        // ★ 2026-11-02（用户："上传后的文件查看不友好，布局排版需要优化"）：
        // 服务器上的文件名从机器名（<base>.asr.json）换成给人看的名字。文件名走
        // 词条而不是常量，中文环境直接可读；词条缺失时回落英文 value。
        static var remoteTranscript: String {
            NSLocalizedString("webdav.remote.transcript", value: "Transcript.txt",
                              comment: "Remote file name on the server: the readable transcript text")
        }
        static var remoteASR: String {
            NSLocalizedString("webdav.remote.asr", value: "ASR Data.json",
                              comment: "Remote file name on the server: raw ASR timing/speaker metadata")
        }
        static var remoteNote: String {
            NSLocalizedString("webdav.remote.note", value: "Summary.md",
                              comment: "Remote file name on the server: the editable summary + outline in Markdown")
        }
        /// ★ 2026-11-04（用户："转化过的录音不要加密的"）：服务器上放的是**可播放**的
        /// m4a，而不是客户端多半解不开的 .opus。
        static var remoteAudio: String {
            NSLocalizedString("webdav.remote.audio", value: "Recording.m4a",
                              comment: "Remote file name on the server: the playable audio")
        }
        /// ★ 2026-11-04（用户："思维导图直接就是生成的图"）：导图以 PNG 上传。
        static var remoteMindMap: String {
            NSLocalizedString("webdav.remote.mindmap", value: "Mind Map.png",
                              comment: "Remote file name on the server: the rendered mind map image")
        }
        /// ★ 2026-11-04（用户："然后 NC 上传也是"）：和分享同一套打包，整条资料一个 zip。
        /// 散文件仍然保留——网盘网页端能直接读、能直接看图，包是给"整条拿走"用的。
        static var remoteBundle: String {
            NSLocalizedString("webdav.remote.bundle", value: "Bundle.zip",
                              comment: "Remote file name on the server: the zipped summary + mind map + to-dos + transcript")
        }
        static var remoteChapters: String {
            NSLocalizedString("webdav.remote.chapters", value: "Chapters.json",
                              comment: "Remote file name on the server: outline chapter data")
        }
        /// Attribution line inside the assembled note, after the date.
        static var noteMeta: String {
            NSLocalizedString("webdav.note.meta", value: "Nomily note",
                              comment: "Attribution line inside the assembled note (after the date)")
        }
        /// ★ 2026-11-04：摘要正文的小节标题（正文里的 H1 统一降级到 H2 之后，
        /// 整篇只剩文档标题一个一级标题，网盘里的目录才干净）。
        static var noteSummaryHeading: String {
            NSLocalizedString("webdav.note.summary_heading", value: "Summary",
                              comment: "Markdown heading above the summary body in the uploaded note")
        }
        /// Markdown heading for the outline section inside the assembled note.
        static var noteChaptersHeading: String {
            NSLocalizedString("webdav.note.chapters_heading", value: "Chapters",
                              comment: "Markdown heading for the outline section inside the assembled note")
        }
    }

    enum RecordingsSettings {
        static var deleteAfterTransfer: String { NSLocalizedString("rec_settings.delete_after_transfer", comment: "") }
        static var deleteAfterTransferFooter: String { NSLocalizedString("rec_settings.delete_after_transfer_footer", comment: "") }
        // ★ 2026-10-29 (饭耳移植 · 规格 §2.2 录音质量 + 冷数据降级)
        static var qualityTitle: String { NSLocalizedString("rec_settings.quality_title", comment: "") }
        static var qualityFooter: String { NSLocalizedString("rec_settings.quality_footer", comment: "") }
        static var qualityTierAsIs: String { NSLocalizedString("rec_settings.quality_as_is", comment: "") }
        static var qualityTierStandard: String { NSLocalizedString("rec_settings.quality_standard", comment: "") }
        static var qualityTierCompact: String { NSLocalizedString("rec_settings.quality_compact", comment: "") }
        static var qualityTierMinimal: String { NSLocalizedString("rec_settings.quality_minimal", comment: "") }
        static var coldDowngrade: String { NSLocalizedString("rec_settings.cold_downgrade", comment: "") }
        static var coldDowngradeFooter: String { NSLocalizedString("rec_settings.cold_downgrade_footer", comment: "") }
        static func coldDowngradeDays(_ d: Int) -> String {
            String(format: NSLocalizedString("rec_settings.cold_downgrade_days", comment: ""), d)
        }
        static var qualityRunNow: String { NSLocalizedString("rec_settings.quality_run_now", comment: "") }
        static var qualityRunning: String { NSLocalizedString("rec_settings.quality_running", comment: "") }
        static var qualityNothingCold: String { NSLocalizedString("rec_settings.quality_nothing_cold", comment: "") }
        static func qualityReport(_ done: Int, _ skipped: Int) -> String {
            String(format: NSLocalizedString("rec_settings.quality_report", comment: ""), done, skipped)
        }
        // ★ 2026-10-29 (饭耳移植 · 规格 §2.2 试听)
        static var auditionLoad: String { NSLocalizedString("rec_settings.audition_load", comment: "") }
        /// ★ 2026-11-02：试听池只收手表录音，一段都没有时给一句提示。
        static var auditionEmpty: String { NSLocalizedString("rec_settings.audition_empty", comment: "") }
        static var auditionOriginal: String { NSLocalizedString("rec_settings.audition_original", comment: "") }
        static var auditionTier: String { NSLocalizedString("rec_settings.audition_tier", comment: "") }
        static func auditionClipLabel(_ name: String) -> String {
            String(format: NSLocalizedString("rec_settings.audition_clip", comment: ""), name)
        }
        static func qualityTierLabel(_ base: String, _ sizePerHour: String, _ recommendation: String?) -> String {
            var s = "\(base) · \(sizePerHour)"
            if let recommendation {
                // ★ 2026-11-05：括号样式本地化——英文用半角括号（用户截图里
                // "约 29MB/小时（不建议）"整段混排就是这么来的另一半）。
                s += String(format: NSLocalizedString("rec_settings.quality_rec_parens", value: "（%@）",
                                                      comment: "Quality picker: wraps the recommendation mark; %@ = e.g. not recommended"),
                            recommendation)
            }
            return s
        }
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
        static var switchToThis: String {
            NSLocalizedString("devices.switch_to_this", value: "Switch", comment: "Row action: connect to this card instead of the current one")
        }
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
        /// A clip whose text was produced by **live transcription** while it was
        /// being recorded — deliberately distinct from the card's own name, so
        /// "transcribed live" and "just recorded" can be told apart in the list.
        static var sourceLive: String {
            NSLocalizedString(
                "library.source_live",
                value: "Live transcript",
                comment: "Short chip label for a clip transcribed while recording"
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
        /// ★ 2026-10-30（用户："录音断联需要状态弹出提醒告知，点击或者在附近就重连"）：
        /// 录音期间与手机断联的提醒弹窗。
        static var linkLostTitle: String {
            NSLocalizedString(
                "watch.link_lost_title",
                value: "iPhone disconnected",
                comment: "Alert title when the phone is out of reach during a watch recording"
            )
        }
        static var linkLostMessage: String {
            NSLocalizedString(
                "watch.link_lost_message",
                value: "The recording keeps running on the watch. Bring the iPhone nearby — it reconnects automatically, or tap Reconnect.",
                comment: "Body of the link-lost alert"
            )
        }
        static var linkLostRetry: String {
            NSLocalizedString(
                "watch.link_lost_retry",
                value: "Reconnect",
                comment: "Button in the link-lost alert that re-pushes state and re-sends queued clips"
            )
        }
        /// ★ 2026-11-03（用户："手表如果断开了，需要通知栏弹出，然后点击自动重连或者不点击也可以"）：
        /// 系统通知正文。应用内 alert 的 `linkLostMessage` 太长，通知里只放一句。
        /// ★ 2026-11-03（V4 原型）：省电录音时的状态标签。
        /// 和 `listening` 一样保留英文——它是这套设计语言里的状态词，不翻译。
        static var moonlit: String {
            NSLocalizedString(
                "watch.moonlit",
                value: "MOONLIT",
                comment: "Watch recording badge in power-saver mode (paired with a moon glyph)"
            )
        }
        /// ★ 2026-11-03（V4 原型）：录音页中间那颗暖色 chip「已攒 3 段 ›」。
        /// 省电模式下用户最需要的一句话是"东西还在，只是攒着没发"。
        static func stashedCount(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "watch.stashed_count", value: "%d saved",
                    comment: "Watch recording page: chip saying how many finished clips are being held back in power-saver mode"
                ),
                count
            )
        }
        static var linkLostNoteRecording: String {
            NSLocalizedString(
                "watch.link_lost_note_recording",
                value: "Still recording on your watch. It syncs once the iPhone is nearby — tap to reconnect now.",
                comment: "Body of the system notification posted when the watch loses the iPhone mid-recording"
            )
        }
        static var linkLostNotePending: String {
            NSLocalizedString(
                "watch.link_lost_note_pending",
                value: "Some clips haven't reached your iPhone yet. Tap to reconnect now.",
                comment: "Body of the system notification posted when the watch has unsynced clips and the iPhone is away"
            )
        }
        /// ★ 2026-11-03：同步页待传列表最多展示 8 条，多出来的收成这一行。
        static func pendingMore(_ count: Int) -> String {
            String(
                format: NSLocalizedString(
                    "watch.pending_more", value: "+%d more",
                    comment: "Watch sync page: how many more queued clips exist beyond the first eight rows"
                ),
                count
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
        // ★ 2026-11-02（用户："手表的整体风格朝着这个看起…他这个里面的内容你也可以加入进来"）：
        //   首页按 `nomily-watch-v3-blink.html` 重做——顶栏时钟、LISTENING 呼吸点、
        //   大号细体计时、以及新增的「最近 / 同步」两页。
        /// 「最近」页的标题（原型里的 `Recent`）。
        static var recent: String { NSLocalizedString("watch.recent", comment: "") }
        static var recentEmpty: String { NSLocalizedString("watch.recent_empty", comment: "") }
        /// 摘要里既没有标题也没有要点时，列表里那行主题的兜底文案。
        static var recentUntitled: String { NSLocalizedString("watch.recent_untitled", comment: "") }
        static var syncToPhone: String { NSLocalizedString("watch.sync_to_phone", comment: "") }
        /// 大数字旁边那个**不带数字**的单位词（原型：「1 项待传」）——
        /// `pendingCount` 是"整句带数字"，这里大号数字单独排版，所以要拆开。
        static var pendingUnit: String { NSLocalizedString("watch.pending_unit", comment: "") }
        static var phoneLabel: String { NSLocalizedString("watch.phone_label", comment: "") }
        static var phoneNear: String { NSLocalizedString("watch.phone_near", comment: "") }
        static var phoneFar: String { NSLocalizedString("watch.phone_far", comment: "") }
        static var storageLabel: String { NSLocalizedString("watch.storage_label", comment: "") }
        static func storageFree(_ value: String) -> String {
            String(format: NSLocalizedString("watch.storage_free", comment: ""), value)
        }
        static var syncNow: String { NSLocalizedString("watch.sync_now", comment: "") }
        static var syncing: String { NSLocalizedString("watch.syncing", comment: "") }
        /// 录音中的呼吸标签。英文约定俗成全大写，中文也照原样保留——它是"状态灯"，不是句子。
        static var listening: String { NSLocalizedString("watch.listening", comment: "") }
        /// 停止录音、睁眼之前闪一下的那个词（原型里的大写字距标题）。
        static var saved: String { NSLocalizedString("watch.saved", comment: "") }
        static func pointsCount(_ count: Int) -> String {
            String(format: NSLocalizedString("watch.points_count", comment: ""), count)
        }
        static var menuHeader: String { NSLocalizedString("watch.menu_header", comment: "") }

        // ★ 2026-11-02 第二轮（用户："手表需要为全天候录音设置，这个功耗跟传输需要优化"）：
        // 全天候录音（省电模式）——采样/重绘放慢 + 回传暂缓。
        static var allDayTitle: String { NSLocalizedString("watch.allday_title", comment: "") }
        static var allDayHint: String { NSLocalizedString("watch.allday_hint", comment: "") }
        // MARK: ★ 2026-11-05 触感等级（录音起止震动的力度，1–5 档）
        static var hapticLevelTitle: String {
            NSLocalizedString("watch.haptic_level_title", value: "Record haptics",
                              comment: "Watch settings: strength of the start/stop haptics")
        }
        static var hapticLevelHint: String {
            NSLocalizedString("watch.haptic_level_hint", value: "Pick 1–5; a sample plays when you change it",
                              comment: "Watch settings: hint under the haptic-strength picker")
        }
        static func hapticLevelName(_ level: Int) -> String {
            let fallback: String
            switch level {
            case 1: fallback = "1 · Light tap"
            case 2: fallback = "2 · Gentle"
            case 3: fallback = "3 · Firm"
            case 4: fallback = "4 · Strong"
            default: fallback = "5 · Maximum"
            }
            return NSLocalizedString("watch.haptic_\(level)", value: fallback,
                                     comment: "Watch settings: haptic strength level label")
        }
        // MARK: ★ 2026-11-05 第二轮（用户："停止录音跟结束录音震动效果也要多出几个"）
        // 录音起止的**花样**（节奏），与上面的力度档位正交：力度管"多重"，这里管"怎么响"。
        // ★ 第三轮（用户："震动样式里面分启动震动跟结束震动"）：拆成启动/结束两组标题。
        // 键名按 `WatchHapticPattern.rawValue` 拼（single / double / triple / single_long / heartbeat / crescendo）。
        static var hapticStartTitle: String {
            NSLocalizedString("watch.haptic_start_title", value: "Start buzz",
                              comment: "Watch settings: haptic rhythm played when a take starts")
        }
        static var hapticStopTitle: String {
            NSLocalizedString("watch.haptic_stop_title", value: "Stop buzz",
                              comment: "Watch settings: haptic rhythm played when a take ends")
        }
        static var hapticPatternHint: String {
            NSLocalizedString("watch.haptic_pattern_hint", value: "Plays once when you pick one",
                              comment: "Watch settings: hint under the start/stop pattern pickers")
        }
        // MARK: ★ 2026-11-05 第四轮：全天候录音中的「环境态」标签。
        // "REC" 各语言通写不翻——它是仪表灯上的一个字，不是句子。
        static var ambientRec: String {
            NSLocalizedString("watch.ambient_rec", value: "REC",
                              comment: "Watch ambient mode (all-day recording): tiny label next to the pulsing dot")
        }
        static func hapticPatternName(_ raw: String) -> String {
            let fallback: String
            switch raw {
            case "double": fallback = "Double knock"
            case "triple": fallback = "Triple tap"
            case "singleLong": fallback = "One long buzz"
            case "heartbeat": fallback = "Heartbeat"
            case "crescendo": fallback = "Crescendo"
            default: fallback = "Single tap"
            }
            // 键里的下划线是给字符串表看的，不是 rawValue 的一部分。
            let key = raw == "singleLong" ? "single_long" : raw
            return NSLocalizedString("watch.haptic_pattern_name.\(key)", value: fallback,
                                     comment: "Watch settings: name of a start/stop haptic rhythm")
        }
        // MARK: ★ 2026-11-05 录音中断后的「继续录音」弹窗（全天候录音）
        static var resumePromptTitle: String {
            NSLocalizedString("watch.resume_prompt_title", value: "Recording was interrupted",
                              comment: "Watch: alert title when the system ended a take and all-day mode is on")
        }
        static var resumePromptBody: String {
            NSLocalizedString("watch.resume_prompt_body", value: "All-day recording is on. Pick up where it left off?",
                              comment: "Watch: alert body offering to restart the interrupted take")
        }
        static var resumePromptContinue: String {
            NSLocalizedString("watch.resume_prompt_continue", value: "Keep recording",
                              comment: "Watch: alert button — restart the take now")
        }
        static var resumePromptDismiss: String {
            NSLocalizedString("watch.resume_prompt_dismiss", value: "Not now",
                              comment: "Watch: alert button — leave it stopped")
        }
        /// iPhone「Apple Watch」设置页里全天候录音开关的脚注。
        static var allDayPhoneFooter: String {
            NSLocalizedString("watch.allday_phone_footer", value: "Same switch as on the watch. Turning it on starts recording on the watch right away.",
                              comment: "iPhone Watch settings: footer of the all-day recording toggle")
        }
        // MARK: ★ 2026-11-06 表情常亮开关（手机设置页，推到手表）
        static var alwaysOnTitle: String {
            NSLocalizedString("watch.alwayson_title", value: "Always-On Face",
                              comment: "iPhone Watch settings: keep the bot face visible on the dimmed always-on display")
        }
        static var alwaysOnHint: String {
            NSLocalizedString("watch.alwayson_hint", value: "Show the face (dimmed, no animation) when the screen rests. Off = black to save power.",
                              comment: "iPhone Watch settings: hint under the always-on face toggle")
        }
        static var alwaysOnFooter: String {
            NSLocalizedString("watch.alwayson_footer", value: "How long the face stays before returning to the watch face is set on the watch: Settings → General → Wake Screen → Return to Clock (you can set Nomily individually, up to 1 hour). While recording, the app always stays on screen.",
                              comment: "iPhone Watch settings: footer explaining the system-side Return to Clock limit")
        }
        static var faceLifeHeader: String {
            NSLocalizedString("watch.facelife_header", value: "Face Life",
                              comment: "iPhone Watch settings: section header for face-life options (eye shape, drowsy, pupil follow)")
        }
        static var faceLifeFooter: String {
            NSLocalizedString("watch.facelife_footer", value: "These settings apply to the face on your Apple Watch. The watch gets drowsy when untouched, and its pupils follow your finger while you press the screen.",
                              comment: "iPhone Watch settings: footer for face-life section")
        }
        static var eyeShapeTitle: String {
            NSLocalizedString("watch.eyeshape_title", value: "Eye Shape",
                              comment: "iPhone Watch settings: eye shape picker title")
        }
        static var drowsyTitle: String {
            NSLocalizedString("watch.drowsy_title", value: "Doze When Idle",
                              comment: "iPhone Watch settings: drowsy toggle title")
        }
        static var drowsyHint: String {
            NSLocalizedString("watch.drowsy_hint", value: "After a while without touching, the face gets sleepy and closes its eyes. Any tap wakes it up.",
                              comment: "iPhone Watch settings: hint under the drowsy toggle")
        }
        static var drowsyAfterTitle: String {
            NSLocalizedString("watch.drowsy_after_title", value: "Start Dozing After",
                              comment: "iPhone Watch settings: picker title for idle time before dozing")
        }
        static func drowsyDelay(_ seconds: Int) -> String {
            String(format: NSLocalizedString("watch.drowsy_delay", value: "%d s", comment: "iPhone Watch settings: seconds before dozing, e.g. 30 s"), seconds)
        }
        static var pupilFollowTitle: String {
            NSLocalizedString("watch.pupil_title", value: "Pupil Follows Finger",
                              comment: "iPhone Watch settings: pupil-follow toggle title")
        }
        static var pupilFollowHint: String {
            NSLocalizedString("watch.pupil_hint", value: "While pressing the screen, the eyes look where your finger goes.",
                              comment: "iPhone Watch settings: hint under the pupil-follow toggle")
        }
        /// 同步页的提示条：解释"待传数字为什么不动"。
        static var deferNote: String { NSLocalizedString("watch.defer_note", comment: "") }

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

        // MARK: 电量监控（★ 2026-11-03 八轮，用户："手表菜单栏加一个电量消耗监控"）

        static var menuBattery: String {
            NSLocalizedString("watch.menu_battery", value: "Battery",
                              comment: "Watch quick menu: battery / power consumption page")
        }

        static var menuHintBattery: String {
            NSLocalizedString("watch.menu_hint_battery", value: "Drain while recording all day",
                              comment: "Watch quick menu: what the battery page holds")
        }
        static var menuHintVoiceprint: String {
            NSLocalizedString("watch.menu_hint_voiceprint", value: "Teach it your voice",
                              comment: "Watch quick menu: what the voiceprint page holds")
        }

        static var batteryNow: String {
            NSLocalizedString("watch.battery_now", value: "Now", comment: "Battery page: current level label")
        }

        static var batteryRate: String {
            NSLocalizedString("watch.battery_rate", value: "Drain", comment: "Battery page: per-hour drain label")
        }

        static var batteryLeft: String {
            NSLocalizedString("watch.battery_left", value: "Left", comment: "Battery page: estimated runtime label")
        }

        static var batteryCharging: String {
            NSLocalizedString("watch.battery_charging", value: "Charging", comment: "Battery page: charging state")
        }

        static var batteryNoData: String {
            NSLocalizedString("watch.battery_no_data", value: "Collecting…", comment: "Battery page: not enough samples yet")
        }

        /// ★ 九轮：样本还不够时不再干等一句 "Collecting…"，直接说还差几分钟。
        static func batteryCollecting(_ minutes: Int) -> String {
            String(format: NSLocalizedString("watch.battery_collecting", value: "%d min more",
                                             comment: "Battery page: how many more minutes of samples are needed"), minutes)
        }

        /// ★ 九轮：待机档（区别于录音档）。两档速率不同，界面必须标出来。
        static var batteryIdle: String {
            NSLocalizedString("watch.battery_idle", value: "Standby", comment: "Battery page: not recording")
        }

        /// ★ 九轮：「今日录音」累计行。
        static var batteryToday: String {
            NSLocalizedString("watch.battery_today", value: "Today", comment: "Battery page: recording drain accumulated today")
        }

        /// 今日录音时长 + 累计掉电。时长用一小时一位小数（"3.2h"）：
        /// 手表这一行只有百来点宽，时分秒写不下。
        static func batteryTodayValue(hours: Double, drop: Double) -> String {
            String(format: NSLocalizedString("watch.battery_today_value", value: "%.1fh · −%.0f%%",
                                             comment: "Battery page: hours recorded today and how much battery that used"),
                   hours, drop)
        }

        /// 速率小于 0.5%/h 时的说法。1% 一档的分辨率下，这个区间算不出更细的数，
        /// 硬写 "0.0%/h" 会被读成"坏了"。
        static var batteryRateSmall: String {
            NSLocalizedString("watch.battery_rate_small", value: "<0.5%/h",
                              comment: "Battery page: drain too small to resolve at 1% granularity")
        }

        /// 百分比 + 每小时耗电 + 预计还能录多久。
        ///
        /// ⚠️ 必须走 `String(format:)`：以前把数字插进 `value:` 里，一旦该键在
        ///    `zh-Hans` 里存在（现在有了），`NSLocalizedString` 会返回**带占位符**的
        ///    译文而不再用那个已插值的 value，屏幕上就会显示 "每小时 %@%%"。
        static func batteryRateValue(_ percentPerHour: Double) -> String {
            String(format: NSLocalizedString("watch.battery_rate_value", value: "%.1f%%/h",
                                             comment: "Battery page: drain per hour"), percentPerHour)
        }

        static func batteryLeftValue(_ hours: Double) -> String {
            String(format: NSLocalizedString("watch.battery_left_value", value: "%.1f h",
                                             comment: "Battery page: estimated remaining hours"), hours)
        }
        static var menuHintRecap: String {
            NSLocalizedString("watch.menu_hint_recap", value: "AI digests pushed from the phone",
                              comment: "Watch quick menu: what the Recap page holds")
        }

        // MARK: Recap (★ 2026-10-23, "watch 那边能否靠 Siri Recap 的看齐")
        //
        // The phone pushes a Siri-Recap-style digest (title + ≤3 key points)
        // after every finished summary; the watch keeps 7 days of them here.
        /// Title of the Recap menu page.
        static var recapTitle: String {
            NSLocalizedString("watch.recap_title", value: "Recap",
                              comment: "Watch recap page: title")
        }
        /// Empty state — also the one-line explanation of what fills the page.
        static var recapEmpty: String {
            NSLocalizedString("watch.recap_empty", value: "Summaries generated on your iPhone appear here",
                              comment: "Watch recap page: empty state")
        }
        /// ★ 2026-10-23 ("只看到一个标题，点进去才是主要内容"): the list row only
        /// carries the title, so the detail page needs its own section label.
        static var recapPoints: String {
            NSLocalizedString("watch.recap_points", value: "Key points",
                              comment: "Watch recap detail page: label above the bullet list")
        }
        /// Shown on the detail page when a digest arrived with no points.
        static var recapNoPoints: String {
            NSLocalizedString("watch.recap_no_points", value: "No key points for this summary",
                              comment: "Watch recap detail page: empty body")
        }
        /// ★ 2026-10-30：详情页的待办区标签（点一条 → 手机「提醒事项」）。
        static var recapTodos: String {
            NSLocalizedString("watch.recap_todos", value: "To-dos",
                              comment: "Watch recap detail page: label above the tappable to-do rows")
        }
        /// 待办区的操作提示——不点不知道能点，所以要写出来。
        static var recapTodoHint: String {
            NSLocalizedString("watch.recap_todo_hint", value: "Tap one to add it to Reminders on your iPhone",
                              comment: "Watch recap detail page: hint under the to-do rows")
        }
        /// ★ 2026-10-30：清空全部回顾的二次确认（单条删除已在行上左滑）。
        static var recapClearAll: String {
            NSLocalizedString("watch.recap_clear_all", value: "Delete every recap on this watch?",
                              comment: "Confirmation title before clearing all recaps")
        }
        static var recapClearAllConfirm: String {
            NSLocalizedString("watch.recap_clear_all_confirm", value: "Delete all", comment: "Destructive button that clears every recap")
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
        // ★ 2026-10-21: stuck-transfer escapes on the status strip
        static var transferStalled: String { NSLocalizedString("watch.transfer_stalled", value: "Watch offline — transfer paused", comment: "The watch stopped heartbeating mid-transfer") }
        static var transferWatchOffline: String { NSLocalizedString("watch.transfer_watch_offline", value: "The watch went offline mid-transfer. The clip stays on the watch and arrives when it reconnects.", comment: "") }
        static var transferGaveUp: String { NSLocalizedString("watch.transfer_gave_up", value: "The watch transfer stopped responding. Open the watch app to resend the clip.", comment: "") }
        static var hideTransferStatus: String { NSLocalizedString("watch.hide_transfer_status", value: "Hide this status", comment: "Close the watch transfer strip") }
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
        /// ★ 2026-10-30：Apple Watch 菜单页里「表盘表情」行下方的说明。
        static var menuFooter: String {
            NSLocalizedString("face.menu_footer", value: "Everything about your watch: face, name and timed recording.",
                              comment: "Apple Watch settings page footer, above the menu rows")
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
        // ★ 2026-11-06：借鉴 agent-avatars（jamesalmeida/agent-avatars）表情库的两档。
        static var wink: String {
            NSLocalizedString("face.wink", value: "Wink", comment: "Watch face expression: one eye closed")
        }
        static var love: String {
            NSLocalizedString("face.love", value: "Love", comment: "Watch face expression: heart-shaped eyes")
        }
        // ★ 2026-11-06 二轮：补齐 agent-avatars 缺的两档。
        static var sorry: String {
            NSLocalizedString("face.sorry", value: "Sorry", comment: "Watch face expression: drooping, apologetic eyes")
        }
        static var confused: String {
            NSLocalizedString("face.confused", value: "Confused", comment: "Watch face expression: uneven eyes tilted the same way")
        }
        // ★ 2026-11-06 二轮：眼睛形状轴（借鉴 agent-avatars 的 4 种 eye styles）。
        static var shapeTall: String {
            NSLocalizedString("face.shape_tall", value: "Tall", comment: "Eye shape: tall capsules (default)")
        }
        static var shapeRound: String {
            NSLocalizedString("face.shape_round", value: "Round", comment: "Eye shape: round eyes")
        }
        static var shapeCalm: String {
            NSLocalizedString("face.shape_calm", value: "Calm", comment: "Eye shape: wide, short, relaxed eyes")
        }
        static var shapeCurious: String {
            NSLocalizedString("face.shape_curious", value: "Curious", comment: "Eye shape: narrow and tall")
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
        // ★ 2026-10-30：face.frame / face.frame_footer 已删——「方框」功能整体下线
        //（用户第二次点名删除），手机端推送恒为不显示。
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
        /// ★ 2026-11-02: 非 Opus 容器播放失败时的真实错误兜底（此前一律误报 Opus 文案）。
        static var playbackFailedGeneric: String { NSLocalizedString("clip_detail.playback_failed_generic", value: "This audio file can't be played — the recording may be damaged or in an unsupported format. Transcription may still work.", comment: "Shown in the player when a non-Opus clip fails to load") }
        static var transcript: String { NSLocalizedString("clip_detail.transcript", comment: "") }

        // MARK: Outline (★ 2026-10-23, "录音来源里面还有大纲总结")
        /// Section header above the chapter list in 来源.
        static var outline: String {
            NSLocalizedString("clip_detail.outline", value: "Outline",
                              comment: "Source tab: chapter outline section header")
        }
        static var outlineGenerate: String {
            NSLocalizedString("clip_detail.outline_generate", value: "Generate Outline",
                              comment: "Source tab: button that builds the chapter outline")
        }
        static var outlineRegenerate: String {
            NSLocalizedString("clip_detail.outline_regenerate", value: "Regenerate outline",
                              comment: "Source tab: refresh button in the outline header")
        }
        static var outlineGenerating: String {
            NSLocalizedString("clip_detail.outline_generating", value: "Building the outline…",
                              comment: "Source tab: outline job is running")
        }
        static var outlineHint: String {
            NSLocalizedString("clip_detail.outline_hint",
                              value: "An outline turns the transcript into chapters you can jump to.",
                              comment: "Source tab: one-line explanation under the empty outline section")
        }
        static var outlineNoTimeline: String {
            NSLocalizedString("clip_detail.outline_no_timeline",
                              value: "This transcript has no timestamps, so it can't be split into chapters.",
                              comment: "Source tab: transcript has no segment timings")
        }
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
        /// ★ (2026-10-19) Detail tabs. ★ (2026-10-23) relabelled to Plaud's
        /// 「来源 | 笔记」 split (captured from the vivo handset): the transcript is
        /// the *source*, the generated pages are the *notes*.
        static var tabTranscript: String { NSLocalizedString("clip_detail.tab_transcript", value: "Source", comment: "Detail page tab — the recording's source (audio + transcript)") }
        static var tabSummary: String { NSLocalizedString("clip_detail.tab_summary", value: "Notes", comment: "Detail page tab — generated note pages") }
        static var tabTodos: String { NSLocalizedString("clip_detail.tab_todos", value: "To-dos", comment: "Detail page tab — action items") }
        // ★ 2026-10-23 ("页面模板"): multi-page notes, Plaud parity.
        static var noteAddPage: String { NSLocalizedString("clip_detail.note_add_page", value: "Add note page", comment: "The + chip that generates another note page") }
        static var noteChangeTemplate: String { NSLocalizedString("clip_detail.note_change_template", value: "Change template", comment: "Page chip menu — regenerate this page from another template") }
        static var noteDeletePage: String { NSLocalizedString("clip_detail.note_delete_page", value: "Delete this page", comment: "Page chip menu — delete one note page") }
        static var noteDeletePageMessage: String { NSLocalizedString("clip_detail.note_delete_page_message", value: "The generated content of this page will be deleted.", comment: "Delete-page confirmation") }
        static var noteDefaultTitle: String { NSLocalizedString("clip_detail.note_default_title", value: "Summary", comment: "Fallback title of the primary note page when its template is unknown") }
        static var moreActions: String { NSLocalizedString("clip_detail.more_actions", value: "More", comment: "Detail page top-right overflow menu") }
        static var aiAskTitle: String { NSLocalizedString("clip_detail.ai_ask_title", value: "AI Q&A", comment: "Detail page — ask questions about this recording") }
        static var aiAskYou: String { NSLocalizedString("clip_detail.ai_ask_you", value: "You", comment: "Chat speaker label — user") }
        static var aiAskAssistant: String { NSLocalizedString("clip_detail.ai_ask_assistant", value: "AI", comment: "Chat speaker label — assistant") }
        static var aiAskThinking: String { NSLocalizedString("clip_detail.ai_ask_thinking", value: "Thinking…", comment: "Chat pending state") }
        static var aiAskClear: String { NSLocalizedString("clip_detail.ai_ask_clear", value: "Clear", comment: "Clear the Q&A history") }
        static var aiAskPlaceholder: String { NSLocalizedString("clip_detail.ai_ask_placeholder", value: "Ask about this recording", comment: "Chat input placeholder") }
        /// Plaud's own wording for the box under a note ("对此笔记提问").
        static var aiAskPlaceholderNote: String { NSLocalizedString("clip_detail.ai_ask_placeholder_note", value: "Ask about this note", comment: "Chat input placeholder on the notes tab — Plaud's wording") }
        static var aiAskDone: String { NSLocalizedString("clip_detail.ai_ask_done", value: "Done", comment: "Close the Q&A sheet") }
        static var aiAskEmptyTitle: String { NSLocalizedString("clip_detail.ai_ask_empty_title", value: "Ask anything about this recording", comment: "Q&A sheet — empty state headline") }
        /// Plaud's line above generated note content ("内容由 AI 生成，仅供参考").
        static var aiGeneratedNote: String { NSLocalizedString("clip_detail.ai_generated_note", value: "AI-generated — for reference only", comment: "Caption above a generated note page") }
        static var aiAskFooter: String { NSLocalizedString("clip_detail.ai_ask_footer", value: "Answers use only this recording's transcript and summary.", comment: "Chat footer — grounding") }
        static var aiAskSystem: String {
            NSLocalizedString("clip_detail.ai_ask_system",
                              value: "You are a meeting assistant. Answer strictly from the RECORDING MATERIAL provided. If it does not contain the answer, say so plainly instead of guessing, and suggest what the user could look for. Reply in the language of the question. Be concise and quote timestamps when useful.",
                              comment: "System prompt for the in-page recording Q&A")
        }
        static var todosEmpty: String { NSLocalizedString("clip_detail.todos_empty", value: "No action items in the summary.", comment: "To-dos tab when the summary has no action-item section") }
        static var todosNeedSummary: String { NSLocalizedString("clip_detail.todos_need_summary", value: "Generate a summary to collect action items here.", comment: "To-dos tab when no summary exists yet") }

        // MARK: 待办分组（★ 2026-11-03 九轮：重排待办页，加了进度行与「已完成」折叠）
        /// 大数字右边那句（还有没做完的）。
        static var todosRemaining: String {
            NSLocalizedString("clip_detail.todos_remaining", value: "left to do",
                              comment: "To-do header: word after the big remaining count")
        }
        /// 全部勾完时替代上面那句。
        static var todosAllDone: String {
            NSLocalizedString("clip_detail.todos_all_done", value: "all done",
                              comment: "To-do header: shown when nothing is left")
        }
        /// 「共 8 项」。⚠️ 走 `String(format:)` 而不是字符串插值：
        /// 中文里数字的位置和英文不同（"共 %d 项" / "of %d"），插值就把语序焊死了。
        static func todosTotal(_ count: Int) -> String {
            String(format: NSLocalizedString("clip_detail.todos_total", value: "of %d",
                                             comment: "To-do header: trailing total, e.g. 'of 8'"), count)
        }
        /// 「已完成 3」——折叠组的小标题。
        static func todosCompleted(_ count: Int) -> String {
            String(format: NSLocalizedString("clip_detail.todos_completed", value: "Completed %d",
                                             comment: "To-do header for the collapsed group of checked rows"), count)
        }

        // MARK: 打包分享（★ 2026-11-04 用户："把我当前总结、思维导图、待办都进行分享出去打包方式"）
        //
        // 之前分享是"一件一件来"：导图一张图、摘要一个 md、待办只能截屏，发给同事要来回翻。
        // 这里给一个 zip 入口，两个粒度：只发文档 / 连录音一起。
        static var todosTitle: String {
            NSLocalizedString("clip_detail.todos_title", value: "To-dos",
                              comment: "Heading of the to-do list inside the share bundle's 待办.md")
        }
        /// 菜单项。括号里写清包里有什么，省得用户点开才知道。
        static var bundleShareTitle: String {
            NSLocalizedString("clip_detail.bundle_title",
                              value: "Share as a bundle (summary + mind map + to-dos)",
                              comment: "Overflow menu entry that zips the note artefacts and opens the share sheet")
        }
        static var bundleDocsOnly: String {
            NSLocalizedString("clip_detail.bundle_docs_only",
                              value: "Documents only (summary / mind map / to-dos / transcript)",
                              comment: "Bundle confirmation — no audio, fast")
        }
        static var bundleWithAudio: String {
            NSLocalizedString("clip_detail.bundle_with_audio",
                              value: "Include the recording (larger, takes a moment)",
                              comment: "Bundle confirmation — include the audio file")
        }
        static var bundleBuilding: String {
            NSLocalizedString("clip_detail.bundle_building", value: "Packaging…",
                              comment: "Menu entry while the zip is being built")
        }
        static var bundleEmpty: String {
            NSLocalizedString("clip_detail.bundle_empty",
                              value: "Nothing to share yet — this recording has no summary, mind map, to-dos or transcript.",
                              comment: "Bundle failed because every part of the package was missing")
        }
        static var searchTranscript: String { NSLocalizedString("clip_detail.search_transcript", value: "Search transcript", comment: "Transcript search field placeholder") }
        static var speakerAll: String { NSLocalizedString("clip_detail.speaker_all", value: "All speakers", comment: "Speaker filter chip — clear the filter") }
        // ★ 2026-10-22 ("还要支持修改说话人的名称"): diarization ids are the vendor's
        // labels; the user was in the room and knows who they were.
        static var editSpeakerNames: String {
            NSLocalizedString("clip_detail.edit_speaker_names",
                              value: "Rename speakers",
                              comment: "Button/menu entry opening the speaker rename sheet")
        }
        /// ★ 2026-10-30（纪要溯源跳转）：摘要要点/待办行尾的小按钮——
        /// 把这条内容在转写里定位出来（滚动 + 高亮 + 从那里播放）。
        static var traceSource: String {
            NSLocalizedString("clip_detail.trace_source",
                              value: "Jump to source in transcript",
                              comment: "Accessibility label for the small per-block button that locates the sentence in the transcript")
        }

        // MARK: 摘要自动版式（★ 2026-11-03 九轮）
        //
        // 四枚标签是"这篇摘要按什么模子排的"。文案刻意短：它们以胶囊形式出现在
        // 摘要正文顶部，长一句就把整块挤到第二行。
        static var layoutMinutes: String {
            NSLocalizedString("summary.layout.minutes", value: "Meeting notes",
                              comment: "Summary layout badge: the body reads like meeting minutes")
        }
        static var layoutQA: String {
            NSLocalizedString("summary.layout.qa", value: "Q&A",
                              comment: "Summary layout badge: the body is organised as questions and answers")
        }
        static var layoutChecklist: String {
            NSLocalizedString("summary.layout.checklist", value: "Action list",
                              comment: "Summary layout badge: most of the body is action items")
        }
        static var layoutNotes: String {
            NSLocalizedString("summary.layout.notes", value: "Notes",
                              comment: "Summary layout badge: the default clean document layout")
        }
        /// ★ 2026-10-30（用户："笔记来源要支持能够直接在摘要进行编辑"）：
        /// 摘要标题栏的编辑入口——带文字，不再是一枚看不出用途的小铅笔。
        static var editSummary: String {
            NSLocalizedString("clip_detail.edit_summary", value: "Edit", comment: "Button in the summary header that opens the inline markdown editor")
        }
        /// ★ 2026-10-30（用户："待办支持手写待办"）：待办区底部的输入框。
        static var addTodoPlaceholder: String {
            NSLocalizedString("clip_detail.add_todo", value: "Add a to-do", comment: "Placeholder of the free-text row that adds a manual to-do")
        }
        static var renameSpeakers: String {
            NSLocalizedString("clip_detail.rename_speakers",
                              value: "Speaker names",
                              comment: "Title of the speaker rename sheet")
        }
        static func speakerLineCount(_ count: Int) -> String {
            String(format: NSLocalizedString("clip_detail.speaker_line_count",
                                             value: "%d lines",
                                             comment: "How many transcript lines this speaker has; helps identify who is who"),
                   count)
        }
        static var resetSpeakerName: String {
            NSLocalizedString("clip_detail.reset_speaker_name",
                              value: "Use the original label",
                              comment: "Per-speaker reset button in the rename sheet")
        }
        static var resetSpeakerNames: String {
            NSLocalizedString("clip_detail.reset_speaker_names",
                              value: "Reset all speaker names",
                              comment: "Destructive row in the rename sheet")
        }
        static var speakerEditHint: String {
            NSLocalizedString("clip_detail.speaker_edit_hint",
                              value: "Names apply to this recording only — transcript, export and AI answers all use them. Clearing a field restores the original label.",
                              comment: "Footer of the speaker rename sheet")
        }
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
        // ★ 2026-10-22 (任务二): document export + email attachments.
        static var exportDocument: String { NSLocalizedString("clip_detail.export_document", value: "Export Document", comment: "Menu row opening the txt/md/pdf choices") }
        static var exportAsTXT: String { NSLocalizedString("clip_detail.export_as_txt", value: "Export as TXT", comment: "Plain-text transcript export") }
        static var exportAsMarkdown: String { NSLocalizedString("clip_detail.export_as_md", value: "Export as Markdown", comment: "Markdown export (summary + transcript)") }
        static var exportAsPDF: String { NSLocalizedString("clip_detail.export_as_pdf", value: "Export as PDF", comment: "Paginated PDF export") }
        static var exportPDFRenderFailed: String { NSLocalizedString("clip_detail.export_pdf_failed", value: "PDF rendering failed.", comment: "PDF export could not be generated") }
        static var emailTitle: String { NSLocalizedString("clip_detail.email_title", value: "Send by Email", comment: "Mail export entry + sheet title") }
        static var emailAttachSummary: String { NSLocalizedString("clip_detail.email_attach_summary", value: "Attach the summary", comment: "Mail attachment toggle") }
        static var emailAttachTranscript: String { NSLocalizedString("clip_detail.email_attach_transcript", value: "Attach the transcript", comment: "Mail attachment toggle") }
        static var emailAttachMindMap: String { NSLocalizedString("clip_detail.email_attach_mindmap", value: "Attach the mind map (image)", comment: "Mail attachment toggle") }
        static var emailAttachFooter: String { NSLocalizedString("clip_detail.email_attach_footer", value: "Attachments are generated from this recording's saved artefacts. Greyed-out options have nothing to attach yet.", comment: "Mail attachment picker footer") }
        static var emailCompose: String { NSLocalizedString("clip_detail.email_compose", value: "Compose Email", comment: "Opens the system mail composer") }
        static var emailUnavailable: String { NSLocalizedString("clip_detail.email_unavailable", value: "No mail account is configured on this device. Set one up in Settings → Mail.", comment: "Mail composer cannot be opened") }
        static var emailSubjectFormat: String { NSLocalizedString("clip_detail.email_subject", value: "Nomily — %@", comment: "Mail subject; parameter is the recording name") }
        static var emailBody: String { NSLocalizedString("clip_detail.email_body", value: "Attachments exported from Nomily.", comment: "Default mail body") }
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

        // MARK: 思维导图结构模板（★ 2026-11-03 九轮）
        //
        // 五枚标签说明"这张图是按哪种结构排的"。名字对齐主流思维导图产品的说法
        // （topic / org chart / timeline），用户不必学一套新词。
        static var mapTemplateTopic: String {
            NSLocalizedString("map.template.topic", value: "Topics",
                              comment: "Mind map template badge: plain topic tree (default)")
        }
        static var mapTemplateMinutes: String {
            NSLocalizedString("map.template.minutes", value: "Meeting",
                              comment: "Mind map template badge: branches reordered as meeting minutes")
        }
        static var mapTemplatePeople: String {
            NSLocalizedString("map.template.people", value: "By person",
                              comment: "Mind map template badge: regrouped with each owner as a branch")
        }
        static var mapTemplateTimeline: String {
            NSLocalizedString("map.template.timeline", value: "Timeline",
                              comment: "Mind map template badge: branches numbered in sequence")
        }
        static var mapTemplateActions: String {
            NSLocalizedString("map.template.actions", value: "Action first",
                              comment: "Mind map template badge: the to-do branch is hoisted to the top")
        }
        static var mapTemplateOthers: String {
            NSLocalizedString("map.template.others", value: "Others",
                              comment: "Mind map branch that keeps the points which had no owner in front of them")
        }
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
        /// Label on the key-point row for a live-transcript bookmark
        /// (`speaker == "mark"` in the saved segments).
        static var markKeyPoint: String {
            NSLocalizedString("clip_detail.mark_key_point", value: "重点标记",
                              comment: "Key-point row label for a live-transcript bookmark in the transcript")
        }
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

    /// ★ 2026-11-09 固件 OTA（0xB0/0xB1）。文案对齐官方升级页的口径
    ///   （"升级预计 5-10 分钟，请勿关闭 App / 断开连接"）。
    enum DeviceOta {
        static var sectionHeader: String { NSLocalizedString("device_ota.section_header", value: "Firmware update", comment: "Device sheet section for OTA") }
        static var footer: String { NSLocalizedString("device_ota.footer", value: "Only load firmware packages (.lz) provided by the factory. The whole update takes about 5–10 minutes: keep the device connected and powered, and don't leave this page. Recordings already on the device are not affected.", comment: "OTA section footer") }
        static var pickFile: String { NSLocalizedString("device_ota.pick_file", value: "Choose firmware file…", comment: "Open the file picker for a .lz firmware package") }
        static func readyFile(_ name: String, _ kb: Int) -> String {
            String(format: NSLocalizedString("device_ota.ready_file", value: "%1$@ (%2$d KB) — tap to start", comment: "Selected firmware package name + size"), name, kb)
        }
        static var readyHint: String { NSLocalizedString("device_ota.ready_hint", value: "The device will enter upgrade mode immediately after you confirm.", comment: "Hint above the start button") }
        static var clearFile: String { NSLocalizedString("device_ota.clear_file", value: "Remove selected file", comment: "Drop the picked firmware package") }
        static var confirmTitle: String { NSLocalizedString("device_ota.confirm_title", value: "Update firmware now?", comment: "Confirmation before entering upgrade mode") }
        static var confirmMessage: String { NSLocalizedString("device_ota.confirm_message", value: "The device enters upgrade mode and stops taking commands. Keep it within range and powered, and don't close this page. Don't do this while recording.", comment: "OTA confirmation body") }
        static var start: String { NSLocalizedString("device_ota.start", value: "Start update", comment: "Confirm button") }
        static var transferring: String { NSLocalizedString("device_ota.transferring", value: "Transferring firmware…", comment: "Upload phase") }
        static var flashing: String { NSLocalizedString("device_ota.flashing", value: "Device is flashing the firmware…", comment: "Self-upgrade phase") }
        static var success: String { NSLocalizedString("device_ota.success", value: "Update complete. The device is restarting — reconnect and check the version below.", comment: "OTA finished") }
        static var errorTitle: String { NSLocalizedString("device_ota.error_title", value: "Update didn't finish", comment: "OTA failure alert title") }
        static var errorRefused: String { NSLocalizedString("device_ota.error_refused", value: "The device refused to enter upgrade mode. Stop any recording, make sure it's connected, and try again.", comment: "0xB0 returned 0x00") }
        static var errorStopped: String { NSLocalizedString("device_ota.error_stopped", value: "The device left upgrade mode.", comment: "Device aborted (status 0011)") }
        static var errorDeviceFailed: String { NSLocalizedString("device_ota.error_device_failed", value: "The device reported a failed update. Retry with the same package; if it fails again, contact the factory.", comment: "Device flashed and failed (status 0110)") }
        static var errorCannotResync: String { NSLocalizedString("device_ota.error_cannot_resync", value: "The transfer lost sync and couldn't resume safely. Nothing was written — you can retry the update.", comment: "Resend request couldn't be located") }
        static var unsupportedFile: String { NSLocalizedString("device_ota.unsupported_file", value: "That doesn't look like a firmware package (.lz). Use the file from the factory folder.", comment: "Picked file failed the zlib/size sanity check") }
        static var unreadableFile: String { NSLocalizedString("device_ota.unreadable_file", value: "Couldn't read that file.", comment: "Picker file couldn't be loaded") }
        static func currentVersion(_ v: String) -> String {
            String(format: NSLocalizedString("device_ota.current_version", value: "Current version: %@", comment: "Footer showing the firmware version read from the device"), v)
        }
        // 阶段化报错（首跑失败后加的：让弹窗直接说出"断在哪一步"）
        static var errorAtStage: String { NSLocalizedString("device_ota.error_at_stage", value: "The update stopped at '%1$@': %2$@", comment: "OTA failure with the phase it died in") }
        static var stageEnter: String { NSLocalizedString("device_ota.stage_enter", value: "Entering upgrade mode", comment: "OTA phase: 0xB0 start") }
        static var stageTransfer: String { NSLocalizedString("device_ota.stage_transfer", value: "Transferring firmware", comment: "OTA phase: 0xB1 upload") }
        static var stageFlash: String { NSLocalizedString("device_ota.stage_flash", value: "Waiting for the device to flash", comment: "OTA phase: device self-upgrade") }
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

    /// ★ 2026-11-04：连接时"钥匙对不对"的状态文案。
    ///
    /// 这些句子存在的意义是**区分责任**：是设备上有别人的钥匙、是本机没有、
    /// 还是手机锁着读不到。以前三种都只说"请设置密码"，而其中两种根本不该
    /// 让用户去设密码。
    enum KeyHealth {
        static var rowLabel: String { NSLocalizedString("keyhealth.row_label", value: "Key check", comment: "Settings row — whether this iPhone's key opens the device's recordings") }
        static var unknown: String { NSLocalizedString("keyhealth.unknown", value: "unknown", comment: "Key health — device state not read yet") }
        static var notEncrypted: String { NSLocalizedString("keyhealth.not_encrypted", value: "device not encrypting", comment: "Key health — device encryption is off") }
        static var noKey: String { NSLocalizedString("keyhealth.no_key", value: "no key on this iPhone", comment: "Key health — device encrypted, this iPhone has no key") }
        static var unreadable: String { NSLocalizedString("keyhealth.unreadable", value: "locked — unlock to read", comment: "Key health — Keychain read was blocked (screen locked)") }
        static var unverified: String { NSLocalizedString("keyhealth.unverified", value: "not verified yet", comment: "Key health — a key exists but nothing has been decrypted with it on this device") }
        static var verified: String { NSLocalizedString("keyhealth.verified", value: "matches device", comment: "Key health — the key opens this device's recordings") }
        static var mismatch: String { NSLocalizedString("keyhealth.mismatch", value: "doesn't match device", comment: "Key health — the key does NOT open this device's recordings") }
        static func fingerprintNote(_ value: String) -> String {
            String(format: NSLocalizedString("keyhealth.fingerprint_note", value: "Key fingerprint %@ — compare it with the device page to tell whether both sides hold the same key.", comment: "Key health footer with the short key fingerprint"), value)
        }
        /// 列表页横幅（只在"确定不匹配"时出现）。
        static var bannerTitle: String { NSLocalizedString("keyhealth.banner_title", value: "This iPhone's key doesn't match the device", comment: "Banner title when the local key fails verification against the device") }
        static var bannerMessage: String { NSLocalizedString("keyhealth.banner_message", value: "Recordings transferred now will save as encrypted files that can't be opened on this iPhone. They stay on the device untouched — fix the key first, or the files are unreadable until you do.", comment: "Banner body explaining transfer would land undecryptable files") }
    }

    /// ★ 2026-11-04：录音键被"设备加密 + 本机没钥匙"拦住时的提示。
    ///
    /// 这道闸门本身是对的（录下来的文件在这台手机上会永远打不开），但它以前是
    /// **静默**的：按钮灰着、点了没反应、没有任何一句解释。P101 用户就是这么撞上的
    /// ——"已经连上了，但没办法录音"。
    enum RecordGate {
        static var blockedTitle: String { NSLocalizedString("record_gate.title", value: "Can't start recording", comment: "Alert title when the record button is blocked by the encryption gate") }
        static var blockedNoKey: String { NSLocalizedString("record_gate.no_key", value: "This device is encrypted and this iPhone has no matching key yet. Set the passphrase once before recording — anything recorded now could never be opened here.", comment: "Record button blocked: device encrypted, no local key") }
        static var blockedMismatch: String { NSLocalizedString("record_gate.mismatch", value: "This iPhone's key doesn't match the device, so new recordings still couldn't be opened here. Fix the key first (see Settings → Recordings).", comment: "Record button blocked: local key mismatches the device") }
        static var openSettings: String { NSLocalizedString("record_gate.open_settings", value: "Open settings", comment: "CTA next to the blocked-recording hint") }
    }

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
        static var footerRotate: String { NSLocalizedString("encryption.footer.rotate", value: "Rotate writes a brand-new key to the device. Recordings still on it stay locked to the old key and stop opening on this iPhone — download them first. The device only lets go of its current key for whoever holds it, so rotate succeeds when this iPhone (or the passphrase you type) owns it; a key set by the vendor's app has to be turned off there first.", comment: "Footer when the user is rotating") }
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
            return String(format: NSLocalizedString("encryption.rotate_confirm.message", value: "%d recording(s) are still on the device and are locked to the current key — after rotation they won't open on this iPhone, so download them first to keep them. Write down the new passphrase: it's the only way to open recordings made from now on, and there is no recovery.", comment: "Rotate confirmation, N recordings at risk"), count)
        }

        // Mismatch alert
        static var mismatchTitle: String { NSLocalizedString("encryption.mismatch.title", value: "Passphrase didn't match", comment: "Alert title when probe verify fails") }
        static var mismatchMessage: String { NSLocalizedString("encryption.mismatch.message", value: "The probe clip didn't decrypt with that passphrase. Double-check it and try again. If the device's key was set by another app (e.g. the vendor's app) or another phone, remove encryption there first, then set the passphrase here. If you truly own this device but lost the passphrase, use \"Rotate\" — it only succeeds when the passphrase matches the device's current key.", comment: "Alert body explaining retry + rotate + mixed-app guidance") }
        static var mismatchTryAgain: String { NSLocalizedString("encryption.mismatch.try_again", value: "Try again", comment: "Alert button to retry") }
        /// ★ 2026-11-03（混合使用兼容）：轮换时设备现役密钥不是这句口令派生的，
        ///   固件拒绝解除（协议 0xA2 规则 2）——必须先去设置该密钥的 App 里解除加密。
        static var foreignKeyBlocked: String { NSLocalizedString("encryption.foreign_key.blocked", value: "The device's current key wasn't set with this passphrase (it was likely created by the vendor's app or another phone), and the firmware refuses to overwrite it. Turn encryption OFF in the app that set the key first, then set the passphrase here. Recordings already on the device stay safe either way.", comment: "Rotate failed because the device holds a foreign key") }
        /// 轮换被拒后的出口：改走「验证并解锁」，不再要求覆盖设备密钥。
        static var switchToUnlock: String { NSLocalizedString("encryption.switch_to_unlock", value: "Verify the current passphrase instead", comment: "Button offered after a rejected rotate — flips the sheet to verify mode") }
        static var switchToUnlockHint: String { NSLocalizedString("encryption.switch_to_unlock_hint", value: "If you know the passphrase this key was created with, verify it here: recordings become readable and nothing on the device is overwritten. Overwriting only works once this iPhone holds the current key.", comment: "Caption under the switch-to-verify button") }

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
        // ★ 2026-10-26: third segment of the live-tab source picker — the PLAUD
        // card's own PCM pipeline. Brand name, not translated.
        static var sourcePlaud: String { NSLocalizedString("live.source_plaud", value: "PLAUD", comment: "Segment label for the PLAUD card's live screen") }
        // ★ 2026-10-26: the mic button on the card's live screen leads here; this
        // is the way back to the card.
        static var backToCard: String { NSLocalizedString("live.back_to_card", value: "Back to card", comment: "Return from the phone-mic live screen to the card's live screen") }
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
        /// ★ 2026-11-09：空态 hero 的副标题（说清这个页面给什么）。
        static var idleHeroHint: String { NSLocalizedString("live.idle_hero_hint", value: "Tap to start live captions — sentences appear as you speak, and the take saves itself to the library when you stop.", comment: "") }
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
        /// ★ 2026-11-02（对齐规格书 §2.2）：录音豆广播 `flags&0x80` 绑定位的展示徽标。
        static var soundcoreBoundBadge: String {
            NSLocalizedString(
                "scanner.soundcore_bound_badge",
                value: "Bound",
                comment: "Badge on a soundcore Work bean already bound to the Feishu app"
            )
        }
        static var wakeAndRetry: String { NSLocalizedString(
            "scanner.wake_and_retry",
            value: "Device not found. Press and hold the device button for 1 second to wake it, then try again.",
            comment: "Manual reconnect timed out because a sleeping known device was not advertising"
        ) }
        // ★ 2026-10-21: category-first add flow
        static var addTitle: String { NSLocalizedString("scanner.add_title", value: "Add device", comment: "Title of the device-type pick page") }
        static var pickHint: String { NSLocalizedString("scanner.pick_hint", value: "Pick a device type, then scan for it", comment: "Hint on the device-type pick page") }
        static var categoryVobot: String { NSLocalizedString("scanner.category_vobot", value: "V05E", comment: "Device family card") }
        static var categoryTicnote: String { NSLocalizedString("scanner.category_ticnote", value: "TicNote", comment: "Device family card") }
        static var categoryA1: String { NSLocalizedString("scanner.category_a1", value: "DingTalk A1", comment: "Device family card") }
        static var categoryPlaud: String { NSLocalizedString("scanner.category_plaud", value: "PLAUD", comment: "Device family card") }
        static var categoryWatch: String { NSLocalizedString("scanner.category_watch", value: "Apple Watch", comment: "Device family card") }
        static var actionScan: String { NSLocalizedString("scanner.action_scan", value: "Scan to connect", comment: "Card subtitle: BLE scan flow") }
        static var actionSDK: String { NSLocalizedString("scanner.action_sdk", value: "Official SDK direct connect", comment: "Card subtitle: PLAUD SDK flow") }
        static var actionWatch: String { NSLocalizedString("scanner.action_watch", value: "Install the Watch app", comment: "Card subtitle: Apple Watch flow") }
        /// ★ 2026-11-05：这里原来写死中文（英文界面漏中文残留排查发现的最后一处）。
        static var categorySoundcore: String { NSLocalizedString("scanner.category_soundcore", value: "soundcore Work (Feishu Recorder Bean)", comment: "Device family card: soundcore Work D3200, used alongside the Feishu app") }
        static func noNewInCategory(_ name: String) -> String {
            String(format: NSLocalizedString(
                "scanner.no_new_in_category",
                value: "No new %@ nearby. Make sure the device is on and in pairing mode.",
                comment: "Empty scan list for one specific device family"), name)
        }
    }

    /// Apple Watch install guide (its "add" action is installing the app).
    enum WatchAdd {
        static var title: String { NSLocalizedString("watchadd.title", value: "Install on Apple Watch", comment: "") }
        static var step1: String { NSLocalizedString("watchadd.step1", value: "Open the “Watch” app on this iPhone", comment: "") }
        static var step2: String { NSLocalizedString("watchadd.step2", value: "Go to “My Watch” → scroll to “AVAILABLE APPS”", comment: "") }
        static var step3: String { NSLocalizedString("watchadd.step3", value: "Find Nomily and tap “Install”, then open it on the watch", comment: "") }
        static var note: String { NSLocalizedString("watchadd.note", value: "Recordings made on the watch sync into the library automatically — no extra pairing needed here.", comment: "") }
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
        /// Shown in the job notes when the source was so short that the full
        /// template was replaced by the two-sentence reply.
        static var shortSourceNote: String {
            NSLocalizedString("summarize.short_source_note", value: "The transcript is very short — a simplified summary was used instead of the full template",
                              comment: "Job note: the template was skipped because the source is tiny")
        }

        /// ★ 2026-11-03 十轮：长录音只摘要重要片段时的一句说明。
        static func salienceNote(dropped: Int) -> String {
            String(format: NSLocalizedString("summarize.salience_note",
                                             value: "This was a long take: %d%% of it was small talk, so only the salient parts were summarized",
                                             comment: "Job note: filler lines were filtered out before summarizing"),
                   dropped)
        }
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

        // MARK: Template spaces (★ 2026-10-23, Plaud 4039 / 4040 / 4041)
        //
        // The picker is split into three spaces. Names follow Plaud's own
        // wording where it is already plain Chinese ("我的空间 / 推荐 / 探索") so
        // a user coming from Plaud recognises the layout.
        static var spaceMine: String {
            NSLocalizedString("summarize.space_mine", value: "My Space",
                              comment: "Template picker: tab holding the user's own templates")
        }
        static var spaceRecommended: String {
            NSLocalizedString("summarize.space_recommended", value: "For You",
                              comment: "Template picker: tab with curated templates")
        }
        static var spaceExplore: String {
            NSLocalizedString("summarize.space_explore", value: "Explore",
                              comment: "Template picker: tab with the full category library")
        }
        static var myTemplates: String {
            NSLocalizedString("summarize.my_templates", value: "My Templates",
                              comment: "Template picker: heading over the user's own templates")
        }
        static var createTemplate: String {
            NSLocalizedString("summarize.create_template", value: "Create Template",
                              comment: "Template picker: dashed card that opens the template editor")
        }
        static var editorsPicks: String {
            NSLocalizedString("summarize.editors_picks", value: "Editors' Picks",
                              comment: "Template picker: curated shelf of daily-driver templates")
        }
        static var inspiration: String {
            NSLocalizedString("summarize.inspiration", value: "Inspiration",
                              comment: "Template picker: curated shelf of less obvious formats")
        }
        static var mineSpaceFooter: String {
            NSLocalizedString("summarize.mine_space_footer",
                              value: "Language and model apply to this generation only in the sense that they are saved as your defaults.",
                              comment: "Template picker: footnote under the language/model rows")
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
        // ★ 2026-10-23 ("自动化生成根据里面内容进行选择合适模板", Plaud 4033)
        static var generateNotes: String { NSLocalizedString("summarize.generate_notes", value: "Generate note", comment: "Title of the generate sheet") }
        static var autoGenerate: String { NSLocalizedString("summarize.auto_generate", value: "Auto", comment: "Generate mode — app picks the template") }
        static var autoGenerateDesc: String { NSLocalizedString("summarize.auto_generate_desc", value: "Picks the best-matching template from the transcript and summary — no manual setup.", comment: "Auto mode description") }
        static var customGenerate: String { NSLocalizedString("summarize.custom_generate", value: "Custom", comment: "Generate mode — user picks template/language/model") }
        static var templateRow: String { NSLocalizedString("summarize.template_row", value: "Template", comment: "Custom mode row label") }
        static var aiModel: String { NSLocalizedString("summarize.ai_model", value: "AI model", comment: "Custom mode row label") }
        static var generateNow: String { NSLocalizedString("summarize.generate_now", value: "Generate now", comment: "Primary button in the generate sheet") }
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
    /// 待办看板（★ 2026-11-06 · 饭耳 1.0 移植 P0-1）。
    ///
    /// 文案基调学饭耳：不说"待办项"，说人话——「都看完了」「今天做完 1 件」
    /// 「卡片攒了很久，现在处理一下」。状态词用动词短语而不是名词，
    /// 因为每个状态都是用户做过的一个**决定**。
    enum Todo {
        static var title: String { NSLocalizedString("todo.title", value: "To-dos", comment: "To-do board page title") }
        static var settingsRow: String { NSLocalizedString("todo.settings_row", value: "To-do Board", comment: "Settings row for the to-do board") }
        static var segmentList: String { NSLocalizedString("todo.segment_list", value: "List", comment: "To-do board segment: list view") }
        static var segmentSchedule: String { NSLocalizedString("todo.segment_schedule", value: "Schedule", comment: "To-do board segment: calendar view") }

        static var statusPending: String { NSLocalizedString("todo.status_pending", value: "New", comment: "To-do status: just extracted, undecided") }
        static var statusAccepted: String { NSLocalizedString("todo.status_accepted", value: "To do", comment: "To-do status: accepted") }
        static var statusDone: String { NSLocalizedString("todo.status_done", value: "Done", comment: "To-do status: done") }
        static var statusWont: String { NSLocalizedString("todo.status_wont", value: "Skip", comment: "To-do status: decided not to do") }
        static var statusDeferred: String { NSLocalizedString("todo.status_deferred", value: "Later", comment: "To-do status: snoozed") }

        static var sectionInbox: String { NSLocalizedString("todo.section_inbox", value: "Waiting for your call", comment: "To-do board section: pending decisions") }
        static var sectionActive: String { NSLocalizedString("todo.section_active", value: "To do", comment: "To-do board section: accepted items") }
        static var sectionLater: String { NSLocalizedString("todo.section_later", value: "Remind me later", comment: "To-do board section: snoozed items") }
        static var sectionClosed: String { NSLocalizedString("todo.section_closed", value: "Closed", comment: "To-do board section: done + skipped") }

        static var emptyInbox: String { NSLocalizedString("todo.empty_inbox", value: "All caught up · nothing waiting on you", comment: "To-do board: empty inbox") }
        static var emptyBoard: String { NSLocalizedString("todo.empty_board", value: "No to-dos yet. Finish a recording's summary and its action items land here automatically.", comment: "To-do board: empty state with no cards at all") }
        static var emptyDay: String { NSLocalizedString("todo.empty_day", value: "Nothing due on this day", comment: "To-do board: empty schedule day") }

        static var decideTitle: String { NSLocalizedString("todo.decide_title", value: "A backlog has piled up — clear it", comment: "Decision sheet title") }
        static var decideHint: String { NSLocalizedString("todo.decide_hint", value: "Swipe right: done / skip · Swipe left: to do / later", comment: "Decision sheet hint") }
        static var decideDone: String { NSLocalizedString("todo.decide_done", value: "Done", comment: "Decision sheet: mark done") }
        static var decideWont: String { NSLocalizedString("todo.decide_wont", value: "Skip it", comment: "Decision sheet: not doing it") }
        static var decideAccept: String { NSLocalizedString("todo.decide_accept", value: "To do", comment: "Decision sheet: accept") }
        static var decideLater: String { NSLocalizedString("todo.decide_later", value: "Remind me later", comment: "Decision sheet: snooze") }
        static var decideSkip: String { NSLocalizedString("todo.decide_skip", value: "Not now", comment: "Decision sheet: skip the whole clearing flow") }
        static var decideProgressFormat: String {
            NSLocalizedString("todo.decide_progress", value: "%1$d of %2$d", comment: "Decision sheet progress, e.g. 2 of 5")
        }
        static func decideProgress(_ done: Int, _ total: Int) -> String {
            String(format: decideProgressFormat, done, total)
        }
        static var decideFinished: String { NSLocalizedString("todo.decide_finished", value: "Cleared. Nice.", comment: "Decision sheet: all cards handled") }

        static var swipeDone: String { NSLocalizedString("todo.swipe_done", value: "Done", comment: "Swipe action: done") }
        static var swipeWont: String { NSLocalizedString("todo.swipe_wont", value: "Skip", comment: "Swipe action: skip") }
        static var swipeLater: String { NSLocalizedString("todo.swipe_later", value: "Later", comment: "Swipe action: snooze to tomorrow 8:30") }
        static var swipeDelete: String { NSLocalizedString("todo.swipe_delete", value: "Delete", comment: "Swipe action: delete card") }
        static var openSource: String { NSLocalizedString("todo.open_source", value: "Open recording", comment: "Open the source recording") }
        static var sourceMissing: String { NSLocalizedString("todo.source_missing", value: "Source recording was deleted", comment: "Shown when the source recording no longer exists") }

        static var doneToday: String {
            NSLocalizedString("todo.done_today", value: "Nothing left · %d done today", comment: "Header line: nothing pending, N done today")
        }
        static func doneToday(_ count: Int) -> String { String(format: doneToday, count) }
        static var overdue: String { NSLocalizedString("todo.overdue", value: "%d overdue", comment: "Overdue count badge") }
        static func overdue(_ count: Int) -> String { String(format: overdue, count) }

        static var notifyBody: String { NSLocalizedString("todo.notify_body", value: "From “%@”", comment: "Notification body, %@ = source recording title") }
        static func notifyBody(_ source: String) -> String { String(format: notifyBody, source) }

        static var reminderFooter: String {
            NSLocalizedString("todo.reminder_footer", value: "Reminders fire at 8:30 tomorrow morning by default. Swipe a card to decide faster.",
                              comment: "To-do board footer about notifications")
        }
    }

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
        /// ★ 2026-10-23: the timestamped chapter outline job (来源 → 大纲).
        static var kindOutline: String {
            NSLocalizedString("jobs.kind_outline", value: "Outline",
                              comment: "Task list: a chapter-outline generation job")
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
        /// ★ 2026-10-22 (任务三): AiTask recovery verdict at launch.
        static var interrupted: String {
            NSLocalizedString("jobs.ai_task_interrupted",
                              value: "Interrupted — the app was closed before this step finished.",
                              comment: "AiTask row: pipeline died with the process")
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
    // MARK: - Phone recording (任务一, 2026-10-22)

    /// Strings for the phone-microphone recording screen + live captions.
    enum Phone {
        static var modeDevice: String {
            NSLocalizedString("phone.mode_device", value: "Device", comment: "Live tab segment: record from a connected recorder")
        }
        static var modePhone: String {
            NSLocalizedString("phone.mode_phone", value: "Phone", comment: "Live tab segment: record with the phone microphone")
        }
        static var record: String {
            NSLocalizedString("phone.record", value: "Record", comment: "Phone record button")
        }
        static var stop: String {
            NSLocalizedString("phone.stop", value: "Stop", comment: "Phone stop button")
        }
        static var idle: String {
            NSLocalizedString("phone.idle", value: "Ready", comment: "Status pill when the phone recording is not running")
        }
        static var listening: String {
            NSLocalizedString("phone.listening", value: "Listening… captions will appear as speech is recognised.",
                              comment: "Caption placeholder while recording and no text yet")
        }
        static var idleCaption: String {
            NSLocalizedString("phone.idle_caption", value: "Tap the microphone to record. Live captions appear while you speak.",
                              comment: "Caption placeholder before any recording")
        }
        static var micDenied: String {
            NSLocalizedString("phone.mic_denied", value: "Microphone access is denied. Enable it in Settings to record.",
                              comment: "Phone recording blocked by TCC")
        }
        static var noInput: String {
            NSLocalizedString("phone.no_input", value: "No microphone is available on this device.",
                              comment: "Phone recording: audio input missing")
        }
        static var conversionUnavailable: String {
            NSLocalizedString("phone.conversion_unavailable", value: "Audio conversion is unavailable on this device.",
                              comment: "Phone recording: PCM converter could not be built")
        }
        static var captionUnavailable: String {
            NSLocalizedString("phone.caption_unavailable",
                              value: "No speech service is configured, so captions are off. The recording itself is unaffected.",
                              comment: "Live captions could not start; recording continues")
        }
        static var savedToLibrary: String {
            NSLocalizedString("phone.saved", value: "Saved to Library", comment: "Toast after the phone recording is stored")
        }
        /// ★ 2026-11-06：麦克风权限的前置说明（系统弹窗之前的一屏）。
        static var micPrimerTitle: String {
            NSLocalizedString("phone.mic_primer_title", value: "Record with the phone microphone",
                              comment: "Pre-permission explainer title")
        }
        static var micPrimerBody: String {
            NSLocalizedString("phone.mic_primer_body",
                              value: "Nomily records audio to transcribe it. Audio stays on this phone unless you have configured a cloud speech service.",
                              comment: "Pre-permission explainer: why the mic is needed, where audio goes")
        }
    }

    // MARK: - 声纹（★ 2026-11-04）

    /// 用户本人的说话人标签。声纹匹配成功时，转写里那个说话人会被改成这个名字。
    enum Voiceprint {
        static var selfLabel: String {
            NSLocalizedString("voiceprint.self_label", value: "我",
                              comment: "Speaker label used when the voiceprint identifies the user")
        }
        static var title: String {
            NSLocalizedString("voiceprint.title", value: "声纹",
                              comment: "Watch menu entry / phone settings section title")
        }
        static var statusEnrolled: String {
            NSLocalizedString("voiceprint.status_enrolled", value: "已录入声纹",
                              comment: "Status: a voiceprint exists")
        }
        static var statusMissing: String {
            NSLocalizedString("voiceprint.status_missing", value: "未录入声纹",
                              comment: "Status: no voiceprint yet")
        }
        /// 手表上要朗读的示例句。刻意是一段正常语速的会议开场白——
        /// 用"啊——啊——"录出来的声纹，和真实说话时的声道状态不一样。
        static var enrollScript: String {
            NSLocalizedString("voiceprint.enroll_script",
                              value: "今天上午我们先过一下这周的进度，然后确认下个月的排期。",
                              comment: "Sentence the user reads aloud when enrolling their voiceprint")
        }
        static var enrollHint: String {
            NSLocalizedString("voiceprint.enroll_hint",
                              value: "安静环境下，用平常的语速读完这句。",
                              comment: "Instruction above the enrollment script")
        }
        static var enrollStart: String {
            NSLocalizedString("voiceprint.enroll_start", value: "开始录音",
                              comment: "Button that starts voiceprint enrollment")
        }
        static var enrollStop: String {
            NSLocalizedString("voiceprint.enroll_stop", value: "完成",
                              comment: "Button that finishes voiceprint enrollment")
        }
        static var enrolling: String {
            NSLocalizedString("voiceprint.enrolling", value: "录音中…",
                              comment: "Enrollment in progress")
        }
        static var sent: String {
            NSLocalizedString("voiceprint.sent", value: "已发送到 iPhone，稍后完成注册",
                              comment: "Shown after the watch sends the enrollment sample")
        }
        /// ★ 2026-11-06：样本已发出后，小号的"重录"出口（大的开始按钮此时不显示）。
        static var rerecord: String {
            NSLocalizedString("voiceprint.rerecord", value: "重新录制",
                              comment: "Small secondary button: discard state and record a new sample")
        }
        /// ★ 2026-11-06：手机端注册失败的回执文案（手表端显示）。
        static var failed: String {
            NSLocalizedString("voiceprint.failed", value: "iPhone 没能注册这条样本，请再录一次。",
                              comment: "Phone reported the enrollment failed")
        }
        static var done: String {
            NSLocalizedString("voiceprint.done", value: "声纹已更新", comment: "Phone finished enrolling")
        }
        static var removed: String {
            NSLocalizedString("voiceprint.removed", value: "已删除声纹", comment: "Voiceprint deleted")
        }
        static var remove: String {
            NSLocalizedString("voiceprint.remove", value: "删除声纹", comment: "Delete the stored voiceprint")
        }
        static var explain: String {
            NSLocalizedString("voiceprint.explain",
                              value: "录一段自己的声音，之后转写会把你认出来、标成「我」。同一条录音里别人的话不受影响。",
                              comment: "One-paragraph explanation on the settings page")
        }
        static func sampleInfo(_ seconds: Int, source: String) -> String {
            String(format: NSLocalizedString("voiceprint.sample_info", value: "%@ · 有效语音 %d 秒",
                                             comment: "Voiceprint status line: device it was recorded on, voiced seconds"),
                   source, seconds)
        }
        static var deviceWatch: String {
            NSLocalizedString("voiceprint.device_watch", value: "手表录制",
                              comment: "Where the voiceprint sample came from")
        }
        static var devicePhone: String {
            NSLocalizedString("voiceprint.device_phone", value: "手机录制",
                              comment: "Where the voiceprint sample came from")
        }
        static var unreadable: String {
            NSLocalizedString("voiceprint.error_unreadable", value: "这段音频读不了，换个格式再试。",
                              comment: "Voiceprint enrollment failed: audio could not be decoded")
        }
        static var tooShort: String {
            NSLocalizedString("voiceprint.error_short", value: "样本太短，至少要说三秒。",
                              comment: "Voiceprint enrollment failed: sample too short")
        }
        static var noSpeech: String {
            NSLocalizedString("voiceprint.error_nospeech", value: "没听到清晰的人声，安静一点再录一次。",
                              comment: "Voiceprint enrollment failed: no voiced frames")
        }
        static var identityFooter: String {
            NSLocalizedString("voiceprint.identity_footer",
                              value: "识别在本机完成，声音样本不会上传到任何服务器。",
                              comment: "Privacy footer under the voiceprint section")
        }
    }
}

// swiftlint:enable type_body_length file_length

/// ★ 2026-11-09（用户："可以选择上传哪些"）：每个目的地的产物开关
/// （WebDAV 编辑页与文件夹导出页共用同一组词条）。
enum L10nUploadContent {
    static var section: String {
        NSLocalizedString("upload.section", value: "What to Upload",
                          comment: "Storage destination: header of the per-artefact toggles")
    }
    static var footer: String {
        NSLocalizedString("upload.footer", value: "Pick what lands in this destination. Recording audio has its own switch above.",
                          comment: "Storage destination: footer of the per-artefact toggles")
    }
    static var transcript: String {
        NSLocalizedString("upload.transcript", value: "Transcript Text", comment: "Artefact toggle: the plain-text transcript")
    }
    static var asr: String {
        NSLocalizedString("upload.asr", value: "Transcription Data", comment: "Artefact toggle: the JSON with timing/speaker metadata")
    }
    static var summary: String {
        NSLocalizedString("upload.summary", value: "Summary", comment: "Artefact toggle: the summary markdown")
    }
    static var todos: String {
        NSLocalizedString("upload.todos", value: "To-dos", comment: "Artefact toggle: the to-do list")
    }
    static var mindMap: String {
        NSLocalizedString("upload.mind_map", value: "Mind Map", comment: "Artefact toggle: the rendered mind-map image")
    }
    static var chapters: String {
        NSLocalizedString("upload.chapters", value: "Chapters", comment: "Artefact toggle: the chapter timeline")
    }
    static var bundle: String {
        NSLocalizedString("upload.bundle", value: "Resource Bundle (zip)", comment: "Artefact toggle: the all-in-one zip")
    }
}

/// ★ 2026-11-09（用户："英文语言展示中文需要优化"）：录音豆 Wi‑Fi 快传整条
/// 流程原来是硬编码中文——英文界面下全部漏中文。统一收进这一组词条。
extension L10n {
    enum WifiXfer {
    static var statusSection: String { NSLocalizedString("wifix.status_section", value: "Status", comment: "") }
    static var hotspotSection: String { NSLocalizedString("wifix.hotspot_section", value: "Recorder Hotspot", comment: "") }
    static var hotspotName: String { NSLocalizedString("wifix.hotspot_name", value: "Hotspot", comment: "") }
    static var password: String { NSLocalizedString("wifix.password", value: "Password", comment: "") }
    static func filesPending(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.files_pending", value: "Files to transfer (%d)", comment: ""), n)
    }
    static var foregroundHint: String { NSLocalizedString("wifix.foreground_hint", value: "Keep this page in the foreground during the transfer — avoid locking the screen for long.", comment: "") }
    static var cancelTransfer: String { NSLocalizedString("wifix.cancel_transfer", value: "Cancel Transfer", comment: "") }
    static var close: String { NSLocalizedString("wifix.close", value: "Close", comment: "") }
    static var navTitle: String { NSLocalizedString("wifix.nav_title", value: "Wi\u{2011}Fi Quick Transfer", comment: "") }
    static var waiting: String { NSLocalizedString("wifix.waiting", value: "Waiting", comment: "") }
    static var savedLibrary: String { NSLocalizedString("wifix.saved_library", value: "Saved to Library", comment: "") }

    static var stagePreparing: String { NSLocalizedString("wifix.stage_preparing", value: "Preparing\u{2026}", comment: "") }
    static var stageConfigHotspot: String { NSLocalizedString("wifix.stage_config_hotspot", value: "Setting up the recorder\u{2019}s hotspot\u{2026}", comment: "") }
    static var stageJoinHotspot: String { NSLocalizedString("wifix.stage_join_hotspot", value: "Joining the recorder\u{2019}s hotspot\u{2026}", comment: "") }
    static var stageConnecting: String { NSLocalizedString("wifix.stage_connecting", value: "Connecting to the recorder\u{2026}", comment: "") }
    static var stageTransferring: String { NSLocalizedString("wifix.stage_transferring", value: "Transferring", comment: "") }
    static var stageDone: String { NSLocalizedString("wifix.stage_done", value: "Transfer Complete", comment: "") }
    static var stageFailed: String { NSLocalizedString("wifix.stage_failed", value: "Transfer Failed", comment: "") }
    static var stageCancelled: String { NSLocalizedString("wifix.stage_cancelled", value: "Cancelled", comment: "") }
    static func partialSaved(_ pct: Int) -> String {
        String(format: NSLocalizedString("wifix.partial_saved", value: "Partial saved (received %d%%)", comment: ""), pct)
    }

    static var manualJoinTitle: String { NSLocalizedString("wifix.manual_join_title", value: "Join the recorder\u{2019}s hotspot manually", comment: "") }
    static func manualJoinMessage(_ ssid: String, _ psk: String) -> String {
        String(format: NSLocalizedString("wifix.manual_join_message", value: "iOS couldn\u{2019}t join \u{201C}%@\u{201D} automatically.\n\nGo to Settings \u{2192} Wi\u{2011}Fi, pick \u{201C}%@\u{201D} and enter the password: %@\n\nReturn to Nomily when done \u{2014} it continues automatically (up to 3 minutes).", comment: "ssid, ssid, password"), ssid, ssid, psk)
    }
    static var goSettings: String { NSLocalizedString("wifix.go_settings", value: "Open Settings", comment: "") }
    static var joinedContinue: String { NSLocalizedString("wifix.joined_continue", value: "Joined \u{2014} Continue", comment: "") }

    static func clipNamed(_ name: String) -> String {
        String(format: NSLocalizedString("wifix.clip_named", value: "Recording %@", comment: ""), name)
    }
    static var stop: String { NSLocalizedString("wifix.stop", value: "Stop", comment: "") }

    static var pickTitle: String { NSLocalizedString("wifix.pick_title", value: "Select Recordings to Transfer", comment: "") }
    static var pickHintEmpty: String { NSLocalizedString("wifix.pick_hint_empty", value: "Pick the takes you want, then use Wi\u{2011}Fi quick transfer.", comment: "") }
    static func pickHint(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.pick_hint", value: "Pick which of the %d takes to send \u{2014} Wi\u{2011}Fi quick transfer beats Bluetooth by far", comment: ""), n)
    }
    static var exportAllA11y: String { NSLocalizedString("wifix.export_all_a11y", value: "Export all recordings via Wi\u{2011}Fi quick transfer", comment: "") }
    static func selectedCount(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.selected_count", value: "%d selected", comment: ""), n)
    }
    static var selectAll: String { NSLocalizedString("wifix.select_all", value: "Select All", comment: "") }
    static var deselectAll: String { NSLocalizedString("wifix.deselect_all", value: "Deselect All", comment: "") }
    static var cancel: String { NSLocalizedString("wifix.cancel", value: "Cancel", comment: "") }
    static func transferSelected(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.transfer_selected", value: "Transfer selected (%d)", comment: ""), n)
    }

    static var errNotConnected: String { NSLocalizedString("wifix.err_not_connected", value: "Recorder not connected \u{2014} connect first and retry.", comment: "") }
    static var errEmpty: String { NSLocalizedString("wifix.err_empty", value: "No recordings on the recorder", comment: "") }
    static var errPickedGone: String { NSLocalizedString("wifix.err_picked_gone", value: "The selected recordings are no longer on the recorder (they may have been transferred by Feishu or auto-delete).", comment: "") }
    static var errNothingExportable: String { NSLocalizedString("wifix.err_nothing_exportable", value: "No recordings to export", comment: "") }
    static func reconnectAttempt(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.reconnect_attempt", value: "Reconnecting to the recorder via Bluetooth (attempt %d/3)\u{2026}", comment: ""), n)
    }
    static func reconnectDetail(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.reconnect_detail", value: "Bluetooth dropped \u{2014} reconnecting to the recorder (attempt %d/3)\u{2026}", comment: ""), n)
    }
    static func waitHotspot(_ ssid: String) -> String {
        String(format: NSLocalizedString("wifix.wait_hotspot", value: "Waiting for you to join the hotspot \u{201C}%@\u{201D} manually\u{2026}", comment: ""), ssid)
    }
    static func partialSkipped(_ pct: Int) -> String {
        String(format: NSLocalizedString("wifix.partial_skipped", value: "Only %d%% received \u{2014} skipped", comment: ""), pct)
    }
    static func partialNote(_ pct: Int) -> String {
        String(format: NSLocalizedString("wifix.partial_note", value: " \u{00b7} partial transfer (%d%%)", comment: ""), pct)
    }
    static var noteWifi: String { NSLocalizedString("wifix.note_wifi", value: " \u{00b7} Wi\u{2011}Fi quick transfer", comment: "") }
    static var noteWifiD3200: String { NSLocalizedString("wifix.note_wifi_d3200", value: "Opus 48 kHz mono (D3200 \u{00b7} Wi\u{2011}Fi quick transfer)", comment: "") }
    static var reconnecting: String { NSLocalizedString("wifix.reconnecting", value: "Reconnecting to the recorder\u{2026}", comment: "") }
    static func exportedReport(_ saved: Int, _ total: Int) -> String {
        String(format: NSLocalizedString("wifix.exported_report", value: "Exported %d/%d recordings to the library", comment: ""), saved, total)
    }
    static func deletedNote(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.deleted_note", value: ", deleted %d from the recorder", comment: ""), n)
    }
    static func deleteFailedNote(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.delete_failed_note", value: ", %d couldn\u{2019}t be deleted from the recorder (an in-progress recording can\u{2019}t be deleted)", comment: ""), n)
    }
    static var deleteBtNote: String { NSLocalizedString("wifix.delete_bt_note", value: "; Bluetooth didn\u{2019}t come back \u{2014} recordings remain on the recorder", comment: "") }
    static var autoDeletedNote: String { NSLocalizedString("wifix.auto_deleted_note", value: "; that take is already gone \u{2014} the firmware auto-deletes fully transferred recordings regardless of the delete switch (it is in the library)", comment: "") }
    static func partialResumableNote(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.partial_resumable_note", value: " (%d partially received and checkpointed \u{2014} tapping Wi\u{2011}Fi quick transfer again resumes instead of re-uploading)", comment: ""), n)
    }
    static func partialSkippedNote(_ n: Int) -> String {
        String(format: NSLocalizedString("wifix.partial_skipped_note", value: " (%d received almost nothing and were skipped \u{2014} retry available)", comment: ""), n)
    }
    static var interrupted: String { NSLocalizedString("wifix.interrupted", value: "Transfer interrupted", comment: "") }
    static var interruptedAdvice: String { NSLocalizedString("wifix.interrupted_advice", value: ". Keep the recorder nearby with enough battery and not occupied by the Feishu app. If joining the hotspot keeps failing, join the recorder\u{2019}s hotspot manually in Settings \u{2192} Wi\u{2011}Fi and retry.", comment: "") }
    static var batteryCase: String { NSLocalizedString("wifix.battery_case", value: "Charging case", comment: "") }
    }
}
