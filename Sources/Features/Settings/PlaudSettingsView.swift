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
    @State private var domain = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showFactoryConfirm = false
    @State private var releasedNote = false
    @State private var showRename = false
    @State private var nameDraft = ""

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
            transferPrefsSection
        }
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
            .disabled(direct.isSyncing)

        Button(L10n.Plaud.disconnect) { direct.disconnect() }
    }

    /// Name + rename (2026-10-21: "需要支持修改设备名称").
    ///
    /// Shown whenever we know which card this is (`pairedSN` or a live link), so
    /// the name can be fixed from Settings even while the card is asleep.
    @ViewBuilder
    private var nameSection: some View {
        if direct.pairedSN != nil || direct.phase.isConnected {
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
        .refreshable {
            direct.refreshVitals()
            direct.refreshCardRecordings()
        }
        .sheet(isPresented: $showInfo) { PlaudDeviceInfoSheet() }
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
            // ★ 打点 (bookmarks pressed on the card while recording). Polled
            // every 3 s via `bleAgent.getMarking(sessionId:)` — `bleMarking` is
            // an answer, not a push, so without the poll the count only appeared
            // after the recording ended.
            if direct.isRecording || !direct.recordMarks.isEmpty {
                HStack {
                    Label(L10n.Plaud.marksLive, systemImage: "bookmark")
                    Spacer()
                    Text(direct.recordMarks.isEmpty
                         ? "—"
                         : L10n.Plaud.marksCount(direct.recordMarks.count))
                        .foregroundStyle(direct.recordMarks.isEmpty ? Color.secondary : Color.appAccent)
                }
            }
            if let notice = direct.recordNotice {
                Text(notice).font(.footnote).foregroundStyle(.orange)
            }
            if !direct.liveTranscript.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Plaud.liveTranscript)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(direct.liveTranscript)
                        .font(.footnote)
                        .lineLimit(6)
                }
            }
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
            HStack {
                Text(L10n.Plaud.cardFiles)
                Spacer()
                if direct.cardFilesLoaded {
                    Text("\(direct.cardFiles.count)").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ file: PlaudDirectService.PlaudCardFile) -> some View {
        HStack(spacing: 10) {
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
            Button {
                direct.download(file: file)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(direct.isSyncing || direct.isRecording)
            .accessibilityLabel(L10n.Plaud.pullThisFile)
        }
        .padding(.vertical, 2)
        // Swipe is the only delete path (2026-10-21: "no popup — tap delete and
        // it's gone"). `allowsFullSwipe` keeps one gesture enough for a full
        // swipe, which is how the other cards' lists behave.
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
                if !direct.recordMarks.isEmpty {
                    Label("\(direct.recordMarks.count)", systemImage: "bookmark.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                        .accessibilityLabel(L10n.Plaud.marksCount(direct.recordMarks.count))
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
