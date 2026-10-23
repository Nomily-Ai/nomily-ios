import SwiftUI

/// The six cloud ASR vendors in one grid, one sheet — the ASR-side twin of
/// `ProviderGridSection`.
///
/// 2026-10-22 request:
/// > "把 ASR 服务器里面增加谷歌、AWS、Deepgram、AssemblyAI、Gladia、IBM Watson
/// >  Speech to Text 这些，然后按照他们的给他们加入 logo 配置好入口测试延迟性，
/// >  跟对应模型选择"
///
/// Vendor differences are **data** (`ASRCloudSpec`): Google needs one key, AWS
/// needs a key pair plus a region, Watson needs a key plus a region. Everything
/// else — the logo tile, the "is it ready" badge, the probe, the model picker — is
/// written once.
struct ASRCloudSection: View {

    @EnvironmentObject private var configService: ConfigService
    // ★ 2026-10-23 ("每次点开配置都会弹出来然后缩回去"): the two sheets used to be
    // attached to this Section — but any `@Published` change during presentation
    // (AppEnvironment broadcasts BLE/queue state constantly; `prime()` writes
    // config right when the sheet opens) rebuilds the Form's subtree and iOS
    // cancels an in-flight presentation. The user saw the sheet flash and had to
    // tap twice. The state now lives in `ASRProvidersView` and the sheets hang
    // off the Form itself, whose identity is stable across re-renders.
    @Binding var editing: ASRCloudSpec?
    @Binding var showAzure: Bool

    var body: some View {
        Section {
            // ★ 2026-10-22 ("ASR 里面 Azure Speech 这个没有在云转写里面"):
            // Azure leads the list — it is the only vendor here that the
            // transcription engine can actually use today, so it must not be the
            // one missing from "云转写".
            Button { showAzure = true } label: {
                AzureCloudRow()
            }
            .tint(.primary)
            ForEach(ASRCloudSpec.all) { spec in
                Button { editing = spec } label: {
                    ASRCloudRow(spec: spec)
                }
                .tint(.primary)
            }
        } header: {
            Text(L10n.ASRCloud.title)
        } footer: {
            Text(L10n.ASRCloud.footer)
        }
    }
}

// MARK: - Azure row

/// The wired one. Deliberately says **已接入** instead of the generic
/// "ready / needs key" badge: among six configurable-but-not-routed vendors, the
/// user needs to know which one produces transcripts *now*.
private struct AzureCloudRow: View {
    @EnvironmentObject private var configService: ConfigService

    private var azure: AppConfig.AsrProviders.Azure? {
        configService.config.asrProviders.azure
    }

    private var verified: Bool { azure?.verification == true }

    var body: some View {
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
                Text(L10n.ASR.azureSpeech).foregroundStyle(.primary)
                Text(azure?.region.isEmpty == false
                     ? (azure?.region ?? "")
                     : L10n.ASRCloud.azureWired)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // ★ 2026-10-23: same latency readout as the cloud rows — the verify
            // round trip in the sheet records it now.
            if let ms = ASRLatencyMemory.millis(for: "azure") {
                Text("\(ms) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if verified {
                Text(L10n.ASRCloud.ready).font(.caption2).foregroundStyle(.green)
            } else if azure?.key.isEmpty == false {
                Text(L10n.ASRCloud.needsVerify).font(.caption2).foregroundStyle(.orange)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Row

private struct ASRCloudRow: View {
    let spec: ASRCloudSpec

    @EnvironmentObject private var configService: ConfigService

    private var entry: AppConfig.AsrProviders.CloudASR? {
        configService.config.asrProviders.cloud?[spec.id]
    }

    private var hasSecrets: Bool {
        guard let secrets = entry?.secrets else { return false }
        return spec.fields.contains { field in
            field.kind == .secret && !(secrets[field.id] ?? "").isEmpty
        }
    }

    private var model: String { entry?.model ?? "" }

    var body: some View {
        HStack(spacing: 12) {
            ASRBrandTile(spec: spec)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name).foregroundStyle(.primary)
                Text(model.isEmpty ? spec.tagline : model)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let ms = ASRLatencyMemory.millis(for: spec.id) {
                Text("\(ms) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        if hasSecrets {
            if model.isEmpty {
                Text(L10n.ASRCloud.needsModel).font(.caption2).foregroundStyle(.orange)
            } else {
                Text(L10n.ASRCloud.ready).font(.caption2).foregroundStyle(.green)
            }
        } else {
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }
}

/// Logo on the vendor's own colour. Same construction as `ProviderMark`: the SVGs
/// are template masks, so the tile supplies the colour and one file covers light
/// and dark.
private struct ASRBrandTile: View {
    let spec: ASRCloudSpec
    var size: CGFloat = 32

    var body: some View {
        let t = spec.tint
        let color = Color(red: t.r, green: t.g, blue: t.b)
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(colors: [color, color.opacity(0.72)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay {
                Image(spec.brandAsset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.22)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Sheet

/// Internal (was file-private): the sheet is now presented by
/// `ASRProvidersView` — the stable Form container — not by this Section.
struct ASRCloudSheet: View {
    let spec: ASRCloudSpec

    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var probing = false
    @State private var probe: ASRCloudService.Result?
    @State private var fetched: [String] = []
    @State private var fetchHint: String?
    @State private var manualModel = false

    private var entry: AppConfig.AsrProviders.CloudASR {
        configService.config.asrProviders.cloud?[spec.id]
            ?? AppConfig.AsrProviders.CloudASR(endpoint: spec.endpoint(values: [:]))
    }

    private var secrets: [String: String] { entry.secrets ?? [:] }
    private var values: [String: String] { entry.values ?? [:] }
    private var model: String { entry.model ?? "" }

    private var endpoint: String {
        entry.endpoint.isEmpty ? spec.endpoint(values: values) : entry.endpoint
    }

    private var options: [String] {
        var list = fetched.isEmpty ? spec.models : fetched
        if !model.isEmpty, !list.contains(model) { list.insert(model, at: 0) }
        return list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ASRBrandTile(spec: spec, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.name).font(.headline)
                            Text(spec.tagline).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(spec.fields) { field in
                        fieldRow(field)
                    }
                    LabeledContent(L10n.LLM.endpointURL) {
                        Text(endpoint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } header: {
                    Text(L10n.Settings.asrProviders)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(L10n.LLM.presetConsole): \(spec.console)")
                        if let note = spec.note { Text(note) }
                        // ★ 2026-10-22: Aliyun is wired now; the honest-scope note
                        // only applies to the vendors that still aren't.
                        if spec.id == "aliyun" {
                            Text(L10n.ASRCloud.aliyunWired)
                        } else {
                            Text(L10n.ASRCloud.notWired)
                        }
                    }
                    .font(.footnote)
                }

                Section {
                    if manualModel || options.isEmpty {
                        TextField(spec.models.first ?? "model", text: modelBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    } else {
                        // ★ 2026-10-22: was an inline `Picker` — the first tap was
                        // swallowed while the pushed list re-laid itself out. See
                        // `ModelPickerView`.
                        NavigationLink {
                            ModelPickerView(title: L10n.ASRCloud.model,
                                            options: options,
                                            current: model,
                                            allowsEmpty: true) { picked in
                                modelBinding.wrappedValue = picked
                            }
                        } label: {
                            LabeledContent(L10n.ASRCloud.model) {
                                Text(model.isEmpty ? L10n.LLM.selectModel : model)
                                    .font(model.isEmpty ? .body : .body.monospaced())
                                    .foregroundStyle(model.isEmpty ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    if spec.canFetchModels {
                        Button {
                            Task { await loadModels() }
                        } label: {
                            HStack {
                                Text(L10n.ASRCloud.fetchModels)
                                Spacer()
                                if probing { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(probing || !hasRequiredSecrets)
                    }
                    if !options.isEmpty, !manualModel {
                        Button(L10n.ASRCloud.manualModel) { manualModel = true }.font(.footnote)
                    }
                } header: {
                    Text(L10n.ASRCloud.model)
                } footer: {
                    if let fetchHint { Text(fetchHint).font(.footnote) }
                }

                Section {
                    Button {
                        Task { await runProbe() }
                    } label: {
                        probeRow
                    }
                    .disabled(probing || !hasRequiredSecrets)
                } footer: {
                    Text(L10n.ASRCloud.testNote).font(.footnote)
                }

                if configService.config.asrProviders.cloud?[spec.id] != nil {
                    Section {
                        Button(role: .destructive) {
                            configService.config.asrProviders.cloud?[spec.id] = nil
                            configService.scheduleSave()
                            dismiss()
                        } label: {
                            Text(L10n.ASRCloud.remove)
                        }
                    }
                }
            }
            // Same reason as the LLM sheet: a focused field must not eat the first
            // tap on the model row.
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

    // MARK: rows

    @ViewBuilder
    private func fieldRow(_ field: ASRCloudSpec.Field) -> some View {
        let label = L10n.ASRCloud.field(field.id, fallback: field.label)
        if field.kind == .secret {
            SecureField(field.placeholder, text: secretBinding(field.id))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .accessibilityLabel(Text(label))
        } else {
            TextField(field.placeholder, text: valueBinding(field.id))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .accessibilityLabel(Text(label))
        }
    }

    @ViewBuilder
    private var probeRow: some View {
        HStack(spacing: 10) {
            if probing {
                ProgressView().controlSize(.small)
                Text(L10n.ASRCloud.testRunning).foregroundStyle(.primary)
            } else if let probe {
                Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(probe.ok ? Color.green : Color.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(probe.ok ? L10n.ASRCloud.ok(probe.millis) : (probe.error ?? ""))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if probe.ok, let detail = probe.detail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "bolt.horizontal.circle").foregroundStyle(.primary)
                Text(L10n.ASRCloud.testButton).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: behaviour

    private var hasRequiredSecrets: Bool {
        spec.fields.filter { $0.kind == .secret && $0.required }.allSatisfy {
            !((entry.secrets?[$0.id]) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Fill in what the user shouldn't have to think about: the derived address and
    /// a sensible first model. Never overwrites an existing choice.
    private func prime() {
        guard configService.config.asrProviders.cloud?[spec.id] == nil else { return }
        var cloud = configService.config.asrProviders.cloud ?? [:]
        cloud[spec.id] = AppConfig.AsrProviders.CloudASR(
            endpoint: spec.endpoint(values: [:]),
            model: spec.models.first,
            values: spec.id == "aws" || spec.id == "watson" ? ["region": spec.id == "aws" ? "us-east-1" : "us-south"] : nil
        )
        configService.config.asrProviders.cloud = cloud
        configService.scheduleSave()
    }

    private func runProbe() async {
        probing = true
        probe = nil
        let result = await ASRCloudService.test(
            spec: spec, endpoint: entry.endpoint, values: values, secrets: secrets
        )
        guard !Task.isCancelled else { probing = false; return }
        probing = false
        probe = result
        if result.ok {
            ASRLatencyMemory.save(result.millis, for: spec.id)
            if !result.models.isEmpty {
                fetched = result.models
                fetchHint = L10n.ASRCloud.modelCount(result.models.count)
            }
        } else {
            ASRLatencyMemory.clear(spec.id)
        }
    }

    private func loadModels() async {
        probing = true
        let result = await ASRCloudService.test(
            spec: spec, endpoint: entry.endpoint, values: values, secrets: secrets
        )
        guard !Task.isCancelled else { probing = false; return }
        probing = false
        probe = result
        if result.ok, !result.models.isEmpty {
            fetched = result.models
            fetchHint = L10n.ASRCloud.modelCount(result.models.count)
            ASRLatencyMemory.save(result.millis, for: spec.id)
        } else if result.ok {
            fetchHint = L10n.LLM.noChatModels
        } else {
            fetchHint = result.error
        }
    }

    // MARK: bindings

    private func secretBinding(_ fieldID: String) -> Binding<String> {
        Binding(
            get: { entry.secrets?[fieldID] ?? "" },
            set: { new in
                update { $0.secrets = ($0.secrets ?? [:]).merging([fieldID: new]) { _, b in b } }
                probe = nil
            }
        )
    }

    private func valueBinding(_ fieldID: String) -> Binding<String> {
        Binding(
            get: { entry.values?[fieldID] ?? "" },
            set: { new in
                update { entry in
                    entry.values = (entry.values ?? [:]).merging([fieldID: new]) { _, b in b }
                    // Region is part of the address for AWS / Watson, so the stored
                    // endpoint has to follow it — otherwise the sheet would show a
                    // host that no longer matches the region above it.
                    if spec.id == "aws" || spec.id == "watson" {
                        entry.endpoint = spec.endpoint(values: entry.values ?? [:])
                    }
                }
                probe = nil
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { entry.model ?? "" },
            set: { new in
                update { $0.model = new }
                probe = nil
            }
        )
    }

    private func update(_ transform: (inout AppConfig.AsrProviders.CloudASR) -> Void) {
        var cloud = configService.config.asrProviders.cloud ?? [:]
        var item = cloud[spec.id] ?? AppConfig.AsrProviders.CloudASR(endpoint: spec.endpoint(values: [:]))
        transform(&item)
        cloud[spec.id] = item
        configService.config.asrProviders.cloud = cloud
        configService.scheduleSave()
    }
}

/// Last measured round trip per vendor, so the list can show it without probing
/// again. Same shape as `LLMLatencyMemory`, different key space.
enum ASRLatencyMemory {
    private struct Entry: Codable {
        var millis: Int
        var measuredAt: Date
    }

    private static let key = "asr.cloud.latency"

    static func save(_ millis: Int, for id: String) {
        var map = load()
        map[id] = Entry(millis: millis, measuredAt: Date())
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear(_ id: String) {
        var map = load()
        map.removeValue(forKey: id)
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func millis(for id: String) -> Int? {
        guard let entry = load()[id] else { return nil }
        guard Date().timeIntervalSince(entry.measuredAt) < 2 * 24 * 3600 else { return nil }
        return entry.millis
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return map
    }
}
