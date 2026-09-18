import AVFoundation
import SwiftUI

/// Recordings tab — Device segment.
///
/// Lists what's on the device, pulls files over BLE, decrypts them with the
/// ChaCha20 key from `config.json`, and (per-row) ships them to the ASR
/// provider chain.
struct RecordingsView: View {
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var env: AppEnvironment
    @State private var segment: Segment = .device
    @State private var pendingSegment: Segment?
    @State private var showCancelSegmentAlert = false
    @State private var showClipDetail = false
    @State private var transferredClipItem: LibraryItem?
    @State private var recordAlert: RecordAlert?

    private enum RecordAlert: Identifiable {
        case notBound(deviceName: String)
        case error(String)

        var id: String {
            switch self {
            case .notBound: return "not-bound"
            case .error(let message): return "error-\(message)"
            }
        }
    }

    enum Segment: CaseIterable, Identifiable {
        case device
        case library
        var id: Int { hashValue }
        var title: String {
            switch self {
            case .device: return L10n.Recordings.device
            case .library: return L10n.Recordings.librarySegment
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: Binding(
                    get: { segment },
                    set: { newSeg in
                        if env.isBLETransferring, newSeg != segment {
                            pendingSegment = newSeg
                            showCancelSegmentAlert = true
                        } else {
                            segment = newSeg
                        }
                    }
                )) {
                    ForEach(Segment.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                RecordControl(
                    client: bluetooth.client,
                    onError: { error in
                        if let dnoteError = error as? DnoteError,
                           case .notBound = dnoteError {
                            recordAlert = .notBound(
                                deviceName: bluetooth.client?.displayName ?? "Nomi"
                            )
                        } else {
                            recordAlert = .error(error.localizedDescription)
                        }
                    }
                )
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            // This segment control follows the page: grouped gray. The navigation bar is a transparent material that shows the color beneath,
            // so the top bar also turns gray, matching the settings page: both top and bottom bars always follow the page background.
            .background(Color(uiColor: .systemGroupedBackground))

            WatchStatusRow()

            switch segment {
            case .device:
                if let client = bluetooth.client {
                    DeviceFilesView(
                        client: client,
                        library: library,
                        env: env,
                        onFileTransferred: { name in
                            Task { @MainActor in
                                if let item = await Self.buildLibraryItem(for: name) {
                                    transferredClipItem = item
                                    segment = .library
                                    showClipDetail = true
                                } else {
                                    segment = .library
                                }
                            }
                        },
                        onFastTransferDone: {
                            segment = .library
                        }
                    )
                } else {
                    EmptyStateView(
                        L10n.Recordings.noDeviceConnected,
                        systemImage: "waveform.slash",
                        message: L10n.Recordings.noDeviceMessage
                    )
                }
            case .library:
                LibraryView()
            }
        }
        .navigationTitle("")
        .onReceive(NotificationCenter.default.publisher(for: .watchClipDidArrive)) { _ in
            // Same landing as a finished device transfer. Skipped mid-BLE-
            // transfer, where switching away is already guarded by an alert.
            guard !env.isBLETransferring else { return }
            segment = .library
        }
        .navigationDestination(isPresented: $showClipDetail) {
            if let item = transferredClipItem {
                ClipDetailView(item: item)
            }
        }
        .alert(
            L10n.DeviceFiles.transferInProgress,
            isPresented: $showCancelSegmentAlert
        ) {
            Button(L10n.DeviceFiles.cancelAndSwitch, role: .destructive) {
                env.cancelBLETransfers?()
                // Clear the flag immediately. The DeviceFilesView that owns
                // the hasActiveTransfers → isBLETransferring observer is torn
                // down as we switch segments, so it would otherwise never fire
                // the false edge, leaving the flag stuck true and re-prompting
                // when the user switches back (k4j6kuu).
                env.isBLETransferring = false
                if let s = pendingSegment { segment = s }
                pendingSegment = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingSegment = nil }
        } message: {
            Text(L10n.DeviceFiles.cancelTransferToSwitch)
        }
        .alert(item: $recordAlert) { alert in
            switch alert {
            case .notBound(let deviceName):
                return Alert(
                    title: Text(L10n.Pairing.title),
                    message: Text(L10n.Pairing.message(deviceName)),
                    primaryButton: .default(Text(L10n.Pairing.goPair)) {
                        env.openDeviceSheetForPairing = true
                    },
                    secondaryButton: .cancel(Text(L10n.Common.cancel))
                )
            case .error(let message):
                return Alert(
                    title: Text(L10n.DeviceFiles.operationFailed),
                    message: Text(message),
                    dismissButton: .cancel(Text(L10n.Common.ok))
                )
            }
        }
    }

    private static func buildLibraryItem(for name: String) async -> LibraryItem? {
        let url = StorageLocations.decryptedDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(attrs?.fileSize ?? 0)
        let mtime = attrs?.contentModificationDate ?? Date()
        let txt = StorageLocations.transcriptURLs(for: name).txt
        let hasTranscript = FileManager.default.fileExists(atPath: txt.path)
        let duration: Double?
        if url.pathExtension.lowercased() == "opus" {
            duration = OpusOgg.duration(ofOggOpusAt: url)
        } else {
            let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            duration = (d.isFinite && d > 0) ? d : nil
        }
        let titleURL = StorageLocations.titleURL(for: name)
        let customTitle: String? = (try? String(contentsOf: titleURL, encoding: .utf8))
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return LibraryItem(name: name, url: url, size: size, modifiedAt: mtime,
                           duration: duration, hasTranscript: hasTranscript, customTitle: customTitle)
    }
}

// MARK: - Record control
//
// Tab-header start/stop button. State is driven by
// `client.lastDeviceInfo?.isRecording` (which is now kept current via
// 0x54/0x55 notifications + the 30 s poll + the local flip on App-
// initiated CMD 0x50/0x51). No need to duplicate state here — the
// button just reflects what the client knows and dispatches commands.

private struct RecordControl: View {
    let client: DnoteClient?
    let onError: (Error) -> Void
    @State private var isBusy = false

    private var isConnected: Bool { client != nil }
    private var isRecording: Bool { client?.lastDeviceInfo?.isRecording == true }

    /// Recording cannot be **started** until the passphrase is fully set (an ongoing recording must still be stoppable).
    /// The command layer `DnoteClient.startRecording` is the actual gate; here we just prevent the button from appearing enabled.
    private var startBlocked: Bool {
        guard !isRecording, let client else { return false }
        return KeyResolver.setupIncomplete(for: client)
    }

    private var symbolName: String {
        isRecording ? "stop.circle.fill" : "record.circle"
    }

    private var tint: Color {
        isConnected && !startBlocked ? .red : .gray
    }

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Image(systemName: symbolName)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundColor(tint)
                    .opacity(isBusy ? 0.3 : 1)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isConnected || isBusy || startBlocked)
        .accessibilityLabel(isRecording ? L10n.DeviceFiles.stopRecording : L10n.Common.recording)
    }

    private func toggle() {
        guard let client, !isBusy else { return }
        let recording = isRecording
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                if recording {
                    _ = try await client.stopRecording()
                } else {
                    try await client.startRecording()
                }
            } catch {
                onError(error)
            }
        }
    }
}

// MARK: - Device files
//
// Kept deliberately simple to avoid SwiftUI/UICollectionView animated-diff
// crashes ("Invalid number of items in section") that the previous design
// hit:
//   - One unconditional `List { ForEach }` over a single source array.
//     Empty / loading / error states render as a non-list overlay so the
//     section count never flips between branches mid-update.
//   - Delete confirmation is a single parent-level `.alert(presenting:)`
//     keyed on `@State pendingDelete: DeviceFile?`. Per-row
//     `.confirmationDialog` was dismissing on the same runloop turn as
//     row mutations and blowing up the diff.
//   - `.animation(.none, value: model.files)` belt-and-braces: don't
//     animate row insertion/removal at all. The list still updates
//     correctly, just without the cross-fade.

private struct DeviceFilesView: View {
    @ObservedObject var client: DnoteClient
    @ObservedObject var library: Library
    let env: AppEnvironment
    var onFileTransferred: ((String) -> Void)?
    var onFastTransferDone: (() -> Void)?
    @StateObject private var model = DeviceFilesModel()
    @State private var pendingDelete: DeviceFile?
    @State private var showFastTransfer = false
    @State private var showNoASR = false
    @State private var lastObservedRecording: Bool?
    /// Device-reported elapsed recording time (ms), from 0x56 `recd`. This is
    /// the device's own truth, so it's correct whether the recording was
    /// started from the app or with the physical button (p4gfshg).
    @State private var recordingElapsedMs: Int?

    /// Fast Transfer entry point appears whenever the backlog of
    /// recordings not yet in the library exceeds the user-configurable
    /// threshold (default 512 KB). A threshold of 0 always shows the
    /// suggestion when any undownloaded file exists.
    private var fastTransferBacklog: Int {
        model.files
            .filter { !library.isDownloaded($0.name, deviceSerial: client.lastDeviceInfo?.serial) }
            .reduce(0) { $0 + $1.size }
    }
    private var showFastTransferButton: Bool {
        fastTransferBacklog > env.config.config.fastTransferThresholdKB * 1024
    }

    /// Banner trigger: device says it's encrypted, but this iPhone has no
    /// matching key in the Keychain. Without this prompt, the user discovers
    /// the problem only when a download lands and the row goes "raw."
    private var needsPassphraseOnboarding: Bool {
        KeyResolver.setupIncomplete(for: client)
    }

    var body: some View {
        List {
            ForEach(model.files) { file in
                FileRow(
                    file: file,
                    state: model.state(for: file.name),
                    transcription: model.transcription(for: file.name),
                    isDownloaded: library.isDownloaded(file.name, deviceSerial: client.lastDeviceInfo?.serial),
                    download: { Task { await model.download(file, using: client, library: library, env: env) } },
                    cancel: { model.cancel(file.name) },
                    transcribe: {
                        // Same gate as Clip detail: a user-triggered
                        // transcribe with no provider configured must offer a
                        // way out instead of failing at request time
                        // (nze7sy4).
                        if env.config.config.asrProviders.hasConfiguredProvider {
                            Task { await model.transcribe(file, env: env) }
                        } else {
                            showNoASR = true
                        }
                    }
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = file
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .environment(\.defaultMinListHeaderHeight, 0)
        .padding(.top, -22)
        .clipped()
        .animation(.none, value: model.files)
        .overlay { overlay }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                if needsPassphraseOnboarding {
                    PassphraseOnboardingBanner(
                        recordingsAtRisk: model.files.count,
                        onOpenSettings: {
                            // Two-step deep link:
                            //   1) flip env flags so Settings → Recordings
                            //      auto-opens with the passphrase sheet
                            //   2) post `navigateToSettings` so RootView
                            //      switches to the Settings tab
                            // The order matters: set the destination flag
                            // before the tab switch so SettingsView sees
                            // it on its first body evaluation.
                            env.navigateToRecordingsSettings = true
                            env.openPassphraseSheet = true
                            NotificationCenter.default.post(name: .navigateToSettings, object: nil)
                        }
                    )
                }
                if model.hasActiveTransfers {
                    Label(L10n.Common.keepForeground, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(Color(.secondarySystemBackground))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if showFastTransferButton {
                Button {
                    showFastTransfer = true
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(L10n.DeviceFiles.fastTransferWifi).font(.body.bold())
                            Text(L10n.DeviceFiles.pending(ByteCountFormatter.string(fromByteCount: Int64(fastTransferBacklog), countStyle: .file)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wifi")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await model.refresh(using: client) }
                } label: {
                    if model.isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                // A BLE transfer holds the device's command lock for its whole
                // duration, so a refresh queued behind it would spin until the
                // transfer finished ("stuck refreshing"). Disable it meanwhile.
                .disabled(model.isLoading || model.hasActiveTransfers)
            }
        }
        .task {
            env.cancelBLETransfers = { [weak model = model] in model?.cancelAll() }
            _ = try? await client.getDeviceInfo()
            await model.refresh(using: client)
        }
        .task {
            // While the device tab is on screen, poll recording state faster
            // than the 30s global loop so a recording started with the
            // device's physical button surfaces the "recording" overlay
            // promptly (49cux2i) — the firmware doesn't reliably push 0x54 for
            // button-started recordings, so without this the state only
            // refreshes on the slow poll or a tab switch. Auto-cancels when
            // the tab disappears; skips while a transfer/list-fetch holds the
            // command lock so it never contends.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                guard !model.hasActiveTransfers, !model.isLoading else { continue }
                _ = try? await client.getDeviceInfo()
            }
        }
        .onDisappear {
            env.cancelBLETransfers = nil
        }
        .task(id: isRecording) {
            // While recording, poll 0x56 every second and show the device's
            // own elapsed time (`recd`). Restarts when isRecording flips;
            // auto-cancels on disappear.
            guard isRecording else { recordingElapsedMs = nil; return }
            while !Task.isCancelled {
                if let status = try? await client.getRecordingStatus(),
                   let recd = (status["recd"] as? NSNumber)?.intValue {
                    recordingElapsedMs = recd
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onChange(of: model.hasActiveTransfers) { active in
            env.isBLETransferring = active
        }
        .onChange(of: client.lastDeviceInfo?.isRecording) { isRecording in
            // The device blocks the file-list command while recording and
            // any previously-fetched list is stale the moment a new clip
            // lands, so react to both edges:
            //   started → clear the list so the "device is recording"
            //             overlay takes over and nobody can act on a
            //             stale row.
            //   stopped → refresh; a new clip just finalised on disk.
            // Skip the initial nil → value transition — `.task` already
            // did the first-load refresh.
            let prev = lastObservedRecording
            lastObservedRecording = isRecording
            guard prev != nil, prev != isRecording else { return }
            switch isRecording {
            case true:
                model.files = []
            case false:
                Task { await model.refresh(using: client) }
            case nil:
                break
            }
        }
        .onChange(of: model.completedTransfer) { name in
            if let name = name {
                model.completedTransfer = nil
                onFileTransferred?(name)
            }
        }
        .sheet(isPresented: $showFastTransfer) {
            FastTransferSheet(
                client: client,
                library: library,
                config: env.config,
                transcription: env.transcription,
                onDone: { onFastTransferDone?() }
            )
        }
        .alert(
            L10n.DeviceFiles.deleteRecording,
            isPresented: deleteAlertBinding,
            presenting: pendingDelete
        ) { file in
            Button(L10n.Common.delete, role: .destructive) {
                Task { await model.delete(file, using: client) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { file in
            Text(L10n.DeviceFiles.deleteRecordingMessage(file.name))
        }
        // `presenting:` overload — SwiftUI tracks the alert by the message
        // value's identity, so it survives the rapid view rebuilds that fire
        // around a download (states, Library, BluetoothCoordinator all
        // republish in quick succession). An `isPresented:` form with a
        // recomputed `Binding(get:set:)` flashes open then auto-dismisses,
        // because a fresh Binding instance reaches SwiftUI on every rebuild.
        .alert(L10n.ASR.noProvider, isPresented: $showNoASR) {
            Button(L10n.Common.openSettings) {
                env.navigateToASRProviders = true
                NotificationCenter.default.post(name: .navigateToSettings, object: nil)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ASR.noProviderMessage)
        }
        .alert(
            L10n.DeviceFiles.operationFailed,
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            ),
            presenting: model.alertMessage
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    private var isRecording: Bool {
        client.lastDeviceInfo?.isRecording == true
    }

    /// Format a device-reported millisecond duration as a clock (h:mm:ss
    /// once past an hour, m:ss otherwise).
    private static func formatElapsed(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder
    private var overlay: some View {
        if model.files.isEmpty {
            if model.isLoading {
                ProgressView(L10n.DeviceFiles.readingFileList)
            } else if isRecording {
                VStack(spacing: 16) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.red)
                    Text(L10n.DeviceFiles.deviceIsRecording)
                        .font(.headline)
                    if let ms = recordingElapsedMs {
                        Text(Self.formatElapsed(ms))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                    Text(L10n.DeviceFiles.recordingUnavailableMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task {
                            _ = try? await client.stopRecording()
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await model.refresh(using: client)
                        }
                    } label: {
                        Label(L10n.DeviceFiles.stopRecording, systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding()
            } else if let err = model.error {
                EmptyStateView(
                    L10n.DeviceFiles.couldntReadDevice,
                    systemImage: "exclamationmark.triangle",
                    message: err
                )
            } else {
                EmptyStateView(
                    L10n.DeviceFiles.noRecordingsOnDevice,
                    systemImage: "tray",
                    message: L10n.DeviceFiles.noRecordingsMessage
                )
            }
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }
}

// MARK: - Row

private struct FileRow: View {
    let file: DeviceFile
    let state: FileTransferState
    let transcription: TranscriptionState
    let isDownloaded: Bool
    let download: () -> Void
    let cancel: () -> Void
    let transcribe: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.displayTitle).font(.body)
                    Text(formatBytes(file.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trailing
            }
            if case .transferring(let got, let total) = state {
                let frac = total > 0 ? Double(got) / Double(total) : 0
                ProgressView(value: frac)
                Text("\(formatBytes(got)) / \(formatBytes(total))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if case .saved(let saved) = state {
                savedDetail(saved)
            }
            if case .failed(let msg) = state {
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            transcriptionDetail
        }
    }

    @ViewBuilder
    private func savedDetail(_ saved: FileSavedState) -> some View {
        switch saved {
        case .ready(let url, .alreadyPlain):
            Text(L10n.FileSave.savedPlain(url.lastPathComponent))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ready(let url, .decrypted):
            Text(L10n.FileSave.decrypted(url.lastPathComponent))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ready(let url, .wrappedRawFrames):
            Text(L10n.FileSave.wrappedFrames(url.lastPathComponent))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .ready(let url, .decryptedThenWrapped):
            Text(L10n.FileSave.decryptedWrapped(url.lastPathComponent))
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .raw(let url, .decryptFailed(let msg)):
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.FileSave.saved(url.lastPathComponent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(L10n.FileSave.decryptFailed(msg), systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        case .raw(let url, .wavWithoutHeader):
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.FileSave.saved(url.lastPathComponent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label(L10n.FileSave.wavWithoutHeader,
                      systemImage: "questionmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var transcriptionDetail: some View {
        switch transcription {
        case .none:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L10n.DeviceFiles.transcribing).font(.caption2).foregroundStyle(.secondary)
            }
        case .done(let url):
            Label(L10n.DeviceFiles.transcriptDone(url.lastPathComponent), systemImage: "text.bubble")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.bubble")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .idle, .failed:
            Button(action: download) {
                Image(systemName: isDownloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .imageScale(.large)
                    .foregroundColor(isDownloaded ? .secondary : .accentColor)
            }
            .buttonStyle(.borderless)
        case .transferring:
            Button(action: cancel) {
                Image(systemName: "stop.circle.fill")
                    .imageScale(.large)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        case .saved(let saved):
            switch saved {
            case .ready:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .imageScale(.large)
                        .foregroundColor(.green)
                    if transcription.canTranscribe {
                        Button(action: transcribe) {
                            Image(systemName: "text.bubble.fill")
                                .imageScale(.large)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            case .raw:
                Button(action: download) {
                    Image(systemName: "arrow.clockwise.circle")
                        .imageScale(.large)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.Common.retry)
            }
        }
    }

    private func formatBytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// MARK: - States

enum FileSavedState: Equatable {
    /// Plaintext on disk (either was already plain, or successfully
    /// decrypted, or raw OPUS frames that we OGG-wrapped in-app).
    case ready(URL, source: ReadySource)
    /// Saved to `audioDir` but not in a playable form. The reason explains
    /// what's blocking — used to pick the right caption in the row UI.
    case raw(URL, reason: RawReason)

    enum ReadySource: Equatable {
        case alreadyPlain        // device shipped a complete container
        case decrypted           // ChaCha20 yielded a complete container
        case wrappedRawFrames    // raw OPUS frames → in-app OGG wrap
        case decryptedThenWrapped // decrypt yielded raw frames → wrapped
    }

    enum RawReason: Equatable {
        /// We attempted ChaCha20 decryption but it threw or produced
        /// something that doesn't look like audio.
        case decryptFailed(String)
        /// `.wav` without a `RIFF` header and no ChaCha20 key — we have no
        /// in-app fallback for unwrapped WAV payloads.
        case wavWithoutHeader
    }
}

enum FileTransferState: Equatable {
    case idle
    case transferring(received: Int, total: Int)
    case saved(FileSavedState)
    case failed(String)
}

enum TranscriptionState: Equatable {
    case none
    case running
    case done(URL)
    case failed(String)

    var canTranscribe: Bool {
        switch self {
        case .none, .failed: return true
        case .running, .done: return false
        }
    }
}

@MainActor
final class DeviceFilesModel: ObservableObject {
    @Published var files: [DeviceFile] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var alertMessage: String?
    @Published var completedTransfer: String?
    @Published private var states: [String: FileTransferState] = [:]
    @Published private var transcripts: [String: TranscriptionState] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]

    var totalBytes: Int? {
        files.isEmpty ? nil : files.reduce(0) { $0 + $1.size }
    }
    var hasActiveTransfers: Bool {
        states.values.contains { if case .transferring = $0 { return true }; return false }
    }

    var alertBinding: Binding<Bool> {
        Binding(get: { self.alertMessage != nil },
                set: { if !$0 { self.alertMessage = nil } })
    }

    func state(for name: String) -> FileTransferState { states[name] ?? .idle }
    func transcription(for name: String) -> TranscriptionState { transcripts[name] ?? .none }

    func refresh(using client: DnoteClient) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let list = try await client.getFileList()
            self.files = list.sorted { $0.name > $1.name }
            let names = Set(list.map(\.name))
            for key in states.keys where !names.contains(key) {
                states.removeValue(forKey: key)
            }
            // Pre-populate transcript state from disk so an existing
            // {name}.txt next to a previously-decrypted clip surfaces
            // immediately on tab open.
            for file in list {
                let urls = StorageLocations.transcriptURLs(for: file.name)
                if FileManager.default.fileExists(atPath: urls.txt.path) {
                    transcripts[file.name] = .done(urls.txt)
                }
            }
        } catch is CancellationError {
            // Switching devices / leaving the page cancels this refresh — it's not that the device can't be read, so don't show an error.
            // If not suppressed, the user would see “Unable to read device” immediately after switching, even though the new device is connected fine
            // (reproduced on a real device on 2026‑08‑12).
        } catch {
            self.error = error.localizedDescription
        }
    }

    func download(_ file: DeviceFile, using client: DnoteClient, library: Library, env: AppEnvironment) async {
        guard tasks[file.name] == nil else { return }
        states[file.name] = .transferring(received: 0, total: file.size)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await client.downloadFile(
                    file.name,
                    expectedSize: file.size
                ) { [weak self] got, total in
                    self?.states[file.name] = .transferring(received: got, total: total)
                }
                try Task.checkCancellation()
                let deviceSerial = client.lastDeviceInfo?.serial
                let localName = library.localNameForDeviceFile(
                    file.name,
                    deviceSerial: deviceSerial
                )
                let saved = try self.writeAndDecrypt(data, name: localName, env: env)
                // A raw encrypted file with a missing/wrong key is not a
                // completed download: recording it in the manifest would make
                // this device file look done and prevent the retry the UI asks
                // the user to perform after fixing the passphrase.
                if case .ready = saved {
                    library.recordDownload(
                        name: file.name,
                        size: data.count,
                        transport: "ble",
                        deviceSerial: deviceSerial,
                        localName: localName
                    )
                }
                self.states[file.name] = .saved(saved)

                // Auto-transcribe (opt-in). Kicked off detached so it doesn't
                // block the auto-delete + refresh cadence below. tooShort is
                // swallowed because the user opted into the duration gate
                // when enabling this toggle.
                if env.config.config.autoTranscribeAfterDownload,
                   case .ready(let decryptedURL, _) = saved {
                    let transcription = env.transcription
                    Task.detached { @MainActor in
                        _ = try? await transcription.transcribe(
                            fileURL: decryptedURL,
                            enforceMinDuration: true
                        )
                    }
                }

                // Drop the file from the device once it's safely on disk and
                // indexed in the library.
                // Only when decryption produced a playable artefact — `.raw`
                // outcomes (missing/wrong passphrase) must keep the encrypted
                // original on the device so the user can retry after setting
                // a passphrase. Auto-navigation to the library is gated for
                // the same reason: tearing down DeviceFilesView while the
                // "no passphrase" alert is presenting yanks the alert before
                // the user can read it.
                if env.config.config.autoDeleteAfterTransfer,
                   case .ready = saved {
                    do {
                        try await client.deleteFile(file.name)
                        self.states.removeValue(forKey: file.name)
                        self.transcripts.removeValue(forKey: file.name)
                        await self.refresh(using: client)
                        self.completedTransfer = file.name
                    } catch {
                        self.alertMessage = "\(file.name): saved locally, but the device kept the original (\(error.localizedDescription))."
                    }
                }
            } catch is CancellationError {
                self.states[file.name] = .idle
            } catch {
                let msg = error.localizedDescription
                self.states[file.name] = .failed(msg)
                self.alertMessage = "\(file.name): \(msg)"
            }
            self.tasks.removeValue(forKey: file.name)
            if self.tasks.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
        }
        tasks[file.name] = task
        if tasks.count == 1 { UIApplication.shared.isIdleTimerDisabled = true }
    }

    func cancel(_ name: String) { tasks[name]?.cancel() }
    func cancelAll() { tasks.values.forEach { $0.cancel() } }

    func delete(_ file: DeviceFile, using client: DnoteClient) async {
        // If a transfer is in flight for this file, cancel it first. Otherwise
        // deleteFile() queues behind the transfer's exclusive command lock and
        // the transfer runs to completion before the delete lands, so the user
        // sees the "download finished" outcome despite asking to delete it
        // (as8sj6z). Cancelling releases the lock so the delete can proceed.
        if tasks[file.name] != nil {
            cancel(file.name)
        }
        // Don't set a transient `.deleting` state here. The BLE delete is
        // ~100 ms, and SwiftUI's UICollectionView-backed List crashes
        // ("invalid number of items in section") when a structural row
        // change (HStack→ProgressView→removed) races with adjacent
        // @Published mutations from a still-settling download. Keep the
        // row visually unchanged until the delete completes, then
        // re-fetch the file list from the device so the list, states,
        // and transcripts go through the same atomic snapshot.
        do {
            try await client.deleteFile(file.name)
        } catch {
            alertMessage = L10n.DeviceFiles.deleteFailed(error.localizedDescription)
            return
        }
        states.removeValue(forKey: file.name)
        transcripts.removeValue(forKey: file.name)
        await refresh(using: client)
    }

    func transcribe(_ file: DeviceFile, env: AppEnvironment) async {
        // Only allow transcription against decoded/plaintext audio; raw
        // (suspected-encrypted) blobs would just look like noise to Azure.
        if case .saved(.ready(let url, _)) = states[file.name] ?? .idle {
            await runTranscribe(name: file.name, fileURL: url, env: env)
            return
        }
        // Fall back to whatever already lives on disk under decryptedDir
        // (e.g. transcribe right after refresh, before re-download).
        let candidate = StorageLocations.decryptedDir.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            alertMessage = L10n.DeviceFiles.downloadBeforeTranscribe(file.name)
            return
        }
        await runTranscribe(name: file.name, fileURL: candidate, env: env)
    }

    private func runTranscribe(name: String, fileURL: URL, env: AppEnvironment) async {
        transcripts[name] = .running
        do {
            let result = try await env.transcription.transcribe(fileURL: fileURL)
            let urls = StorageLocations.transcriptURLs(for: name)
            transcripts[name] = .done(urls.txt)
            _ = result // result already written by TranscriptionService
        } catch {
            let msg = error.localizedDescription
            transcripts[name] = .failed(msg)
            alertMessage = L10n.DeviceFiles.transcribeFailed(name, msg)
        }
    }

    /// Save the device's bytes under `audio_clips/<name>` and produce the
    /// playable `audio_clips/decrypted/<name>` artefact. Dispatch:
    ///
    ///   - head starts with `"encryt"` → ChaCha20-decrypt with the
    ///     SN-scoped Keychain key (via `KeyResolver`) and wrap raw frames.
    ///     If no key is configured locally, the file is left as raw and
    ///     the user sees a "set passphrase in Settings" prompt.
    ///   - `OggS` / `RIFF` magic → already-plain container.
    ///   - anything else `.opus` → raw OPUS frames; wrap.
    private func writeAndDecrypt(_ data: Data, name: String, env: AppEnvironment) throws -> FileSavedState {
        let key = env.bluetooth.client.map(KeyResolver.key(for:)) ?? nil
        let outcome = try PostDownload.process(data, name: name, chacha20Key: key)
        switch outcome {
        case .ready(let url, .alreadyPlain):
            return .ready(url, source: .alreadyPlain)
        case .ready(let url, .decrypted):
            return .ready(url, source: .decrypted)
        case .ready(let url, .decryptedThenWrapped):
            return .ready(url, source: .decryptedThenWrapped)
        case .ready(let url, .wrappedRawFrames):
            return .ready(url, source: .wrappedRawFrames)
        case .raw(let url, .decryptFailed(let msg)):
            self.alertMessage = L10n.EncryptionOnboarding.downloadFailedWrongKey(name, msg)
            return .raw(url, reason: .decryptFailed(msg))
        case .raw(let url, .keyMissing):
            self.alertMessage = L10n.EncryptionOnboarding.downloadFailedKeyMissing(name)
            return .raw(url, reason: .decryptFailed("no key configured"))
        case .raw(let url, .wavWithoutHeader):
            return .raw(url, reason: .wavWithoutHeader)
        }
    }

}

/// Onboarding banner shown above the device file list when the device is
/// encrypted but this iPhone has no matching passphrase. Covers the
/// "second iPhone with old device" and "second-hand encrypted device"
/// flows by surfacing the problem before the user attempts a download.
///
/// Severity follows what is actually at stake. Firmware v1.50 switches
/// encryption on by itself at bind time, so a user who has just unboxed a
/// V05 lands here with an empty device — an orange alarm at that moment
/// reads as "something is wrong with your new device" when nothing is. With
/// no recordings on the device the banner is a plain setup prompt; it turns
/// orange only once there are recordings this iPhone cannot open.
private struct PassphraseOnboardingBanner: View {
    let recordingsAtRisk: Int
    let onOpenSettings: () -> Void

    private var isWarning: Bool { recordingsAtRisk > 0 }

    private var title: String {
        isWarning
            ? L10n.EncryptionOnboarding.bannerTitle
            : L10n.EncryptionOnboarding.bannerSetupTitle
    }

    private var message: String {
        isWarning
            ? L10n.EncryptionOnboarding.bannerMessage
            : L10n.EncryptionOnboarding.bannerSetupMessage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isWarning ? "lock.fill" : "lock.badge.clock")
                .foregroundStyle(foreground)
                .font(.title3)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundStyle(foreground)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(foreground.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenSettings) {
                    Text(L10n.EncryptionOnboarding.bannerCTA)
                        .font(.caption.bold())
                        .foregroundStyle(isWarning ? Color.white : Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            isWarning ? AnyShapeStyle(.white.opacity(0.2))
                                      : AnyShapeStyle(Color.accentColor.opacity(0.12)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isWarning ? AnyShapeStyle(Color.orange)
                              : AnyShapeStyle(Color(.secondarySystemBackground)))
    }

    private var foreground: Color { isWarning ? .white : .primary }
}
