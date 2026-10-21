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

    /// SN of the card the BLE link is actually up for. `nil` = not connected
    /// (even when a card is remembered — see the note in `PlaudDirectService.init`).
    private var connectedSN: String? {
        if case .connected(let sn) = direct.phase { return sn }
        return nil
    }

    var body: some View {
        if let sn = connectedSN ?? direct.pairedSN {
            let isLive = connectedSN != nil
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.title3)
                        .foregroundStyle(Color.appAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PLAUD").font(.body.bold())
                        Text(sn).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        if let fw = direct.firmware, isLive {
                            Text(fw).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let battery = direct.battery, isLive {
                        Label(
                            "\(battery)%" + (direct.isCharging ? " \(L10n.Plaud.charging)" : ""),
                            systemImage: direct.isCharging ? "battery.100percent.bolt" : "battery.75percent"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                if !isLive {
                    // Remembered but not linked: say so, and offer the one tap
                    // that fixes it, instead of showing stale live data.
                    HStack {
                        Text(L10n.Plaud.stateDisconnected)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.Plaud.reconnect) { direct.reconnect() }
                            .font(.footnote)
                    }
                }
                // ★ Official-app parity: recording state + stop from the app.
                if direct.isRecording && isLive {
                    HStack {
                        Label(L10n.Plaud.recordingNow, systemImage: "record.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                        Spacer()
                        Button(L10n.Plaud.stopRecord, role: .destructive) {
                            direct.stopRecording()
                        }
                        .font(.footnote)
                    }
                }
                if isLive {
                    if let total = direct.storageTotal, let free = direct.storageFree, total > 0 {
                        Text("\(L10n.TicNoteCard.storageFree) \(Self.storageLine(total: total, free: free))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // History count — same "unknown is not zero" rule as the settings row.
                    Text("\(L10n.Plaud.cardRecordings) "
                         + (direct.cardFileCount.map(L10n.Plaud.cardRecordingsCount) ?? L10n.Plaud.historyUnknown))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
            }
            .padding(14)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    /// "free / total" only — the caller owns the label, so the same string
    /// serves the compact card (one line) and the settings row (label + value).
    static func storageLine(total: Int, free: Int) -> String {
        let mb: (Int) -> String = { $0 >= 1_000_000 ? String(format: "%.1f GB", Double($0) / 1_000_000) : "\($0 / 1000) MB" }
        return "\(mb(free)) / \(mb(total))"
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
            // ★ Scan-first (official-app parity): the scan/selection/status
            // block works WITHOUT credentials; the credential form is only
            // needed to actually connect, and sits right below the picked
            // card when missing.
            statusAndControls
            if !direct.isConfigured {
                setupFields
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

    /// Everything the section shows besides the credential form.
    @ViewBuilder
    private var statusAndControls: some View {
        switch direct.phase {
        case .connected(let sn):
            connectedControls(sn: sn)
        case .scanning:
            HStack { ProgressView(); Text(L10n.Plaud.scanning) }
            Button(L10n.Common.cancel) { direct.stopScan() }
            ForEach(direct.scanned) { card in
                Button {
                    direct.select(card)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name).foregroundStyle(.primary)
                            Text(card.sn).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(direct.selectedCard?.sn == card.sn
                             ? L10n.Plaud.connect
                             : L10n.Plaud.connect)
                            .font(.footnote)
                    }
                }
            }
            if let selected = direct.selectedCard {
                Label(L10n.Plaud.cardSelected(selected.name), systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .connecting(let name):
            HStack { ProgressView(); Text(name) }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            scanButton
        case .idle:
            if let selected = direct.selectedCard {
                // Picked a card but credentials are missing: show the
                // selection prominently; the setup fields are right below.
                Label(L10n.Plaud.cardSelected(selected.name), systemImage: "checkmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Remembered card, no live link (relaunch / card asleep): one tap
            // re-binds it by SN instead of asking the user to pick it again.
            if let sn = direct.pairedSN {
                Label("\(L10n.Plaud.stateDisconnected) · \(sn)",
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(L10n.Plaud.reconnect) { direct.reconnect() }
            }
            scanButton
        }

        if direct.isSyncing { ProgressView() }
        if let msg = direct.syncMessage {
            Text(msg).font(.footnote).foregroundStyle(.secondary)
        }
        if releasedNote {
            Label(L10n.Plaud.released, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if direct.isConfigured {
            // ★ Return / hand-back guarantee (2026-10-21 user question "7 天无理由"):
            // takeover must be reversible — these two release the card so the
            // official app (or a buyer) can pair it again as if new.
            Button(L10n.Plaud.unbindKeep, role: .destructive) {
                direct.releaseDevice(factoryReset: false)
                releasedNote = true
            }
            .disabled(!direct.phase.isConnected)
            Button(L10n.Plaud.factoryReset, role: .destructive) {
                showFactoryConfirm = true
            }
            .disabled(!direct.phase.isConnected)
            Button(L10n.Plaud.deactivate, role: .destructive) {
                direct.deactivate()
                message = nil
            }
        }
    }

    /// Battery / recording / firmware row set shown while connected —
    /// parity with the official app's device panel.
    @ViewBuilder
    private func connectedControls(sn: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.Plaud.connectedTo(sn)).font(.body.weight(.medium))
                if let fw = direct.firmware {
                    Text(fw).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let battery = direct.battery {
                Label(
                    "\(battery)%" + (direct.isCharging ? " \(L10n.Plaud.charging)" : ""),
                    systemImage: direct.isCharging ? "battery.100percent.bolt" : "battery.75percent"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        if direct.isRecording {
            HStack {
                Label(L10n.Plaud.recordingNow, systemImage: "record.circle")
                    .foregroundStyle(.red)
                Spacer()
                Button(L10n.Plaud.stopRecord, role: .destructive) {
                    direct.stopRecording()
                }
            }
        } else {
            Button {
                direct.startRecording()
            } label: {
                Label(L10n.Plaud.startRecord, systemImage: "record.circle")
            }
        }
        // ★ History count (2026-10-21 user request "录音跟历史条数"): how many
        // recordings the card is holding right now, re-readable on demand.
        // "Not read yet" instead of 0 — an unread count is not a zero.
        HStack {
            Text(L10n.Plaud.cardRecordings)
            Spacer()
            Text(direct.cardFileCount.map(L10n.Plaud.cardRecordingsCount) ?? L10n.Plaud.historyUnknown)
                .foregroundStyle(.secondary)
            Button {
                direct.refreshCardRecordings()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.Plaud.refresh)
        }
        if let total = direct.storageTotal, let free = direct.storageFree, total > 0 {
            HStack {
                Text(L10n.TicNoteCard.storageFree)
                Spacer()
                Text(PlaudDeviceCard.storageLine(total: total, free: free)).foregroundStyle(.secondary)
            }
        }
        Button(L10n.Plaud.syncFromCard) { direct.syncFromCard() }
            .disabled(direct.isSyncing)

        Toggle(L10n.Plaud.deleteAfterSync, isOn: $direct.deleteAfterSync)
        Button(L10n.Plaud.disconnect) { direct.disconnect() }
    }

    private var scanButton: some View {
        Button {
            message = nil
            direct.startScan()
        } label: {
            if direct.phase == .scanning {
                HStack { ProgressView(); Text(L10n.Plaud.scanning) }
            } else {
                Label(L10n.Plaud.scanNearby, systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }

    // MARK: first-time setup (only the credential form; scan lives above)

    @ViewBuilder
    private var setupFields: some View {
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
            // A card picked before activation now proceeds automatically —
            // the official app behaves the same way (select → key → connect).
            direct.connectSelected()
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Known-devices row + detail page

/// One row in Settings → Devices & Library → Known devices for a PLAUD card.
///
/// Why a dedicated row: the generic ledger row only knows name / id / last-seen,
/// which is all `DeviceRecord` stores. A PLAUD card additionally has live BLE
/// state the service already holds (battery, charging, recording, firmware,
/// history count) — showing "PLAUD Note Pro / plaud-881…" and nothing else
/// would make it the odd one out next to the other cards' pages.
struct PlaudLedgerRow: View {
    @ObservedObject private var direct = PlaudDirectService.shared
    let sn: String
    let record: AppConfig.DeviceRecord

    private var isThisCardConnected: Bool {
        if case .connected(let connectedSN) = direct.phase { return connectedSN == sn }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.name).font(.body)
                if direct.isRecording && isThisCardConnected {
                    Text(L10n.Plaud.recordingNow)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                if let battery = direct.battery, isThisCardConnected {
                    Label(
                        "\(battery)%" + (direct.isCharging ? " \(L10n.Plaud.charging)" : ""),
                        systemImage: direct.isCharging ? "battery.100percent.bolt" : "battery.75percent"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
            }
            Text(sn).font(.caption2.monospaced()).foregroundStyle(.secondary)
            if let fw = direct.firmware, isThisCardConnected {
                Text(fw).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(isThisCardConnected ? L10n.Plaud.stateConnected : L10n.Plaud.stateDisconnected)
                    .font(.caption2)
                    .foregroundStyle(isThisCardConnected ? Color.appAccent : .secondary)
                Text("·").font(.caption2).foregroundStyle(.secondary)
                Text("\(L10n.Plaud.cardRecordings) "
                     + (direct.cardFileCount.map(L10n.Plaud.cardRecordingsCount) ?? L10n.Plaud.historyUnknown))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let last = record.lastConnected {
                Text(L10n.DevicesLibrary.lastSeen(last)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Pushed from the known-devices row. Reuses the exact same control block as
/// the add-device sheet (`DirectConnectSection`), so recording start/stop,
/// history count, pull, unbind and factory reset live in ONE place — the sheet
/// is "add", this page is "manage", both drive the same service.
struct PlaudDeviceDetailView: View {
    @ObservedObject private var direct = PlaudDirectService.shared

    var body: some View {
        Form {
            DirectConnectSection(direct: direct)
        }
        .navigationTitle(L10n.Plaud.deviceDetailTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Opening the page is a "tell me about this card" request: read the
            // vitals and the history count, but do NOT start a transfer (that is
            // `refreshCardRecordings`'s probe-only contract).
            guard direct.phase.isConnected else { return }
            direct.refreshVitals()
            direct.refreshCardRecordings()
        }
        // A link that comes up while this page is open (reconnect, or the card
        // waking up) must fill the rows in — `onAppear` alone ran too early and
        // left "Not read yet" on screen forever.
        .onChange(of: direct.phase) { newPhase in
            guard newPhase.isConnected else { return }
            direct.refreshVitals()
            direct.refreshCardRecordings()
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
