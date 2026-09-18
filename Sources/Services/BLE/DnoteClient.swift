import CoreBluetooth
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ble.client")

/// Wraps a single connected `CBPeripheral` and exposes the high-level command
/// surface. Acts as the peripheral delegate; routes incoming notifications
/// onto three queues (response / transfer / stream) keyed by command byte.
@MainActor
final class DnoteClient: NSObject, ObservableObject {
    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?

    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?

    /// Pending continuation for the next response packet (cmd != 0x70/0x68/0x55).
    /// A single waiter: there is only ever one outstanding request at a time
    /// and we keep that invariant here.
    private let respQueue = NotifyQueue()
    private let xferQueue = NotifyQueue()
    private let streamQueue = NotifyQueue()

    /// Set to `true` when a download is cancelled by the caller while the
    /// device is still mid-transfer. The next `doDownload` sees the flag and
    /// reads packets until the device sends a terminal status before sending
    /// the new cmd_start — otherwise the device receives a start while it is
    /// still streaming the previous file and responds with XFER_ERROR.
    private var pendingXferDrain = false

    /// Resolved during `completeHandshake` so SwiftUI can show it in the
    /// Device sheet hero card.
    @Published private(set) var negotiatedMTU: Int = 0
    @Published private(set) var lastDeviceInfo: DeviceInfo?
    @Published private(set) var lastSwitchInfo: SwitchInfo?
    @Published private(set) var disconnectError: Error?

    /// Bond state as last reported by the device (v1.47). Nil until the
    /// first `queryBondState` completes. When `bound == false`, recording
    /// and live-stream commands throw `DnoteError.notBound`; the UI then
    /// prompts the user to pair.
    @Published private(set) var lastBondState: BondState?

    struct BondState: Equatable {
        let bound: Bool
        /// 16 raw bytes when `bound == true`, nil otherwise.
        let bondID: Data?
    }

    /// Device-side ChaCha20 encryption state (v1.47). Nil until the first
    /// `getEncryptionState` completes. When `false`, files come off the
    /// device plaintext and the download pipeline must skip the ChaCha20
    /// decrypt path — applying a stale configured key to plaintext would
    /// produce garbage. Refreshed on connect and after every `setEncryption`.
    @Published private(set) var deviceEncryptionOn: Bool?

    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var notifyEnabledContinuation: CheckedContinuation<Void, Error>?

    // Request/response serialization — the device speaks one command at a
    // time, and NotifyQueue supports only one waiter per channel. Without
    // this, two concurrent `.task` blocks (e.g. DeviceSheet + Recordings)
    // race through the shared respQueue, and the second recv() evicts the
    // first with CancellationError. runExclusive() funnels commands into
    // a single in-flight operation.
    private var cmdBusy = false
    private var cmdWaiters: [CheckedContinuation<Void, Never>] = []

    init(peripheral: CBPeripheral, central: CBCentralManager) {
        self.peripheral = peripheral
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    var displayName: String { peripheral.name ?? "DNOTE" }

    var isConnected: Bool { peripheral.state == .connected && rxChar != nil && txChar != nil }

    // MARK: handshake

    /// Called by `BluetoothCoordinator` once `centralManager(_:didConnect:)`
    /// fires. Discovers service + characteristics, enables notifications on
    /// TX_CHAR, captures the negotiated MTU.
    func completeHandshake() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.handshakeContinuation = cont
            peripheral.discoverServices([DnoteProtocol.serviceUUID])
        }
        negotiatedMTU = peripheral.maximumWriteValueLength(for: .withResponse)
        log.info("Handshake complete; MTU=\(self.negotiatedMTU, privacy: .public)")
    }

    func handleDisconnect(error: Error?) {
        rxChar = nil
        txChar = nil
        disconnectError = error
        respQueue.failAll(with: DnoteError.notConnected)
        xferQueue.failAll(with: DnoteError.notConnected)
        streamQueue.failAll(with: DnoteError.notConnected)
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: error ?? DnoteError.notConnected)
        }
        if let cont = notifyEnabledContinuation {
            notifyEnabledContinuation = nil
            cont.resume(throwing: error ?? DnoteError.notConnected)
        }
    }

    // MARK: command serialization

    private func acquireCmdLock() async {
        if !cmdBusy {
            cmdBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cmdWaiters.append(cont)
        }
        // When resumed, the previous holder has already set cmdBusy = true
        // on our behalf (see releaseCmdLock).
    }

    private func releaseCmdLock() {
        if cmdWaiters.isEmpty {
            cmdBusy = false
        } else {
            let next = cmdWaiters.removeFirst()
            next.resume()
        }
    }

    /// Run `op` with exclusive access to the request/response channel.
    /// Every public command goes through this so two SwiftUI `.task`
    /// blocks can safely touch the same client.
    private func runExclusive<T>(_ op: () async throws -> T) async throws -> T {
        await acquireCmdLock()
        defer { releaseCmdLock() }
        return try await op()
    }

    // MARK: low-level send / recv

    /// Drains stale responses, then writes the request frame to RX_CHAR
    /// with response.
    private func send(cmd: UInt8, payload: Data = Data()) async throws {
        guard isConnected, let rx = rxChar else {
            log.warning("send cmd=\(String(format: "0x%02X", cmd), privacy: .public) but not connected")
            throw DnoteError.notConnected
        }
        respQueue.drain()
        let pkt = PacketCodec.encode(cmd: cmd, payload: payload)
        log.debug("→ cmd=\(String(format: "0x%02X", cmd), privacy: .public) len=\(payload.count, privacy: .public)")
        peripheral.writeValue(pkt, for: rx, type: .withResponse)
    }

    private func sendJSON(cmd: UInt8, _ object: [String: Any]) async throws {
        guard isConnected, let rx = rxChar else {
            log.warning("sendJSON cmd=\(String(format: "0x%02X", cmd), privacy: .public) but not connected")
            throw DnoteError.notConnected
        }
        respQueue.drain()
        let pkt = try PacketCodec.encodeJSON(cmd: cmd, object)
        log.debug("→ cmd=\(String(format: "0x%02X", cmd), privacy: .public) json=\(String(describing: Self.redactedForLog(object)), privacy: .public)")
        peripheral.writeValue(pkt, for: rx, type: .withResponse)
    }

    /// Credential fields that must never reach the log. `setWifiAP` (0x88)
    /// sends the hotspot SSID and PSK in this object, and the generic
    /// "dump the whole JSON" debug line was putting the complete Wi-Fi
    /// credentials into the system log — anything that exports logs would
    /// carry them out with it.
    private static let secretJSONKeys: Set<String> = ["psk", "password", "key", "passphrase", "ssid"]

    private static func redactedForLog(_ object: [String: Any]) -> [String: Any] {
        object.reduce(into: [String: Any]()) { out, pair in
            out[pair.key] = secretJSONKeys.contains(pair.key.lowercased())
                ? "<redacted>"
                : pair.value
        }
    }

    private func recv(timeout: TimeInterval = 5) async throws -> PacketCodec.Frame {
        let data = try await respQueue.pop(timeout: timeout)
        guard let frame = PacketCodec.decode(data) else {
            log.error("recv malformed len=\(data.count, privacy: .public)")
            throw DnoteError.malformedResponse
        }
        log.debug("← cmd=\(String(format: "0x%02X", frame.cmd), privacy: .public) len=\(frame.length, privacy: .public) ack=\(frame.isAck, privacy: .public)")
        return frame
    }

    /// Pop frames until one carries `cmd`, discarding anything else.
    ///
    /// The device reports state changes on its own — it pushes a notification
    /// right after a switch flips — and `dispatchNotification` funnels every
    /// non-stream/non-transfer frame into the same FIFO. A blind pop returns
    /// whatever lands first, so an unsolicited push that beats the reply is
    /// consumed *as* that reply: `sendExpectAck` tests the push's first byte,
    /// sees no 0x01, and throws `ackFailed` even though the command worked —
    /// which is how a switch could be turned off but not back on. (`send`
    /// drains the queue beforehand, so this is a race inside one command
    /// rather than a lasting offset.) Correlating by command byte makes the
    /// client immune to any unsolicited push — the same approach
    /// `collectRecordingResponses` already uses to absorb 0x56.
    private func recv(expect cmd: UInt8, timeout: TimeInterval = 5) async throws -> PacketCodec.Frame {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw DnoteError.timeout }
            let frame = try await recv(timeout: remaining)
            if frame.cmd == cmd { return frame }
            log.debug("recv(expect 0x\(String(format: "%02X", cmd), privacy: .public)) discarding unsolicited cmd=0x\(String(format: "%02X", frame.cmd), privacy: .public)")
        }
    }

    private func recvJSON(timeout: TimeInterval = 5) async throws -> [String: Any] {
        let frame = try await recv(timeout: timeout)
        let obj = try PacketCodec.decodeJSON(frame)
        log.debug("← json cmd=\(String(format: "0x%02X", frame.cmd), privacy: .public) payload=\(String(describing: obj), privacy: .public)")
        return obj
    }

    /// `recvJSON` correlated by command byte. See `recv(expect:timeout:)`.
    private func recvJSON(expect cmd: UInt8, timeout: TimeInterval = 5) async throws -> [String: Any] {
        let frame = try await recv(expect: cmd, timeout: timeout)
        let obj = try PacketCodec.decodeJSON(frame)
        log.debug("← json cmd=\(String(format: "0x%02X", frame.cmd), privacy: .public) payload=\(String(describing: obj), privacy: .public)")
        return obj
    }

    /// Send a request and expect an "OK" ack (`payload[0] == 0x01`).
    private func sendExpectAck(cmd: UInt8, payload: Data = Data(), timeout: TimeInterval = 10) async throws {
        try await send(cmd: cmd, payload: payload)
        let frame = try await recv(expect: cmd, timeout: timeout)
        guard frame.isAck else { throw DnoteError.ackFailed(cmd: cmd) }
    }

    // MARK: high-level commands

    /// CMD 0x80 — fetch SN, FW version, battery, free space, BT name, etc.
    @discardableResult
    func getDeviceInfo() async throws -> DeviceInfo {
        try await runExclusive { try await readDeviceInfoLocked() }
    }

    /// Read 0x80 while the caller already owns the command lock.
    private func readDeviceInfoLocked() async throws -> DeviceInfo {
        try await send(cmd: DnoteProtocol.Cmd.deviceInfo)
        let json = try await recvJSON(expect: DnoteProtocol.Cmd.deviceInfo)
        let info = DeviceInfo(json: json)
        lastDeviceInfo = info
        return info
    }

    /// Mutating device commands go through a fresh 0x80 read immediately
    /// before the command. UI disabling is only advisory: the physical button
    /// can start recording after the sheet was rendered.
    private func runWhenNotRecording<T>(_ op: () async throws -> T) async throws -> T {
        try await runExclusive {
            let info = try await readDeviceInfoLocked()
            guard !info.isRecording else {
                throw DnoteError.operationUnavailableWhileRecording
            }
            return try await op()
        }
    }

    /// CMD 0x81 — fetch the device's switch states.
    @discardableResult
    func getSwitchInfo() async throws -> SwitchInfo {
        try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.switchInfo)
            let json = try await recvJSON(expect: DnoteProtocol.Cmd.switchInfo)
            let info = SwitchInfo(json: json)
            lastSwitchInfo = info
            return info
        }
    }

    enum Switch: String {
        case ms, led, motor, nc, wav, vad

        var cmd: UInt8 {
            switch self {
            case .ms:    return DnoteProtocol.Cmd.massStorage
            case .led:   return DnoteProtocol.Cmd.led
            case .motor: return DnoteProtocol.Cmd.motor
            case .nc:    return DnoteProtocol.Cmd.noiseCancel
            case .wav:   return DnoteProtocol.Cmd.saveWAV
            case .vad:   return DnoteProtocol.Cmd.vad
            }
        }
    }

    func setSwitch(_ s: Switch, on: Bool) async throws {
        try await runWhenNotRecording {
            try await sendExpectAck(cmd: s.cmd, payload: Data([on ? 0x01 : 0x00]))
        }
    }

    func setMicGain(_ level: Int) async throws {
        precondition((1...9).contains(level), "gain must be 1...9")
        try await runWhenNotRecording {
            try await sendExpectAck(cmd: DnoteProtocol.Cmd.micGain, payload: Data([UInt8(level)]))
        }
    }

    func setNRLevel(_ level: Int) async throws {
        precondition((1...9).contains(level), "nr must be 1...9")
        try await runWhenNotRecording {
            try await sendExpectAck(cmd: DnoteProtocol.Cmd.nrLevel, payload: Data([UInt8(level)]))
        }
    }

    func setIdleOff(seconds: UInt32) async throws {
        precondition(seconds > 0, "use DnoteProtocol.idleOffNever to disable")
        var be = seconds.bigEndian
        let payload = Data(bytes: &be, count: 4)
        try await runWhenNotRecording {
            try await sendExpectAck(cmd: DnoteProtocol.Cmd.idleOff, payload: payload)
        }
    }

    func setBluetoothName(_ name: String) async throws {
        let bytes = name.data(using: .utf8) ?? Data()
        guard !bytes.isEmpty, bytes.count <= DnoteProtocol.btNameMaxBytes else {
            throw DnoteError.deviceError("BT name must be 1…\(DnoteProtocol.btNameMaxBytes) UTF-8 bytes (got \(bytes.count))")
        }
        try await runWhenNotRecording {
            let nameCmd = bytes.count <= 16
                ? DnoteProtocol.Cmd.btNameShort
                : DnoteProtocol.Cmd.btNameLong
            if bytes.count <= 16 {
                try await sendJSON(cmd: nameCmd, ["bt": name])
            } else {
                try await send(cmd: nameCmd, payload: bytes)
            }
            let frame = try await recv(expect: nameCmd, timeout: 10)
            guard frame.isAck else { throw DnoteError.ackFailed(cmd: nameCmd) }
        }
    }

    func syncTime(to date: Date = Date()) async throws {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        try await runExclusive {
            try await sendJSON(cmd: DnoteProtocol.Cmd.syncTime, ["time": f.string(from: date)])
            let frame = try await recv(expect: DnoteProtocol.Cmd.syncTime, timeout: 10)
            guard frame.isAck else { throw DnoteError.ackFailed(cmd: DnoteProtocol.Cmd.syncTime) }
        }
    }

    func formatDisk() async throws {
        try await runWhenNotRecording {
            try await sendExpectAck(cmd: DnoteProtocol.Cmd.formatDisk, timeout: 30)
        }
    }

    func factoryReset() async throws {
        try await runWhenNotRecording {
            try await sendExpectAck(cmd: DnoteProtocol.Cmd.factoryReset, timeout: 15)
        }
    }

    /// CMD 0x88 — toggle the device's Wi-Fi AP for fast TCP file transfer (v1.47+).
    /// `ssid` / `psk` are each capped at 32 bytes UTF-8.
    ///
    /// When `on == false` and either credential is non-empty the off
    /// payload is sent as `{"ap": 0, "ssid": ..., "psk": ...}` instead
    /// of the bare `{"ap": 0}`. This is an experimental probe (the
    /// documented spec is bare-`ap` only) for the v1.47 "ack=false on
    /// off" behaviour. Pass empty strings
    /// (default) to send the spec-compliant bare payload.
    ///
    /// Note: the ACK only means "command accepted". Radio bring-up takes
    /// 20-45 s on battery — poll `getDeviceInfo().wifiAPOn` before joining.
    func setWifiAP(on: Bool, ssid: String = "", psk: String = "") async throws {
        guard ssid.utf8.count <= 32 else {
            throw DnoteError.deviceError("SSID too long (max 32 bytes UTF-8)")
        }
        guard psk.utf8.count <= 32 else {
            throw DnoteError.deviceError("PSK too long (max 32 bytes UTF-8)")
        }
        let payload: [String: Any]
        if on {
            payload = ["ap": 1, "ssid": ssid, "psk": psk]
        } else if !ssid.isEmpty || !psk.isEmpty {
            payload = ["ap": 0, "ssid": ssid, "psk": psk]
        } else {
            payload = ["ap": 0]
        }
        // Log payload shape (not values) so the SSID/PSK don't leak;
        // shape alone is enough to tell the bare-off vs creds-off
        // variants apart in Console.app.
        let shape = payload.keys.sorted().joined(separator: ",")
        log.info("→ cmd=0x88 fields=[\(shape, privacy: .public)] ap=\(on ? 1 : 0, privacy: .public)")
        try await runExclusive {
            try await sendJSON(cmd: DnoteProtocol.Cmd.wifiAP, payload)
            let frame = try await recv(expect: DnoteProtocol.Cmd.wifiAP, timeout: 15)
            log.info("← cmd=0x88 ack=\(frame.isAck, privacy: .public)")
            guard frame.isAck else { throw DnoteError.ackFailed(cmd: DnoteProtocol.Cmd.wifiAP) }
        }
    }

    func shutdown() async throws {
        // Device hangs up immediately after ack; tolerate the disconnect.
        do {
            try await runWhenNotRecording {
                try await sendExpectAck(cmd: DnoteProtocol.Cmd.shutdown, timeout: 5)
            }
        } catch DnoteError.timeout, DnoteError.notConnected {
            return
        }
    }

    // MARK: binding (v1.47)

    /// CMD 0xA0 — bind this app to the device. Firmware v1.47 refuses
    /// `startRecording` / `startStream` until a bind is on record. The
    /// payload is `[0x01][bond_id(16 bytes)]`; any 16 random bytes
    /// will do — the device stores them verbatim and just checks that a
    /// bond exists. Call `queryBondState()` afterwards to refresh the
    /// UI-visible cache, or trust the optimistic update done here.
    func bindDevice(bondID: Data) async throws {
        precondition(bondID.count == DnoteProtocol.bondIDLength, "bondID must be 16 bytes")
        try await runExclusive {
            var payload = Data([0x01])
            payload.append(bondID)
            try await sendExpectAck(cmd: DnoteProtocol.Cmd.bind, payload: payload, timeout: 10)
            lastBondState = BondState(bound: true, bondID: bondID)
        }
    }

    /// CMD 0xA0 — unbind. Permissive on the device side (any app can unbind
    /// anyone else's pairing), so this is mainly a user-driven escape hatch.
    func unbindDevice() async throws {
        try await runWhenNotRecording {
            try await sendExpectAck(cmd: DnoteProtocol.Cmd.bind, payload: Data([0x00]), timeout: 10)
            lastBondState = BondState(bound: false, bondID: nil)
        }
    }

    /// CMD 0xA1 — read current bond state. Response is either `[0x00]`
    /// (unbound) or `[0x01][bond_id(16)]` (bound). Populates
    /// `lastBondState` as a side effect so SwiftUI views can bind to it
    /// without running the command themselves.
    @discardableResult
    func queryBondState() async throws -> BondState {
        try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.queryBond)
            let frame = try await recv(expect: DnoteProtocol.Cmd.queryBond, timeout: 10)
            guard frame.cmd == DnoteProtocol.Cmd.queryBond, !frame.payload.isEmpty else {
                throw DnoteError.malformedResponse
            }
            let boundByte = frame.payload[frame.payload.startIndex]
            let state: BondState
            if boundByte == 0x01, frame.payload.count >= 1 + DnoteProtocol.bondIDLength {
                let start = frame.payload.startIndex + 1
                let end   = start + DnoteProtocol.bondIDLength
                state = BondState(bound: true, bondID: Data(frame.payload[start..<end]))
            } else {
                state = BondState(bound: false, bondID: nil)
            }
            lastBondState = state
            return state
        }
    }

    /// Ensure the device has an active bond before issuing a recording
    /// command. Runs `queryBondState` lazily when the cache is still nil so
    /// the first call after connect self-heals instead of throwing.
    /// Cannot be called while holding the command lock — callers invoke it
    /// *before* their own `runExclusive` block.
    private func ensureBound() async throws {
        if lastBondState == nil {
            _ = try? await queryBondState()
        }
        guard lastBondState?.bound == true else {
            throw DnoteError.notBound
        }
    }

    // MARK: encryption (v1.47)

    /// CMD 0xA2 — turn on-device ChaCha20 encryption on or off. The 32-byte
    /// `key` must match the current one when toggling OFF (firmware enforces
    /// this); when toggling ON, `key` is the new value to store. Updates
    /// `deviceEncryptionOn` optimistically on success.
    func setEncryption(on: Bool, key: Data) async throws {
        precondition(key.count == DnoteProtocol.chachaKeyLength, "key must be 32 bytes")
        try await runWhenNotRecording {
            var payload = Data([on ? 0x01 : 0x00])
            payload.append(key)
            try await sendExpectAck(cmd: DnoteProtocol.Cmd.encryptSet, payload: payload, timeout: 10)
            deviceEncryptionOn = on
        }
    }

    /// CMD 0xA3 — read current encryption state. Populates
    /// `deviceEncryptionOn` as a side effect so download paths can gate on
    /// a @Published value without re-issuing the command on every chunk.
    @discardableResult
    func getEncryptionState() async throws -> Bool {
        try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.encryptQuery)
            let frame = try await recv(expect: DnoteProtocol.Cmd.encryptQuery, timeout: 10)
            guard frame.cmd == DnoteProtocol.Cmd.encryptQuery, !frame.payload.isEmpty else {
                throw DnoteError.malformedResponse
            }
            let on = frame.payload[frame.payload.startIndex] == 0x01
            deviceEncryptionOn = on
            return on
        }
    }

    // MARK: recording / live stream

    /// Cleared on start_stream, set by the `0x55` notification path when the
    /// device proactively stops recording (physical button). `streamAudio`
    /// watches this so the stream exits promptly instead of waiting 30 s for
    /// a data-timeout.
    @Published private(set) var recordingStopped: Bool = false

    /// CMD 0x51 — start recording. Payload `0x01` enables real-time upload
    /// so the stream (CMD 0x68) starts producing OPUS frames.
    ///
    /// `lastDeviceInfo.rec` is flipped locally on success because the
    /// device's 0x54 notification only fires for physical-button starts —
    /// App-initiated starts (this method) get an ack but no 0x54, so the
    /// pill would otherwise wait for the next `getDeviceInfo` poll before
    /// reflecting the new state.
    ///
    /// The device also emits a 0x56 proactive status push around every
    /// start/stop transition; we drain it in `collectRecordingResponses`
    /// so the frame doesn't leak into the next command's recv. Same deal
    /// in `stopRecording`.
    ///
    /// `bypassPassphraseGate` is only used for the passphrase verification flow: the probe clip is recorded for verification and deleted immediately after, not a guard against “user records an undecipherable file”.
    // All three user entry points use the default value.
    func startRecording(realTime: Bool = true, bypassPassphraseGate: Bool = false) async throws {
        try await ensureBound()
        // Do not start recording until the passcode is set. The guard is placed at the command level rather than on each button: recording entry point
        // There are three entry points: home button, live page, watch App Intent; UI greying out is only a hint, bypassing one
        // will leave an irrecoverable file on this phone forever. Recordings started via hardware keys are not captured,
        // and the routing banner plus download‑failure prompt act as a fallback.
        if !bypassPassphraseGate, KeyResolver.setupIncomplete(for: self) {
            throw DnoteError.passphraseSetupIncomplete
        }
        recordingStopped = false
        try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.startRec, payload: Data([realTime ? 0x01 : 0x00]))
            _ = try await collectRecordingResponses(ackCmd: DnoteProtocol.Cmd.startRec)
        }
        if let info = lastDeviceInfo {
            lastDeviceInfo = info.setting("rec", to: 1 as AnyHashable)
        }
    }

    /// CMD 0x50 — stop recording. Returns the device's status JSON.
    ///
    /// Same deal as `startRecording`: the device's 0x55 notification only
    /// fires for physical-button stops, so App-initiated stops have to
    /// flip the local flag themselves. `recordingStopped` is set so views
    /// observing it react (auto-refresh file list, drop the red dot).
    @discardableResult
    func stopRecording() async throws -> [String: Any] {
        let result: [String: Any] = try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.stopRec)
            return try await collectRecordingResponses(ackCmd: DnoteProtocol.Cmd.stopRec)
        }
        if let info = lastDeviceInfo {
            lastDeviceInfo = info.setting("rec", to: 0 as AnyHashable)
        }
        recordingStopped = true
        return result
    }

    /// The device responds to CMD 0x50 / 0x51 with TWO frames: a proactive
    /// 0x56 status push (JSON body with `rec`, `name`, `recd`, `size`,
    /// `upload`) plus the ack for the originating command (0x50 or 0x51,
    /// 1-byte `0x01`). They can arrive in either order. If we only wait for
    /// one, the other lingers in `respQueue` and gets consumed as the
    /// response to the next unrelated command — which then fails to parse
    /// ("Cannot read data because it isn't in the correct format"). Loop
    /// until we've seen the matching ack, absorbing any 0x56 along the way
    /// (the JSON payload is returned so the caller can pick up the
    /// finalised clip name if needed).
    private func collectRecordingResponses(ackCmd: UInt8) async throws -> [String: Any] {
        var statusJSON: [String: Any] = [:]
        var sawAck = false
        let deadline = Date().addingTimeInterval(5)
        while !sawAck {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let frame = try await recv(timeout: remaining)
            switch frame.cmd {
            case DnoteProtocol.Cmd.recStatus:
                if let json = try? PacketCodec.decodeJSON(frame) {
                    statusJSON = json
                }
            case ackCmd:
                // Recorder firmware uses two successful response shapes here:
                // stop (0x50) normally returns the one-byte 0x01 ack, while
                // start (0x51) may return JSON such as {"name":"…opus"}.
                // The device treats that 0x51 JSON frame as
                // the recording-start confirmation. Do not interpret its
                // leading "{" byte as a failed ack.
                if frame.payload.first == 0x00 {
                    log.error("cmd 0x\(String(format: "%02X", ackCmd), privacy: .public) refused by device (status=0x00)")
                    throw DnoteError.ackFailed(cmd: ackCmd)
                }
                if frame.payload.first == 0x01 {
                    sawAck = true
                } else if ackCmd == DnoteProtocol.Cmd.startRec,
                          let json = try? PacketCodec.decodeJSON(frame),
                          json["name"] is String {
                    statusJSON.merge(json) { _, new in new }
                    sawAck = true
                } else if frame.payload.isEmpty {
                    log.warning("cmd 0x\(String(format: "%02X", ackCmd), privacy: .public) acked with an empty payload — treating as success")
                    sawAck = true
                } else {
                    log.error("cmd 0x\(String(format: "%02X", ackCmd), privacy: .public) returned an unrecognised response")
                    throw DnoteError.malformedResponse
                }
            default:
                log.debug("collectRecordingResponses ignoring cmd=\(String(format: "0x%02X", frame.cmd), privacy: .public)")
            }
        }
        // Falling out of the loop on the deadline used to look identical to
        // success. It isn't: nothing confirmed the device took the command.
        guard sawAck else {
            log.error("cmd 0x\(String(format: "%02X", ackCmd), privacy: .public) got no ack within 5 s")
            throw DnoteError.timeout
        }
        return statusJSON
    }

    /// CMD 0x56 — query current recording status. The JSON carries `rec`,
    /// `recd`, `name`, `size` and `upload` — the last one is whether the
    /// device is pushing OPUS frames for this recording (set by 0x51 payload
    /// 0x01 or by our 0x01 ack to the 0x54 button-start push; there is no
    /// command to turn it on for a recording already in progress).
    func getRecordingStatus() async throws -> [String: Any] {
        try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.recStatus)
            return try await recvJSON(expect: DnoteProtocol.Cmd.recStatus)
        }
    }

    /// CMD 0x68 payload `0x00` — begin the real-time OPUS stream. Drains
    /// any stale stream packets first so `streamAudio()` starts clean.
    func startStream() async throws {
        try await ensureBound()
        streamQueue.drain()
        try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.stream, payload: Data([0x00]))
        }
    }

    /// CMD 0x68 payload `0x01` — stop the stream. No response expected.
    func stopStream() async throws {
        try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.stream, payload: Data([0x01]))
        }
    }

    /// AsyncStream of raw OPUS frames. The device shapes packets as
    /// `[PID][0x68][LC][START(1)][OFFSET(4 LE)][DATA…]`. Exits on the
    /// `STOP` status nibble, on `0x55` recording-stopped, on 30 s silence,
    /// or when the caller cancels the consuming task.
    ///
    /// `firstFrameTimeout` bounds the wait for the *first* packet only. A
    /// device that never pushes (recording started by the button before the
    /// app connected, so `upload` = 0) would otherwise sit silent for the
    /// full 30 s and then look like a dropped link; it throws
    /// `DnoteError.streamNoAudio` instead so the UI can say what happened.
    ///
    /// Does NOT go through `runExclusive` — the stream keeps the channel
    /// busy for the whole recording, and other commands (like stopStream
    /// itself) need to interleave. Data arrives on `streamQueue`, which is
    /// a separate logical channel.
    func streamAudio(firstFrameTimeout: TimeInterval = 30) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var sawPacket = false
                do {
                    while true {
                        try Task.checkCancellation()
                        if recordingStopped {
                            continuation.finish()
                            return
                        }
                        let pkt: Data
                        do {
                            pkt = try await streamQueue.pop(timeout: sawPacket ? 30 : firstFrameTimeout)
                        } catch DnoteError.timeout where !sawPacket {
                            throw DnoteError.streamNoAudio
                        }
                        sawPacket = true
                        guard pkt.count >= 4, pkt[pkt.startIndex] == DnoteProtocol.pid else { continue }
                        let lc = Int(pkt[pkt.startIndex + 2])
                        let startByte = pkt[pkt.startIndex + 3]
                        let status = startByte & 0xF0
                        if status == DnoteProtocol.Stream.error {
                            throw DnoteError.deviceError("Live stream error")
                        }
                        if status == DnoteProtocol.Stream.stop {
                            continuation.finish()
                            return
                        }
                        if lc > 5 {
                            let dataStart = pkt.startIndex + 8
                            let dataEnd = pkt.startIndex + 3 + lc
                            if dataEnd > dataStart, dataEnd <= pkt.endIndex {
                                continuation.yield(Data(pkt[dataStart..<dataEnd]))
                            }
                        }
                    }
                } catch {
                    if case DnoteError.streamEnded = error {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func deleteFile(_ name: String) async throws {
        try await runExclusive {
            try await sendJSON(cmd: DnoteProtocol.Cmd.fileDelete, ["name": name])
            let frame = try await recv(expect: DnoteProtocol.Cmd.fileDelete, timeout: 10)
            guard frame.isAck else { throw DnoteError.ackFailed(cmd: DnoteProtocol.Cmd.fileDelete) }
        }
    }

    /// CMD 0x90 — walk the device's recording list. The device streams one JSON
    /// object per entry; the final entry has `end == 1, name == ""`.
    func getFileList() async throws -> [DeviceFile] {
        try await runExclusive {
            try await send(cmd: DnoteProtocol.Cmd.fileList)
            var out: [DeviceFile] = []
            while true {
                let json = try await recvJSON(expect: DnoteProtocol.Cmd.fileList, timeout: 15)
                if (json["end"] as? NSNumber)?.intValue == 1 { break }
                guard
                    let index = (json["index"] as? NSNumber)?.intValue,
                    let name  = json["name"] as? String,
                    let size  = (json["size"] as? NSNumber)?.intValue
                else {
                    // Unsolicited status push (e.g. 0x56 rec-status right after
                    // connect) landed in respQueue before the file-list reply.
                    // Skip it — the 15 s timeout is the safety net.
                    log.warning("getFileList: skipping unexpected packet keys=\(json.keys.sorted(), privacy: .public)")
                    continue
                }
                out.append(DeviceFile(index: index, name: name, size: size))
            }
            return out
        }
    }

    /// CMD 0x70 — download a recording file over BLE.
    ///
    /// Transfer protocol: device streams chunks shaped
    /// `[PID][0x70][LC][START(1)][OFFSET(4 BE)][DATA…]`. The upper nibble of
    /// `START` is the transfer status (start/in-progress/eof/err/cancel/404).
    /// `progress` is called on the main actor with (bytesSoFar, totalBytes)
    /// after each chunk; `total` is zero if the caller didn't pass
    /// `expectedSize`.
    func downloadFile(
        _ name: String,
        expectedSize: Int = 0,
        progress: ((_ received: Int, _ total: Int) -> Void)? = nil
    ) async throws -> Data {
        try await runExclusive {
            do {
                return try await doDownload(name, expectedSize: expectedSize, progress: progress)
            } catch is CancellationError {
                // Cancelling only the iOS task leaves the *device* streaming the
                // whole file. The residual 0x70 stream then collides with the
                // next command — e.g. getFileList after a cancelled transfer +
                // Wi-Fi detour fails (vv5p52u). Actively tell the device to stop
                // (0x70 cmd=0, mirroring the recorder app's requestFileData
                // stop), then drain to the terminal status so the channel is
                // clean. Run it in a detached task so the parent's cancellation
                // can't skip the stop write; we still hold the command lock, so
                // nothing else interleaves.
                await Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await self.sendJSON(
                        cmd: DnoteProtocol.Cmd.xfer,
                        ["cmd": 0, "name": name, "offset": 0]
                    )
                    await self.drainXferUntilTerminal()
                    self.pendingXferDrain = false
                }.value
                throw CancellationError()
            }
        }
    }

    private func doDownload(
        _ name: String,
        expectedSize: Int,
        progress: ((_ received: Int, _ total: Int) -> Void)?
    ) async throws -> Data {
        log.info("download start name=\(name, privacy: .public) expectedSize=\(expectedSize, privacy: .public)")
        let t0 = Date()
        if pendingXferDrain {
            pendingXferDrain = false
            await drainXferUntilTerminal()
        }
        xferQueue.drain()
        try await sendJSON(
            cmd: DnoteProtocol.Cmd.xfer,
            ["cmd": 1, "name": name, "offset": 0]
        )

        var buf = Data()
        var lastLoggedPct = -1
        while true {
            try Task.checkCancellation()
            let pkt = try await xferQueue.pop(timeout: 30)
            guard pkt.count >= 4, pkt[pkt.startIndex] == DnoteProtocol.pid else {
                throw DnoteError.malformedResponse
            }
            let lc = Int(pkt[pkt.startIndex + 2])
            let startByte = pkt[pkt.startIndex + 3]
            let status = startByte & 0xF0

            switch status {
            case DnoteProtocol.Xfer.notFound:
                log.error("download NOT_FOUND name=\(name, privacy: .public)")
                throw DnoteError.fileNotFound(name)
            case DnoteProtocol.Xfer.error:
                log.error("download ERROR name=\(name, privacy: .public)")
                throw DnoteError.deviceError("Transfer error: \(name)")
            case DnoteProtocol.Xfer.cancel:
                log.warning("download CANCEL name=\(name, privacy: .public)")
                throw DnoteError.transferCancelled
            default:
                break
            }

            if lc > 5 {
                let dataStart = pkt.startIndex + 8
                let dataEnd = pkt.startIndex + 3 + lc
                if dataEnd > dataStart, dataEnd <= pkt.endIndex {
                    // OFFSET(4 LE) sits between START and the payload. It was
                    // parsed past until now, so a repeated or skipped chunk
                    // produced a silently corrupt file that still counted as a
                    // successful download (and the caller then deleted the
                    // device's original).
                    let o0 = UInt32(pkt[pkt.startIndex + 4]) << 24
                    let o1 = UInt32(pkt[pkt.startIndex + 5]) << 16
                    let o2 = UInt32(pkt[pkt.startIndex + 6]) << 8
                    let o3 = UInt32(pkt[pkt.startIndex + 7])
                    let chunkOffset = Int(o0 | o1 | o2 | o3)
                    if chunkOffset != buf.count {
                        log.error("download \(name, privacy: .public): offset gap local=\(buf.count, privacy: .public) device=\(chunkOffset, privacy: .public)")
                        throw DnoteError.transferIncomplete("\(name): the device skipped to offset \(chunkOffset) while \(buf.count) bytes had arrived.")
                    }
                    buf.append(pkt[dataStart..<dataEnd])
                    progress?(buf.count, expectedSize)
                    if expectedSize > 0 {
                        let pct = min(100, buf.count * 100 / expectedSize)
                        if pct / 10 != lastLoggedPct / 10 {
                            log.info("download \(name, privacy: .public) \(pct, privacy: .public)% (\(buf.count, privacy: .public)/\(expectedSize, privacy: .public))")
                            lastLoggedPct = pct
                        }
                    }
                }
            }

            if status == DnoteProtocol.Xfer.eof { break }
        }
        // EOF alone never meant "the whole file arrived" — a link drop that
        // still produced an EOF-flagged packet, or a device-side truncation,
        // returned a short buffer that callers treated as a finished
        // download. Compare against the size the file list declared.
        if expectedSize > 0 && buf.count != expectedSize {
            log.error("download \(name, privacy: .public): truncated got=\(buf.count, privacy: .public) expected=\(expectedSize, privacy: .public)")
            throw DnoteError.transferIncomplete("\(name): got \(buf.count) bytes but the device listed \(expectedSize). Nothing was deleted from the device.")
        }
        let elapsed = Date().timeIntervalSince(t0)
        let kbps = elapsed > 0 ? Double(buf.count) / 1024.0 / elapsed : 0
        log.info("download done name=\(name, privacy: .public) bytes=\(buf.count, privacy: .public) elapsed=\(String(format: "%.1f", elapsed), privacy: .public)s rate=\(String(format: "%.1f", kbps), privacy: .public) KB/s")
        return buf
    }

    /// After a cancelled download the device keeps streaming until it hits
    /// EOF on its side. Read packets until we see a terminal status (EOF /
    /// ERROR / CANCEL / NOT_FOUND) or until 5 s pass without a packet, then
    /// flush whatever remains so the next cmd_start goes to a clean queue.
    private func drainXferUntilTerminal() async {
        log.info("xfer: draining stale packets after cancel")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            guard let pkt = try? await xferQueue.pop(timeout: 1) else { break }
            guard pkt.count >= 4 else { continue }
            let status = pkt[pkt.startIndex + 3] & 0xF0
            if status == DnoteProtocol.Xfer.eof
                || status == DnoteProtocol.Xfer.error
                || status == DnoteProtocol.Xfer.cancel
                || status == DnoteProtocol.Xfer.notFound {
                log.info("xfer: drain saw terminal status 0x\(String(status, radix: 16), privacy: .public)")
                break
            }
        }
        xferQueue.drain()
    }

    // MARK: notification routing

    /// Mirrors `_ack_rec_stopped` — when the device proactively reports the
    /// physical stop button was hit (cmd 0x55), echo the ack so it stops
    /// re-broadcasting.
    private func ackRecStopped() {
        guard let rx = rxChar else { return }
        log.info("0x55 recording-stopped received, acking")
        let pkt = Data([DnoteProtocol.pid, DnoteProtocol.Cmd.recStopped, 0x01, 0x01])
        peripheral.writeValue(pkt, for: rx, type: .withResponse)
        recordingStopped = true
        streamQueue.failAll(with: DnoteError.streamEnded)
        // Reflect the physical-button stop in `lastDeviceInfo` right away
        // so the connection-pill dot drops immediately. Otherwise the pill
        // stays "recording" for up to one poll interval until the next
        // `getDeviceInfo` overwrites the stale `rec=1` flag.
        if let info = lastDeviceInfo {
            lastDeviceInfo = info.setting("rec", to: 0 as AnyHashable)
        }
    }

    /// 0x54 is the device's proactive "recording started" notification —
    /// fires every time the physical record button kicks a new clip. The
    /// payload is `{"name": "...opus"}`. No firmware doc for the ack, so we
    /// mirror 0x55 (1-byte 0x01 success); devices that don't expect an ack
    /// just ignore the reply. Without this handler the notification drops
    /// into `respQueue` as a stale response and the recording state only
    /// catches up at the next `getDeviceInfo` poll.
    private func handleRecStarted(_ frame: Data) {
        guard let rx = rxChar else { return }
        let ack = Data([DnoteProtocol.pid, DnoteProtocol.Cmd.recStarted, 0x01, 0x01])
        peripheral.writeValue(ack, for: rx, type: .withResponse)

        var updated = lastDeviceInfo ?? DeviceInfo(raw: [:])
        updated = updated.setting("rec", to: 1 as AnyHashable)
        // Carry the filename if the payload included one so anything
        // keyed on the current clip (e.g. future live-state UI) can pick
        // it up without another round-trip.
        if frame.count > 3 {
            let payload = frame.subdata(in: (frame.startIndex + 3)..<frame.endIndex)
            if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let name = obj["name"] as? String {
                updated = updated.setting("name", to: name as AnyHashable)
                log.info("0x54 recording-started name=\(name, privacy: .public)")
            } else {
                log.info("0x54 recording-started (unparseable payload)")
            }
        } else {
            log.info("0x54 recording-started (no payload)")
        }
        lastDeviceInfo = updated
        recordingStopped = false
    }

    private func dispatchNotification(_ data: Data) {
        guard data.count >= 3, data[data.startIndex] == DnoteProtocol.pid else {
            log.warning("dispatch: bad frame len=\(data.count, privacy: .public)")
            return
        }
        let cmd = data[data.startIndex + 1]
        let len = data[data.startIndex + 2]
        switch cmd {
        case DnoteProtocol.Cmd.xfer:
            xferQueue.push(data)
        case DnoteProtocol.Cmd.stream:
            streamQueue.push(data)
        case DnoteProtocol.Cmd.recStarted:
            handleRecStarted(data)
        case DnoteProtocol.Cmd.recStopped:
            ackRecStopped()
        default:
            log.debug("notify → respQueue cmd=\(String(format: "0x%02X", cmd), privacy: .public) len=\(len, privacy: .public)")
            respQueue.push(data)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DnoteClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log.info("didDiscoverServices err=\(String(describing: error), privacy: .public) count=\(peripheral.services?.count ?? 0, privacy: .public)")
        Task { @MainActor in
            if let error = error {
                self.failHandshake(error)
                return
            }
            guard let svc = peripheral.services?.first(where: { $0.uuid == DnoteProtocol.serviceUUID }) else {
                log.error("D·NOTE service not found, services=\(String(describing: peripheral.services), privacy: .public)")
                self.failHandshake(DnoteError.deviceError("D·NOTE service not found on peripheral"))
                return
            }
            log.info("discovering characteristics…")
            peripheral.discoverCharacteristics(
                [DnoteProtocol.rxCharUUID, DnoteProtocol.txCharUUID],
                for: svc
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        log.info("didDiscoverCharacteristics err=\(String(describing: error), privacy: .public) count=\(service.characteristics?.count ?? 0, privacy: .public)")
        Task { @MainActor in
            if let error = error {
                self.failHandshake(error)
                return
            }
            for ch in service.characteristics ?? [] {
                if ch.uuid == DnoteProtocol.rxCharUUID { self.rxChar = ch }
                if ch.uuid == DnoteProtocol.txCharUUID { self.txChar = ch }
            }
            guard let tx = self.txChar, self.rxChar != nil else {
                log.error("RX/TX missing — rx=\(self.rxChar != nil, privacy: .public) tx=\(self.txChar != nil, privacy: .public)")
                self.failHandshake(DnoteError.deviceError("RX/TX characteristics missing"))
                return
            }
            log.info("enabling notify on TX…")
            peripheral.setNotifyValue(true, for: tx)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        log.info("didUpdateNotificationState \(characteristic.uuid, privacy: .public) notifying=\(characteristic.isNotifying, privacy: .public) err=\(String(describing: error), privacy: .public)")
        Task { @MainActor in
            if let error = error {
                self.failHandshake(error)
                return
            }
            if characteristic.uuid == DnoteProtocol.txCharUUID, characteristic.isNotifying {
                self.completeHandshakeContinuation()
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        Task { @MainActor in self.dispatchNotification(data) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            log.warning("Write failed on \(characteristic.uuid, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func failHandshake(_ error: Error) {
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: error)
        }
    }

    private func completeHandshakeContinuation() {
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume()
        }
    }
}
