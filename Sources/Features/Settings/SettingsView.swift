import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var watch: WatchSyncService
    @EnvironmentObject private var localization: LocalizationService
    @State private var versionTapCount = 0
    @State private var versionTapResetTask: Task<Void, Never>?
    @State private var devModeToast: String?

    private static let tapsToToggle = 7
    private static let tapsBeforeHint = 3

    var body: some View {
        Form {
            Section {
                NavigationLink(L10n.Settings.asrProviders) { ASRProvidersView() }
                NavigationLink(L10n.Settings.llmProviders) { LLMProvidersView() }
                NavigationLink(L10n.Settings.recordings) { RecordingsSettingsView() }
                NavigationLink(L10n.Settings.summarizeTemplates) { SummarizeTemplatesView() }
                NavigationLink(L10n.Settings.devicesAndLibrary) { DevicesLibraryView() }
                // Language sits last, right above About: it belongs to none of
                // the four feature areas above, and slotting it among them
                // would break their order. The row shows the current choice so
                // you don't have to open it to see what's set.
                NavigationLink {
                    LanguagePickerView()
                } label: {
                    HStack {
                        Text(L10n.Settings.language)
                        Spacer()
                        Text(currentLanguageLabel)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            watchSection
                .id("watch-\(localization.effective)")

            aboutSection
        }
        .padding(.top, -20)
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
    private var watchSection: some View {
        Section {
            HStack {
                Label(L10n.Watch.settingsTitle, systemImage: "applewatch")
                Spacer()
                Text(watchStatus)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(watchFooter)
        }
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
    @Environment(\.dismiss) private var dismiss
    @State private var azureVerify: VerifyState = .idle
    @State private var showAzureHelp = false
    @State private var showLeaveWarning = false

    /// When the user provides a host but omits the port, a default port is supplied. **Only written when creating the record**,
    // and not used as the displayed value for an empty field.
    private static let defaultLocalPort = 12300

    var body: some View {
        Form {
            transcriptionSection
            azureSection
            localSection
        }
        .navigationTitle(L10n.Settings.asrProviders)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { azureVerify = storedAzureVerify }
        .onDisappear { configService.saveNow() }
        .sheet(isPresented: $showAzureHelp) { AzureSpeechSetupGuide() }
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

    /// When re‑entering the page, show the previous verification result; otherwise “Saved” and “Verified usable” look identical in the UI.
    private var storedAzureVerify: VerifyState {
        switch configService.config.asrProviders.azure?.verification {
        case true: return .success
        case false: return .failed(L10n.ASR.lastVerifyFailed)
        case nil: return .idle
        }
    }

    private var configuredASR: [(key: String, label: String)] {
        var result: [(String, String)] = []
        // Only list services that are fully filled **and** whose credentials have not been rejected by verification: partially filled configs and those that failed verification would produce no transcription, and showing them as candidates would mislead users into thinking they are set up.
        if let a = configService.config.asrProviders.azure,
           !a.key.isEmpty, !a.region.isEmpty, a.verification != false {
            result.append(("azure", L10n.ASR.azure))
        }
        if let l = configService.config.asrProviders.local, !l.host.isEmpty {
            result.append(("local", L10n.ASR.localServer))
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

            Toggle(isOn: Binding(
                get: { configService.config.localVADEnabled },
                set: { configService.config.localVADEnabled = $0; configService.scheduleSave() }
            )) {
                HStack(spacing: 4) {
                    Text(L10n.ASR.localVAD)
                    InfoTip(text: L10n.ASR.localVADFooter)
                }
            }
        } header: {
            Text(L10n.ASR.transcription)
        }
    }

    private var azureSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SecureField(L10n.ASR.subscriptionKey, text: azureKeyBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    keyHint(configService.config.asrProviders.azure?.key)
                    if azureKeyMissing {
                        fieldError(L10n.ASR.keyRequired)
                    }
                    // The reason for verification failure must be displayed in the UI: changing the button to a red X alone leaves the user unaware of “why”.
                    if case .failed(let reason) = azureVerify {
                        fieldError(reason)
                    }
                }
                verifyButton(azureVerify) {
                    let key = configService.config.asrProviders.azure?.key ?? ""
                    let region = configService.config.asrProviders.azure?.region ?? ""
                    // No network call while a required field is empty — the
                    // user gets a per-field hint instead of the provider's
                    // English "Key and region required".
                    guard !key.isEmpty, !region.isEmpty else {
                        // The per-field hints below are already on screen for
                        // whichever box is empty; nothing to add here.
                        azureVerify = .idle
                        return
                    }
                    azureVerify = .verifying
                    let r = await LLMModelService.verifyAzure(key: key, region: region)
                    azureVerify = r.ok ? .success : .failed(r.error ?? L10n.ASR.verifyFailed)
                    // The conclusion must be persisted: only then will the next page load distinguish between "saved" and "verification passed",
                    // and the transcription pipeline will know that these credentials have been rejected.
                    var azure = configService.config.asrProviders.azure ?? .init(key: key, region: region)
                    azure.verifiedFingerprint = AppConfig.AsrProviders.Azure.fingerprint(key: key, region: region)
                    azure.verifiedOK = r.ok
                    configService.config.asrProviders.azure = azure
                    configService.scheduleSave()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField(L10n.ASR.region, text: azureRegionBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if azureRegionMissing {
                    fieldError(L10n.ASR.regionRequired)
                }
            }
            azureStatusRow
        } header: {
            HStack(spacing: 4) {
                Text(L10n.ASR.azureSpeech)
                Spacer()
                Button(L10n.ASR.azureHowToGetKey) { showAzureHelp = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .textCase(nil)
            }
        } footer: {
            // Providing only the key‑retrieval step leaves the user unable to judge “why configure” and “where the audio was sent”.
            // Since the page lacks a save button, without clear wording the user won’t know whether those previous entries count.
            Text(L10n.ASR.azurePurposeFooter + "\n\n" + L10n.ASR.autosaveNote)
        }
    }

    /// “Filled” and “Usable” are different: only after successful verification can we claim the configuration is usable.
    @ViewBuilder
    private var azureStatusRow: some View {
        switch azureVerify {
        case .success:
            Label(L10n.ASR.statusVerified, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .verifying:
            Text(L10n.ASR.statusVerifying)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            EmptyView()   // The failure reason is already displayed below the key field.
        case .idle:
            if !azureIncomplete {
                Text(L10n.ASR.statusUnverified)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localSection: some View {
        Section(L10n.ASR.localASRServer) {
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
        }
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
                let other = (new == "azure") ? "local" : "azure"
                configService.config.defaults.asr.fallbacks = [other]
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

    private var azureKeyBinding: Binding<String> {
        Binding(
            get: { configService.config.asrProviders.azure?.key ?? "" },
            set: { new in
                var azure = configService.config.asrProviders.azure ?? .init(key: "", region: "")
                azure.key = new
                configService.config.asrProviders.azure = azure
                // Changing credentials invalidates the previous verification result.
                azureVerify = .idle
                configService.scheduleSave()
            }
        )
    }

    private var azureRegionBinding: Binding<String> {
        Binding(
            get: { configService.config.asrProviders.azure?.region ?? "" },
            set: { new in
                var azure = configService.config.asrProviders.azure ?? .init(key: "", region: "")
                azure.region = new
                configService.config.asrProviders.azure = azure
                azureVerify = .idle
                configService.scheduleSave()
            }
        )
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
                writeLocal(local)
            }
        )
    }
}

// MARK: - LLM Providers

struct LLMProvidersView: View {
    @EnvironmentObject private var configService: ConfigService

    private var configured: [(key: String, label: String)] {
        configService.config.llmProviders.configuredProviders
    }

    var body: some View {
        Form {
            if !configured.isEmpty {
                Section {
                    Picker(selection: Binding(
                        get: { configService.config.llmProviders.primary ?? "" },
                        set: {
                            configService.config.llmProviders.primary = $0.isEmpty ? nil : $0
                            configService.scheduleSave()
                        }
                    )) {
                        Text(L10n.Common.none).tag("")
                        ForEach(configured, id: \.key) { Text($0.label).tag($0.key) }
                    } label: {
                        HStack(spacing: 4) {
                            Text(L10n.ASR.activeProvider)
                            InfoTip(text: L10n.LLM.activeProviderFooter)
                        }
                    }
                }
            }

            OpenRouterSection()
            KeyedProviderSection(
                title: "OpenAI", placeholder: "gpt-4.1",
                keyPath: \.openai, fetch: { await LLMModelService.fetchOpenAI(apiKey: $0) }
            )
            KeyedProviderSection(
                title: "Claude", placeholder: "claude-opus-4-0-20250514",
                keyPath: \.claude, fetch: { await LLMModelService.fetchClaude(apiKey: $0) }
            )
            KeyedProviderSection(
                title: "Gemini", placeholder: "gemini-2.5-pro",
                keyPath: \.gemini, fetch: { await LLMModelService.fetchGemini(apiKey: $0) }
            )
            OllamaSection()
            CustomEndpointSection()
        }
        .navigationTitle(L10n.Settings.llmProviders)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { configService.saveNow() }
    }
}

// MARK: - Keyed provider (OpenAI / Claude / Gemini)

private struct KeyedProviderSection: View {
    let title: String
    let placeholder: String
    let keyPath: WritableKeyPath<AppConfig.LlmProviders, AppConfig.LlmProviders.KeyedProvider?>
    let fetch: (String) async -> LLMModelService.FetchResult

    @EnvironmentObject private var configService: ConfigService
    @State private var verify: VerifyState = .idle
    @State private var models: [String] = []

    private var provider: AppConfig.LlmProviders.KeyedProvider? {
        configService.config.llmProviders[keyPath: keyPath]
    }

    var body: some View {
        Section(title) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SecureField(L10n.LLM.apiKey, text: apiKeyBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    keyHint(provider?.apiKey)
                }
                verifyButton(verify) {
                    guard let key = provider?.apiKey, !key.isEmpty else {
                        verify = .failed("No key"); return
                    }
                    verify = .verifying
                    let r = await fetch(key)
                    if r.ok {
                        verify = .success
                        models = r.models
                    } else {
                        verify = .failed(r.error ?? "Failed")
                    }
                }
            }

            if models.isEmpty {
                TextField(L10n.LLM.modelPlaceholder(placeholder), text: modelBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } else {
                Picker(L10n.LLM.model, selection: modelPickerBinding) {
                    Text(L10n.LLM.selectModel).tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { provider?.apiKey ?? "" },
            set: { new in
                if new.isEmpty {
                    configService.config.llmProviders[keyPath: keyPath] = nil
                } else {
                    var p = provider ?? .init(apiKey: new)
                    p.apiKey = new
                    configService.config.llmProviders[keyPath: keyPath] = p
                }
                configService.config.llmProviders.autoSelectPrimaryIfFirst()
                verify = .idle; models = []
                configService.scheduleSave()
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { provider?.model ?? "" },
            set: { new in
                var p = provider ?? .init(apiKey: "")
                p.model = new.isEmpty ? nil : new
                configService.config.llmProviders[keyPath: keyPath] = p
                configService.scheduleSave()
            }
        )
    }

    private var modelPickerBinding: Binding<String> {
        Binding(
            get: { provider?.model ?? "" },
            set: { new in
                var p = provider ?? .init(apiKey: "")
                p.model = new.isEmpty ? nil : new
                configService.config.llmProviders[keyPath: keyPath] = p
                configService.scheduleSave()
            }
        )
    }
}

// MARK: - Open Router

private struct OpenRouterSection: View {
    @EnvironmentObject private var configService: ConfigService
    @State private var verify: VerifyState = .idle
    @State private var models: [String] = []
    @State private var providerFilter = ""

    private let defaultEndpoint = "https://openrouter.ai/api/v1"

    private var config: AppConfig.LlmProviders.EndpointProvider? {
        configService.config.llmProviders.openRouter
    }

    var body: some View {
        Section("Open Router") {
            VStack(alignment: .leading, spacing: 2) {
                SecureField(L10n.LLM.apiKey, text: apiKeyBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                keyHint(config?.apiKey)
            }

            HStack {
                TextField(L10n.LLM.providerPlaceholder("anthropic"), text: $providerFilter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .onChange(of: providerFilter) { _ in models = [] }
                verifyButton(verify) {
                    guard let key = config?.apiKey, !key.isEmpty else {
                        verify = .failed("No key"); return
                    }
                    guard !providerFilter.isEmpty else {
                        verify = .failed("Enter provider first"); return
                    }
                    verify = .verifying
                    let r = await LLMModelService.fetchOpenRouter(apiKey: key, providerPrefix: providerFilter)
                    if r.ok {
                        verify = .success
                        models = r.models
                    } else {
                        verify = .failed(r.error ?? "Failed")
                    }
                }
            }

            if models.isEmpty {
                TextField(L10n.LLM.modelPlaceholder("anthropic/claude-opus-4-0"), text: modelBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } else {
                Picker(L10n.LLM.model, selection: modelPickerBinding) {
                    Text(L10n.LLM.selectModel).tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
        }
        .onAppear {
            if let model = config?.model, let slash = model.firstIndex(of: "/") {
                providerFilter = String(model[model.startIndex..<slash])
            }
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { config?.apiKey ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: defaultEndpoint)
                p.apiKey = new.isEmpty ? nil : new
                if p.endpoint.isEmpty { p.endpoint = defaultEndpoint }
                configService.config.llmProviders.openRouter = p
                configService.config.llmProviders.autoSelectPrimaryIfFirst()
                verify = .idle; models = []
                configService.scheduleSave()
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { config?.model ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: defaultEndpoint)
                p.model = new.isEmpty ? nil : new
                if p.endpoint.isEmpty { p.endpoint = defaultEndpoint }
                configService.config.llmProviders.openRouter = p
                configService.scheduleSave()
            }
        )
    }

    private var modelPickerBinding: Binding<String> {
        Binding(
            get: { config?.model ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: defaultEndpoint)
                p.model = new.isEmpty ? nil : new
                if p.endpoint.isEmpty { p.endpoint = defaultEndpoint }
                configService.config.llmProviders.openRouter = p
                configService.scheduleSave()
            }
        )
    }
}

// MARK: - Ollama

private struct OllamaSection: View {
    @EnvironmentObject private var configService: ConfigService
    @State private var verify: VerifyState = .idle
    @State private var models: [String] = []

    private let defaultEndpoint = "http://localhost:11434"

    private var config: AppConfig.LlmProviders.EndpointProvider? {
        configService.config.llmProviders.ollama
    }

    var body: some View {
        Section("Ollama") {
            HStack {
                TextField(L10n.LLM.endpointURL, text: endpointBinding)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                verifyButton(verify) {
                    let ep = config?.endpoint ?? defaultEndpoint
                    guard !ep.isEmpty else { verify = .failed("No endpoint"); return }
                    verify = .verifying
                    let r = await LLMModelService.fetchOllama(endpoint: ep)
                    if r.ok {
                        verify = .success
                        models = r.models
                    } else {
                        verify = .failed(r.error ?? "Failed")
                    }
                }
            }

            if models.isEmpty {
                TextField(L10n.LLM.modelPlaceholder("qwen3:32b"), text: modelBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } else {
                Picker(L10n.LLM.model, selection: modelPickerBinding) {
                    Text(L10n.LLM.selectModel).tag("")
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { config?.endpoint ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: defaultEndpoint)
                p.endpoint = new
                configService.config.llmProviders.ollama = p
                configService.config.llmProviders.autoSelectPrimaryIfFirst()
                verify = .idle; models = []
                configService.scheduleSave()
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { config?.model ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: defaultEndpoint)
                p.model = new.isEmpty ? nil : new
                configService.config.llmProviders.ollama = p
                configService.scheduleSave()
            }
        )
    }

    private var modelPickerBinding: Binding<String> {
        Binding(
            get: { config?.model ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: defaultEndpoint)
                p.model = new.isEmpty ? nil : new
                configService.config.llmProviders.ollama = p
                configService.scheduleSave()
            }
        )
    }
}

// MARK: - Custom endpoint

private struct CustomEndpointSection: View {
    @EnvironmentObject private var configService: ConfigService

    private var config: AppConfig.LlmProviders.EndpointProvider? {
        configService.config.llmProviders.custom
    }

    var body: some View {
        Section("Custom") {
            TextField(L10n.LLM.endpointURL, text: endpointBinding)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())

            TextField(L10n.LLM.model, text: modelBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())

            VStack(alignment: .leading, spacing: 2) {
                SecureField(L10n.LLM.apiKeyOptional, text: apiKeyBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                keyHint(config?.apiKey)
            }
        }
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { config?.endpoint ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: "")
                p.endpoint = new
                configService.config.llmProviders.custom = p
                configService.config.llmProviders.autoSelectPrimaryIfFirst()
                configService.scheduleSave()
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { config?.model ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: "")
                p.model = new.isEmpty ? nil : new
                configService.config.llmProviders.custom = p
                configService.scheduleSave()
            }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { config?.apiKey ?? "" },
            set: { new in
                var p = config ?? .init(apiKey: nil, endpoint: "")
                p.apiKey = new.isEmpty ? nil : new
                configService.config.llmProviders.custom = p
                configService.scheduleSave()
            }
        )
    }
}

// MARK: - Azure Speech setup guide

private struct AzureSpeechSetupGuide: View {
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
                let shouldDelete = target.map { ClipArtefact.of(fileNamed: name) == $0 } ?? true
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

    private var devicesSection: some View {
        Section(L10n.DevicesLibrary.knownDevices) {
            if configService.config.devices.isEmpty {
                Text(L10n.DevicesLibrary.noDevicesYet)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedDevices, id: \.0) { id, record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.name).font(.body)
                        Text(id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        if let last = record.lastConnected {
                            Text(L10n.DevicesLibrary.lastSeen(last)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indices in
                    let keys = sortedDevices.map(\.0)
                    for i in indices { configService.config.devices.removeValue(forKey: keys[i]) }
                    configService.scheduleSave()
                }
            }
        }
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
