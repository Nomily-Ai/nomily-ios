import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var watch: WatchSyncService
    @EnvironmentObject private var localization: LocalizationService
    /// Background job queue. For why it's injected separately see the `.environmentObject`
    /// block in `NomilyApp`: a nested `ObservableObject`'s `@Published` won't invalidate
    /// views that only observe the parent, so going through `env.jobs` would leave the entry badge stuck on its old value forever.
    @EnvironmentObject private var jobs: JobQueue
    /// The number of items sitting in the trash is shown on the right of that row, so it has to be observed — delete
    /// one on the detail page and come back to the settings page, and the number has to follow.
    @ObservedObject private var trash = ClipTrash.shared
    @State private var versionTapCount = 0
    @State private var versionTapResetTask: Task<Void, Never>?
    @State private var devModeToast: String?

    private static let tapsToToggle = 7
    private static let tapsBeforeHint = 3

    /// Jobs not finished yet: summary / translation / format conversion (`jobs`) + transcription (`transcription`).
    ///
    /// **Both** kinds count: the entry badge answers "is anything still busy in the background", and leaving transcription out
    /// would show a blank entry when only transcription is queued, making people think the page is empty.
    private var busyJobCount: Int {
        jobs.unfinishedCount + env.transcription.pending.count
    }

    /// One settings row: a coloured glyph tile, the title, and an optional right-hand
    /// detail (current value) or count (badge).
    ///
    /// 2026-10-22 ("按照苹果的简约风格来"): the rows used to be bare
    /// `NavigationLink(title)`s, so ten items of six different kinds read as one
    /// undifferentiated list. The tile gives each area a shape to recognise and
    /// makes the groups scan vertically instead of requiring the labels to be read.
    @ViewBuilder
    private func settingsRow<D: View>(
        _ title: String,
        icon: String,
        tint: Color,
        detail: String? = nil,
        count: Int? = nil,
        @ViewBuilder destination: () -> D
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).foregroundStyle(.secondary)
                }
                if let count {
                    Text("\(count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    var body: some View {
        Form {
            // ★ 2026-10-22 ("按照苹果的简约风格来"): one flat Section held ten
            // rows in no particular order, so "where do I change the ASR vendor"
            // was a full-page scan. Now four groups, each a place the user would
            // look for that thing: what records, what generates text, the files
            // themselves, and how the app behaves.
            Section {
                settingsRow(L10n.Settings.recordings, icon: "waveform", tint: .blue) {
                    RecordingsSettingsView()
                }
                settingsRow(L10n.Settings.asrProviders, icon: "text.bubble", tint: .indigo) {
                    ASRProvidersView()
                }
            } header: {
                Text(L10n.Settings.groupCapture)
            }

            Section {
                settingsRow(L10n.Settings.llmProviders, icon: "sparkles", tint: .purple) {
                    LLMProvidersView()
                }
                settingsRow(L10n.Settings.summarizeTemplates, icon: "doc.text", tint: .teal) {
                    SummarizeTemplatesView()
                }
            } header: {
                Text(L10n.Settings.groupGenerate)
            }

            Section {
                settingsRow(L10n.Settings.devicesAndLibrary, icon: "externaldrive", tint: .orange) {
                    DevicesLibraryView()
                }
                // ⛔ PLAUD lives on Recordings → Device, not here (2026-10-21): it is
                // a device-scoped feature, not an app-wide setting. DingTalk A1 is
                // likewise **not** here (2026-10-18): its credential belongs only on
                // that card's own device-info page, because from Settings a
                // card-shaped secret reads as account-level and people paste the
                // wrong card's key.
                settingsRow(L10n.Trash.settingsRow, icon: "trash", tint: .gray,
                            count: trash.items.isEmpty ? nil : trash.items.count) {
                    TrashView()
                }
                settingsRow(L10n.Jobs.openQueue, icon: "clock.arrow.circlepath", tint: .green,
                            count: busyJobCount > 0 ? busyJobCount : nil) {
                    TaskCenterView()
                }
            } header: {
                Text(L10n.Settings.groupLibrary)
            }

            Section {
                settingsRow(L10n.Settings.language, icon: "globe", tint: .cyan,
                            detail: currentLanguageLabel) {
                    LanguagePickerView()
                }
                settingsRow(L10n.Settings.theme, icon: "circle.lefthalf.filled", tint: currentTheme.accent,
                            detail: currentTheme.title) {
                    ThemePickerView()
                }
            } header: {
                Text(L10n.Settings.groupGeneral)
            }

            watchSection
                .id("watch-\(localization.effective)")

            aboutSection
        }
        // ★ 2026-10-22 ("设置里面顶部的录音与转写被顶部遮挡住了"): this Form carried
        // `.padding(.top, -20)` — a leftover from when the page had no navigation
        // title (it pulled the empty nav-bar strip away). The bar now shows a
        // principal title, so the same -20 slid the first section header *under*
        // it and the group header was clipped. The nav bar reserves its own space;
        // no compensation needed.
        .navigationTitle("")
        .navigationDestination(isPresented: $env.navigateToASRProviders) {
            ASRProvidersView()
        }
        .navigationDestination(isPresented: $env.navigateToLLMProviders) {
            LLMProvidersView()
        }
        .navigationDestination(isPresented: $env.navigateToRecordingsSettings) {
            RecordingsSettingsView()
        }
        .onDisappear { configService.saveNow() }
    }

    /// The watch app ships inside this one, so there's nothing to download —
    /// but that's exactly why it needs explaining. iOS installs it on its own
    /// only when "Automatic App Install" is on, and otherwise leaves it sitting
    /// in the Watch app's Available Apps list with no notification.
    ///
    /// ★ 2026-10-16 revision thirteen: this section gained a **Home Face** row (at the time an independent row +
    /// independent Section).
    ///
    /// ★★ 2026-10-16 revision fifteen: those two rows were **merged into one** (user's words: "add the watch
    ///   home-screen expression to the Nomily AI app's watch settings; tapping Apple Watch there is the menu bar,
    ///   and when it is installed a tap goes into the expression settings -- merge it rather than giving the watch its own expression menu bar;
    ///   and when it is not installed, a tap jumps to the phone's Watch app").
    ///
    /// So this row now branches on **whether the watch App is installed**:
    ///   · **Installed** — a `NavigationLink` into the expression picker, with the current option's name on the right;
    ///   · **Not installed** (including a watch that isn't paired) — becomes a button that **jumps to the
    ///     "Watch" App on the iPhone**, to install it there (the right side keeps the original status text, plus an "opens elsewhere" badge).
    ///
    /// ⚠️ Why merging is right: install state and expression setting are two things about the **same object** to begin with,
    ///    and once split into two rows the user sees no way out on the "not installed" row — that row can only be looked at,
    ///    not tapped, while "what to do" is buried in a long footer. After the merge, "what happens when
    ///    you tap this row" and "its current state" land in the same place.
    ///
    /// ⚠️ The check uses `isWatchAppInstalled` **and** `isActivated`: before activation completes that
    ///    flag is necessarily `false` (see the top of `WatchSyncService`), and looking at it alone would misjudge
    ///    the first few seconds after launch as "not installed", so a single tap throws the user over to the Watch App.
    private var watchSection: some View {
        Section {
            watchRow
        } footer: {
            // The two sentences each do their own job: one says what this row is now (pick an expression),
            // the other says what state the watch side is in (installed or not / connected or not).
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Face.rowFooter)
                Text(watchFooter)
            }
        }
    }

    /// The single row of this section. For the three forms see the block above `watchSection`.
    @ViewBuilder
    private var watchRow: some View {
        if watch.isActivated, watch.isPaired, watch.isWatchAppInstalled {
            NavigationLink {
                WatchFacePickerView()
            } label: {
                watchRowLabel(trailing: chosenFaceTitle, leavesTheApp: false)
            }
        } else if watch.isActivated, isWatchAppReachableOnThisOS {
            // Not installed (or not paired) — tap to go handle it in the Watch App. Unpaired also goes here:
            // the Watch App is exactly where you pair.
            //
            // ⚠️ This branch requires `isActivated`: before activation `isWatchAppInstalled` is necessarily
            //    `false`, and offering a button then would throw the user to the
            //    Watch App in the first few seconds after launch — when the watch App was installed long ago. For those seconds, honestly be a
            //    read-only status row ("Checking…").
            Button(action: openWatchApp) {
                watchRowLabel(trailing: watchStatus, leavesTheApp: true)
            }
            // ⚠️ `.plain` rather than the default style: the default tints the whole row's text and label blue,
            //    which would make this row differ from every row above and below in font size and weight.
            .buttonStyle(.plain)
        } else {
            // Not activated yet, or on iOS 16 this feature can never become ready
            // (see `isWatchAppReachableOnThisOS`): honestly be a read-only status row,
            // don't offer a button that does nothing when tapped.
            watchRowLabel(trailing: watchStatus, leavesTheApp: false)
        }
    }

    /// The row's content. `trailing` is the status/current value on the right.
    ///
    /// ⚠️ The icon uses `Label` rather than an `Image` + `Text` pair: `Label` automatically aligns the symbol
    ///    to the text baseline, whereas a hand-rolled pair has to be adjusted by hand across dynamic type sizes.
    private func watchRowLabel(trailing: String, leavesTheApp: Bool) -> some View {
        HStack {
            Label(L10n.Watch.settingsTitle, systemImage: "applewatch")
            Spacer()
            Text(trailing)
                .foregroundStyle(.secondary)
            if leavesTheApp {
                // A badge for "this jumps to another App". Without it this row looks like the
                // `NavigationLink`s above, and the user is baffled when tapping leaves "the whole App switched away".
                Image(systemName: "arrow.up.forward.app")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Open the "Watch" App on the iPhone — when the watch App isn't installed, the user has to tap install there.
    ///
    /// ## Why not `canOpenURL`
    /// `itms-watchs://` is a system App's private scheme; unless it's listed in `LSApplicationQueriesSchemes`,
    /// `canOpenURL` **always** returns `false` (the query restriction since iOS 9) —
    /// using it as a pre-check would make this button dead on every device. So `open` directly
    /// and use its completion callback to tell whether it worked.
    private func openWatchApp() {
        guard let url = URL(string: "itms-watchs://") else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened,
                  let fallback = URL(string: UIApplication.openSettingsURLString)
            else { return }
            // If it can't open (say there's no Watch App on iPad), fall back to **this App's settings page**:
            // there you can at least dig up permissions like "Microphone". Better than "tap and nothing happens".
            UIApplication.shared.open(fallback)
        }
    }

    /// The name shown on the right of that row — the localised name of the current option.
    ///
    /// Same as the language row: you know what's set without tapping in.
    private var chosenFaceTitle: String {
        (BotFaceStyle.decode(configService.config.watchFaceStyle) ?? .calm).title
    }

    /// The bundled watch app needs watchOS 10, and watchOS 10 only pairs with
    /// iPhones on iOS 17 — so on iOS 16 the section can never light up. Say so
    /// instead of leaving the row parked on "no watch paired".
    private var isWatchAppReachableOnThisOS: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    private var watchStatus: String {
        guard isWatchAppReachableOnThisOS else { return L10n.Watch.statusUnsupported }
        guard watch.isActivated else { return L10n.Watch.statusChecking }
        guard watch.isPaired else { return L10n.Watch.statusNoWatch }
        guard watch.isWatchAppInstalled else { return L10n.Watch.statusNotInstalled }
        // Reachable means the watch app is up and messages will get through
        // right now — the only "connected" this link actually has.
        return watch.isReachable ? L10n.Watch.statusConnected : L10n.Watch.statusInstalled
    }

    private var watchFooter: String {
        guard isWatchAppReachableOnThisOS else { return L10n.Watch.hintUnsupported }
        guard watch.isActivated else { return L10n.Watch.hintChecking }
        guard watch.isPaired else { return L10n.Watch.hintNoWatch }
        return watch.isWatchAppInstalled
            ? L10n.Watch.hintInstalled
            : L10n.Watch.hintNotInstalled
    }

    private var aboutSection: some View {
        Section {
            // HStack + tap gesture rather than LabeledContent so the
            // whole row (including empty trailing space) is the hit
            // target — users shouldn't have to aim for the version
            // string itself.
            HStack {
                Text(L10n.Settings.version)
                Spacer()
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { handleVersionTap() }

            if let devModeToast {
                Text(devModeToast)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if configService.config.isDeveloperMode {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                    Text(L10n.DeveloperMode.statusOn)
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } header: {
            Text(L10n.Settings.about)
        }
    }

    /// What the Language row shows on the right — the **effective** language,
    /// not the raw stored tag (see `LanguagePickerView.effective`).
    private var currentLanguageLabel: String {
        guard let tag = configService.config.appLanguage else { return L10n.Language.followSystem }
        return AppLanguage.autonym(of: AppLanguage.resolve(tag))
    }

    /// Which palette the app is actually rendering with. Same "resolve, don't
    /// trust the tag" rule as the language row: an unknown tag from a newer
    /// build resolves to the default, and the row must show what's on screen.
    private var currentTheme: AppTheme {
        AppTheme.resolve(configService.config.appTheme)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    /// Classic "tap the version seven times" easter egg. Taps reset
    /// after 2 s of inactivity so stray touches don't accumulate.
    /// When dev mode is already on, the same gesture turns it off so
    /// it's symmetric — no second hidden path needed.
    private func handleVersionTap() {
        versionTapCount += 1
        versionTapResetTask?.cancel()

        if versionTapCount >= Self.tapsToToggle {
            versionTapCount = 0
            configService.config.isDeveloperMode.toggle()
            configService.scheduleSave()
            let isOn = configService.config.isDeveloperMode
            withAnimation {
                devModeToast = isOn ? L10n.DeveloperMode.toastEnabled : L10n.DeveloperMode.toastDisabled
            }
            scheduleToastClear(after: 2)
            return
        }

        let remaining = Self.tapsToToggle - versionTapCount
        if versionTapCount >= Self.tapsBeforeHint {
            withAnimation {
                devModeToast = configService.config.isDeveloperMode
                    ? L10n.DeveloperMode.tapsToDisable(remaining)
                    : L10n.DeveloperMode.tapsToEnable(remaining)
            }
        }

        versionTapResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                versionTapCount = 0
                withAnimation { devModeToast = nil }
            }
        }
    }

    private func scheduleToastClear(after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation { devModeToast = nil }
            }
        }
    }
}

// MARK: - ASR Providers

struct ASRProvidersView: View {
    @EnvironmentObject private var configService: ConfigService
    /// 2026-10-15: to read the transcription queue state (`pending` / `inFlight`).
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    /// Active connectivity test for the local server (added 2026-10-13).
    /// `detail` / `warning` are separated: `VerifyState.success` carries no value,
    /// And after "connected", a detail line and a warning line for "a port did not respond" must be shown.
    @State private var localProbe: VerifyState = .idle
    @State private var localProbeDetail: String?
    @State private var localProbeWarning: String?
    @State private var showLeaveWarning = false
    /// Connectivity/auth test for the custom (OpenAI-compatible) server.
    @State private var customProbe: VerifyState = .idle
    @State private var customProbeDetail: String?
    /// ★ 2026-10-20: connectivity/auth test for the remote live (WSS) server.
    @State private var remoteProbe: VerifyState = .idle
    @State private var remoteProbeDetail: String?
    // ★ 2026-10-23: cloud-vendor sheets live here, not on `ASRCloudSection` —
    // a sheet attached to a Form Section gets cancelled whenever the section's
    // subtree re-renders during presentation (config writes, AppEnvironment
    // publishes), which showed up as "sheet flashes open then closes".
    @State private var editingCloud: ASRCloudSpec?
    @State private var showAzureSheet = false

    /// When the user provides a host but omits the port, a default port is supplied. **Only written when creating the record**,
    // and not used as the displayed value for an empty field.
    private static let defaultLocalPort = 12300

    var body: some View {
        Form {
            transcriptionSection
            // ★ 2026-10-22 ("ASR 里面 Azure Speech 这个没有在云转写里面"):
            // Azure's own section used to sit here, **above** the cloud list — so
            // the only vendor that can actually transcribe was the one missing
            // from "云转写". It is now the first row of `ASRCloudSection` (its
            // sheet is `AzureSpeechSheet`), which keeps one list of cloud vendors
            // instead of two places writing the same credentials.
            ASRCloudSection(editing: $editingCloud, showAzure: $showAzureSheet)
            localSection
            customSection
            remoteLiveSection
        }
        .sheet(item: $editingCloud) { spec in
            ASRCloudSheet(spec: spec)
                .environmentObject(configService)
        }
        .sheet(isPresented: $showAzureSheet) {
            AzureSpeechSheet()
                .environmentObject(configService)
        }
        .navigationTitle(L10n.Settings.asrProviders)
        .navigationBarTitleDisplayMode(.inline)
        // Partial or unverified configurations are excluded from transcription; report this before returning so the user isn’t surprised during transcription.
        .navigationBarBackButtonHidden(azureNeedsAttention)
        .toolbar {
            if azureNeedsAttention {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showLeaveWarning = true } label: {
                        Image(systemName: "chevron.backward")
                    }
                }
            }
        }
        .alert(L10n.ASR.leaveTitle, isPresented: $showLeaveWarning) {
            Button(L10n.ASR.leaveAnyway, role: .destructive) { dismiss() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(azureIncomplete ? L10n.ASR.leaveIncompleteMessage : L10n.ASR.leaveUnverifiedMessage)
        }
    }

    /// Either partially filled, or fully filled but the credentials have never been verified — neither case should exit silently.
    private var azureNeedsAttention: Bool {
        let azure = configService.config.asrProviders.azure
        let key = azure?.key ?? ""
        let region = azure?.region ?? ""
        if key.isEmpty && region.isEmpty { return false }   // If not configured at all, it’s not considered partial.
        return azureIncomplete || azure?.verification != true
    }

    private var azureIncomplete: Bool {
        azureKeyMissing || azureRegionMissing
    }

    private var configuredASR: [(key: String, label: String)] {
        var result: [(String, String)] = []
        // On-device first: it needs no credentials, so it is the only entry that is always
        // available and the one most users will want as the active service.
        if configService.config.onDeviceASREnabled {
            result.append(("ondevice", L10n.ASR.onDevice))
        }
        // Only list services that are fully filled **and** whose credentials have not been rejected by verification: partially filled configs and those that failed verification would produce no transcription, and showing them as candidates would mislead users into thinking they are set up.
        // ★ 2026-10-22: Aliyun is wired into file transcription (`AliyunFileASR`),
        // so it joins the picker once the AK pair + Appkey + OSS bucket are all
        // in — the primary market for this app transcribes Chinese, so it leads
        // the cloud entries.
        if let c = configService.config.asrProviders.cloud?["aliyun"],
           !(c.secrets?["accessKeyId"] ?? "").isEmpty,
           !(c.secrets?["accessKeySecret"] ?? "").isEmpty,
           !(c.values?["appKey"] ?? "").isEmpty,
           !(c.values?["ossBucket"] ?? "").isEmpty {
            result.append(("aliyun", L10n.ASR.aliyun))
        }
        if let a = configService.config.asrProviders.azure,
           !a.key.isEmpty, !a.region.isEmpty, a.verification != false {
            result.append(("azure", L10n.ASR.azure))
        }
        if let l = configService.config.asrProviders.local, !l.host.isEmpty {
            result.append(("local", L10n.ASR.localServer))
        }
        if let c = configService.config.asrProviders.custom, !c.endpoint.isEmpty {
            result.append(("custom", L10n.ASR.customServer))
        }
        // ★ 2026-10-20: the remote live server serves **live** transcription; it is
        // offered here so the live chain can pick it as primary/fallback. The file
        // chain ignores the key "remote" (`TranscriptionService.hasCredentials`
        // returns false for it), so choosing it never breaks file transcription.
        if let r = configService.config.asrProviders.remoteLive, !r.endpoint.isEmpty {
            result.append(("remote", L10n.ASR.remoteLive))
        }
        return result
    }

    private var transcriptionSection: some View {
        Section {
            if !configuredASR.isEmpty {
                Picker(L10n.ASR.activeProvider, selection: primaryBinding) {
                    ForEach(configuredASR, id: \.key) { Text($0.label).tag($0.key) }
                }
            }

            Toggle(isOn: Binding(
                get: { configService.config.autoTranscribeAfterDownload },
                set: { configService.config.autoTranscribeAfterDownload = $0; configService.scheduleSave() }
            )) {
                HStack(spacing: 4) {
                    Text(L10n.ASR.autoTranscribeAfterDownload)
                    InfoTip(text: L10n.ASR.autoTranscribeFooter)
                }
            }

            if configService.config.autoTranscribeAfterDownload {
                Stepper(
                    L10n.ASR.autoTranscribeMin(configService.config.minTranscribeDuration),
                    value: Binding(
                        get: { configService.config.minTranscribeDuration },
                        set: { configService.config.minTranscribeDuration = $0; configService.scheduleSave() }
                    ),
                    in: 0...600,
                    step: 5
                )
            }

            // ★ 2026-10-18: the phone's own offline model. Kept next to "Auto-transcribe" because both
            // answer the same question — "can I get text without setting up a cloud account".
            Toggle(isOn: Binding(
                get: { configService.config.onDeviceASREnabled },
                set: {
                    configService.config.onDeviceASREnabled = $0
                    configService.scheduleSave()
                    // Turning it off while it is the active service would leave the picker
                    // pointing at something that no longer exists; fall back to whatever is
                    // configured, or to nothing (the picker then hides itself).
                    if !$0, configService.config.defaults.asr.primary.lowercased() == "ondevice" {
                        let fallback = configuredASR.first?.key ?? ""
                        configService.config.defaults.asr.primary = fallback
                        configService.scheduleSave()
                    }
                }
            )) {
                HStack(spacing: 4) {
                    Text(L10n.ASR.onDevice)
                    InfoTip(text: L10n.ASR.onDeviceFooter)
                }
            }

            // "Summarize right after transcribing" — the LLM half of the pipeline the user asked for:
            // speech → text → summary, with no tap in between.
            Toggle(isOn: Binding(
                get: { configService.config.autoSummarizeAfterTranscription },
                set: { configService.config.autoSummarizeAfterTranscription = $0; configService.scheduleSave() }
            )) {
                HStack(spacing: 4) {
                    Text(L10n.ASR.autoSummarize)
                    InfoTip(text: L10n.ASR.autoSummarizeFooter)
                }
            }

            Toggle(isOn: Binding(
                get: { configService.config.localVADEnabled },
                set: { configService.config.localVADEnabled = $0; configService.scheduleSave() }
            )) {
                HStack(spacing: 4) {
                    Text(L10n.ASR.localVAD)
                    InfoTip(text: L10n.ASR.localVADFooter)
                }
            }

            // ★ 2026-10-15: background keep-alive.
            Toggle(isOn: Binding(
                get: { configService.config.backgroundKeepAliveEnabled },
                set: { configService.config.backgroundKeepAliveEnabled = $0; configService.scheduleSave() }
            )) {
                HStack(spacing: 4) {
                    Text(L10n.ASR.backgroundKeepAlive)
                    InfoTip(text: L10n.ASR.backgroundKeepAliveFooter)
                }
            }

            // The queue state only appears when there's really a job queued — adding an extra row while it's empty
            // is just noise (and makes people think "is it broken?").
            if !env.transcription.pending.isEmpty {
                queueStatusRow
            }
        } header: {
            Text(L10n.ASR.transcription)
        }
    }

    /// "How many are still waiting to be transcribed".
    ///
    /// Why it deserves a row: this queue is **cross-launch**. Users may simply not remember that yesterday
    /// they fed it a few recordings waiting to be transcribed, and those jobs are either quietly running or have quietly
    /// given up after three tries — without saying so, both can only be inferred from "that recording in the library never gets transcript text",
    /// and "not transcribed" and "transcription failed" look exactly alike in the list.
    private var queueStatusRow: some View {
        let pending = env.transcription.pending
        let running = pending.filter { $0.attempts < TranscriptionService.maxAttempts }.count
        let stuck = pending.count - running
        let inFlight = env.transcription.inFlight.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if inFlight > 0 {
                    ProgressView().controlSize(.mini)
                }
                Text(L10n.ASR.queueTitle)
                Spacer(minLength: 8)
                Text(
                    [
                        inFlight > 0 ? L10n.ASR.queueRunning(inFlight) : nil,
                        running - inFlight > 0 ? L10n.ASR.queueWaiting(running - inFlight) : nil,
                        stuck > 0 ? L10n.ASR.queueStuck(stuck) : nil,
                    ]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            // Only report the **first** one given up: reporting them all would stretch this Section to a full screen,
            // when what the user wants right now is "to know something is stuck", not to read every error one by one.
            if stuck > 0,
               let first = pending.first(where: { $0.attempts >= TranscriptionService.maxAttempts }) {
                Text(L10n.ASR.queueStuckDetail(
                    first.name,
                    first.attempts,
                    first.lastError ?? ""
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private var localSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                TextField(L10n.ASR.host, text: localHostBinding)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if localHostMissing {
                    fieldError(L10n.ASR.hostRequired)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField(L10n.ASR.port, text: localPortBinding)
                    .keyboardType(.numberPad)
                if localPortInvalid {
                    fieldError(L10n.ASR.portInvalid)
                }
            }
            localProbeRow
            // ★ 2026-10-20: the "I don't know what a faster-whisper server is" escape hatch.
            // Copies a one-shot prompt the user pastes into ChatGPT / Claude Code on the
            // computer that will run the server; the AI does the install and prints the
            // host/port to type above.
            SetupAssistantRow()
        } header: {
            Text(L10n.ASR.localASRServer)
        } footer: {
            Text(L10n.ASR.localProbeFooter)
        }
    }

    /// Active connectivity test.
    ///
    /// "Filled" and "connected" are two different things: service not started, port typo, phone and server not on the same
    /// network segment — these three issues are invisible before actual transcription, and transcription‑failure errors only appear in the segment detail page
    /// making attribution difficult. The Azure section already has the `verifyButton` interaction, and the local section copies it,
    /// so the two providers' "test" behavior looks identical.
    @ViewBuilder
    private var localProbeRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.ASR.localProbe)
                switch localProbe {
                case .success:
                    if let detail = localProbeDetail {
                        Text(L10n.ASR.localProbeReachable(detail))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let warning = localProbeWarning {
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                case .failed(let reason):
                    fieldError(reason)
                case .verifying:
                    Text(L10n.ASR.statusVerifying)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
            }
            Spacer()
            verifyButton(localProbe) { await runLocalProbe() }
        }
    }

    private func runLocalProbe() async {
        guard let local = configService.config.asrProviders.local,
              !local.host.isEmpty, (1...65535).contains(local.port) else {
            invalidateLocalProbe()
            localProbe = .failed(L10n.ASR.localProbeNoHost)
            return
        }
        localProbe = .verifying
        localProbeDetail = nil
        localProbeWarning = nil
        let result = await LocalASR.probe(host: local.host, port: local.port)
        if result.ok {
            localProbeDetail = result.detail
            localProbeWarning = result.warning
            localProbe = .success
        } else {
            invalidateLocalProbe()
            localProbe = .failed(result.error ?? L10n.ASR.verifyFailed)
        }
    }

    /// When the host/port changes, the previous probe result no longer applies — similar to changing the Azure key and resetting `azureVerify` to `.idle`,
    /// otherwise an outdated "connected" status would remain.
    private func invalidateLocalProbe() {
        localProbe = .idle
        localProbeDetail = nil
        localProbeWarning = nil
    }

    private var primaryBinding: Binding<String> {
        Binding(
            // The stored primary may no longer be in the candidates (credentials cleared or verification rejected) —
            // in that case the Picker can’t find a matching tag, shows blank, and falls back to the first option.
            get: {
                let stored = configService.config.defaults.asr.primary
                guard configuredASR.contains(where: { $0.key == stored }) else {
                    return configuredASR.first?.key ?? stored
                }
                return stored
            },
            set: { new in
                configService.config.defaults.asr.primary = new
                // Fallbacks = every other configured provider, in a sensible order
                // (server first, offline model last — it is already appended by the chain).
                let others = configuredASR.map(\.key).filter { $0 != new }
                configService.config.defaults.asr.fallbacks = others
                configService.scheduleSave()
            }
        )
    }

    /// Only prompt when “partially configured”: both fields empty means “no local service configured”, not an error.
    private var localHostMissing: Bool {
        guard let l = configService.config.asrProviders.local else { return false }
        return l.host.isEmpty && l.port > 0
    }

    private var localPortInvalid: Bool {
        guard let l = configService.config.asrProviders.local, !l.host.isEmpty || l.port > 0 else { return false }
        return !(1...65535).contains(l.port)
    }

    private var azureKeyMissing: Bool {
        (configService.config.asrProviders.azure?.key ?? "").isEmpty
    }

    private var azureRegionMissing: Bool {
        (configService.config.asrProviders.azure?.region ?? "").isEmpty
    }

    private func fieldError(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.red)
    }

    // MARK: - Custom (OpenAI-compatible) server

    private func writeCustom(_ custom: AppConfig.AsrProviders.Custom) {
        // Same hygiene as `writeLocal`: a half-typed endpoint must not linger as a
        // configured provider (it would appear in the picker and fail every transcription).
        let hasEndpoint = !custom.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        configService.config.asrProviders.custom = hasEndpoint ? custom : nil
        configService.scheduleSave()
    }

    /// ★ 2026-10-21: model dropdown for the custom (API-key) ASR server.
    /// Filled from `GET {base}/v1/models` and filtered to transcription-
    /// capable models only — chat/embedding/image models would just fail at
    /// transcribe time, so they are not offered. Manual entry stays available
    /// as a fallback (some servers ship no usable /models).
    @State private var customModelChoices: [String] = []
    @State private var customModelTotal = 0
    @State private var customModelLoading = false
    @State private var customModelManual = false
    @State private var customModelNotice: String?

    private var customModelBinding: Binding<String> {
        Binding(
            get: { configService.config.asrProviders.custom?.model ?? "" },
            set: {
                writeCustom(AppConfig.AsrProviders.Custom(
                    endpoint: configService.config.asrProviders.custom?.endpoint ?? "",
                    apiKey: configService.config.asrProviders.custom?.apiKey,
                    model: $0.isEmpty ? nil : $0,
                    language: configService.config.asrProviders.custom?.language))
            })
    }

    @ViewBuilder
    private var customModelRow: some View {
        if !customModelChoices.isEmpty && !customModelManual {
            Picker(L10n.ASR.customModel, selection: customModelBinding) {
                ForEach(customModelChoices, id: \.self) { Text($0).tag($0) }
                if !customModelChoices.contains(customModelBinding.wrappedValue),
                   !customModelBinding.wrappedValue.isEmpty {
                    Text(customModelBinding.wrappedValue).tag(customModelBinding.wrappedValue)
                }
            }
            .labelsHidden()
            if let notice = customModelNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
            Button(L10n.ASR.customModelsManual, systemImage: "keyboard") {
                customModelManual = true
            }
        } else {
            TextField(L10n.ASR.customModel, text: customModelBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await loadCustomModels() }
            } label: {
                if customModelLoading {
                    ProgressView()
                } else {
                    Label(L10n.ASR.customLoadModels, systemImage: "list.bullet")
                        .font(.footnote)
                }
            }
            .disabled(customModelLoading
                      || (configService.config.asrProviders.custom?.endpoint.isEmpty ?? true))
            if let notice = customModelNotice {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func loadCustomModels() async {
        guard let custom = configService.config.asrProviders.custom,
              !custom.endpoint.isEmpty else {
            customModelNotice = L10n.ASR.customModelsNone
            return
        }
        customModelLoading = true
        customModelNotice = nil
        defer { customModelLoading = false }
        if let result = await CustomASR.listModels(endpoint: custom.endpoint,
                                                   apiKey: custom.apiKey ?? "") {
            customModelChoices = result.models
            customModelTotal = result.total
            customModelManual = false
            customModelNotice = L10n.ASR.customModelsLoaded(result.models.count)
        } else {
            customModelChoices = []
            customModelManual = false
            customModelNotice = L10n.ASR.customModelsNone
        }
    }

    private var customSection: some View {
        Section {
            TextField(L10n.ASR.customEndpoint, text: Binding(
                get: { configService.config.asrProviders.custom?.endpoint ?? "" },
                set: {
                    writeCustom(AppConfig.AsrProviders.Custom(
                        endpoint: $0,
                        apiKey: configService.config.asrProviders.custom?.apiKey,
                        model: configService.config.asrProviders.custom?.model,
                        language: configService.config.asrProviders.custom?.language))
                    customProbe = .idle
                    // A model list fetched from the previous endpoint is now stale.
                    customModelChoices = []
                    customModelNotice = nil
                    customModelManual = false
                }))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField(L10n.ASR.customApiKey, text: Binding(
                get: { configService.config.asrProviders.custom?.apiKey ?? "" },
                set: {
                    writeCustom(AppConfig.AsrProviders.Custom(
                        endpoint: configService.config.asrProviders.custom?.endpoint ?? "",
                        apiKey: $0.isEmpty ? nil : $0,
                        model: configService.config.asrProviders.custom?.model,
                        language: configService.config.asrProviders.custom?.language))
                }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            customModelRow
            TextField(L10n.ASR.customLanguage, text: Binding(
                get: { configService.config.asrProviders.custom?.language ?? "" },
                set: {
                    writeCustom(AppConfig.AsrProviders.Custom(
                        endpoint: configService.config.asrProviders.custom?.endpoint ?? "",
                        apiKey: configService.config.asrProviders.custom?.apiKey,
                        model: configService.config.asrProviders.custom?.model,
                        language: $0.isEmpty ? nil : $0))
                }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            customProbeRow
        } header: {
            Text(L10n.ASR.customServer)
        } footer: {
            Text(L10n.ASR.customProbeFooter)
        }
    }

    @ViewBuilder
    private var customProbeRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.ASR.customProbe)
                switch customProbe {
                case .success:
                    if let detail = customProbeDetail {
                        Text(L10n.ASR.localProbeReachable(detail))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let reason):
                    fieldError(reason)
                case .verifying:
                    Text(L10n.ASR.statusVerifying)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
            }
            Spacer()
            verifyButton(customProbe) { await runCustomProbe() }
        }
    }

    private func runCustomProbe() async {
        guard let custom = configService.config.asrProviders.custom,
              !custom.endpoint.isEmpty else {
            customProbe = .failed(L10n.ASR.localProbeNoHost)
            return
        }
        customProbe = .verifying
        customProbeDetail = nil
        let result = await CustomASR.probe(endpoint: custom.endpoint,
                                           apiKey: custom.apiKey ?? "")
        if result.ok {
            customProbeDetail = result.detail
            customProbe = .success
            // Key is proven good — fetch the model dropdown for free, so the
            // user's next tap is picking a model, not hunting for a button.
            await loadCustomModels()
        } else {
            customProbe = .failed(result.error ?? L10n.ASR.verifyFailed)
        }
    }

    // MARK: - Remote live (WSS) server ★ 2026-10-20

    /// Endpoint + API key for the **remote secure** live service. Key never touches
    /// disk: `ConfigService.extractSecrets` pulls it into the Keychain at the save
    /// boundary, so these bindings can treat `config` as the source of truth exactly
    /// like every other provider.
    private func writeRemoteLive(_ remote: AppConfig.AsrProviders.RemoteLive) {
        // Same hygiene as `writeCustom`: a half-typed endpoint must not linger as a
        // configured provider.
        let hasEndpoint = !remote.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        configService.config.asrProviders.remoteLive = hasEndpoint ? remote : nil
        configService.scheduleSave()
    }

    /// True when the user typed an endpoint that can never work: an explicit
    /// plaintext `ws://` (LAN-only shape) or something the normalizer can't parse.
    private var remoteEndpointInvalid: Bool {
        let raw = configService.config.asrProviders.remoteLive?.endpoint ?? ""
        guard !raw.isEmpty else { return false }
        return RemoteLiveASR.listenURL(raw) == nil
    }

    private var remoteLiveSection: some View {
        Section {
            TextField(L10n.ASR.remoteEndpoint, text: Binding(
                get: { configService.config.asrProviders.remoteLive?.endpoint ?? "" },
                set: {
                    writeRemoteLive(AppConfig.AsrProviders.RemoteLive(
                        endpoint: $0,
                        apiKey: configService.config.asrProviders.remoteLive?.apiKey))
                    remoteProbe = .idle
                }))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            if remoteEndpointInvalid {
                fieldError(L10n.ASR.remoteErrInvalidScheme)
            }
            SecureField(L10n.ASR.remoteApiKey, text: Binding(
                get: { configService.config.asrProviders.remoteLive?.apiKey ?? "" },
                set: {
                    writeRemoteLive(AppConfig.AsrProviders.RemoteLive(
                        endpoint: configService.config.asrProviders.remoteLive?.endpoint ?? "",
                        apiKey: $0.isEmpty ? nil : $0))
                }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            remoteProbeRow
        } header: {
            Text(L10n.ASR.remoteLive)
        } footer: {
            Text(L10n.ASR.remoteFooter)
        }
    }

    @ViewBuilder
    private var remoteProbeRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.ASR.remoteProbe)
                switch remoteProbe {
                case .success:
                    if let detail = remoteProbeDetail {
                        Text(L10n.ASR.localProbeReachable(detail))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let reason):
                    fieldError(reason)
                case .verifying:
                    Text(L10n.ASR.statusVerifying)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
            }
            Spacer()
            verifyButton(remoteProbe) { await runRemoteProbe() }
        }
    }

    private func runRemoteProbe() async {
        guard let remote = configService.config.asrProviders.remoteLive,
              !remote.endpoint.isEmpty else {
            remoteProbe = .failed(L10n.ASR.localProbeNoHost)
            return
        }
        remoteProbe = .verifying
        remoteProbeDetail = nil
        let result = await RemoteLiveASR.probe(endpoint: remote.endpoint,
                                               apiKey: remote.apiKey ?? "")
        if result.ok {
            remoteProbeDetail = result.detail
            remoteProbe = .success
        } else {
            remoteProbe = .failed(result.error ?? L10n.ASR.verifyFailed)
        }
    }

    /// When no local server is configured, the config should not contain a `local` entry — e.g., `{host: "", port: 1}`
    // Such a partial record would be treated by the UI as “configured”, causing a stray number to appear in the port field.
    private func writeLocal(_ local: AppConfig.AsrProviders.Local) {
        configService.config.asrProviders.local =
            (local.host.isEmpty && local.port <= 0) ? nil : local
        configService.scheduleSave()
    }

    private var localHostBinding: Binding<String> {
        Binding(
            get: { configService.config.asrProviders.local?.host ?? "" },
            set: { new in
                var local = configService.config.asrProviders.local ?? .init(host: "", port: Self.defaultLocalPort)
                local.host = new
                invalidateLocalProbe()
                writeLocal(local)
            }
        )
    }

    /// Bind the port as a `String` instead of `Binding<Int>`: an `Int` binding always has a value, so “not set” and “set to 0” are indistinguishable in the UI, and the placeholder “Port” never appears — the user sees an unexpected number.
// The original setter also used the current input as the default port, so typing `1` in an empty field would write `{host: "", port: 1}`.
    private var localPortBinding: Binding<String> {
        Binding(
            get: {
                guard let port = configService.config.asrProviders.local?.port, port > 0 else { return "" }
                return String(port)
            },
            set: { new in
                var local = configService.config.asrProviders.local ?? .init(host: "", port: 0)
                local.port = Int(new.filter(\.isNumber)) ?? 0
                invalidateLocalProbe()
                writeLocal(local)
            }
        )
    }
}

// MARK: - LLM Providers

struct LLMProvidersView: View {
    @EnvironmentObject private var configService: ConfigService
    // ★ 2026-10-23: sheet hangs off the Form (stable identity), not the grid
    // Section — otherwise any @Published change during presentation cancels it.
    @State private var editingProvider: LLMProviderSpec?

    private var configured: [(key: String, label: String)] {
        configService.config.llmProviders.configuredProviders
    }

    /// Why the primary channel is incompletely configured. Non-nil ⇒ the Picker above shows as "nothing selected".
    ///
    /// ★ 2026-10-15: this state really happened in practice — `primary = "openRouter"`,
    /// while the `open_router` section didn't even have an `api_key`. And the Picker only lists **fully configured**
    /// channels, so the tags don't line up, the UI just looks like "nothing is selected", with no clue at all;
    /// the user only sees every summary fail once before falling back.
    private var primaryGap: String? {
        guard let primary = configService.config.llmProviders.primary, !primary.isEmpty else {
            return nil
        }
        return LLMCompletionService.configGap(primary, configService.config)
    }

    var body: some View {
        Form {
            if !configured.isEmpty || primaryGap != nil {
                Section {
                    if !configured.isEmpty {
                        Picker(selection: Binding(
                            get: { configService.config.llmProviders.primary ?? "" },
                            set: {
                                configService.config.llmProviders.primary = $0.isEmpty ? nil : $0
                                configService.scheduleSave()
                            }
                        )) {
                            Text(L10n.Common.none).tag("")
                            // ★ 2026-10-15: when the primary channel is incompletely configured it is **not** in `configured`
                            //   so no tag equals the current selection, and the Picker
                            //   renders as "nothing selected" — all the user sees is a blank
                            //   dropdown, when the real cause is the orange notice beside it.
                            //   Add an entry labelled "Not configured" so the selected state has somewhere to land.
                            if let primary = configService.config.llmProviders.primary,
                               !primary.isEmpty,
                               !configured.contains(where: { $0.key == primary }) {
                                Text(L10n.LLM.unconfigured(
                                    LLMCompletionService.providerLabel(primary)
                                )).tag(primary)
                            }
                            ForEach(configured, id: \.key) { Text($0.label).tag($0.key) }
                        } label: {
                            HStack(spacing: 4) {
                                Text(L10n.ASR.activeProvider)
                                InfoTip(text: L10n.LLM.activeProviderFooter)
                            }
                        }
                    }

                    // When it's incomplete, add the reason + a one-tap switch to the fallback. The one-tap part pays off most here:
                    // since the user tapped into this page, what they want is "make it right", not to
                    // work out for themselves which field to fill in, or that they should switch channels.
                    if let gap = primaryGap {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(gap, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            if let fix = LLMCompletionService.suggestedPrimary(configService.config) {
                                Button(L10n.LLM.adoptAsPrimary(
                                    LLMCompletionService.providerLabel(fix)
                                )) {
                                    configService.config.llmProviders.primary = fix
                                    configService.scheduleSave()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            ProviderGridSection(
                title: L10n.LLM.gridTitle,
                footer: L10n.LLM.gridFooter,
                specs: LLMProviderSpec.all,
                editing: $editingProvider
            )
        }
        .sheet(item: $editingProvider) { spec in
            ProviderConfigSheet(spec: spec)
                .environmentObject(configService)
        }
        .navigationTitle(L10n.Settings.llmProviders)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { configService.saveNow() }
    }
}

// MARK: - Provider grid (every provider, one sheet)

/// 2026-10-22 request:
/// > "下面的 openrouter 也要要国外的主流模型，Claude / chatgpt / gemini，ollama 跟用户自定义的模型
/// >  也要加入进去，然后给这些模型配置对应的图标，然后他们的模型要兼容 —
/// >  能够根据我们支持的模型才可以在里面进行选择"
///
/// So the grid covers all ten providers and every one of them opens the **same**
/// sheet. Before this, each provider had its own hand-written section, which is
/// why OpenRouter had a provider-prefix field, Ollama had a debounce probe and
/// Custom had a different model row — three behaviours to learn for one task.
private struct ProviderGridSection: View {
    let title: String
    let footer: String?
    let specs: [LLMProviderSpec]
    // ★ 2026-10-23: sheet state moved to the owning Form view — same
    // "sheet flashes then closes" fix as `ASRCloudSection`.
    @Binding var editing: LLMProviderSpec?

    @EnvironmentObject private var configService: ConfigService

    var body: some View {
        Section {
            ForEach(specs) { spec in
                Button {
                    editing = spec
                } label: {
                    ProviderRow(spec: spec)
                }
                .tint(.primary)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

private struct ProviderRow: View {
    let spec: LLMProviderSpec
    @EnvironmentObject private var configService: ConfigService

    private var key: String { configService.config.llmProviders.apiKeyValue(for: spec.storage) ?? "" }
    private var model: String { configService.config.llmProviders.modelValue(for: spec.storage) ?? "" }
    private var endpoint: String {
        let stored = configService.config.llmProviders.endpointValue(for: spec.storage) ?? ""
        return stored.isEmpty ? spec.defaultEndpoint : stored
    }

    var body: some View {
        HStack(spacing: 12) {
            ProviderMark(spec: spec)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name).foregroundStyle(.primary)
                Text(detailLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // Last measured round trip, if this provider was ever probed. Shown on
            // the row rather than only inside the sheet, because "which of these is
            // actually fast" is a question you have while looking at the list.
            if let ms = LLMLatencyMemory.millis(for: spec.id) {
                Text("\(ms) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            status
        }
    }

    /// Second line: what you'd recognise the provider by — the model when one is
    /// chosen, otherwise the address. Showing the model matters more than the host
    /// once it's set ("which model am I actually on?" is the recurring question).
    private var detailLine: String {
        if !model.isEmpty { return model }
        if !endpoint.isEmpty, let host = URL(string: endpoint)?.host { return host + pathSuffix }
        return L10n.LLM.notConfigured
    }

    private var pathSuffix: String {
        guard let url = URL(string: endpoint), url.path.count > 1 else { return "" }
        return url.path
    }

    @ViewBuilder
    private var status: some View {
        if hasAnyConfig {
            if model.isEmpty {
                Text(L10n.LLM.presetNeedsModel).font(.caption2).foregroundStyle(.orange)
            } else if spec.keyRequired, key.isEmpty {
                Text(L10n.LLM.presetNeedsKey).font(.caption2).foregroundStyle(.orange)
            } else {
                Text(L10n.LLM.presetReady).font(.caption2).foregroundStyle(.green)
            }
        } else {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    /// "Is there anything stored for this provider" — deliberately not
    /// `endpointValue`, which returns the **default** address for the three
    /// fixed-endpoint providers and would make every row look configured.
    private var hasAnyConfig: Bool {
        let p = configService.config.llmProviders
        return p.apiKeyValue(for: spec.storage) != nil || p.modelValue(for: spec.storage) != nil
    }
}

/// Brand tile — the vendor's own logo on its brand-coloured square.
///
/// 2026-10-22:
/// > "不要文字字幕做图标，需要按照当前他们模型 Logo 做图标"
///
/// so the letter marks ("通" / "DS" / "豆" / "火") are gone. The logos are
/// monochrome template images; the tile supplies the colour, which means the same
/// asset works in light and dark mode and never looks like a mismatched sticker.
/// `custom` has no vendor, so it keeps a symbol rather than a fake logo.
private struct ProviderMark: View {
    let spec: LLMProviderSpec

    private var color: Color {
        let t = spec.tint
        return Color(red: t.r, green: t.g, blue: t.b)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                LinearGradient(colors: [color, color.opacity(0.72)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 32, height: 32)
            .overlay { glyph }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if let asset = spec.brandAsset {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(7)
        } else if spec.id == "custom" {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            Text(spec.mark)
                .font(.system(size: spec.mark.count > 1 ? 11 : 15, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

/// Key + address + model for one provider, in the same order every time.
///
/// Endpoints are pre-filled from `LLMProviderSpec`, which is the whole request:
/// tap the icon, and the address is already right. Where the API fixes the
/// address (OpenAI / Claude / Gemini) the row is shown but locked — a free-text
/// field there could only produce a 404.
private struct ProviderConfigSheet: View {
    let spec: LLMProviderSpec

    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var verify: VerifyState = .idle
    @State private var models: [String] = []
    @State private var manualModel = false
    @State private var fetchHint: String?
    @State private var modelQuery = ""
    @State private var probing = false
    @State private var probe: LLMConnectivityService.Result?

    private var key: String { configService.config.llmProviders.apiKeyValue(for: spec.storage) ?? "" }
    private var model: String { configService.config.llmProviders.modelValue(for: spec.storage) ?? "" }
    private var endpoint: String {
        let stored = configService.config.llmProviders.endpointValue(for: spec.storage) ?? ""
        return stored.isEmpty ? spec.defaultEndpoint : stored
    }
    private var isConfigured: Bool {
        let p = configService.config.llmProviders
        // Same rule as the row's badge: a *stored* value, not the default address
        // that `endpointValue` synthesises for fixed-endpoint providers.
        return p.apiKeyValue(for: spec.storage) != nil || p.modelValue(for: spec.storage) != nil
    }

    /// Always offer the saved value: a model that was renamed upstream, or an
    /// `ep-…` access point typed by hand, is not in any fetched list — and a
    /// Picker whose selection matches no tag renders blank.
    private var options: [String] {
        var list = models.isEmpty ? spec.curatedModels : models
        if !model.isEmpty, !list.contains(model) { list.insert(model, at: 0) }
        if !modelQuery.isEmpty {
            let q = modelQuery.lowercased()
            list = list.filter { $0.lowercased().contains(q) }
        }
        return list
    }

    /// Unfiltered list for the pushed picker: the picker has its **own** search,
    /// and handing it the in-form query would have made "the list looks empty"
    /// read as "this vendor has no models".
    private var pickerOptions: [String] {
        var list = models.isEmpty ? spec.curatedModels : models
        if !model.isEmpty, !list.contains(model) { list.insert(model, at: 0) }
        return list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ProviderMark(spec: spec)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.name).font(.headline)
                            Text(endpoint.isEmpty ? L10n.LLM.notConfigured : (URL(string: endpoint)?.host ?? endpoint))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    if spec.keyRequired {
                        SecureField(L10n.LLM.apiKey, text: keyBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } else {
                        SecureField(L10n.LLM.apiKeyOptional, text: keyBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }

                    if spec.endpointEditable {
                        TextField(L10n.LLM.presetEndpointFilled, text: endpointBinding)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                    } else {
                        LabeledContent(L10n.LLM.endpointURL) {
                            Text(endpoint)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let console = spec.console, spec.keyRequired {
                            Text("\(L10n.LLM.presetConsole): \(console)")
                        }
                        if !spec.endpointEditable {
                            Text(L10n.LLM.endpointFixedByAPI)
                        }
                    }
                    .font(.footnote)
                }

                Section {
                    if manualModel || options.isEmpty {
                        TextField(L10n.LLM.modelPlaceholder(spec.curatedModels.first ?? "model-name"), text: modelBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } else {
                        // ★ 2026-10-22: was an inline `Picker`. See `ModelPickerView`
                        // for why the first tap used to be swallowed — the pushed
                        // list re-laid itself out mid-animation.
                        NavigationLink {
                            ModelPickerView(title: L10n.LLM.model,
                                            options: pickerOptions,
                                            current: model,
                                            allowsEmpty: true) { picked in
                                modelBinding.wrappedValue = picked
                            }
                        } label: {
                            LabeledContent(L10n.LLM.model) {
                                Text(model.isEmpty ? L10n.LLM.selectModel : model)
                                    .font(model.isEmpty ? .body : .body.monospaced())
                                    .foregroundStyle(model.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }

                    // OpenRouter alone lists several hundred models; scrolling them
                    // in a Picker is unusable, so filter first.
                    if !manualModel, models.count > 15 {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(L10n.LLM.modelSearch, text: $modelQuery)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.footnote.monospaced())
                        }
                    }

                    Button {
                        Task { await loadModels() }
                    } label: {
                        HStack {
                            Text(L10n.LLM.presetFetchModels)
                            Spacer()
                            if verify == .verifying {
                                ProgressView().controlSize(.small)
                            } else if !options.isEmpty, !manualModel {
                                Text("\(models.isEmpty ? spec.curatedModels.count : models.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(verify == .verifying || (spec.keyRequired && key.isEmpty))

                    if !options.isEmpty, !manualModel {
                        Button(L10n.LLM.presetManualModel) { manualModel = true }
                            .font(.footnote)
                    } else if !spec.curatedModels.isEmpty {
                        Button(L10n.LLM.useCuratedModels) { manualModel = false }
                            .font(.footnote)
                    }
                } header: {
                    Text(L10n.LLM.model)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let note = spec.note { Text(note) }
                        Text(L10n.LLM.chatOnlyNote)
                        if let fetchHint { Text(fetchHint) }
                        if case .failed(let reason) = verify {
                            Text(reason).foregroundStyle(.red)
                        }
                    }
                    .font(.footnote)
                }

                // Probe last, and after the model row: it needs a key *and* a model,
                // and it is the only row that spends a token of quota, so it should
                // be the last thing on the page you touch.
                Section {
                    Button {
                        Task { await runProbe() }
                    } label: {
                        probeRow
                    }
                    .disabled(probing || !canProbe)
                } header: {
                    Text(L10n.LLM.testSection)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.LLM.testNote)
                        if !canProbe {
                            Text(spec.keyRequired && key.isEmpty ? L10n.LLM.testNeedKey : L10n.LLM.testNeedModel)
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.footnote)
                }

                if spec.id == "ollama" {
                    Section { SetupAssistantRow() }
                }

                if isConfigured {
                    Section {
                        Button(role: .destructive) {
                            configService.config.llmProviders.removeProvider(for: spec.storage)
                            configService.scheduleSave()
                            dismiss()
                        } label: {
                            Text(L10n.LLM.presetRemove)
                        }
                    }
                }
            }
            // A focused text field swallows the first tap on the next row (it is
            // spend dismissing the keyboard). This page is mostly fields, so let
            // the scroll dismiss the keyboard instead of eating taps.
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(spec.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) {
                        configService.saveNow()
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: prime)
    }

    // MARK: - Behaviour

    /// Fill in what the user shouldn't have to type. Endpoint first (that is the
    /// promise), then a sensible default model, so the key field is the only empty
    /// thing on screen.
    ///
    /// Never overwrites an existing choice — coming back to change the key must not
    /// silently swap the model.
    private func prime() {
        models = spec.curatedModels
        manualModel = spec.curatedModels.isEmpty
        let stored = configService.config.llmProviders
        if spec.endpointEditable,
           (stored.endpointValue(for: spec.storage) ?? "").isEmpty,
           !spec.defaultEndpoint.isEmpty {
            configService.config.llmProviders.setEndpointURL(spec.defaultEndpoint, for: spec.storage)
            configService.scheduleSave()
        }
        if (stored.modelValue(for: spec.storage) ?? "").isEmpty,
           let first = spec.curatedModels.first,
           spec.kind != .local {
            configService.config.llmProviders.setModel(first, for: spec.storage)
            configService.scheduleSave()
        }
    }

    private func loadModels() async {
        verify = .verifying
        fetchHint = nil
        modelQuery = ""
        let result = await LLMModelService.fetchModels(for: spec, endpoint: endpoint, apiKey: key)
        if Task.isCancelled { return }
        if result.ok, !result.models.isEmpty {
            models = result.models
            verify = .success
            manualModel = false
            fetchHint = result.detail
        } else if result.ok {
            // Reachable, but nothing callable — say exactly that instead of a red
            // "failed", because the key was fine.
            models = []
            verify = .failed(L10n.LLM.noChatModels)
            fetchHint = spec.curatedModels.isEmpty ? L10n.LLM.presetBuiltinHint : nil
        } else {
            verify = .failed((result.error ?? L10n.LLM.noModelsOnServer) + "\n" + L10n.LLM.fetchFailedHint)
            models = spec.curatedModels
            fetchHint = L10n.LLM.presetBuiltinHint
        }
    }

    // MARK: - Probe

    private var canProbe: Bool {
        !model.isEmpty && (!spec.keyRequired || !key.isEmpty)
    }

    @ViewBuilder
    private var probeRow: some View {
        HStack(spacing: 10) {
            if probing {
                ProgressView().controlSize(.small)
                Text(L10n.LLM.testRunning).foregroundStyle(.primary)
            } else if let probe {
                Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(probe.ok ? Color.green : Color.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(probe.ok ? L10n.LLM.testOK(probe.millis) : (probe.error ?? ""))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if probe.ok {
                        Text("\(L10n.LLM.testBand(probe.millis)) · \(probe.detail ?? "")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.primary)
                Text(L10n.LLM.testButton).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
    }

    private func runProbe() async {
        probing = true
        probe = nil
        let result = await LLMConnectivityService.test(
            spec: spec, endpoint: endpoint, apiKey: key, model: model
        )
        guard !Task.isCancelled else { probing = false; return }
        probing = false
        probe = result
        // Only a pass is worth remembering: a failure is usually a half-typed key,
        // and caching that would put a stale "N ms" on the row of a provider that
        // has since been fixed.
        if result.ok { LLMLatencyMemory.save(result.millis, for: spec.id) }
        else { LLMLatencyMemory.clear(spec.id) }
    }

    // MARK: - Bindings

    private var keyBinding: Binding<String> {
        Binding(
            get: { key },
            set: { new in
                configService.config.llmProviders.setAPIKey(new, for: spec.storage)
                configService.config.llmProviders.autoSelectPrimaryIfFirst()
                verify = .idle
                probe = nil
                configService.scheduleSave()
            }
        )
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { endpoint },
            set: { new in
                configService.config.llmProviders.setEndpointURL(new, for: spec.storage)
                verify = .idle
                probe = nil
                configService.scheduleSave()
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { model },
            set: { new in
                configService.config.llmProviders.setModel(new, for: spec.storage)
                probe = nil
                configService.scheduleSave()
            }
        )
    }
}

// MARK: - Azure Speech setup guide

struct AzureSpeechSetupGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    step(
                        number: 1,
                        title: L10n.AzureGuide.step1Title,
                        items: [
                            L10n.AzureGuide.step1Item1,
                            L10n.AzureGuide.step1Item2,
                        ]
                    )

                    step(
                        number: 2,
                        title: L10n.AzureGuide.step2Title,
                        items: [
                            L10n.AzureGuide.step2Item1,
                            L10n.AzureGuide.step2Item2,
                            L10n.AzureGuide.step2Item3,
                            L10n.AzureGuide.step2Item4,
                            L10n.AzureGuide.step2Item5,
                            L10n.AzureGuide.step2Item6,
                        ]
                    )

                    step(
                        number: 3,
                        title: L10n.AzureGuide.step3Title,
                        items: [
                            L10n.AzureGuide.step3Item1,
                            L10n.AzureGuide.step3Item2,
                            L10n.AzureGuide.step3Item3,
                        ]
                    )

                    freeTierInfo
                }
                .padding()
            }
            .navigationTitle(L10n.AzureGuide.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }

    private func step(number: Int, title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.AzureGuide.step(number, title))
                .font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(item)
                        .font(.subheadline)
                }
            }
        }
    }

    private var freeTierInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.AzureGuide.freeTierTitle)
                .font(.headline)
            Group {
                row(L10n.AzureGuide.fastTranscription, L10n.AzureGuide.fastTranscriptionValue)
                row(L10n.AzureGuide.realtimeTranscription, L10n.AzureGuide.realtimeTranscriptionValue)
                row(L10n.AzureGuide.speakerDiarization, L10n.AzureGuide.speakerDiarizationValue)
                row(L10n.AzureGuide.audioFormats, L10n.AzureGuide.audioFormatsValue)
            }
        }
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Shared helpers

@ViewBuilder
private func keyHint(_ key: String?) -> some View {
    if let key, !key.isEmpty {
        let masked = "\(key.prefix(4))····\(key.suffix(4))"
        Text(masked)
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
    }
}

private func verifyButton(_ state: VerifyState, action: @escaping () async -> Void) -> some View {
    Button {
        Task { await action() }
    } label: {
        Group {
            switch state {
            case .idle:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .verifying:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.borderless)
    .disabled(state == .verifying)
}

// MARK: - Recordings

struct RecordingsSettingsView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var env: AppEnvironment
    @State private var showGeneratedAlert = false
    @State private var encryptionError: String?
    @State private var encryptionBusy = false
    @State private var passphraseSheet: PassphraseSheetMode?
    /// Snapshot of the connected device's SN taken at the moment the user
    /// taps "Set/Rotate/Clear." Pinning prevents a mid-flow device switch
    /// (via the toolbar connection pill) from causing the passphrase that
    /// was typed for device A to be saved under device B's Keychain
    /// account. Each device gets one passphrase; mixing them up is the
    /// one thing the per-SN Keychain scoping must never silently allow.
    @State private var pinnedSN: String = ""

    enum PassphraseSheetMode: Identifiable {
        case set    // derive + save locally
        case rotate // derive + 0xA2 enable + save locally
        var id: Int { self == .set ? 0 : 1 }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { configService.config.autoDeleteAfterTransfer },
                    set: { configService.config.autoDeleteAfterTransfer = $0; configService.scheduleSave() }
                )) {
                    HStack(spacing: 4) {
                        Text(L10n.RecordingsSettings.deleteAfterTransfer)
                        InfoTip(text: L10n.RecordingsSettings.deleteAfterTransferFooter)
                    }
                }
            }

            passphraseSection
            deviceEncryptionSection

            Section {
                Picker(selection: Binding(
                    get: { configService.config.fastTransferThresholdKB },
                    set: { configService.config.fastTransferThresholdKB = $0; configService.scheduleSave() }
                )) {
                    ForEach(Self.fastTransferThresholdOptions, id: \.self) { kb in
                        Text(Self.formatThreshold(kb)).tag(kb)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(L10n.RecordingsSettings.fastTransferThreshold)
                        InfoTip(text: L10n.RecordingsSettings.fastTransferThresholdFooter)
                    }
                }
            }

            Section {
                TextField(L10n.RecordingsSettings.ssid, text: wifiSSIDBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L10n.RecordingsSettings.password, text: wifiPSKBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                // WPA2 passphrases must be 8–63 characters. This field can be edited manually; shortening it causes fast transfer to be rejected by the system (`invalid WPA/WPA2 Passphrase.`), so report the issue immediately,
// instead of waiting for the fast transfer to fail.
                if let psk = configService.config.wifiAP?.psk,
                   !psk.isEmpty,
                   !(8...63).contains(psk.count) {
                    Label(L10n.FastTransfer.invalidPSK, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                HStack(spacing: 4) {
                    Text(L10n.RecordingsSettings.wifiAP)
                    InfoTip(text: L10n.RecordingsSettings.wifiCredentialsFooter)
                }
            }
        }
        .navigationTitle(L10n.Settings.recordings)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            generateWifiIfNeeded()
            // Banner deep-link: when the device-tab banner asked us to
            // open the passphrase sheet, do it after the view has settled.
            // We consume the flag immediately so it doesn't re-fire on
            // every reappearance.
            if env.openPassphraseSheet {
                env.openPassphraseSheet = false
                pinnedSN = bluetooth.client?.lastDeviceInfo?.serial ?? ""
                passphraseSheet = .set
            }
        }
        .onDisappear { configService.saveNow() }
        .alert(L10n.RecordingsSettings.wifiGenerated, isPresented: $showGeneratedAlert) {
            Button(L10n.Common.ok) {}
        } message: {
            Text(L10n.RecordingsSettings.wifiGeneratedMessage)
        }
        // Attach the passphrase sheet to the Form, not the Section inside
        // `passphraseSection`. Sheet modifiers on a Section race with the
        // Form's first layout pass: the first tap presents-then-dismisses
        // before the user can read it; only the second tap works.
        // Pinned-SN: the sheet is bound to the device that was connected at
        // tap-time, not whatever the current `bluetooth.client` happens to
        // be. If we read SN from `bluetooth.client` here, a mid-flow device
        // switch would re-render the sheet with the new device's SN while
        // the @State passphrase typed for the old device persists — and the
        // wrong device would end up with the wrong key in its Keychain
        // entry. See `pinnedSN`.
        .sheet(item: $passphraseSheet) { mode in
            PassphraseEntrySheet(
                mode: mode,
                sn: pinnedSN,
                client: bluetooth.client,
                onError: { msg in encryptionError = msg }
            )
        }
    }

    /// Threshold values offered in the picker, in KB. 0 means "always
    /// show the Wi-Fi Fast Transfer button whenever the backlog is
    /// non-empty"; higher values gate the suggestion behind a minimum.
    private static let fastTransferThresholdOptions = [0, 256, 512, 1024, 2048, 5120]

    /// Format thresholds manually rather than via ByteCountFormatter:
    /// the `.file` style uses decimal KB (1000 bytes) and would render
    /// "256 KB" as "262 KB", which is misleading next to a binary-KB
    /// option list.
    private static func formatThreshold(_ kb: Int) -> String {
        if kb < 1024 { return "\(kb) KB" }
        let mb = Double(kb) / 1024.0
        return mb.rounded() == mb
            ? "\(Int(mb)) MB"
            : String(format: "%.1f MB", mb)
    }

    /// Passphrase / Keychain key management. Lives in this section instead
    /// of `deviceEncryptionSection` because it's host-side state that
    /// applies even when the device is not connected.
    @ViewBuilder
    private var passphraseSection: some View {
        let sn = bluetooth.client?.lastDeviceInfo?.serial ?? ""
        let hasLocalKey = !sn.isEmpty && PassphraseStore.load(sn: sn) != nil
        Section {
            HStack {
                Text(L10n.EncryptionOnboarding.localKey)
                Spacer()
                Text(hasLocalKey ? L10n.EncryptionOnboarding.configured : L10n.EncryptionOnboarding.missing)
                    .foregroundStyle(hasLocalKey ? Color.secondary : Color.red)
                    .font(.callout)
            }
            // "How do I know what my passphrase is?" — you don't, and the
            // app can't tell you: only the derived key is stored, never the
            // passphrase. Say that here rather than leaving the user to
            // discover it by hunting for a reveal button that will never
            // exist.
            if hasLocalKey {
                Text(L10n.EncryptionOnboarding.cannotRevealNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // When the device is already encrypted, this flow performs **verification**: record a probe, attempt decryption with the entered passphrase,
// and only if it succeeds write it to the Keychain (see `PassphraseSheet.primaryActionLabel`). Naming the entry “Set Passphrase” would mislead users into thinking they are creating a new one, while the device does not store or retrieve the passphrase.
            Button(bluetooth.client?.deviceEncryptionOn == true
                   ? L10n.EncryptionOnboarding.verifyButton
                   : L10n.EncryptionOnboarding.setButton) {
                pinnedSN = sn
                passphraseSheet = .set
            }
            .disabled(sn.isEmpty)
            Button(L10n.EncryptionOnboarding.rotateButton) {
                pinnedSN = sn
                passphraseSheet = .rotate
            }
            .disabled(sn.isEmpty)
            Button(L10n.EncryptionOnboarding.clearButton, role: .destructive) {
                guard !sn.isEmpty else { return }
                PassphraseStore.clear(sn: sn)
            }
            .disabled(!hasLocalKey)
        } header: {
            Text(L10n.EncryptionOnboarding.sectionHeader)
        } footer: {
            Text(L10n.EncryptionOnboarding.sectionFooter)
                .font(.caption)
        }
        // Sheet presentation lives on the Form (see `body`); attaching it
        // here on the Section is what caused the first tap to flash open
        // and immediately dismiss.
    }

    /// On-device encryption state (read-only here — toggling is firmware
    /// behavior the user can't control). We just show the current state so
    /// the user knows whether a key is required.
    @ViewBuilder
    private var deviceEncryptionSection: some View {
        if let client = bluetooth.client, let state = client.deviceEncryptionOn {
            Section {
                HStack {
                    Text(L10n.DeviceEncryption.stateRow)
                    Spacer()
                    Text(state ? L10n.DeviceEncryption.stateOn : L10n.DeviceEncryption.stateOff)
                        .foregroundStyle(.secondary)
                }
                if let msg = encryptionError {
                    Text(msg).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                if state {
                    Text(L10n.DeviceEncryption.firmwareFooter)
                        .font(.caption)
                }
            }
            .id(client.deviceEncryptionOn) // refresh on state change
        }
    }

    private func generateWifiIfNeeded() {
        let ap = configService.config.wifiAP
        if ap == nil || (ap!.ssid.isEmpty && ap!.psk.isEmpty) {
            let ssid = "DNOTE-\(randomHex(4))"
            let psk = randomHex(8)
            configService.config.wifiAP = .init(ssid: ssid, psk: psk)
            configService.scheduleSave()
            showGeneratedAlert = true
        }
    }

    private func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
    }

    private var wifiSSIDBinding: Binding<String> {
        Binding(
            get: { configService.config.wifiAP?.ssid ?? "" },
            set: { new in
                var ap = configService.config.wifiAP ?? .init(ssid: "", psk: "")
                ap.ssid = new
                configService.config.wifiAP = ap
                configService.scheduleSave()
            }
        )
    }

    private var wifiPSKBinding: Binding<String> {
        Binding(
            get: { configService.config.wifiAP?.psk ?? "" },
            set: { new in
                var ap = configService.config.wifiAP ?? .init(ssid: "", psk: "")
                ap.psk = new
                configService.config.wifiAP = ap
                configService.scheduleSave()
            }
        )
    }
}

// MARK: - Devices & Library

struct DevicesLibraryView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var library: Library
    /// PLAUD direct-connect service. Its live state (battery, recording,
    /// history count) is what the PLAUD row adds on top of the plain ledger
    /// fields the other devices show.
    @ObservedObject private var plaudDirect = PlaudDirectService.shared
    /// Needed for the "switch to this card" row: a PLAUD card is not a
    /// `RecorderLink`, so nothing else releases the previous card's link.
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    // Scan the on-disk library so the stats match what the Library tab
    // shows. The manifest (`library.entries`) only tracks device downloads,
    // so imported clips were missing from the total (showed 0).
    @StateObject private var libraryStats = LibraryListModel()

    private enum CleanupScope { case audio, transcripts, summaries, all }
    @State private var pendingCleanup: CleanupScope?
    @State private var showCleanupAlert = false
    @State private var cleanupFailureMessage: String?

    var body: some View {
        Form {
            connectionSection
            devicesSection
            librarySection
            dangerSection
        }
        .navigationTitle(L10n.Settings.devicesAndLibrary)
        .navigationBarTitleDisplayMode(.inline)
        .task { await libraryStats.refresh() }
        .alert(alertTitle, isPresented: $showCleanupAlert, presenting: pendingCleanup) { scope in
            Button(L10n.Common.delete, role: .destructive) { performCleanup(scope) }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { scope in
            Text(alertMessage(scope))
        }
        .alert(
            L10n.DevicesLibrary.cleanupPartialTitle,
            isPresented: Binding(
                get: { cleanupFailureMessage != nil },
                set: { if !$0 { cleanupFailureMessage = nil } }
            ),
            presenting: cleanupFailureMessage
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Cleanup helpers

    private func alertTitle(_ scope: CleanupScope) -> String {
        switch scope {
        case .audio: return L10n.DevicesLibrary.clearAudio
        case .transcripts: return L10n.DevicesLibrary.clearTranscripts
        case .summaries: return L10n.DevicesLibrary.clearSummaries
        case .all: return L10n.DevicesLibrary.clearAllData
        }
    }

    // Overload so the .alert title parameter (String, not closure) compiles.
    private var alertTitle: String {
        pendingCleanup.map { alertTitle($0) } ?? ""
    }

    private func alertMessage(_ scope: CleanupScope) -> String {
        switch scope {
        case .audio: return L10n.DevicesLibrary.clearAudioMessage
        case .transcripts: return L10n.DevicesLibrary.clearTranscriptsMessage
        case .summaries: return L10n.DevicesLibrary.clearSummariesMessage
        case .all: return L10n.DevicesLibrary.clearAllDataMessage
        }
    }

    private func performCleanup(_ scope: CleanupScope) {
        let fm = FileManager.default
        // Deletions must not be `try?` with no feedback, or "cleared" is a
        // claim nobody checked. Count the failures and say so.
        var failures = 0

        // Which artefact this scope targets; nil means "everything".
        let target: ClipArtefact?
        switch scope {
        case .audio:       target = .audio
        case .transcripts: target = .transcript
        case .summaries:   target = .summary
        case .all:         target = nil
        }

        // Clean decryptedDir
        if let items = try? fm.contentsOfDirectory(
            at: StorageLocations.decryptedDir, includingPropertiesForKeys: nil
        ) {
            for url in items {
                let name = url.lastPathComponent
                // `.marks.json` rides with the audio: it is a set of timestamps into that recording, so
                // "clear audio" must take it too — otherwise the next scan finds markers for a clip that
                // no longer exists. (`ClipArtefact` keeps it unclassified on purpose; see `marksSuffix`.)
                let marksRidesWithAudio = name.hasSuffix(ClipArtefact.marksSuffix)
                let shouldDelete = target.map {
                    ClipArtefact.of(fileNamed: name) == $0 || (marksRidesWithAudio && $0 == .audio)
                } ?? true
                if shouldDelete {
                    do { try fm.removeItem(at: url) } catch { failures += 1 }
                }
            }
        }

        // Clean raw files in audioDir (skip the decrypted/ subdir and manifest)
        if let items = try? fm.contentsOfDirectory(
            at: StorageLocations.audioDir, includingPropertiesForKeys: nil
        ) {
            for url in items {
                let name = url.lastPathComponent
                guard name != "decrypted", name != ".manifest.json" else { continue }
                // Raw (still-encrypted) blobs are the audio payload, so they go
                // only when audio is the target (or everything is).
                guard target == nil || target == .audio else { continue }
                if ClipArtefact.of(fileNamed: name) == .audio {
                    do { try fm.removeItem(at: url) } catch { failures += 1 }
                }
            }
        }

        // The manifest tracks downloaded *audio*; clearing transcripts or
        // summaries must not wipe it, or the app forgets what it already
        // pulled off the device.
        if target == nil || target == .audio { library.clearAll() }
        // A lone .title would otherwise rebuild a ghost entry.
        ClipArtefact.sweepOrphanTitles()
        if failures > 0 {
            cleanupFailureMessage = L10n.DevicesLibrary.cleanupPartialFailure(failures)
        }
        Task { await libraryStats.refresh() }
    }

    private var sortedDevices: [(String, AppConfig.DeviceRecord)] {
        configService.config.devices
            .map { ($0.key, $0.value) }
            .sorted { ($0.1.lastConnected ?? "") > ($1.1.lastConnected ?? "") }
    }

    private var connectionSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { configService.config.autoReconnectEnabled },
                set: { configService.config.autoReconnectEnabled = $0; configService.scheduleSave() }
            )) {
                Text(L10n.DevicesLibrary.autoReconnect)
            }
        } header: {
            Text(L10n.DevicesLibrary.connection)
        } footer: {
            Text(L10n.DevicesLibrary.autoReconnectFooter)
        }
    }

    /// One row of the known-devices list.
    ///
    /// Built from the ledger, PLUS a synthesised entry when a PLAUD card is
    /// paired but has no ledger row yet — that happens on installs upgraded
    /// from a build that predates the ledger write, and it would otherwise look
    /// like "my card disappeared" even though it is connected.
    private struct DeviceRow: Identifiable {
        let id: String
        let record: AppConfig.DeviceRecord
        let plaudSN: String?
    }

    private var deviceRows: [DeviceRow] {
        var rows = sortedDevices.map {
            DeviceRow(id: $0.0, record: $0.1, plaudSN: Self.plaudSerial(fromLedgerID: $0.0))
        }
        if let sn = plaudDirect.pairedSN {
            let key = PlaudDirectService.ledgerID(for: sn)
            if !rows.contains(where: { $0.id == key }) {
                rows.insert(
                    DeviceRow(id: key, record: .init(name: PlaudDirectService.modelName(for: sn)), plaudSN: sn),
                    at: 0
                )
            }
        }
        return rows
    }

    private var devicesSection: some View {
        Section(L10n.DevicesLibrary.knownDevices) {
            // ★ 2026-10-22 ("切换卡片点击了但是没有同步切换卡片过去"): a switch is a
            // BLE round trip — wake, scan, bind — and it produced **no** visible
            // change until it finished (or silently failed). This line makes it
            // observable, and the row roles below flip the instant `pairedSN`
            // moves, so the list agrees with the card being switched to.
            if let note = plaudDirect.switchNote {
                HStack(spacing: 8) {
                    if plaudDirect.phase.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if deviceRows.isEmpty {
                Text(L10n.DevicesLibrary.noDevicesYet)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(deviceRows) { row in
                    // PLAUD cards live in the SAME ledger (key `plaud-<SN>`) but
                    // get a richer row + their own page, because they carry live
                    // BLE state the plain record can't hold.
                    if let sn = row.plaudSN {
                        // ★ 2026-10-22: every PLAUD row used to push the SAME
                        // page — the one bound to `pairedSN` — so tapping card B
                        // showed card A's details and nothing switched. Only the
                        // active card opens the page now; the others switch first.
                        if sn == plaudDirect.pairedSN {
                            NavigationLink {
                                PlaudDeviceDetailView()
                            } label: {
                                PlaudLedgerRow(sn: sn, record: row.record)
                            }
                        } else {
                            Button {
                                // ★ 2026-10-22: one card at a time. Switching
                                // *to* PLAUD used to skip the teardown that
                                // `connectToDevice` does for the other cards,
                                // so the old link stayed live and kept owning
                                // the pill — "选 PLAUD 切换不过去，其他卡片可以".
                                if bluetooth.client != nil || bluetooth.recorderLink != nil {
                                    bluetooth.disconnect()
                                }
                                plaudDirect.switchCard(to: sn)
                            } label: {
                                HStack(spacing: 8) {
                                    PlaudLedgerRow(sn: sn, record: row.record)
                                    Spacer(minLength: 4)
                                    Text(L10n.DevicesLibrary.switchToThis)
                                        .font(.caption2)
                                        .foregroundStyle(Color.appAccent)
                                }
                            }
                            .tint(.primary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.record.name).font(.body)
                            Text(row.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            if let last = row.record.lastConnected {
                                Text(L10n.DevicesLibrary.lastSeen(last)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { indices in
                    let keys = deviceRows.map(\.id)
                    for i in indices { configService.config.devices.removeValue(forKey: keys[i]) }
                    configService.scheduleSave()
                }
            }
        }
        // Reading the row's history count is a probe, not a transfer.
        .onAppear {
            guard plaudDirect.phase.isConnected else { return }
            plaudDirect.refreshVitals()
            plaudDirect.refreshCardRecordings()
        }
    }

    /// `plaud-881…` → `881…`; nil for every other ledger key.
    private static func plaudSerial(fromLedgerID id: String) -> String? {
        id.hasPrefix("plaud-") ? String(id.dropFirst("plaud-".count)) : nil
    }

    private var librarySection: some View {
        Section {
            LabeledContent(L10n.DevicesLibrary.files, value: "\(libraryStats.items.count)")
            LabeledContent(L10n.DevicesLibrary.totalSize, value: ByteCountFormatter.string(
                fromByteCount: libraryStats.totalBytes,
                countStyle: .file
            ))
        } header: {
            HStack(spacing: 4) {
                Text(L10n.DevicesLibrary.library)
                InfoTip(text: L10n.DevicesLibrary.libraryFooter)
            }
        }
    }

    private var dangerSection: some View {
        Section(L10n.DevicesLibrary.dangerZone) {
            Button(L10n.DevicesLibrary.clearAudio, role: .destructive) {
                pendingCleanup = .audio
                showCleanupAlert = true
            }
            Button(L10n.DevicesLibrary.clearTranscripts, role: .destructive) {
                pendingCleanup = .transcripts
                showCleanupAlert = true
            }
            Button(L10n.DevicesLibrary.clearSummaries, role: .destructive) {
                pendingCleanup = .summaries
                showCleanupAlert = true
            }
            Button(L10n.DevicesLibrary.clearAllData, role: .destructive) {
                pendingCleanup = .all
                showCleanupAlert = true
            }
        }
    }
}

// MARK: - Passphrase entry sheet

struct PassphraseEntrySheet: View {
    let mode: RecordingsSettingsView.PassphraseSheetMode
    let sn: String
    let client: DnoteClient?
    let onError: (String) -> Void
    /// The one that pops up immediately after the first binding. Also note that encryption is enforced by firmware and the passphrase cannot be recovered,
    // and the app will not start recording until the passphrase is fully set — users arriving from the settings page don’t need this.
    var firstBind = false

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase: String = ""
    @State private var confirm: String = ""
    @State private var busy = false
    @State private var progressMessage: String = ""
    @State private var localError: String?
    @State private var mismatchAlert = false
    /// Set once the pre-rotate check has counted what's still on the device.
    /// Rotating makes all of it undecryptable, so the count goes in front of
    /// the user before the key is written.
    @State private var rotatePlan: RotatePlan?
    /// Set when "Set" failed to verify on a device that holds no recordings.
    /// See `runSet` — at that point adopting the typed passphrase costs
    /// nothing, so the user is offered that instead of "wrong passphrase".
    @State private var adoptOffer: RotatePlan?

    struct RotatePlan: Identifiable, Equatable {
        let passphrase: String
        let salt: String
        let recordingsAtRisk: Int
        var id: String { "\(recordingsAtRisk)" }
    }

    private var deviceIsEncrypted: Bool {
        // When the device says encryption is ON, "Set" needs to verify the
        // passphrase against an actual encrypted clip — otherwise the user
        // can silently save a wrong key and only discover the mismatch on
        // their next download. When the device says OFF, no verify is
        // possible (and not useful: there are no encrypted files yet).
        client?.deviceEncryptionOn == true
    }

    private var primaryActionLabel: String {
        if busy {
            return progressMessage.isEmpty ? L10n.EncryptionOnboarding.working : progressMessage
        }
        switch mode {
        case .rotate: return L10n.EncryptionOnboarding.actionRotate
        case .set:    return deviceIsEncrypted
            ? L10n.EncryptionOnboarding.actionVerifyAndSave
            : L10n.EncryptionOnboarding.actionSave
        }
    }

    private var footerCopy: String {
        switch mode {
        case .rotate:
            return L10n.EncryptionOnboarding.footerRotate
        case .set:
            return deviceIsEncrypted
                ? L10n.EncryptionOnboarding.footerSetEncrypted
                : L10n.EncryptionOnboarding.footerSetUnencrypted
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    if firstBind {
                        Section {
                            Text(L10n.EncryptionOnboarding.firstBindNote)
                                .font(.callout)
                        }
                    }
                    Section {
                        SecureField(L10n.EncryptionOnboarding.passphraseField, text: $passphrase)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(busy)
                        SecureField(L10n.EncryptionOnboarding.confirmField, text: $confirm)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(busy)
                    } footer: {
                        Text(footerCopy).font(.caption)
                    }
                    if let msg = localError {
                        Section { Text(msg).foregroundStyle(.red).font(.caption) }
                    }
                    Section {
                        Button(action: submit) {
                            HStack {
                                if busy {
                                    ProgressView().controlSize(.small)
                                }
                                Text(primaryActionLabel)
                            }
                        }
                        .disabled(busy || passphrase.isEmpty || passphrase != confirm)
                        Button(L10n.EncryptionOnboarding.actionCancel, role: .cancel) { dismiss() }
                            .disabled(busy)
                    }
                }
                .disabled(busy)

                if busy {
                    // Full-sheet dim + centered spinner. Argon2id at
                    // 512 MiB / t=4 takes several seconds; the verify path
                    // adds a ~3 s device recording + BLE download on top.
                    // Surface the current step so the user knows what's
                    // happening.
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text(progressMessage.isEmpty ? L10n.EncryptionOnboarding.working : progressMessage)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        if mode == .set && deviceIsEncrypted {
                            Text(L10n.EncryptionOnboarding.probeOverlaySubtitle)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)
                        }
                    }
                    .padding(24)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle(mode == .rotate
                             ? L10n.EncryptionOnboarding.sheetTitleRotate
                             : deviceIsEncrypted
                               ? L10n.EncryptionOnboarding.sheetTitleVerify
                               : L10n.EncryptionOnboarding.sheetTitleSet)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy)
            .alert(L10n.EncryptionOnboarding.mismatchTitle, isPresented: $mismatchAlert) {
                Button(L10n.EncryptionOnboarding.mismatchTryAgain, role: .cancel) {
                    passphrase = ""
                    confirm = ""
                }
            } message: {
                Text(L10n.EncryptionOnboarding.mismatchMessage)
            }
            .alert(
                L10n.EncryptionOnboarding.rotateConfirmTitle,
                isPresented: Binding(
                    get: { rotatePlan != nil },
                    set: { if !$0 { rotatePlan = nil } }
                ),
                presenting: rotatePlan
            ) { plan in
                Button(L10n.EncryptionOnboarding.actionRotate, role: .destructive) {
                    Task {
                        busy = true
                        localError = nil
                        defer { busy = false; progressMessage = "" }
                        do {
                            try await runRotate(passphrase: plan.passphrase, salt: plan.salt)
                        } catch {
                            localError = error.localizedDescription
                            onError(error.localizedDescription)
                        }
                    }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: { plan in
                Text(L10n.EncryptionOnboarding.rotateConfirmMessage(plan.recordingsAtRisk))
            }
            .alert(
                L10n.EncryptionOnboarding.adoptTitle,
                isPresented: Binding(
                    get: { adoptOffer != nil },
                    set: { if !$0 { adoptOffer = nil } }
                ),
                presenting: adoptOffer
            ) { plan in
                Button(L10n.EncryptionOnboarding.adoptAction) {
                    Task {
                        busy = true
                        localError = nil
                        defer { busy = false; progressMessage = "" }
                        do {
                            try await runRotate(passphrase: plan.passphrase, salt: plan.salt)
                        } catch {
                            localError = error.localizedDescription
                            onError(error.localizedDescription)
                        }
                    }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: { _ in
                Text(L10n.EncryptionOnboarding.adoptMessage)
            }
        }
    }

    private func submit() {
        guard !passphrase.isEmpty, passphrase == confirm else { return }
        let p = passphrase
        let salt = sn
        Task {
            busy = true
            localError = nil
            defer {
                busy = false
                progressMessage = ""
            }
            do {
                switch mode {
                case .set:
                    try await runSet(passphrase: p, salt: salt)
                case .rotate:
                    try await prepareRotate(passphrase: p, salt: salt)
                }
            } catch {
                localError = error.localizedDescription
                onError(error.localizedDescription)
            }
        }
    }

    /// "Set" flow:
    ///   - device encrypted → derive + verify by probe-clip + save on match
    ///   - device not encrypted → derive + save (the key is dormant until
    ///     the user enables encryption later; this is the case for a
    ///     freshly-purchased device that hasn't been turned on yet)
    private func runSet(passphrase: String, salt: String) async throws {
        if deviceIsEncrypted {
            guard let client else {
                localError = L10n.EncryptionOnboarding.errorConnectFirst
                return
            }
            progressMessage = L10n.EncryptionOnboarding.progressDeriving
            let outcome = try await PassphraseVerifier.verify(
                passphrase: passphrase,
                sn: salt,
                client: client,
                progress: { progressMessage = $0 }
            )
            switch outcome.result {
            case .matches:
                try PassphraseStore.save(outcome.derivedKey, sn: salt)
                dismiss()
            case .mismatch:
                // A factory-fresh V05 always lands here: firmware v1.50
                // enables encryption at bind time under a key the phone
                // never chose, so the very first passphrase the user types
                // cannot match. Telling them "wrong passphrase" is both
                // wrong and a dead end — they have no old passphrase to
                // recall. When the device holds nothing, adopting the typed
                // passphrase destroys nothing, so offer exactly that.
                let onDevice = (try? await client.getFileList().filter { !$0.name.isEmpty }.count) ?? -1
                if onDevice == 0 {
                    adoptOffer = RotatePlan(passphrase: passphrase, salt: salt, recordingsAtRisk: 0)
                } else {
                    mismatchAlert = true
                }
            case .deviceNotEncrypting:
                // Device flipped state mid-flow (or reported ON but isn't
                // actually wrapping clips). Save the key anyway so the user
                // is covered when encryption next turns on.
                try PassphraseStore.save(outcome.derivedKey, sn: salt)
                dismiss()
            }
        } else {
            progressMessage = L10n.EncryptionOnboarding.progressDeriving
            let key = try await Task.detached(priority: .userInitiated) {
                try PassphraseStore.derive(passphrase: passphrase, sn: salt)
            }.value
            try PassphraseStore.save(key, sn: salt)
            dismiss()
        }
    }

    /// Step 1 of rotate: count what's still on the device. Anything recorded
    /// under the old key becomes unreadable the moment the new one lands, so
    /// the user gets that number — and a chance to go download them first —
    /// before anything is written.
    private func prepareRotate(passphrase: String, salt: String) async throws {
        guard let client else {
            localError = L10n.EncryptionOnboarding.errorDeviceNotConnected
            return
        }
        progressMessage = L10n.EncryptionOnboarding.progressCheckingDevice
        let atRisk = (try? await client.getFileList().filter { !$0.name.isEmpty }.count) ?? 0
        rotatePlan = RotatePlan(passphrase: passphrase, salt: salt, recordingsAtRisk: atRisk)
    }

    /// Step 2 of rotate: derive a fresh key, save it locally, then write it
    /// to the device (0xA2). No verify needed because we just *set* the
    /// device's key — it's guaranteed to match.
    ///
    /// Order matters. Device-first meant a Keychain write that failed (screen
    /// locked, app killed) left the device on a key the phone had never
    /// stored — unrecoverable for every recording made afterwards. Saving
    /// first makes the failure recoverable, and the device write failing
    /// rolls the Keychain back to what was there before.
    private func runRotate(passphrase: String, salt: String) async throws {
        guard let client else {
            localError = L10n.EncryptionOnboarding.errorDeviceNotConnected
            return
        }
        progressMessage = L10n.EncryptionOnboarding.progressDeriving
        let key = try await Task.detached(priority: .userInitiated) {
            try PassphraseStore.derive(passphrase: passphrase, sn: salt)
        }.value

        let previous = PassphraseStore.load(sn: salt)
        try PassphraseStore.save(key, sn: salt)

        progressMessage = L10n.EncryptionOnboarding.progressWritingKey
        do {
            try await client.setEncryption(on: true, key: key)
        } catch {
            if let previous {
                try? PassphraseStore.save(previous, sn: salt)
            } else {
                PassphraseStore.clear(sn: salt)
            }
            throw error
        }
        dismiss()
    }
}
