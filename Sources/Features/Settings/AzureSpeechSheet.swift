import SwiftUI

/// **Azure Speech** — the one cloud vendor that is already wired into the
/// transcription engine (`TranscriptionService` speaks Azure natively).
///
/// ★ 2026-10-22 (user: "ASR 里面 Azure Speech 这个没有在云转写里面需要优化调整"):
/// the ASR page grew a "云转写" list of six vendors — and the only vendor that can
/// actually transcribe was **not in it**, sitting in its own section above. That
/// reads as "Azure is something else", which is exactly backwards. Azure is now the
/// first row of the cloud list and opens this sheet, so there is one place to look
/// for "cloud speech-to-text" and the list is ordered by "works today" first.
///
/// Why it is a **separate sheet** instead of one more `ASRCloudSpec` entry: those
/// six are credential + probe only (not routed into the engine yet), while Azure
/// needs region + key + a real verification round trip and is the provider the
/// pipeline uses. Flattening it into the generic form would have thrown away the
/// verified/unverified distinction, which is the state the engine trusts.
struct AzureSpeechSheet: View {
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var verify: VerifyState = .idle
    @State private var showHelp = false
    /// Round trip of the last verify, so the test row can say "可用 · 1234 ms"
    /// even before the value is read back from `ASRLatencyMemory`.
    @State private var lastMillis: Int?

    private var azure: AppConfig.AsrProviders.Azure? {
        configService.config.asrProviders.azure
    }
    private var key: String { azure?.key ?? "" }
    private var region: String { azure?.region ?? "" }
    private var keyMissing: Bool { key.isEmpty }
    private var regionMissing: Bool { region.isEmpty }

    private var keyBinding: Binding<String> {
        Binding(
            get: { key },
            set: { new in
                var a = azure ?? .init(key: "", region: "")
                a.key = new
                configService.config.asrProviders.azure = a
                configService.scheduleSave()
                // Any edit invalidates the stored verdict — otherwise the UI keeps
                // claiming "verified" for credentials that were just changed.
                verify = .idle
            }
        )
    }

    private var regionBinding: Binding<String> {
        Binding(
            get: { region },
            set: { new in
                var a = azure ?? .init(key: "", region: "")
                a.region = new
                configService.config.asrProviders.azure = a
                configService.scheduleSave()
                verify = .idle
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color(red: 0.0, green: 0.47, blue: 0.83),
                                         Color(red: 0.0, green: 0.47, blue: 0.83).opacity(0.72)],
                                startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 32, height: 32)
                            .overlay {
                                Image("BrandAzure")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundStyle(.white)
                                    .padding(7)
                            }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.ASR.azureSpeech).font(.headline)
                            Text(L10n.ASRCloud.azureWired)
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            SecureField(L10n.ASR.subscriptionKey, text: keyBinding)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                            azureKeyHint(key)
                            if keyMissing { azureFieldError(L10n.ASR.keyRequired) }
                            if case .failed(let reason) = verify { azureFieldError(reason) }
                        }
                        azureVerifyButton(verify) { await runVerify() }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        TextField(L10n.ASR.region, text: regionBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if regionMissing { azureFieldError(L10n.ASR.regionRequired) }
                    }
                    statusRow
                } header: {
                    HStack(spacing: 4) {
                        Text(L10n.ASRCloud.credentials)
                        Spacer()
                        Button(L10n.ASR.azureHowToGetKey) { showHelp = true }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .textCase(nil)
                    }
                } footer: {
                    Text(L10n.ASR.azurePurposeFooter + "\n\n" + L10n.ASR.autosaveNote)
                        .font(.footnote)
                }

                // ★ 2026-10-23 ("Azure 没有测速"): the tiny checkmark next to the key
                // field *is* the round-trip test, but nobody reads it that way, and
                // the result vanished. A dedicated row now states the measured
                // latency in words, same as every cloud vendor's sheet.
                Section {
                    Button {
                        Task { await runVerify() }
                    } label: {
                        HStack(spacing: 10) {
                            if verify == .verifying {
                                ProgressView().controlSize(.small)
                                Text(L10n.ASRCloud.testRunning).foregroundStyle(.primary)
                            } else if case .success = verify {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L10n.ASRCloud.ok(
                                        lastMillis ?? ASRLatencyMemory.millis(for: "azure") ?? 0))
                                        .foregroundStyle(.primary)
                                    Text(L10n.ASRCloud.ready)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            } else if case .failed(let reason) = verify {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.red)
                                Text(reason)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                                    .foregroundStyle(.primary)
                                Text(L10n.ASRCloud.testButton).foregroundStyle(.primary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .disabled(verify == .verifying || key.isEmpty || region.isEmpty)
                } footer: {
                    Text(L10n.ASRCloud.testNote).font(.footnote)
                }
            }
            .navigationTitle(L10n.ASR.azureSpeech)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) {
                        configService.saveNow()
                        dismiss()
                    }
                }
            }
            .onAppear { verify = storedVerify }
            .onDisappear { configService.saveNow() }
            .sheet(isPresented: $showHelp) {
                AzureSpeechSetupGuide()
                    .environmentObject(configService)
            }
        }
    }

    /// Re-entering the sheet must not look like "never verified" — the stored
    /// verdict is part of the config for exactly this reason.
    private var storedVerify: VerifyState {
        switch azure?.verification {
        case true: return .success
        case false: return .failed(L10n.ASR.lastVerifyFailed)
        case nil: return .idle
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch verify {
        case .success:
            Label(L10n.ASR.statusVerified, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .verifying:
            Text(L10n.ASR.statusVerifying)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed:
            EmptyView()   // the reason is printed under the field
        case .idle:
            if !keyMissing, !regionMissing {
                Text(L10n.ASR.statusUnverified)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runVerify() async {
        // No network call while a required field is empty: a per-field hint is
        // more useful than the provider's English "Key and region required".
        guard !key.isEmpty, !region.isEmpty else {
            verify = .idle
            return
        }
        verify = .verifying
        // ★ 2026-10-23: record the round trip so the Azure row in the cloud list
        // shows a latency like every other vendor (the probe IS the verify).
        let started = Date()
        let result = await LLMModelService.verifyAzure(key: key, region: region)
        let millis = Int(Date().timeIntervalSince(started) * 1000)
        lastMillis = millis
        verify = result.ok ? .success : .failed(result.error ?? L10n.ASR.verifyFailed)
        if result.ok {
            ASRLatencyMemory.save(millis, for: "azure")
        } else {
            ASRLatencyMemory.clear("azure")
        }
        // Persist the verdict: the pipeline consults it before using these
        // credentials, and the list badge reads it too.
        var a = azure ?? .init(key: key, region: region)
        a.verifiedFingerprint = AppConfig.AsrProviders.Azure.fingerprint(key: key, region: region)
        a.verifiedOK = result.ok
        configService.config.asrProviders.azure = a
        configService.scheduleSave()
    }
}

// MARK: - Local helpers

/// Masked echo of the stored key: "abcd····wxyz". Same shape as the ASR page's
/// helper, duplicated rather than shared because that one is file-private.
@ViewBuilder
private func azureKeyHint(_ key: String?) -> some View {
    if let key, !key.isEmpty {
        Text("\(key.prefix(4))····\(key.suffix(4))")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
    }
}

private func azureFieldError(_ text: String) -> some View {
    Text(text).font(.caption2).foregroundStyle(.red)
}

/// One button that is also the status light: idle / spinning / ✓ / ✗.
private func azureVerifyButton(_ state: VerifyState,
                               action: @escaping () async -> Void) -> some View {
    Button {
        Task { await action() }
    } label: {
        Group {
            switch state {
            case .idle:
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            case .verifying:
                ProgressView().controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.borderless)
    .disabled(state == .verifying)
}
