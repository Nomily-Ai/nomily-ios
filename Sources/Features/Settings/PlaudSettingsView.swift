import SwiftUI

/// PLAUD sheet — dual mode (2026-10-21).
///
/// **Direct connect (primary, recommended)** — SDK takeover, same mental
/// model as the other recorder cards (A1): fill the developer Client ID +
/// Secret once (dev.plaud.ai), then Bluetooth scan → connect → pull the
/// ORIGINAL audio files off the card. No PLAUD consumer account involved,
/// so a phone-number account works fine here.
///
/// **Cloud sync (secondary, compatibility)** — sign in with an EMAIL-based
/// consumer account and download what the official app uploaded. Kept for
/// users who don't want to unbind from the official app.
///
/// Entry point: the ADD-DEVICE flow (ScannerSheet row → this sheet), per
/// user feedback — not the device page bottom and not Settings. The former
/// `PlaudSettingsView` wrapper was folded into `PlaudAddSheet`.
struct PlaudAddSheet: View {
    @ObservedObject private var direct = PlaudDirectService.shared
    @ObservedObject private var plaud = PlaudCloudService.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DirectConnectSection(direct: direct)
                CloudSyncSection(plaud: plaud)
            }
            .navigationTitle(L10n.Plaud.addTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Device-page card (device segment)

/// Shown in the Recordings tab's device segment while the card is connected
/// (direct mode) — PLAUD sits next to the other recorder devices, mirroring
/// how D·NOTE / TicNote present themselves there.
struct PlaudDeviceCard: View {
    @ObservedObject private var direct = PlaudDirectService.shared

    var body: some View {
        if case .connected(let sn) = direct.phase {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.title3)
                        .foregroundStyle(Color.appAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PLAUD").font(.body.bold())
                        Text(sn).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let battery = direct.battery {
                        Label("\(battery)%", systemImage: direct.battery == 100 ? "battery.100percent.bolt" : "battery.75percent")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let total = direct.storageTotal, let free = direct.storageFree, total > 0 {
                    Text(Self.storageLine(total: total, free: free))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    direct.syncFromCard()
                } label: {
                    if direct.isSyncing {
                        HStack { ProgressView(); Text(L10n.Plaud.syncFromCard) }
                    } else {
                        Label(L10n.Plaud.syncFromCard, systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(direct.isSyncing)
                if let msg = direct.syncMessage {
                    Text(msg).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private static func storageLine(total: Int, free: Int) -> String {
        let mb: (Int) -> String = { $0 >= 1_000_000 ? String(format: "%.1f GB", Double($0) / 1_000_000) : "\($0 / 1000) MB" }
        return "\(L10n.TicNoteCard.storageFree) \(mb(free)) / \(mb(total))"
    }
}

/// Internal (not private) on purpose: `PlaudAddSheet` — the **add device**
/// flow opened from the scan page — reuses this exact section, so the
/// first-time credential setup and the scan/connect list live in ONE place.
struct DirectConnectSection: View {
    @ObservedObject var direct: PlaudDirectService
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var domain = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showFactoryConfirm = false
    @State private var releasedNote = false

    var body: some View {
        Section {
            if direct.isConfigured {
                activatedContent
            } else {
                setupContent
            }
        } header: {
            Text(L10n.Plaud.directHeader)
        } footer: {
            Text(L10n.Plaud.directFooter)
        }
        .confirmationDialog(L10n.Plaud.factoryResetTitle, isPresented: $showFactoryConfirm, titleVisibility: .visible) {
            Button(L10n.Plaud.erase, role: .destructive) {
                direct.releaseDevice(factoryReset: true)
                releasedNote = true
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Plaud.factoryResetMsg)
        }
    }

    // MARK: already activated

    @ViewBuilder
    private var activatedContent: some View {
        switch direct.phase {
        case .connected(let sn):
            Label(L10n.Plaud.connectedTo(sn), systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.primary)
            Button(L10n.Plaud.syncFromCard) { direct.syncFromCard() }
                .disabled(direct.isSyncing)
        case .scanning:
            HStack { ProgressView(); Text(L10n.Plaud.scanning) }
            ForEach(direct.scanned) { card in
                Button {
                    direct.connect(card)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name).foregroundStyle(.primary)
                            Text(card.sn).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(L10n.Plaud.connect).font(.footnote)
                    }
                }
            }
        case .connecting(let name):
            HStack { ProgressView(); Text(name) }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            scanButton
        case .idle:
            scanButton
        }

        if direct.isSyncing { ProgressView() }
        if let msg = direct.syncMessage {
            Text(msg).font(.footnote).foregroundStyle(.secondary)
        }
        Toggle(L10n.Plaud.deleteAfterSync, isOn: $direct.deleteAfterSync)
        if releasedNote {
            Label(L10n.Plaud.released, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        // ★ Return / hand-back guarantee (2026-10-21 user question "7 天无理由"):
        // takeover must be reversible — these two release the card so the
        // official app (or a buyer) can pair it again as if new.
        Button(L10n.Plaud.unbindKeep, role: .destructive) {
            direct.releaseDevice(factoryReset: false)
            releasedNote = true
        }
        Button(L10n.Plaud.factoryReset, role: .destructive) {
            showFactoryConfirm = true
        }
        Button(L10n.Plaud.deactivate, role: .destructive) {
            direct.deactivate()
            message = nil
        }
    }

    private var scanButton: some View {
        Button(L10n.Plaud.scan) {
            message = nil
            direct.startScan()
        }
    }

    // MARK: first-time setup

    @ViewBuilder
    private var setupContent: some View {
        TextField(L10n.Plaud.clientId, text: $clientId)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField(L10n.Plaud.clientSecret, text: $clientSecret)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        TextField(L10n.Plaud.domain, text: $domain, prompt: Text(verbatim: PlaudDirectService.defaultDomain))
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        Button {
            Task { await activate() }
        } label: {
            if busy { ProgressView() } else { Text(L10n.Plaud.directActivate) }
        }
        .disabled(busy || clientId.isEmpty || clientSecret.isEmpty)
        if let message {
            Text(message).font(.footnote).foregroundStyle(.secondary)
        }
        Label(L10n.Plaud.devHint, systemImage: "key.horizontal")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func activate() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await direct.activate(
                clientId: clientId, secret: clientSecret,
                domain: domain.isEmpty ? PlaudDirectService.defaultDomain : domain
            )
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Cloud sync (compatibility)

private struct CloudSyncSection: View {
    @ObservedObject var plaud: PlaudCloudService
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var message: String?
    @State private var syncSummary: String?

    var body: some View {
        Section {
            if plaud.isSignedIn {
                LabeledContent(L10n.Plaud.accountLabel, value: plaud.email ?? "")
                Button(L10n.Plaud.syncNow) { Task { await sync() } }
                    .disabled(busy)
                if busy { ProgressView() }
                if let syncSummary {
                    Text(syncSummary).font(.footnote).foregroundStyle(.secondary)
                }
                Button(L10n.Plaud.signOut, role: .destructive) {
                    plaud.signOut()
                    codeSent = false
                }
            } else {
                TextField(L10n.Plaud.emailPlaceholder, text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if codeSent {
                    TextField(L10n.Plaud.codePlaceholder, text: $code)
                        .keyboardType(.numberPad)
                    Button(L10n.Plaud.signIn) { Task { await signIn() } }
                        .disabled(busy || code.isEmpty || email.isEmpty)
                } else {
                    Button(L10n.Plaud.sendCode) { Task { await sendCode() } }
                        .disabled(busy || email.isEmpty)
                }
                if busy { ProgressView() }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Label(L10n.Plaud.cloudNote, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Plaud.syncHeader)
        } footer: {
            if plaud.isSignedIn {
                Text(L10n.Plaud.syncFooter)
            }
        }
    }

    private func sendCode() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await plaud.sendCode(to: email)
            codeSent = true
            message = L10n.Plaud.codeSent
        } catch {
            message = error.localizedDescription
        }
    }

    private func signIn() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await plaud.verify(code, email: email)
            code = ""
        } catch {
            message = error.localizedDescription
        }
    }

    private func sync() async {
        busy = true
        syncSummary = nil
        defer { busy = false }
        do {
            let (done, skipped) = try await PlaudCloudService.shared.syncAll { _, _, _ in }
            syncSummary = L10n.Plaud.syncResult(done, skipped)
        } catch {
            syncSummary = error.localizedDescription
        }
    }
}
