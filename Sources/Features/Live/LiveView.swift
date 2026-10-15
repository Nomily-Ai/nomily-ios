import SwiftUI
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "live-view")

// MARK: - Outer shell

struct LiveView: View {
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model = LiveModel()
    @State private var clipItem: LibraryItem?
    @State private var clipMissing = false

    /// Which device this live session should capture audio from.
    ///
    /// | Priority | Device | Source |
    /// |---|---|---|
    /// | 1 | **Recorder card** (TicNote etc., via `bluetooth.recorderLink`) | The link itself (`TicNoteLink` implements `LiveAudioSource`) |
    /// | 2 | **D·NOTE** (via `bluetooth.client`) | Wrapped in a `DnoteLiveSource` |
    ///
    /// Why the card takes priority: the two are **mutually exclusive** device models (one `any RecorderLink`,
    /// one `DnoteClient`); both being connected at once never happens. The card path was added later,
    /// and putting it first guarantees "once the card is connected, the phone-side source is never mistakenly used."
    ///
    /// ⚠️ `DnoteLiveSource` is a **new object** every time, and that's intentional: it's stateless
    /// (just a strong reference to `client`), while `LiveModel` records the source for that session
    /// only at the moment of `start`; at `stop` a similarly-shaped one is passed in — the two are equivalent.
    private var liveSource: (any LiveAudioSource)? {
        if let card = bluetooth.recorderLink as? any LiveAudioSource, card.isAvailable {
            return card
        }
        if let client = bluetooth.client {
            return DnoteLiveSource(client: client)
        }
        return nil
    }

    /// There is only one true source of truth: `clipItem`. Previously, `item` and `flag` were two independent @State variables (setting `item` first, then `flag`), which could cause the destination page to evaluate once before `item` took effect.
    private var showClipDetail: Binding<Bool> {
        Binding(get: { clipItem != nil }, set: { if !$0 { clipItem = nil } })
    }

    var body: some View {
        // The outermost container must be a **stable host** like VStack, not Group: Group is a transparent container,
        // so modifiers are dispatched to the current branch. When `bluetooth.client` changes, the branch switches,
        // and the pushed detail page loses the navigation bar's safe-area layout — this is the phenomenon
        // where "the navigation bar overlaps the body when entering the detail page from the real-time page" (u7y9w25). The path in the database works correctly precisely because the outermost container of RecordingsView is a VStack.
        VStack(spacing: 0) {
            if let source = liveSource {
                LiveContent(model: model, source: source, config: env.config, library: env.library) { item in
                    // nil = The recording is no longer in the database; provide a prompt instead of silently swallowing it
                    if let item { clipItem = item } else { clipMissing = true }
                }
            } else if !model.finalSegments.isEmpty || model.savedClipName != nil {
                disconnectedResults
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemGroupedBackground))
            } else {
                EmptyStateView(
                    L10n.Live.noDeviceConnected,
                    systemImage: "dot.radiowaves.left.and.right",
                    message: L10n.Live.noDeviceMessage
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .navigationDestination(isPresented: showClipDetail) {
            if let item = clipItem {
                ClipDetailView(item: item)
            }
        }
        .alert(L10n.Live.clipNotInLibrary, isPresented: $clipMissing) {
            Button(L10n.Common.ok, role: .cancel) {}
        }
        .onDisappear {
            if model.isRunning, let source = liveSource {
                Task {
                    await model.stop(source: source)
                    env.isStreaming = false
                }
            }
        }
        .onChange(of: model.isRunning) { running in
            env.isStreaming = running
            UIApplication.shared.isIdleTimerDisabled = running
        }
    }

    @ViewBuilder
    private var disconnectedResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.finalSegments.enumerated()), id: \.offset) { _, seg in
                    if let translation = seg.translation {
                        BilingualRow(source: seg.text, translation: translation)
                    } else {
                        Text(seg.text)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let name = model.savedClipName {
                    Button {
                        // Cannot be silently ignored — after the session ends, the recording may be renamed, merged, or replaced in the repository.
                        // In such cases, `savedClipName` becomes invalid, and the button becomes permanently unresponsive.
                        if let item = buildLibraryItem(for: name) {
                            clipItem = item
                        } else {
                            clipMissing = true
                        }
                    } label: {
                        Label(L10n.Live.viewInLibrary, systemImage: "arrow.right.circle.fill")
                            .font(.subheadline.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding()
        }
    }
}

// MARK: - Content

private struct LiveContent: View {
    @ObservedObject var model: LiveModel
    /// This session's audio source. **Deliberately not `@ObservedObject`** —
    /// nowhere in the view body is its state read (it's only used to call `model.start/stop/repair`),
    /// and `any LiveAudioSource` isn't observable anyway (existential + protocol).
    let source: any LiveAudioSource
    @ObservedObject var config: ConfigService
    @EnvironmentObject private var env: AppEnvironment
    let library: Library
    /// Passing nil indicates that this recording is no longer in the library (renamed/merged/deleted), and the outer layer should provide a prompt.
    var onNavigateToClip: (LibraryItem?) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var languages = LanguageService()

    @State private var showSourcePicker = false
    @State private var showTargetPicker = false
    @State private var pendingSourceLang: String?
    @State private var pendingTargetLang: String?
    @State private var showSwitchConfirm = false

    init(model: LiveModel, source: any LiveAudioSource, config: ConfigService, library: Library,
         onNavigateToClip: @escaping (LibraryItem?) -> Void) {
        self.model = model
        self.source = source
        self.config = config
        self.library = library
        self.onNavigateToClip = onNavigateToClip
    }

    private var activeProviderName: String {
        config.config.defaults.asr.primary
    }

    private var azureConfigured: Bool {
        if let azure = config.config.asrProviders.azure,
           !azure.key.isEmpty, !azure.region.isEmpty {
            return true
        }
        return false
    }

    /// Whether the on-device LLM channel is usable (★ added 2026-10-14).
    ///
    /// Why the target language picker checks this too: on the local ASR path, the translation is **handed to
    /// the on-device LLM afterwards** (`LiveModel.beginLiveTranslation` → `LLMCompletionService`),
    /// Azure isn't needed at all. This used to check only `azureConfigured`, so on machines without Azure configured
    /// the target language picker was **entirely locked out** (showing just a lock + "Set up Azure") — users couldn't even pick a target language,
    /// and thus had no way to trigger translation. This was the most surface-level gate of "local ASR can't translate live."
    private var llmConfigured: Bool {
        LLMCompletionService.isConfigured(config.config)
    }

    /// Whether this session's translation has a path: Azure live translation **or** the on-device LLM both count.
    private var translationAvailable: Bool { azureConfigured || llmConfigured }

    private var sourceLanguageList: [LanguageService.Language] {
        LanguageService.sourceLanguages(for: activeProviderName)
    }

    private var currentSourceName: String {
        sourceLanguageList.first { $0.code == model.sourceLang }?.name ?? model.sourceLang
    }

    private func adaptSourceLang() {
        let list = sourceLanguageList
        if list.contains(where: { $0.code == model.sourceLang }) { return }
        let prefix = model.sourceLang.components(separatedBy: "-").first ?? model.sourceLang
        if let match = list.first(where: { $0.code == prefix })
                    ?? list.first(where: { $0.code.hasPrefix(prefix + "-") })
                    ?? list.first(where: { $0.code.hasPrefix(prefix) }) {
            model.sourceLang = match.code
        }
    }

    private var currentTargetName: String {
        if let target = model.targetLang, !target.isEmpty {
            return languages.targetLanguages.first { $0.code == target }?.name ?? target
        }
        return L10n.Live.sameAsSource
    }

    var body: some View {
        VStack(spacing: 0) {
            languageHeader
            // ★ 2026-10-14: translation soft warning. **Deliberately not reusing `model.error`** —
            //   below in `transcriptBody`, `if let err = model.error` would replace **the entire body
            //   with an error page**. A missing translation should never cost the user the transcript in progress:
            //   the transcript itself is fine, just missing half the content. So this takes only one line and doesn't interrupt the body.
            if let notice = model.translationNotice {
                translationNoticeBanner(notice)
            }
            if model.repairState != .idle {
                repairBanner
            }
            transcriptBody
            Divider()
            controlBar
        }
        .task {
            languages.fetchTargetLanguagesIfNeeded()
            if let saved = config.config.lastSourceLang {
                model.sourceLang = saved
            }
            adaptSourceLang()
            if let saved = config.config.lastTargetLang {
                model.targetLang = saved
            } else {
                let uiLang = Locale.preferredLanguages.first ?? "en"
                let prefix = Locale(identifier: uiLang).language.languageCode?.identifier ?? "en"
                if prefix != "en",
                   let match = languages.targetLanguages.first(where: { $0.code == prefix })
                              ?? languages.targetLanguages.first(where: { $0.code.hasPrefix(prefix) }) {
                    model.targetLang = match.code
                }
            }
            if let t = model.targetLang,
               let lang = languages.targetLanguages.first(where: { $0.code == t }) {
                model.targetLangName = lang.name
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background: model.sceneDidBackground()
            case .active:     model.sceneDidForeground()
            default: break
            }
        }
        .onChange(of: activeProviderName) { _ in
            adaptSourceLang()
        }
        .sheet(isPresented: $showSourcePicker) {
            LanguagePickerSheet(
                title: L10n.Live.sourceLanguage,
                languages: sourceLanguageList,
                defaultOption: nil
            ) { lang in
                showSourcePicker = false
                handleSourcePick(lang.code)
            }
        }
        .sheet(isPresented: $showTargetPicker) {
            LanguagePickerSheet(
                title: L10n.Live.targetLanguage,
                languages: languages.targetLanguages,
                defaultOption: L10n.Live.sameAsSource
            ) { lang in
                showTargetPicker = false
                handleTargetPick(lang.code)
            }
        }
        .alert(L10n.Live.switchLanguage, isPresented: $showSwitchConfirm) {
            Button(L10n.Live.continueButton) {
                applyPendingLanguageChange()
            }
            Button(L10n.Common.cancel, role: .cancel) {
                pendingSourceLang = nil
                pendingTargetLang = nil
            }
        } message: {
            Text(switchConfirmMessage)
        }
        .alert(
            L10n.Live.repairTitle,
            isPresented: Binding(
                get: { model.pendingRepair != nil },
                set: { if !$0 { model.pendingRepair = nil } }
            ),
            presenting: model.pendingRepair
        ) { repair in
            // Capture `repair` from the presenting parameter — the binding's
            // `set(false)` on dismiss clears `model.pendingRepair` before
            // our Task runs, so the model-side guard would otherwise drop
            // the request.
            Button(L10n.Live.repairReplace) {
                Task { await model.repair(source: source, repair: repair) }
            }
            Button(L10n.Live.repairKeep, role: .cancel) {
                Task { await model.declineRepair(repair: repair) }
            }
        } message: { repair in
            Text(repair.message)
        }
        .alert(
            L10n.Live.startUnknownTitle,
            isPresented: $model.pendingStartConfirm
        ) {
            Button(L10n.Live.startAnyway) {
                Task { await model.start(source: source, config: config, library: library, assumeIdle: true) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Live.startUnknownMessage)
        }
    }

    /// The translation channel's **soft** warning banner (★ 2026-10-14).
    ///
    /// It only indicates "something went wrong on the translation path"; the transcript is completely unaffected. The style is deliberately lighter than `repairBanner`
    /// (no buttons, no orange warning icon), so users don't mistake the whole session for being broken.
    private func translationNoticeBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "character.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.6))
    }

    private var repairBanner: some View {
        HStack(spacing: 10) {
            switch model.repairState {
            case .downloading(let got, let total):
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Live.repairDownloading)
                        .font(.caption.bold())
                    ProgressView(value: Double(got), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                }
            case .failed(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(L10n.Live.repairFailed(msg))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(L10n.Common.close) { model.dismissRepairState() }
                    .font(.caption)
            case .needsManualTransfer:
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundColor(.orange)
                Text(L10n.Live.repairManualTransfer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer()
                Button(L10n.Common.close) { model.dismissRepairState() }
                    .font(.caption)
            case .succeeded:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(L10n.Live.repairSucceeded)
                    .font(.caption.bold())
                Spacer()
                Button(L10n.Common.close) { model.dismissRepairState() }
                    .font(.caption)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - Language header

    private var languageHeader: some View {
        HStack(spacing: 12) {
            Button { showSourcePicker = true } label: {
                HStack(spacing: 4) {
                    Text(currentSourceName)
                        .font(.subheadline)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // ★ 2026-10-14: it used to be `if azureConfigured`. That gate completely blocked the "local ASR +
            //   on-device LLM translation" path in the UI — without Azure configured there was no target language
            //   picker at all, so users couldn't select a target language. Changed so either one being available suffices.
            if translationAvailable {
                Button { showTargetPicker = true } label: {
                    HStack(spacing: 4) {
                        Text(currentTargetName)
                            .font(.subheadline)
                            .foregroundStyle(model.targetLang == nil ? .secondary : .primary)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(L10n.Live.setupAzure)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - Transcript body

    @ViewBuilder
    private var transcriptBody: some View {
        if let err = model.error {
            VStack(spacing: 16) {
                Spacer()
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                if model.errorNeedsPairing {
                    Button(L10n.Pairing.goPair) {
                        env.openDeviceSheetForPairing = true
                    }
                    .buttonStyle(.borderedProminent)
                } else if !config.config.asrProviders.hasConfiguredProvider {
                    Button(L10n.ASR.openProviderSettings) {
                        env.navigateToASRProviders = true
                        NotificationCenter.default.post(name: .navigateToSettings, object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        } else if model.finalSegments.isEmpty && model.partialText.isEmpty {
            if model.isRunning {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text(L10n.Live.listening)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text(L10n.Live.tapMicToStart)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                    HStack {
                        Spacer()
                        CurvedArrowHint()
                            .padding(.trailing, 36)
                            .padding(.bottom, 4)
                    }
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(model.finalSegments.enumerated()), id: \.offset) { idx, seg in
                            if let translation = seg.translation {
                                BilingualRow(source: seg.text, translation: translation)
                                    .id(idx)
                            } else {
                                Text(seg.text)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }

                        partialRow
                            .id("partial")

                        // ── Post-session cleanup actions
                        //
                        // A save already happened automatically when recording stopped (`LiveModel.saveAndCleanup`);
                        // what's shown here is **the result of that save**:
                        //   · Saved → "View in Library" (original);
                        //   · Not saved but bytes still in hand → "**Save to Library**" (added 2026-10-12).
                        //     User's exact words: "After ending the current live transcription, a Save to Library button needs to be added."
                        // The two are mutually exclusive; two buttons never appear at the same time.
                        if !model.isRunning {
                            if let name = model.savedClipName {
                                VStack(spacing: 6) {
                                    Label(L10n.Live.savedToLibrary, systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        navigateToClip(name)
                                    } label: {
                                        Label(L10n.Live.viewInLibrary, systemImage: "arrow.right.circle.fill")
                                            .font(.subheadline.bold())
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(.top, 12)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .id("viewClip")
                            } else if model.canSaveToLibrary {
                                Button {
                                    Task {
                                        if let name = await model.saveToLibrary(source: source) {
                                            navigateToClip(name)
                                        }
                                    }
                                } label: {
                                    Label(L10n.Live.saveToLibrary, systemImage: "square.and.arrow.down")
                                        .font(.subheadline.bold())
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(.top, 12)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .id("saveClip")
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: model.finalSegments.count) { _ in
                    withAnimation {
                        proxy.scrollTo(model.finalSegments.count - 1, anchor: .bottom)
                    }
                }
                .onChange(of: model.partialText) { _ in
                    withAnimation {
                        proxy.scrollTo("partial", anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var partialRow: some View {
        if !model.partialTranslation.isEmpty {
            BilingualRow(
                source: model.partialText,
                translation: model.partialTranslation,
                isPartial: true
            )
        } else if !model.partialText.isEmpty {
            Text(model.partialText)
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(height: 0)
        }
    }

    // MARK: - Control bar

    private var controlBar: some View {
        HStack(spacing: 16) {
            if !model.activeProvider.isEmpty {
                Text(model.activeProvider.capitalized)
                    .font(.caption2.bold())
                    .foregroundColor(model.wsConnected ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(model.wsConnected
                                  ? Color.green.opacity(0.12)
                                  : Color.orange.opacity(0.12))
                    )
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.statusText).font(.subheadline.bold())
                HStack(spacing: 12) {
                    Text(model.durationLabel)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(model.bytes), countStyle: .file))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            controlButtons
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var controlButtons: some View {
        if model.isRunning {
            HStack(spacing: 12) {
                pauseResumeButton
                stopButton
            }
        } else {
            micButton
        }
    }

    private var pauseResumeButton: some View {
        Button {
            Task {
                if model.isPaused {
                    await model.resume(config: config)
                } else {
                    await model.pause()
                }
            }
        } label: {
            circleIcon(
                systemImage: model.isPaused ? "play.fill" : "pause.fill",
                tint: .accentColor
            )
        }
        .buttonStyle(.plain)
    }

    private var stopButton: some View {
        Button {
            Task {
                await model.stop(source: source)
                env.isStreaming = false
            }
        } label: {
            circleIcon(systemImage: "stop.fill", tint: .red)
        }
        .buttonStyle(.plain)
    }

    private var micButton: some View {
        Button {
            Task {
                await model.start(source: source, config: config, library: library)
                env.isStreaming = model.isRunning
            }
        } label: {
            circleIcon(systemImage: "mic.fill", tint: .accentColor)
        }
        .buttonStyle(.plain)
    }

    private func circleIcon(systemImage: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.15))
                .frame(width: 48, height: 48)
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(tint)
        }
    }

    private var switchConfirmMessage: String {
        let fromName: String
        if let pending = pendingSourceLang {
            fromName = sourceLanguageList.first { $0.code == pending }?.name ?? pending
        } else {
            fromName = currentSourceName
        }
        let toCode = pendingTargetLang ?? (model.targetLang ?? "")
        if toCode.isEmpty {
            return L10n.Live.transcribeOnly(fromName)
        }
        let toName = languages.targetLanguages.first { $0.code == toCode }?.name ?? toCode
        return L10n.Live.translatePair(fromName, toName)
    }

    // MARK: - Language change handling

    private func handleSourcePick(_ code: String) {
        guard code != model.sourceLang else { return }
        if model.isRunning {
            pendingSourceLang = code
            showSwitchConfirm = true
        } else {
            model.sourceLang = code
            persistLanguages()
        }
    }

    private func handleTargetPick(_ code: String) {
        let newTarget: String? = code.isEmpty ? nil : code
        if model.isRunning {
            pendingTargetLang = code
            showSwitchConfirm = true
        } else {
            model.targetLang = newTarget
            if let lang = languages.targetLanguages.first(where: { $0.code == code }) {
                model.targetLangName = lang.name
            } else {
                model.targetLangName = ""
            }
            persistLanguages()
        }
    }

    private func applyPendingLanguageChange() {
        if let source = pendingSourceLang {
            model.sourceLang = source
            pendingSourceLang = nil
        }
        if let target = pendingTargetLang {
            let newTarget: String? = target.isEmpty ? nil : target
            model.targetLang = newTarget
            if let lang = languages.targetLanguages.first(where: { $0.code == target }) {
                model.targetLangName = lang.name
            } else {
                model.targetLangName = ""
            }
            pendingTargetLang = nil
        }
        persistLanguages()
        Task {
            await model.switchASR(config: config)
        }
    }

    private func persistLanguages() {
        config.config.lastSourceLang = model.sourceLang
        config.config.lastTargetLang = model.targetLang
        config.scheduleSave()
    }

    // MARK: - Navigation

    private func navigateToClip(_ name: String) {
        // Cannot silently return if not found: `savedClipName` becomes invalid
        // if it has been renamed / merged / replaced in the database,
        // causing the button to become a dead key with zero feedback (u7y9w25).
        onNavigateToClip(buildLibraryItem(for: name))
    }

}

// MARK: - Helpers

private func buildLibraryItem(for name: String) -> LibraryItem? {
    let url = StorageLocations.decryptedDir.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let duration: Double? = url.pathExtension.lowercased() == "opus"
        ? OpusOgg.duration(ofOggOpusAt: url) : nil
    return LibraryItem.readFromDisk(name: name, duration: duration)
}

// MARK: - Bilingual row

private struct BilingualRow: View {
    let source: String
    let translation: String
    var isPartial = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source)
                .font(.body)
                .italic(isPartial)
                .foregroundStyle(isPartial ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !translation.isEmpty {
                Text(translation)
                    .font(.body)
                    .italic(isPartial)
                    .foregroundColor(.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isPartial {
                Divider()
            }
        }
    }
}

// MARK: - Language picker sheet

// MARK: - Curved arrow hint

private struct CurvedArrowHint: View {
    var body: some View {
        CurvedArrow()
            .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .foregroundStyle(.secondary)
            .frame(width: 60, height: 80)
    }
}

private struct CurvedArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let start = CGPoint(x: rect.midX - 10, y: rect.minY)
        let end = CGPoint(x: rect.maxX, y: rect.maxY - 8)
        let cp1 = CGPoint(x: rect.minX, y: rect.midY)
        let cp2 = CGPoint(x: rect.maxX - 5, y: rect.maxY - 25)
        p.move(to: start)
        p.addCurve(to: end, control1: cp1, control2: cp2)
        p.move(to: CGPoint(x: end.x - 12, y: end.y - 8))
        p.addLine(to: end)
        p.addLine(to: CGPoint(x: end.x - 3, y: end.y - 13))
        return p
    }
}
