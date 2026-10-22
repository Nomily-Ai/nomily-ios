import MapKit
import SwiftUI
import UIKit

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


/// Thin loudness bar fed by the live PCM blocks — the visible proof that the
/// card is streaming audio into the app while recording.
struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(Color.appAccent)
                    .frame(width: max(2, geo.size.width * min(1, max(0, level))))
            }
        }
    }
}

/// Internal (not private) on purpose: `PlaudAddSheet` — the **add device**
/// flow opened from the scan page — reuses this exact section, so the
/// first-time credential setup and the scan/connect list live in ONE place.
struct DirectConnectSection: View {
    @ObservedObject var direct: PlaudDirectService
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var editingKeys = false
    @State private var busy = false
    @State private var message: String?
    @State private var showHandoverConfirm = false
    @State private var handedOver = false
    @State private var showRecoveryConfirm = false
    @State private var recoveryDoneShown = false
    @State private var releasedNote = false
    @State private var showRename = false
    @State private var nameDraft = ""
    @State private var copiedSN = false

    var body: some View {
        nameSection
            .alert(L10n.Plaud.rename, isPresented: $showRename) {
                TextField(L10n.Plaud.deviceName, text: $nameDraft)
                Button(L10n.Common.save) { direct.rename(to: nameDraft) }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Plaud.renameMessage)
            }
        mainSection
        if direct.isConfigured {
            batteryModeSection
            transferPrefsSection
            handoverSection
        }
    }

    /// ★ Recording mode (2026-10-22: "官方 App 的几个模式搬过来") — the card's
    /// `BatteryMode` common setting: 高性能 / 自适应 / 长续航. Values and copy
    /// mirror the official app's 电池电量 page; the hour estimates are the
    /// official figures for high performance (linear 0.3 h per battery %).
    private var batteryModeSection: some View {
        Section {
            if direct.batteryModeUnsupported {
                Label(L10n.Plaud.batteryModeUnsupported, systemImage: "xmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker(L10n.Plaud.batteryMode, selection: Binding(
                    get: { direct.batteryMode },
                    set: { if let mode = $0 { direct.setBatteryMode(mode) } }
                )) {
                    Text(L10n.Plaud.bmHigh).tag(0 as Int?)
                    Text(L10n.Plaud.bmAdaptive).tag(1 as Int?)
                    Text(L10n.Plaud.bmEndurance).tag(2 as Int?)
                }
                .disabled(!direct.phase.isConnected)
                batteryModeFooter
            }
        } header: {
            Text(L10n.Plaud.batteryModeHeader)
        }
    }

    @ViewBuilder
    private var batteryModeFooter: some View {
        let desc: String = {
            switch direct.batteryMode {
            case 1: return L10n.Plaud.bmAdaptiveDesc
            case 2: return L10n.Plaud.bmEnduranceDesc
            default: return L10n.Plaud.bmHighDesc
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            if !direct.phase.isConnected {
                Text(L10n.Plaud.bmNeedConnect)
            }
            if direct.batteryMode == nil {
                Text(L10n.Plaud.bmUnread)
            }
            Text(desc)
            if direct.phase.isConnected, let pct = direct.battery, direct.batteryMode == 0 {
                // Official table: 100%→30 h, 80%→24 h … 5%→1.5 h (0.3 h/%).
                Text(L10n.Plaud.bmEstimate(pct, Double(pct) * 0.3))
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var mainSection: some View {
        Section {
            // ★ Scan-first (official-app parity): the scan/selection/status
            // block works WITHOUT credentials; the credential form is only
            // needed to actually connect, and sits right below the picked
            // card when missing.
            statusAndControls
            if !direct.isConfigured {
                setupFields
            } else if editingKeys {
                // ★ 2026-10-22: keys are stored after the first activation, so
                // the form is hidden by default — but "where do I type a new
                // key?" needs an answer. Prefill from the store so re-activating
                // with the same values is a no-op and switching apps is easy.
                setupFields
            } else {
                Button(L10n.Plaud.changeKeys) {
                    clientId = direct.clientId
                    clientSecret = direct.clientSecret
                    message = nil
                    editingKeys = true
                }
                Label(L10n.Plaud.keysStoredHint, systemImage: "key.horizontal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Plaud.directHeader)
        } footer: {
            Text(L10n.Plaud.directFooter)
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
        // ★ The record button does NOT live here (2026-10-21: "录音按键不是在
        // 设备信息里面"). Recording is a daily action and belongs on the home
        // device page, right above the card's file list — device info is for
        // identity, capacity and connection housekeeping.
        // ★ History count: how many recordings the card is holding right now.
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
        // ★ Storage as a bar (2026-10-21: "设备内存展示是进度条，用了多少剩下多少").
        // A bare "62.5 GB / 62.5 GB" line made the user do the arithmetic; the
        // bar answers "how full is it" at a glance, and the two labels split
        // used from free.
        if let total = direct.storageTotal, let free = direct.storageFree, total > 0 {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(max(0, total - free)), total: Double(total))
                    .progressViewStyle(.linear)
                HStack(spacing: 8) {
                    Text(L10n.Plaud.storageUsed(PlaudCardFilesView.sizeText(total - free)))
                    Spacer()
                    Text(L10n.Plaud.storageLeft(PlaudCardFilesView.sizeText(free)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        Button(L10n.Plaud.syncFromCard) { direct.syncFromCard() }
            .disabled(direct.isRecording)

        Button(L10n.Plaud.disconnect) { direct.disconnect() }
    }

    /// Name + SN + rename (2026-10-21: "需要支持修改设备名称" / "设备详情要有产品的 SN").
    ///
    /// Shown whenever we know which card this is (`pairedSN` or a live link), so
    /// the name can be fixed and the SN read off from Settings even while the
    /// card is asleep.
    @ViewBuilder
    private var nameSection: some View {
        let sn = direct.pairedSN ?? { if case .connected(let s) = direct.phase { return s }; return nil }()
        if sn != nil || direct.phase.isConnected {
            Section {
                HStack {
                    Text(L10n.Plaud.deviceName)
                    Spacer()
                    Text(direct.displayName)
                        .foregroundStyle(.secondary)
                    Button {
                        nameDraft = direct.displayName
                        showRename = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.Plaud.rename)
                }
                if let sn {
                    HStack {
                        Text(L10n.Plaud.serialNumber)
                        Spacer()
                        // Selectable: the SN is what you paste into a support
                        // ticket or the official app's device list.
                        Text(sn)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = sn
                            copiedSN = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedSN = false }
                        } label: {
                            Image(systemName: copiedSN ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.Plaud.copySN)
                    }
                }
            } header: {
                Text(L10n.Plaud.deviceInfoHeader)
            }
        }
    }

    /// Transfer preferences (2026-10-21 request: "add an auto-delete-after-
    /// transfer setting in the PLAUD device info"). Deliberately its **own**
    /// section outside `connectedControls`: a preference must be reachable while
    /// the card is away, and burying it under six live rows is why nobody found
    /// it in the add-device sheet.
    private var transferPrefsSection: some View {
        Section {
            Toggle(L10n.Plaud.deleteAfterSync, isOn: $direct.deleteAfterSync)
        } header: {
            Text(L10n.Plaud.transferHeader)
        } footer: {
            Text(L10n.Plaud.deleteAfterSyncFooter)
        }
    }

    /// Hand the card back to PLAUD's own app (2026-10-21 8th round: "增加一个
    /// 切换通过官方 app 绑定的按钮，会解绑卡片清除录音恢复出厂设置").
    ///
    /// Why one purpose-built exit instead of the old "factory reset" row: the BLE
    /// work was already there, but it never said *why* you would want it, and the
    /// user was left to discover on their own that a bound card is invisible to
    /// the official app. So this button does the full hand-back — `depair(clear:)`
    /// + cloud unbind + radio released — and then prints the three steps that
    /// actually decide whether the official app can pair (quit Nomily, forget the
    /// OS-level pairing, then pair). "Unbind but keep recordings" stays as the
    /// non-destructive variant, and deactivate stays as the local-only reset.
    private var handoverSection: some View {
        Section {
            Button(L10n.Plaud.handover) {
                // Enabled even while disconnected: the common case is "the card
                // is asleep and the official app won't pair", and a greyed-out
                // row there explains nothing. Say what is missing instead.
                if direct.phase.isConnected {
                    showHandoverConfirm = true
                } else {
                    message = L10n.Plaud.notConnected
                }
            }
            Button(L10n.Plaud.unbindKeep, role: .destructive) {
                if direct.phase.isConnected {
                    direct.releaseDevice(factoryReset: false)
                    releasedNote = true
                } else {
                    message = L10n.Plaud.notConnected
                }
            }
            Button(L10n.Plaud.deactivate, role: .destructive) {
                direct.deactivate()
                message = nil
            }
            // ★ Device recovery (9th round: "Nomily 无法匹配 + 官方中国版加不上"):
            // when the on-device lock matches NO app any more, the documented
            // escape is a force-clear handshake with each historical client id,
            // then a full wipe. Lives here because it is the last resort of the
            // same hand-back story.
            Button(L10n.Plaud.recoveryButton) {
                showRecoveryConfirm = true
            }
            .disabled(direct.phase.isBusy && !direct.phase.isConnected)
            if recoveryDoneShown {
                Label(L10n.Plaud.recoveryDone, systemImage: "checkmark.seal.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
            if handedOver && direct.pairedSN == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.Plaud.handoverDone, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(L10n.Plaud.handoverStep1)
                    Text(L10n.Plaud.handoverStep2)
                    Text(L10n.Plaud.handoverStep3)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Plaud.handoverHeader)
        } footer: {
            Text(L10n.Plaud.handoverFooter)
        }
        .confirmationDialog(
            L10n.Plaud.handoverConfirmTitle,
            isPresented: $showHandoverConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.Plaud.handoverConfirmAction, role: .destructive) {
                direct.releaseDevice(factoryReset: true)
                releasedNote = true
                handedOver = true
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Plaud.handoverConfirmMsg)
        }
        .confirmationDialog(
            L10n.Plaud.recoveryConfirmTitle,
            isPresented: $showRecoveryConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.Plaud.recoveryConfirmAction, role: .destructive) {
                direct.startRecovery()
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Plaud.recoveryConfirmMsg)
        }
        .onChange(of: direct.syncMessage) { msg in
            if msg == L10n.Plaud.recoveryDone { recoveryDoneShown = true }
            if msg == L10n.Plaud.recoveryRunning { recoveryDoneShown = false }
        }
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
        // ★ Two fields only (2026-10-21 8th round: "填写 2 个值，下面那个没有用的
        // 则不用填写去掉那个框"). The third box was the platform host — it only ever
        // held `PlaudDirectService.defaultDomain`, and a hand-typed host could
        // only break sign-in. The service still reads the stored value, so an
        // existing custom host keeps working; new setups just get the default.
        TextField(L10n.Plaud.clientId, text: $clientId)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField(L10n.Plaud.clientSecret, text: $clientSecret)
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
                domain: PlaudDirectService.defaultDomain
            )
            // A card picked before activation now proceeds automatically —
            // the official app behaves the same way (select → key → connect).
            direct.connectSelected()
            editingKeys = false
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Home device segment: the card's own page

/// The PLAUD card as it appears in the Recordings tab's **device segment**.
///
/// ★ 2026-10-21 (3rd round) — "device info belongs behind the top-left device
/// tap, not on the home page". Battery / SN / storage / firmware are diagnostics:
/// they belong in the card's own page, which is what the other recorder cards do
/// too (TicNote: one `cardRow` here → `cardInfoSheet` for the details). So this
/// page is now three things and nothing else:
///
///   1. one compact row (name + link state) that **opens the device info**;
///   2. the recording control (start/stop, clock, level, live marks);
///   3. what is **on** the card, with pull-per-row and swipe-to-delete.
///
/// Delete is swipe-only and needs no confirmation (user: "右滑删除…点击删除即可，
/// 无需在弹窗确认") — the row also lost its trash button for the same reason.
struct PlaudCardFilesView: View {
    @ObservedObject private var direct = PlaudDirectService.shared
    @State private var showInfo = false
    /// Multi-select on the card's list ("不只滑动，还要能多选拉取/删除"). Same
    /// state shape as `LibraryView` (`isSelecting` + `selectedIDs`), so the two
    /// lists behave identically.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<Int> = []
    @State private var showBatchDeleteConfirm = false
    /// Same epoch anchor as `RecorderControl.tickAnchor` — see the note there.
    static let tickAnchor = Date(timeIntervalSince1970: 0)

    private var connectedSN: String? {
        if case .connected(let sn) = direct.phase { return sn }
        return nil
    }

    private var cardSN: String? { connectedSN ?? direct.pairedSN }

    private var cardName: String {
        if cardSN != nil { return direct.displayName }
        return "PLAUD"
    }

    var body: some View {
        List {
            identitySection
            // ★ 2026-10-21: the record row lives HERE (home → Device), never in
            // the device-info sheet — the user's own words were "the record
            // button does not belong in device info". It stays visible while
            // the card is asleep too: a tap wakes the card and starts the
            // recording once the bind answers (`startRecordingWhenReady`).
            recordingSection
            if connectedSN != nil {
                transferSection
            }
            filesSection
        }
        .listStyle(.insetGrouped)
        // Selection bar floats over the list's own bottom edge (same placement
        // LibraryView uses) instead of a toolbar sheet — no second sheet to
        // dismiss, and the list keeps scrolling underneath.
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .refreshable {
            direct.refreshVitals()
            direct.refreshCardRecordings()
        }
        .sheet(isPresented: $showInfo) { PlaudDeviceInfoSheet() }
        .alert(L10n.Plaud.deleteSelectedTitle, isPresented: $showBatchDeleteConfirm) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Common.delete, role: .destructive) {
                direct.delete(files: selectedFiles)
                exitSelection()
            }
        } message: {
            Text(L10n.Plaud.deleteSelectedMessage(selectedFiles.count))
        }
        .onChange(of: direct.cardFiles) { files in
            // Keep the tick set in sync with reality: a file deleted from the
            // card (by us or by the card itself) must not stay ticked, and an
            // empty list has nothing left to select.
            let alive = Set(files.map(\.sessionID))
            selectedIDs.formIntersection(alive)
            if files.isEmpty, isSelecting { exitSelection() }
        }
    }

    // MARK: - ① one row: the way into device info

    private var identitySection: some View {
        Section {
            Button {
                showInfo = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.title3)
                        .foregroundStyle(Color.appAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cardName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(connectedSN != nil ? L10n.Plaud.stateConnected : L10n.Plaud.stateDisconnected)
                            .font(.caption)
                            .foregroundStyle(connectedSN != nil ? Color.appAccent : .secondary)
                    }
                    Spacer()
                    if direct.isRecording {
                        Label(L10n.Plaud.recordingNow, systemImage: "record.circle")
                            .labelStyle(.iconOnly)
                            .font(.body)
                            .foregroundStyle(.red)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.Plaud.deviceInfoHint)
        }
    }

    // MARK: - ② recording control + clock + level + live marks

    @ViewBuilder
    private var recordingSection: some View {
        Section {
            // The clock ticks because the card's own millisecond counter only
            // arrives with each PCM block; between blocks our anchor fills in.
            // ⚠️ Anchor to the epoch, not `.now`: `from: .now` re-phases on every
            // body evaluation, so the second hand visible got stuck/delayed
            // (the same trap `RecorderControl` documents).
            TimelineView(.periodic(from: Self.tickAnchor, by: 1)) { context in
                if direct.isRecording {
                    HStack(spacing: 10) {
                        Label(L10n.Plaud.recordingElapsed(Self.elapsedText(direct, at: context.date)),
                              systemImage: "record.circle")
                            .foregroundStyle(.red)
                        Spacer()
                        Button(L10n.Plaud.stopRecord, role: .destructive) {
                            direct.stopRecording()
                        }
                        .buttonStyle(.borderless)
                    }
                } else if direct.isPaused {
                    HStack(spacing: 10) {
                        Label(L10n.Plaud.recordingPaused, systemImage: "pause.circle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L10n.Plaud.resumeRecord) { direct.resumeRecording() }
                            .buttonStyle(.borderless)
                    }
                } else {
                    Button {
                        direct.startRecordingWhenReady()
                    } label: {
                        HStack {
                            Label(L10n.Plaud.startRecord, systemImage: "record.circle")
                            Spacer()
                            if connectedSN == nil {
                                Text(L10n.Plaud.stateDisconnected)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(direct.phase.isBusy)
                }
            }
            if direct.isRecording || direct.liveStreaming {
                LevelMeter(level: direct.liveLevel)
                    .frame(height: 6)
            }
            // ★ 打点 (bookmarks pressed on the card). ★ 2026-10-22 on request:
            //   nothing at all is shown until there IS a count — a row that says
            //   "the card reports marks when the take ends" for the whole
            //   recording is noise. When the card does report them, its times are
            //   what matters, so they are shown as chips next to the count (that
            //   is also where the old "本次打点" row was pointing).
            if direct.recordMarkCount > 0 {
                marksRow
            }
            if let notice = direct.recordNotice {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            }
            // The live transcript itself lives on the 实时 tab (`PlaudLiveScreen`) —
            // it is not a footnote under the recording controls any more.
        }
    }

    private var marksRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(L10n.Plaud.marksCount(direct.recordMarkCount))
                .font(.caption)
                .foregroundStyle(.orange)
            ForEach(Array(direct.markTimestamps.prefix(4).enumerated()), id: \.offset) { _, time in
                Text(PlaudLiveLine.stamp(time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
            }
            if direct.markTimestamps.count > 4 {
                Text("+\(direct.markTimestamps.count - 4)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - ③ transfer progress

    /// Why a dedicated block: the old page only had a footer sentence
    /// ("Transferring file 2…") with no bar and no speed, so a multi-minute BLE
    /// pull looked frozen. Progress + "2 / 5" + KB/s answer "is it moving".
    @ViewBuilder
    private var transferSection: some View {
        if direct.isSyncing || direct.syncMessage != nil {
            Section {
                if direct.isSyncing {
                    ProgressView(value: direct.downloadProgress)
                        .progressViewStyle(.linear)
                    HStack(spacing: 6) {
                        Text(Self.transferCount(direct))
                        Spacer()
                        if !direct.downloadSpeed.isEmpty {
                            Text(direct.downloadSpeed)
                        }
                        // ★ 2026-10-21 (6th round): the transfer could stall (card
                        // asleep / dropped) and there was no way out of the bar —
                        // every later "pull" just queued behind a dead transfer.
                        // The service's watchdog skips after 20 s of silence; this
                        // is the human override.
                        Button(L10n.Plaud.stopTransfer, role: .destructive) {
                            direct.cancelSync()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                } else if let msg = direct.syncMessage {
                    Text(msg).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(L10n.Plaud.transferHeader)
            }
        }
    }

    // MARK: - ④ recordings ON the card

    private var filesSection: some View {
        Section {
            if direct.isRecording {
                // `getFileList` is unavailable mid-recording; say why instead of
                // showing a stale list as if it were current.
                Text(L10n.Plaud.recordingNowOnCard)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !direct.cardFilesLoaded {
                Text(L10n.Plaud.historyUnknown)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if direct.cardFiles.isEmpty {
                Text(L10n.Plaud.cardFilesEmpty)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(direct.cardFiles) { file in
                    row(file)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(L10n.Plaud.cardFiles)
                Spacer()
                if direct.cardFilesLoaded {
                    Text("\(direct.cardFiles.count)").foregroundStyle(.secondary)
                }
                // Selection entry point sits on the section header rather than
                // the nav bar: this page lives inside the recordings tab, whose
                // top bar already carries the pill + record control.
                if !direct.isRecording && !direct.cardFiles.isEmpty {
                    Button(isSelecting ? L10n.Common.cancel : L10n.Plaud.selectFiles) {
                        if isSelecting { exitSelection() } else { enterSelection() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.appAccent)
                }
            }
            .textCase(nil)
        }
    }

    // MARK: - multi-select

    private var selectedFiles: [PlaudDirectService.PlaudCardFile] {
        // In card order, not set order: the transfer queue then pulls in the
        // order the user sees.
        direct.cardFiles.filter { selectedIDs.contains($0.sessionID) }
    }

    private var allFilesSelected: Bool {
        !direct.cardFiles.isEmpty
            && Set(direct.cardFiles.map(\.sessionID)).isSubset(of: selectedIDs)
    }

    private func enterSelection() {
        withAnimation(.easeInOut(duration: 0.2)) { isSelecting = true }
    }

    private func exitSelection() {
        selectedIDs.removeAll()
        withAnimation(.easeInOut(duration: 0.2)) { isSelecting = false }
    }

    private func toggle(_ file: PlaudDirectService.PlaudCardFile) {
        if selectedIDs.contains(file.sessionID) {
            selectedIDs.remove(file.sessionID)
        } else {
            selectedIDs.insert(file.sessionID)
        }
    }

    /// 全选 / 取消全选 + 拉取 N + 删除 N. Mirrors `LibraryView.selectionBar`.
    private var selectionBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    if allFilesSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(direct.cardFiles.map(\.sessionID))
                    }
                } label: {
                    Text(allFilesSelected
                         ? L10n.Plaud.deselectAllFiles
                         : L10n.Plaud.selectAllFilesCount(direct.cardFiles.count))
                        .font(.subheadline)
                }
                .disabled(direct.cardFiles.isEmpty)

                Spacer()

                Text(L10n.Plaud.selectedFilesCount(selectedIDs.count))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    direct.download(files: selectedFiles)
                    exitSelection()
                } label: {
                    Label(L10n.Plaud.pullSelected(selectedIDs.count),
                          systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Label(L10n.Plaud.deleteSelected(selectedIDs.count), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            // Nothing ticked = neither action has anything to do. Grey both out
            // rather than letting the tap pop "select something first".
            .disabled(selectedFiles.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        // The bar exists for selection only; a recording start (card key) must
        // not leave a dangling bar over a list that just went stale.
        .onChange(of: direct.isRecording) { recording in
            if recording, isSelecting { exitSelection() }
        }
    }

    @ViewBuilder
    private func row(_ file: PlaudDirectService.PlaudCardFile) -> some View {
        let ticked = selectedIDs.contains(file.sessionID)
        HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(ticked ? Color.appAccent : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Self.dateText(file)).font(.body)
                    if file.marks > 0 {
                        Label("\(file.marks)", systemImage: "bookmark.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                            .accessibilityLabel(L10n.Plaud.marksCount(file.marks))
                    }
                }
                HStack(spacing: 6) {
                    if let d = file.duration {
                        Text(Self.durationText(d)).monospacedDigit()
                    }
                    Text(Self.sizeText(file.size))
                    if direct.pulledSessions.contains(file.sessionID) {
                        Label(L10n.Plaud.savedToLibrary, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !isSelecting {
                Button {
                    direct.download(file: file)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                // ★ 2026-10-21 (6th round): do NOT grey this out while a
                // transfer runs. That is exactly when the user taps it (the
                // previous transfer looks stuck), and a disabled button reads as
                // "下载无法传输". The service now appends to the live queue — or
                // resets a stalled one — so a tap always does something.
                .disabled(direct.isRecording)
                .accessibilityLabel(L10n.Plaud.pullThisFile)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // Tapping toggles in selection mode; long-press is the shortcut into it
        // (the Photos idiom) and ticks the row that was pressed.
        .onTapGesture {
            if isSelecting { toggle(file) }
        }
        .onLongPressGesture {
            guard !isSelecting, !direct.isRecording else { return }
            enterSelection()
            selectedIDs = [file.sessionID]
        }
        // Swipe is the only single-row delete path (2026-10-21: "no popup — tap
        // delete and it's gone"). `allowsFullSwipe` keeps one gesture enough for
        // a full swipe, which is how the other cards' lists behave.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                direct.delete(file: file)
            } label: {
                Label(L10n.Plaud.deleteFromCard, systemImage: "trash")
            }
            // Only a live recording blocks it: a running transfer must NOT
            // (that is what made the swipe button look dead, since the card
            // auto-pulls almost continuously). The service refuses only for the
            // single file currently being exported.
            .disabled(direct.isRecording)
        }
    }

    // MARK: - formatting

    private static func dateText(_ file: PlaudDirectService.PlaudCardFile) -> String {
        guard let date = file.approxDate else { return "#\(file.sessionID)" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// "2 / 5" for the transfer block; "—" when a single-file pull is running.
    private static func transferCount(_ direct: PlaudDirectService) -> String {
        guard direct.downloadTotal > 1 else { return L10n.Plaud.downloadingSingle }
        return "\(min(direct.downloadDone + 1, direct.downloadTotal)) / \(direct.downloadTotal)"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "free / total". The SDK reports **bytes**; the old formatter divided by
    /// 1e6 and printed "GB", which turned a 64 GB card into "62541 GB".
    static func storageLine(total: Int, free: Int) -> String {
        let gb: (Int) -> String = {
            $0 >= 1_000_000_000
                ? String(format: "%.1f GB", Double($0) / 1_000_000_000)
                : String(format: "%.0f MB", Double($0) / 1_000_000)
        }
        return "\(gb(free)) / \(gb(total))"
    }

    /// Clock text: the card's own counter wins; our anchor fills the gaps
    /// between reports so the number still ticks every second.
    ///
    /// `at` exists so a `TimelineView` can pass its own phase date — calling
    /// `Date()` inside the body would make the header clock freeze whenever the
    /// view happened to be re-evaluated off-beat.
    static func elapsedText(_ direct: PlaudDirectService, at date: Date = Date()) -> String {
        let seconds: TimeInterval
        if let device = direct.deviceElapsed {
            seconds = device
        } else if let start = direct.recordStartedAt {
            seconds = date.timeIntervalSince(start)
        } else {
            seconds = 0
        }
        return durationText(max(0, seconds))
    }
}

/// Compact record button for the **tab header**, next to Device / Library.
///
/// Why it exists twice (here and inside `PlaudCardFilesView`): V05E and TicNote
/// both put their `RecorderControl` in this row so the button survives a switch
/// to "Library" — without it, a user browsing their recordings mid-recording had
/// no way to stop the card short of walking back to the device segment.
struct PlaudRecordControl: View {
    @ObservedObject private var direct = PlaudDirectService.shared

    var body: some View {
        HStack(spacing: 6) {
            if direct.isRecording {
                TimelineView(.periodic(from: PlaudCardFilesView.tickAnchor, by: 1)) { context in
                    Text(PlaudCardFilesView.elapsedText(direct, at: context.date))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.red)
                        .frame(minWidth: 44, alignment: .trailing)
                }
                // "N marks so far" — the card itself gives no feedback for its
                // bookmark key, so this badge is the only proof a press landed.
                if direct.recordMarkCount > 0 {
                    Label("\(direct.recordMarkCount)", systemImage: "bookmark.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                        .accessibilityLabel(L10n.Plaud.marksCount(direct.recordMarkCount))
                }
            }
            Button {
                if direct.isRecording {
                    direct.stopRecording()
                } else {
                    direct.startRecordingWhenReady()
                }
            } label: {
                ZStack {
                    Image(systemName: direct.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(.red)
                        .opacity(direct.phase.isBusy ? 0.3 : 1)
                    if direct.phase.isBusy {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(direct.phase.isBusy)
            .accessibilityLabel(direct.isRecording ? L10n.Plaud.stopRecord : L10n.Plaud.startRecord)
        }
        .animation(.none, value: direct.isRecording)
    }
}

/// The card's **device info** (SN / firmware / battery / storage / history /
/// disconnect / unbind / transfer prefs) — presented as a sheet from the top-left
/// pill and from the compact row on the device segment.
///
/// Same content as `PlaudDeviceDetailView` (which Settings pushes), so there is
/// one implementation of "what this card is and can do", two entry points.
struct PlaudDeviceInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlaudDeviceDetailView()
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.Common.done) { dismiss() }
                    }
                }
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
    @ObservedObject private var plaud = PlaudCloudService.shared

    var body: some View {
        Form {
            DirectConnectSection(direct: direct)
            // 任务八 · 8.1 — "find my card", the part that works with no
            // firmware help. Lives on the device page (and therefore in the
            // top-left info sheet) because "where did I leave it" is a property
            // of this card, not of a recording.
            FindCardSection(direct: direct)
            // Same second mode as the add-device sheet: reachable from device
            // info too, so the cloud path is never hidden behind "add device".
            CloudSyncSection(plaud: plaud)
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
        // The scan costs radio time; a page that has been popped must not keep
        // listening.
        .onDisappear { PlaudCardFinder.shared.setScanning(false) }
    }
}

// MARK: - Find card (任务八 · 8.1)

/// Pure-App "find my card": last-seen time/place, three-tier RSSI proximity,
/// and an optional drop notification.
///
/// ## What it deliberately does NOT do
/// No buzzer. PLAUD's SDK has no beep command at all — grep over the whole
/// string table finds only `getFindMyState` / `sendFindMyToken` / `resetFindmy`
/// (Apple Find My), so 任务 8.2 physically cannot ship before the firmware
/// grows a `CMD_FIND_DEVICE`. The row is still on screen, greyed, with the
/// reason inline: hiding it would only produce the "why is there no beep"
/// question later.
///
/// ## Why proximity only works while disconnected
/// A BLE peripheral that is connected stops advertising, and the tier comes
/// from advertisement RSSI. That is not a limitation to work around — a card
/// that is connected is by definition within range, so the section shows that
/// instead of a fake reading.
struct FindCardSection: View {
    @ObservedObject var direct: PlaudDirectService
    @ObservedObject private var finder = PlaudCardFinder.shared

    private var connected: Bool { direct.phase.isConnected }

    var body: some View {
        Section {
            lastSeenRows
            if finder.locationDenied {
                Label(L10n.Find.placeDenied, systemImage: "location.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            proximityRows
            Toggle(isOn: $finder.notifyOnDisconnect) {
                Label(L10n.Find.notifyToggle, systemImage: "bell.badge")
            }
            HStack {
                Label(L10n.Find.soundRow, systemImage: "speaker.wave.2")
                Spacer()
                Image(systemName: "lock")
            }
            .foregroundStyle(.secondary)
            .disabled(true)
        } header: {
            Text(L10n.Find.header)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.Find.hint)
                Text(L10n.Find.soundUnavailable)
            }
            .font(.footnote)
        }
    }

    // MARK: Last seen

    @ViewBuilder
    private var lastSeenRows: some View {
        if let at = finder.lastSeenAt {
            LabeledContent {
                Text(at.formatted(date: .abbreviated, time: .shortened))
            } label: {
                Label(L10n.Find.lastSeenHeader, systemImage: "clock.arrow.circlepath")
            }
            LabeledContent {
                Text(finder.lastSeenPlace ?? L10n.Find.placeUnknown)
                    .multilineTextAlignment(.trailing)
            } label: {
                Label(L10n.Find.radarHeader, systemImage: "mappin.and.ellipse")
            }
            if #available(iOS 17.0, *), let coordinate = finder.lastSeenCoordinate {
                lastSeenMap(coordinate)
            }
        } else {
            Text(L10n.Find.lastSeenNever)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A still thumbnail, not a live map: `allowsHitTesting(false)` keeps it from
    /// hijacking the sheet's scroll, and tapping the row above opens Maps via the
    /// system anyway. The point is "roughly here", at a glance.
    @available(iOS 17.0, *)
    private func lastSeenMap(_ coordinate: CLLocationCoordinate2D) -> some View {
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        ))) {
            Marker(L10n.Find.header, coordinate: coordinate).tint(.red)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Proximity

    @ViewBuilder
    private var proximityRows: some View {
        if connected {
            Label(L10n.Plaud.stateConnected, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(Color.appAccent)
        } else {
            HStack(spacing: 12) {
                proximityMeter
                Text(L10n.Find.tier(finder.proximity.rawValue))
                    .font(.footnote)
                    .foregroundStyle(finder.proximity == .unknown ? .secondary : .primary)
                Spacer()
                if let rssi = finder.rssi {
                    Text("\(rssi) dBm")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            if finder.isScanning, finder.proximity == .unknown {
                Text(L10n.Find.scanning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                finder.setScanning(!finder.isScanning)
            } label: {
                Label(finder.isScanning ? L10n.Find.stop : L10n.Find.start,
                      systemImage: finder.isScanning ? "stop.circle.fill" : "dot.radiowaves.left.and.right")
            }
            .foregroundStyle(finder.isScanning ? Color.red : Color.appAccent)
        }
    }

    /// Three bars that fill as you get warmer. Deliberately not a numeric
    /// gauge: RSSI is noisy and a number invites "why is it 71 then 68".
    private var proximityMeter: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(1...3, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(level <= finder.proximity.rawValue ? Color.appAccent : Color.secondary.opacity(0.25))
                    .frame(width: 5, height: CGFloat(6 + level * 5))
            }
        }
        .frame(height: 21, alignment: .bottom)
        .animation(.easeOut(duration: 0.25), value: finder.proximity)
        .accessibilityLabel(L10n.Find.tier(finder.proximity.rawValue))
    }
}

// MARK: - Cloud sync (compatibility)

// MARK: - Cloud mode

/// **云模式** — the second way to get recordings off a PLAUD card: sign in with
/// the PLAUD consumer account (email OTP) and pull what the official app has
/// already uploaded.
///
/// Why it exists next to direct connect (user: "直连模式下面要增加一个云模式"):
/// · Direct connect reads the card itself — no account, no internet, but the
///   card must be awake and paired with THIS app (the official app loses access).
/// · Cloud mode touches no Bluetooth at all: the card keeps working with the
///   official app, and whatever that app already synced can be fetched here.
///   The trade-off is freshness — a recording only exists in the cloud after the
///   official app uploaded it.
struct CloudSyncSection: View {
    @ObservedObject var plaud: PlaudCloudService
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var message: String?
    @State private var syncSummary: String?
    /// How many recordings the cloud holds for this account (nil = not read).
    @State private var cloudCount: Int?
    /// "3/12 · name.mp3" while a pull is running.
    @State private var progressLine: String?

    var body: some View {
        Section {
            if plaud.isSignedIn {
                LabeledContent(L10n.Plaud.accountLabel, value: plaud.email ?? "")
                HStack {
                    Text(L10n.Plaud.cloudRecordings)
                    Spacer()
                    Text(cloudCount.map(L10n.Plaud.cloudRecordingsCount) ?? L10n.Plaud.historyUnknown)
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await refreshCount() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .accessibilityLabel(L10n.Plaud.refresh)
                }
                Button(L10n.Plaud.pullFromCloud) { Task { await sync() } }
                    .disabled(busy)
                    .accessibilityIdentifier("plaudCloudPull")
                if busy {
                    if let progressLine {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(progressLine).font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                    }
                }
                if let syncSummary {
                    Text(syncSummary).font(.footnote).foregroundStyle(.secondary)
                }
                Button(L10n.Plaud.signOut, role: .destructive) {
                    plaud.signOut()
                    codeSent = false
                    cloudCount = nil
                    syncSummary = nil
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
            Text(L10n.Plaud.cloudHeader)
        } footer: {
            Text(plaud.isSignedIn ? L10n.Plaud.syncFooter : L10n.Plaud.cloudModeFooter)
        }
        // Read the count as soon as the section is on screen with a live token:
        // "how many are up there" is the first thing the user wants to know
        // before deciding to pull.
        .task(id: plaud.isSignedIn) {
            guard plaud.isSignedIn, cloudCount == nil else { return }
            await refreshCount()
        }
    }

    private func refreshCount() async {
        busy = true
        defer { busy = false }
        do {
            cloudCount = try await plaud.listFiles().count
        } catch {
            message = error.localizedDescription
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
            await refreshCount()
        } catch {
            message = error.localizedDescription
        }
    }

    private func sync() async {
        busy = true
        syncSummary = nil
        progressLine = nil
        defer {
            busy = false
            progressLine = nil
        }
        do {
            let (done, skipped) = try await PlaudCloudService.shared.syncAll { index, total, name in
                // Progress hops to the main actor: the closure is called from a
                // background task owned by the service.
                Task { @MainActor in
                    progressLine = L10n.Plaud.cloudProgress(index + 1, total, name)
                }
            }
            syncSummary = L10n.Plaud.syncResult(done, skipped)
            await refreshCount()
        } catch {
            syncSummary = error.localizedDescription
        }
    }
}
