import SwiftUI
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "fast-transfer")

/// Fast Transfer over Wi-Fi (TCP, firmware v1.47+). Uses
/// `NEHotspotConfigurationManager` to join the pen's SoftAP so the user
/// doesn't have to leave the app.
///
/// Flow:
///   1. Stop any active recording so the AP has the power budget.
///   2. Ensure we have SSID/PSK stored in `config.wifi_ap`; generate if absent.
///   3. BLE CMD 0x88 on → poll `getDeviceInfo().wifiAPOn` for up to 60 s.
///   4. Auto-join the AP via `NEHotspotConfigurationManager`; retry on failure.
///   5. Retry TCP connection for up to 60 s → `listFiles` → per-file `pull` + decrypt
///      + library write + delete from device.
///   6. Cleanup: `wifi.close()` sends `quit` so the device drops the AP on
///      its own; remove the hotspot config so the phone hops back to its
///      normal network.
///
/// The button on the Device segment appears when the pending backlog
/// (files the library doesn't yet know about) exceeds 512 KB, per the UI
/// plan's Fast Transfer trigger rule.
struct FastTransferSheet: View {
    let client: DnoteClient
    let library: Library
    let config: ConfigService
    let transcription: TranscriptionService
    let onDone: () -> Void

    @StateObject private var model = FastTransferModel()
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.FastTransfer.status) {
                    HStack {
                        Image(systemName: model.stage.icon)
                            .foregroundColor(model.stage.color)
                        Text(model.stage.title).bold()
                    }
                    if let hint = model.stage.hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                    if let err = model.error {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                    }
                    if model.apStillOn, model.stage == .done || model.stage == .failed {
                        Label(L10n.FastTransfer.apStillOn, systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                if model.ssid != nil {
                    Section(L10n.FastTransfer.apCredentials) {
                        if let ssid = model.ssid { LabeledContent(L10n.RecordingsSettings.ssid, value: ssid) }
                        if let psk = model.psk { LabeledContent(L10n.RecordingsSettings.password, value: psk) }
                    }
                }

                if !model.fileStates.isEmpty {
                    Section(L10n.FastTransfer.filesCount(model.fileStates.count)) {
                        ForEach(model.fileStates) { fs in
                            FileProgressRow(state: fs)
                        }
                    }
                }

                if model.stage != .done && model.stage != .failed {
                    Section {
                        Label(L10n.Common.keepForeground, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if model.stage == .done || model.stage == .failed {
                    Section {
                        Button(L10n.Common.close) {
                            if model.stage == .done { onDone() }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(L10n.FastTransfer.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.Common.cancel) {
                        model.cancel()
                        dismiss()
                    }
                    .disabled(model.stage == .done)
                }
                if model.canRetryJoin {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.Common.retry) { model.retryJoin() }
                    }
                } else if model.canRetryTransfer {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.Common.retry) {
                            Task {
                                await model.retryTransfer(
                                    client: client,
                                    library: library,
                                    config: config,
                                    transcription: transcription,
                                    bluetooth: bluetooth
                                )
                            }
                        }
                    }
                }
            }
            // Only recognize the transition to "entering background". Using scenePhase itself as the ID would treat
            // events like Control Center pull-down or incoming call banners (which trigger .inactive) as interruptions—
            // the app is still running, but the transmission has been cut off.
            .task(id: scenePhase == .background) {
                guard scenePhase != .background else {
                    model.cancelForBackground()
                    return
                }
                UIApplication.shared.isIdleTimerDisabled = true
                defer { UIApplication.shared.isIdleTimerDisabled = false }
                await model.run(client: client, library: library, config: config, transcription: transcription, bluetooth: bluetooth)
            }
        }
    }
}

// MARK: - row

private struct FileProgressRow: View {
    let state: FastTransferFileState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.name).font(.body.monospaced())
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(state.size), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch state.status {
            case .pending:
                Text(L10n.FastTransfer.pendingStatus).font(.caption2).foregroundStyle(.secondary)
            case .downloading(let got):
                let frac = state.size > 0 ? Double(got) / Double(state.size) : 0
                ProgressView(value: frac)
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(got), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(state.size), countStyle: .file))")
                    .font(.caption2).foregroundStyle(.secondary)
            case .done:
                Label(L10n.FastTransfer.saved, systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

struct FastTransferFileState: Identifiable, Equatable {
    let name: String
    let size: Int
    var status: Status

    var id: String { name }
    enum Status: Equatable {
        case pending
        case downloading(Int)
        case done
        case failed(String)
    }
}

// MARK: - model

@MainActor
final class FastTransferModel: ObservableObject {
    enum Stage: Equatable {
        case idle
        case stoppingRecording
        case startingAP
        case pollingAP(attempt: Int, of: Int)
        case joiningWiFi
        case joinFailed
        case connectingTCP
        case listing
        case downloading
        case cleanup
        case done
        case failed

        var title: String {
            switch self {
            case .idle: return L10n.FastTransfer.stageReady
            case .stoppingRecording: return L10n.FastTransfer.stageStopping
            case .startingAP: return L10n.FastTransfer.stageStartingAP
            case .pollingAP(let attempt, let total): return L10n.FastTransfer.stagePollingAP(attempt, total)
            case .joiningWiFi: return L10n.FastTransfer.stageJoiningWifi
            case .joinFailed: return L10n.FastTransfer.stageJoinFailed
            case .connectingTCP: return L10n.FastTransfer.stageConnecting
            case .listing: return L10n.FastTransfer.stageListing
            case .downloading: return L10n.FastTransfer.stageDownloading
            case .cleanup: return L10n.FastTransfer.stageCleanup
            case .done: return L10n.FastTransfer.stageDone
            case .failed: return L10n.FastTransfer.stageStopped
            }
        }
        var hint: String? {
            switch self {
            case .pollingAP: return L10n.FastTransfer.hintPolling
            case .joiningWiFi: return L10n.FastTransfer.hintJoining
            case .joinFailed: return L10n.FastTransfer.hintJoinFailed
            case .connectingTCP: return L10n.FastTransfer.hintConnecting
            default: return nil
            }
        }
        var icon: String {
            switch self {
            case .joinFailed: return "wifi.exclamationmark"
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            default: return "arrow.triangle.2.circlepath"
            }
        }
        var color: Color {
            switch self {
            case .joinFailed: return .orange
            case .done: return .green
            case .failed: return .orange
            default: return .accentColor
            }
        }
    }

    @Published var stage: Stage = .idle
    @Published var error: String?
    /// Device still reports `wifiap=1` after we asked it to turn the AP off.
    /// The next join is likely to fail until the device is power-cycled, so
    /// the sheet says so instead of leaving it in the log.
    @Published var apStillOn = false
    @Published var ssid: String?
    @Published var psk: String?
    @Published var fileStates: [FastTransferFileState] = []
    private var retryContinuation: CheckedContinuation<Void, Never>?
    private var cancelled = false
    private var interruptedByBackground = false
    private var activeWifi: WifiClient?
    private static let apReadyMaxAttempts = 30
    private static let tcpConnectWindow: TimeInterval = 60

    var canRetryJoin: Bool {
        if case .joinFailed = stage { return true }
        return false
    }

    var canRetryTransfer: Bool {
        if case .failed = stage { return true }
        return false
    }

    func cancel() {
        cancelled = true
        activeWifi?.close()
        retryContinuation?.resume()
        retryContinuation = nil
    }

    func cancelForBackground() {
        guard stage != .done && stage != .failed else { return }
        cancelled = true
        interruptedByBackground = true
        activeWifi?.close()
        retryContinuation?.resume()
        retryContinuation = nil
        markInterruptedFilesFailed(L10n.FastTransfer.backgroundInterrupted)
    }

    func retryJoin() {
        retryContinuation?.resume()
        retryContinuation = nil
    }

    func retryTransfer(
        client: DnoteClient,
        library: Library,
        config: ConfigService,
        transcription: TranscriptionService,
        bluetooth: BluetoothCoordinator
    ) async {
        guard stage == .failed else { return }
        cancelled = false
        interruptedByBackground = false
        error = nil
        apStillOn = false
        fileStates = []
        activeWifi = nil
        stage = .idle
        await run(
            client: client,
            library: library,
            config: config,
            transcription: transcription,
            bluetooth: bluetooth
        )
    }

    /// Driver. The `.task(id:)` modifier on the sheet calls this once when
    /// the sheet appears.
    func run(client: DnoteClient, library: Library, config: ConfigService, transcription: TranscriptionService, bluetooth: BluetoothCoordinator) async {
        guard stage == .idle else { return }
        await driver(client: client, library: library, config: config, transcription: transcription, bluetooth: bluetooth)
    }

    private func driver(client: DnoteClient, library: Library, config: ConfigService, transcription: TranscriptionService, bluetooth: BluetoothCoordinator) async {
        // Keep the TCP client reachable by every exit path. Letting it merely
        // deinit cancels the socket but skips WifiClient.close()'s `quit`, which
        // can leave the device AP alive and make the next fast transfer fail to
        // join until the recorder is rebooted.
        do {
            // 1. Stop any active recording.
            stage = .stoppingRecording
            let currentInfo = try await client.getDeviceInfo()
            if currentInfo.isRecording {
                // Do not swallow a rejected/timeout 0x50 and continue into AP
                // setup while the device is still writing the recording. That
                // races file finalisation with list/download and can surface a
                // missing or truncated clip. A failed stop aborts fast transfer
                // and leaves the recording on the device.
                _ = try await client.stopRecording()
            }

            // 2. Ensure creds.
            let (ssid, psk) = creds(from: config)
            self.ssid = ssid
            self.psk = psk

            // WPA2 only accepts passphrases of 8–63 characters. The settings page does not validate this field.
            // If a 4-character password is saved, joinAP will be directly rejected by the system with
            // `invalid WPA/WPA2 Passphrase.`, while the UI only displays
            // "Connection failed, tap to retry" — retrying will never succeed (verified on a real device).
            // Clarify this upfront before starting the hotspot, so users don't waste time tapping the retry button.
            guard (8...63).contains(psk.count) else {
                throw FastTransferError.invalidPSK
            }

            // 3. Start AP + poll.
            stage = .startingAP
            // After being interrupted by the background or canceled, the device often gets stuck at `wifiap=1`
            // without broadcasting the SSID.
            // In this case, directly enabling the AP will cause the polling to see the status bit as 1
            // and immediately allow it, but joining will always fail,
            // leaving the user with only one option: "power cycle the device". First, disable the residual AP
            // to let the device's Wi-Fi state machine go through the startup process again.
            if currentInfo.wifiAPOn {
                log.info("device still advertises wifiap=1 on entry — cycling the AP")
                await turnOffAP(client: client)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                try checkCancel()
                // This round has just started; the “hotspot not turned off” warning at cleanup must not be triggered by the entry‑cleanup step.
                apStillOn = false
            }
            try await client.setWifiAP(on: true, ssid: ssid, psk: psk)
            stage = .pollingAP(attempt: 0, of: Self.apReadyMaxAttempts)
            try await pollAPReady(client: client)
            try checkCancel()

            // Give the AP a few seconds to stabilize after wifiap=1 — without
            // an explicit wait the iOS NEHotspotConfigurationManager join
            // often fails with "Unable to join the network".
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            // 4+5. Join Wi-Fi + verify with TCP. If either step fails
            //       the user can retry (iOS sometimes reports a successful
            //       join even though the phone never reached the AP).
            let wifi = try await joinAndConnect(ssid: ssid, psk: psk, client: client)
            activeWifi = wifi

            // 6. List + filter.
            stage = .listing
            let all = try await wifi.listFiles()
            let deviceSerial = client.lastDeviceInfo?.serial
            let pending = all.filter {
                !library.isDownloaded($0.name, deviceSerial: deviceSerial)
            }
            fileStates = pending.map { .init(name: $0.name, size: $0.size, status: .pending) }
            if pending.isEmpty {
                try? await teardown(wifi: wifi, client: client, ssid: ssid, bluetooth: bluetooth)
                activeWifi = nil
                stage = .done
                return
            }

            // 7. Download each.
            stage = .downloading
            for file in pending {
                try checkCancel()
                await markStatus(file.name, .downloading(0))
                do {
                    // `expectedSize` makes the client reject a short read
                    // instead of handing back a truncated file — the delete
                    // below keys off this call succeeding.
                    let data = try await wifi.downloadFile(file.name, expectedSize: file.size) { [weak self] got, _ in
                        Task { @MainActor in self?.updateProgress(file.name, got) }
                    }
                    let chachaKey = KeyResolver.key(for: client)
                    let localName = library.localNameForDeviceFile(
                        file.name,
                        deviceSerial: deviceSerial
                    )
                    let outcome = try PostDownload.process(
                        data,
                        name: localName,
                        chacha20Key: chachaKey
                    )
                    // Unreadable originals (no password set / incorrect password) **do not count as fully transferred**. Follow the BLE
                    // path `RecordingsView.writeAndDecrypt`: report failure, and **preserve the original on the
                    // device**, allowing the user to retry after setting the password.
                    //
                    // Previously, this was `_ = try PostDownload.process(...)` — the outcome was discarded,
                    // causing the ciphertext to be treated as success, the device file to be deleted,
                    // and the database to only scan the decrypted/ directory, making it invisible.
                    // From the user's perspective, the recording disappeared (V05 v1.50 enforces encryption upon binding; reproducible on real devices).
                    guard case .ready = outcome else {
                        let reason: String
                        switch outcome {
                        case .raw(_, .keyMissing):
                            reason = L10n.EncryptionOnboarding.downloadFailedKeyMissing(file.name)
                        case .raw(_, .decryptFailed(let msg)):
                            reason = L10n.EncryptionOnboarding.downloadFailedWrongKey(file.name, msg)
                        default:
                            reason = L10n.FastTransfer.decodeFailed(file.name)
                        }
                        log.warning("keep \(file.name, privacy: .public) on device — not playable")
                        await markStatus(file.name, .failed(reason))
                        continue
                    }
                    library.recordDownload(
                        name: file.name,
                        size: data.count,
                        transport: "wifi",
                        deviceSerial: deviceSerial,
                        localName: localName
                    )
                    await markStatus(file.name, .done)

                    // Auto-transcribe (opt-in). Detached so teardown isn't
                    // blocked by ASR latency. tooShort is swallowed — the
                    // user opted into the duration gate when enabling this.
                    if config.config.autoTranscribeAfterDownload {
                        let decryptedURL = StorageLocations.decryptedDir.appendingPathComponent(localName)
                        if FileManager.default.fileExists(atPath: decryptedURL.path) {
                            Task.detached { @MainActor in
                                _ = try? await transcription.transcribe(
                                    fileURL: decryptedURL,
                                    enforceMinDuration: true
                                )
                            }
                        }
                    }
                    // Best-effort delete; log-only on failure. Scope same as BLE path:
                    // Only when a playable file has been extracted (guard above guarantees) **and** the user has enabled
                    // the “Delete from device after transfer” option, then we act on the original file on the device. Previously this switch was not read,
                    // so even if the user turned it off, it would still be deleted.
                    if config.config.autoDeleteAfterTransfer {
                        do { try await wifi.deleteFile(file.name) } catch {
                            log.warning("delete \(file.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                        }
                    }
                } catch is CancellationError {
                    await markStatus(file.name, .failed(L10n.FastTransfer.cancelled))
                    break
                } catch {
                    await markStatus(file.name, .failed(error.localizedDescription))
                }
            }

            // 8. Cleanup. The driver finishing does not mean every file
            // finished: a per-file timeout/decode error is caught above so the
            // remaining files can continue. Summarise those outcomes instead
            // of showing a green "Done" over failed rows.
            try? await teardown(wifi: wifi, client: client, ssid: ssid, bluetooth: bluetooth)
            activeWifi = nil
            if fileStates.contains(where: {
                if case .failed = $0.status { return true }
                return false
            }) {
                stage = .failed
                error = L10n.DeviceFiles.operationFailed
            } else {
                stage = .done
            }
        } catch is CancellationError {
            activeWifi?.close()
            activeWifi = nil
            let message = interruptedByBackground
                ? L10n.FastTransfer.backgroundInterrupted
                : L10n.FastTransfer.cancelled
            markInterruptedFilesFailed(message)
            stage = .failed
            error = message
            await cleanupAP(client: client, bluetooth: bluetooth)
        } catch {
            activeWifi?.close()
            activeWifi = nil
            stage = .failed
            self.error = error.localizedDescription
            await cleanupAP(client: client, bluetooth: bluetooth)
        }
    }

    // MARK: helpers

    private func checkCancel() throws {
        if cancelled || Task.isCancelled { throw CancellationError() }
    }

    private func joinAndConnect(ssid: String, psk: String, client: DnoteClient) async throws -> WifiClient {
        while true {
            try checkCancel()

            // a) Ask iOS to join th
            stage = .joiningWiFi
            do {
                try await HotspotJoiner.apply(ssid: ssid, psk: psk)
            } catch {
                log.warning("Wi-Fi join failed: \(String(describing: error), privacy: .public)")
                self.error = error.localizedDescription
                stage = .joinFailed
                await awaitRetry()
                self.error = nil
                // If the user taps “Cancel” on the system dialog, the hotspot itself is fine; just show it again.
// Other failures (typically iOS's "Unable to join the network") indicate that the device reports wifiap=1 but is not actually broadcasting; before retrying, have it turn the hotspot off and on again.
                var userDeclined = false
                if case .userDenied? = error as? HotspotError { userDeclined = true }
                if !userDeclined {
                    try await cycleAP(client: client, ssid: ssid, psk: psk)
                }
                continue
            }

            // b) Verify by opening a TCP session. iOS can report a
            //    successful join even when the phone stayed on its
            //    original network, so this is the real connectivity test.
            stage = .connectingTCP
            let tcpDeadline = Date().addingTimeInterval(Self.tcpConnectWindow)
            var attempt = 0
            while tcpDeadline.timeIntervalSinceNow > 0 {
                try checkCancel()
                attempt += 1
                // Keep individual attempts short so a network route that appears
                // during the one-minute window can be retried promptly. Cap the
                // final attempt at the remaining time so the total does not drift
                // materially beyond 60 seconds.
                let remaining = tcpDeadline.timeIntervalSinceNow
                let wifi = WifiClient(connectTimeout: min(5, remaining))
                do {
                    try await wifi.connect()
                    return wifi
                } catch {
                    log.info("TCP connect attempt \(attempt): \(String(describing: error), privacy: .public)")
                    let retryDelay = min(2, tcpDeadline.timeIntervalSinceNow)
                    if retryDelay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    }
                }
            }

            // TCP unreachable for one minute — the join likely failed silently.
            HotspotJoiner.remove(ssid: ssid)
            log.warning("TCP unreachable after Wi-Fi join — prompting retry")
            self.error = L10n.FastTransfer.tcpUnreachable
            stage = .joinFailed
            await awaitRetry()
            self.error = nil
            // If joining succeeds but TCP cannot connect within a minute, it means the device's reported `wifiap=1` does not match the actual broadcast.
            // Retrying with the same AP any number of times yields the same result; first have the device turn the hotspot off and on again.
            try await cycleAP(client: client, ssid: ssid, psk: psk)
        }
    }

    /// Turn off the device hotspot, then turn it back on, and wait again for `wifiap=1`.
    ///
    /// `pollAPReady` is a read‑only status flag, so it must be actually toggled once: the flag goes from 1 to 0 and back to 1,
    // only then does it represent the newly started AP for this round, not the leftover from the previous round.
    private func cycleAP(client: DnoteClient, ssid: String, psk: String) async throws {
        stage = .startingAP
        await turnOffAP(client: client)
        apStillOn = false
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        try checkCancel()
        try await client.setWifiAP(on: true, ssid: ssid, psk: psk)
        try await pollAPReady(client: client)
        try checkCancel()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    private func awaitRetry() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.retryContinuation = cont
        }
    }

    private func markStatus(_ name: String, _ status: FastTransferFileState.Status) async {
        if let idx = fileStates.firstIndex(where: { $0.name == name }) {
            fileStates[idx].status = status
        }
    }

    private func updateProgress(_ name: String, _ got: Int) {
        if let idx = fileStates.firstIndex(where: { $0.name == name }) {
            fileStates[idx].status = .downloading(got)
        }
    }

    private func markInterruptedFilesFailed(_ message: String) {
        for idx in fileStates.indices {
            switch fileStates[idx].status {
            case .pending, .downloading:
                fileStates[idx].status = .failed(message)
            case .done, .failed:
                break
            }
        }
    }

    private func pollAPReady(client: DnoteClient) async throws {
        // The recorder can need close to a minute to bring up its SoftAP on
        // battery power. Poll every two seconds for a full minute before
        // reporting failure instead of exposing the old 22-attempt (~44 s)
        // implementation detail to the user.
        let maxAttempts = Self.apReadyMaxAttempts
        for attempt in 1...maxAttempts {
            try checkCancel()
            stage = .pollingAP(attempt: attempt, of: maxAttempts)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let info = try await client.getDeviceInfo()
                if info.wifiAPOn { return }
            } catch {
                log.info("poll attempt \(attempt)/\(maxAttempts) failed: \(String(describing: error), privacy: .public)")
            }
        }
        throw FastTransferError.apNotBroadcasting
    }

    private func teardown(wifi: WifiClient, client: DnoteClient, ssid: String, bluetooth: BluetoothCoordinator) async throws {
        stage = .cleanup
        wifi.close()
        HotspotJoiner.remove(ssid: ssid)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await turnOffAP(client: client)
        await ensureBLEReconnected(deviceID: client.peripheral.identifier, bluetooth: bluetooth)
    }

    /// Teardown for the cancel / background path.
    ///
    /// Runs detached on purpose, for the same reason `ensureBLEReconnected`
    /// does. We only get here with the whole task tree already flagged
    /// cancelled (SwiftUI cancels the sheet's `.task` when `scenePhase`
    /// changes or the sheet is dismissed), and every BLE round trip waits in
    /// `NotifyQueue.pop(timeout:)`, whose `Task.sleep` throws
    /// `CancellationError` the instant it is entered. Awaiting
    /// `setWifiAP(off:)` inline therefore never reaches the radio: the device
    /// keeps `wifiap=1`, stops broadcasting, and the next fast transfer can't
    /// join until the recorder is power-cycled — the "cannot rejoin the hotspot after a failure"
    /// half of the bug report.
    private func cleanupAP(client: DnoteClient, bluetooth: BluetoothCoordinator) async {
        if let ssid = self.ssid { HotspotJoiner.remove(ssid: ssid) }
        let teardown = Task.detached { @MainActor [weak self] in
            await self?.turnOffAP(client: client)
            await self?.ensureBLEReconnected(deviceID: client.peripheral.identifier, bluetooth: bluetooth)
        }
        // Task<Void, Never>.value can't throw, so a cancelled caller still
        // waits here instead of skipping past the teardown it just started.
        await teardown.value
    }

    /// iOS sometimes drops the BLE link while the phone is on the device's
    /// Wi-Fi AP (radio contention), so the connection pill goes stale even
    /// after the AP is back down. Idempotent no-op when `bluetooth.client`
    /// already matches; otherwise a handful of reconnect attempts with
    /// short backoff.
    ///
    /// Runs detached on purpose. The sheet's `.task { await model.run(...) }`
    /// scope is flagged `isCancelled` by the time we get here (the
    /// NWConnection teardown + hotspot removal propagates cancellation up
    /// the task tree) — any `await bluetooth.reconnect(...)` in the same
    /// task sees that flag and throws `CancellationError` instantly without
    /// ever reaching the radio. Detaching breaks the cancellation chain so
    /// the retries actually run. Caller doesn't wait on this; reconnection
    /// happens on its own timeline and `bluetooth.client` publishes the
    /// update whenever it lands.
    private func ensureBLEReconnected(deviceID: UUID, bluetooth: BluetoothCoordinator) async {
        if let existing = bluetooth.client,
           existing.peripheral.identifier == deviceID,
           existing.peripheral.state == .connected {
            return
        }
        Task.detached { @MainActor in
            for attempt in 1...3 {
                if let existing = bluetooth.client,
                   existing.peripheral.identifier == deviceID,
                   existing.peripheral.state == .connected {
                    return
                }
                do {
                    _ = try await bluetooth.reconnect(deviceID: deviceID)
                    return
                } catch {
                    log.info("BLE reconnect attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                    if attempt < 3 {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            }
        }
    }

    /// Close the device's Wi-Fi AP via `CMD 0x88 {"ap": 0, "ssid": ...,
    /// "psk": ...}`. v1.47 firmware requires the same SSID/PSK that
    /// started the AP — the documented bare `{"ap": 0}` shape is
    /// rejected. After ack we verify with `getDeviceInfo().wifiAPOn`
    /// because the ack only means "command accepted".
    private func turnOffAP(client: DnoteClient) async {
        let credSSID = self.ssid ?? ""
        let credPSK = self.psk ?? ""
        do {
            try await client.setWifiAP(on: false, ssid: credSSID, psk: credPSK)
        } catch {
            log.warning("setWifiAP(off) failed: \(String(describing: error), privacy: .public)")
            // Failing to turn off the hotspot, or turning it off but it stays on, is the same issue for the user: the next fast transfer will likely fail to join.
            // Silently returning here keeps the UI looking normal, leaving the problem only in the log.
            apStillOn = true
            return
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let info = try? await client.getDeviceInfo() {
            log.info("post-off cmd=0x80 wifiAPOn=\(info.wifiAPOn, privacy: .public)")
            if !info.wifiAPOn {
                log.info("setWifiAP(off) verified — AP actually down")
                apStillOn = false
            } else {
                log.warning("setWifiAP(off) ack=true but wifiap still 1 — power-cycle the device if it's still broadcasting")
                apStillOn = true
            }
        } else {
            log.warning("post-off 0x80 read failed — AP state unconfirmed")
            apStillOn = true
        }
    }

    private func creds(from config: ConfigService) -> (String, String) {
        if let existing = config.config.wifiAP,
           !existing.ssid.isEmpty, !existing.psk.isEmpty {
            return (existing.ssid, existing.psk)
        }
        let suffix = Self.randomSuffix(length: 4, alphabet: "abcdefghijklmnopqrstuvwxyz0123456789")
        let ssid = "dnote-\(suffix)"
        let psk = Self.randomSuffix(length: 12, alphabet: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        config.config.wifiAP = .init(ssid: ssid, psk: psk)
        config.saveNow()
        return (ssid, psk)
    }

    private static func randomSuffix(length: Int, alphabet: String) -> String {
        let chars = Array(alphabet)
        var out = ""
        for _ in 0..<length {
            out.append(chars.randomElement() ?? "x")
        }
        return out
    }
}

enum FastTransferError: LocalizedError {
    case apNotBroadcasting
    /// The hotspot password in the configuration is not a valid WPA2 passphrase (length must be 8–63 characters).
    case invalidPSK

    var errorDescription: String? {
        switch self {
        case .apNotBroadcasting:
            return L10n.FastTransfer.apNotBroadcasting
        case .invalidPSK:
            return L10n.FastTransfer.invalidPSK
        }
    }
}
