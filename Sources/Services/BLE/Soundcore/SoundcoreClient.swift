import CoreBluetooth
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ble.soundcore")

/// soundcore Work / D3200（飞书录音豆）BLE client — sibling of `DnoteClient`.
///
/// Faithful Swift port of the verified Kotlin `SoundcoreBleClient.kt`:
///
///  - Notify stream (00008888) runs through a stateful `SoundcoreFrameParser`
///    — GATT may split or coalesce frames arbitrarily.
///  - Requests go to 00007777, preferring write-without-response (upstream
///    picks it whenever the characteristic allows).
///  - Command responses are matched by (cmdType, cmdId) — the device pushes
///    unsolicited battery/charging/record-status packets between replies.
///  - Transport packets (0x1A/0x1B family) are routed to either the file-pull
///    channel or the realtime path, never both (see `dispatchTransport`).
///    ⚠️ Command replies of the 0x1A/0x1B family (0x0E list, 0x10 delete,
///    0x0F, 0x02, 0x05) must go to the **response** queue, NOT a transport
///    queue nobody consumes (real-device lesson 2026-10-27 on Android).
///
/// 红线（用户决策 2026-10-27）：本客户端**不会发送** bind/unbind/resetDevice ——
/// 这些命令会改变设备持久状态、影响原厂飞书 App。与录音豆的共存模式是
/// "并行抢连接"，不注册写入绑定关系。
@MainActor
final class SoundcoreClient: NSObject, ObservableObject {
    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?

    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private let parser = SoundcoreFrameParser()
    private let respQueue = NotifyQueue()
    private let transportQueue = NotifyQueue()

    private var handshakeContinuation: CheckedContinuation<Void, Error>?

    /// ECDH/AES crypto session — established by `handshake()` right after connect.
    let crypto = SoundcoreDeviceCrypto()

    @Published private(set) var negotiatedMTU: Int = 0
    @Published private(set) var lastDeviceInfo: SoundcoreDeviceInfo?
    @Published private(set) var disconnectError: Error?

    // Device-pushed state (0x01/0x03 battery, 0x01/0x04 charging, 0x18/0x82 record).
    @Published private(set) var pushedRecording: Bool?
    @Published private(set) var pushedBatteryPercent: Int?
    @Published private(set) var pushedCharging: Bool?

    /// Device pushes a new recording's file id while recording (0x1A/0x06).
    private(set) var lastNewFileId: UInt32?

    // Request/response serialization — same shape as `DnoteClient.runExclusive`:
    // the device speaks one command at a time, and NotifyQueue supports only
    // one waiter per channel.
    private var cmdBusy = false
    private var cmdWaiters: [CheckedContinuation<Void, Never>] = []

    init(peripheral: CBPeripheral, central: CBCentralManager) {
        self.peripheral = peripheral
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    var displayName: String { peripheral.name ?? "soundcore Work" }

    var isConnected: Bool { peripheral.state == .connected && writeChar != nil && notifyChar != nil }

    // MARK: connection / handshake

    /// Called by `BluetoothCoordinator` once `centralManager(_:didConnect:)`
    /// fires. Discovers service + characteristics, enables notifications on
    /// 00008888, captures the negotiated write chunk size.
    /// iOS negotiates MTU automatically — there is no requestMtu.
    func completeHandshake() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.handshakeContinuation = cont
            peripheral.discoverServices([SoundcoreUuids.d3200Service])
        }
        negotiatedMTU = peripheral.maximumWriteValueLength(for: .withoutResponse)
        log.info("Handshake complete; chunk=\(self.negotiatedMTU, privacy: .public)")
    }

    /// ECDH P-256 key exchange after GATT connect. Sends the app public key
    /// (0x2E/0x01), waits for the device reply carrying its 65-B public key
    /// (payload 0…65) + shared secret (payload 65…97), then derives the
    /// sessionKey. **Required before any file pull.**
    func handshake() async -> Bool {
        do {
            let pub = crypto.ensureKeyPair()
            let reply = try await sendExpect(
                type: SoundcoreRxCmd.encryptType,
                id: SoundcoreRxCmd.encryptHandshakeId
            ) {
                SoundcoreCommands.notifyEncryptPublicKey(pub)
            }
            guard reply.payload.count >= 97 else {
                log.warning("Encrypt handshake reply too short: \(reply.payload.count)B")
                return false
            }
            let devicePub = reply.payload.subdata(in: (reply.payload.startIndex)..<(reply.payload.startIndex + 65))
            let deviceShared = reply.payload.subdata(in: (reply.payload.startIndex + 65)..<(reply.payload.startIndex + 97))
            let ok = crypto.completeHandshake(devicePublicKey: devicePub, deviceSharedKey: deviceShared)
            log.info("Encrypt handshake \(ok ? "ok" : "FAILED (shared mismatch)", privacy: .public)")
            return ok
        } catch {
            log.warning("Encrypt handshake failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func handleDisconnect(error: Error?) {
        writeChar = nil
        notifyChar = nil
        disconnectError = error
        parser.reset()
        respQueue.failAll(with: SoundcoreError.notConnected)
        transportQueue.failAll(with: SoundcoreError.notConnected)
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: error ?? SoundcoreError.notConnected)
        }
    }

    func close() {
        if let central {
            central.cancelPeripheralConnection(peripheral)
        }
        handleDisconnect(error: nil)
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
    }

    private func releaseCmdLock() {
        if cmdWaiters.isEmpty {
            cmdBusy = false
        } else {
            let next = cmdWaiters.removeFirst()
            next.resume()
        }
    }

    private func runExclusive<T>(_ op: () async throws -> T) async throws -> T {
        await acquireCmdLock()
        defer { releaseCmdLock() }
        return try await op()
    }

    // MARK: low-level send / recv

    /// Split frames larger than the negotiated write chunk across multiple
    /// writes (the Kotlin client splits by MTU the same way; iOS has no
    /// requestMtu — the stack negotiates ATT MTU by itself).
    private func writeFrame(_ frame: Data) throws {
        guard let ch = writeChar else {
            log.warning("writeFrame but not connected")
            throw SoundcoreError.notConnected
        }
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        let preferNoResponse = ch.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = preferNoResponse ? .withoutResponse : .withResponse
        if frame.count <= chunkSize {
            peripheral.writeValue(frame, for: ch, type: type)
        } else {
            var offset = frame.startIndex
            while offset < frame.endIndex {
                let end = frame.index(offset, offsetBy: chunkSize, limitedBy: frame.endIndex) ?? frame.endIndex
                peripheral.writeValue(frame.subdata(in: offset..<end), for: ch, type: type)
                offset = end
            }
        }
    }

    /// Send a command and wait for the matching (type, id) reply, discarding
    /// unsolicited pushes in between (battery, record status, …).
    private func sendExpect(
        type: UInt8,
        id: UInt8,
        timeout: TimeInterval = 8,
        frame: () -> Data
    ) async throws -> SoundcorePacket {
        respQueue.drain()
        try writeFrame(frame())
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw SoundcoreError.device(String(format: "Timeout waiting for 0x%02X/0x%02X", type, id))
            }
            let data: Data
            do {
                data = try await respQueue.pop(timeout: remaining)
            } catch {
                throw SoundcoreError.device(String(format: "Timeout waiting for 0x%02X/0x%02X", type, id))
            }
            let pkt = SoundcorePacket.from(bytes: data)
            if pkt.cmdType == type && pkt.cmdId == id { return pkt }
            log.debug("Discarding unsolicited push 0x\(String(format: "%02X", pkt.cmdType), privacy: .public)/0x\(String(format: "%02X", pkt.cmdId), privacy: .public) while waiting for 0x\(String(format: "%02X", type), privacy: .public)/0x\(String(format: "%02X", id), privacy: .public)")
        }
    }

    private func cmdRetry<T>(retries: Int = 3, delayMs: Int = 1_000, op: () async throws -> T) async throws -> T {
        var last: Error?
        for attempt in 1...retries {
            do {
                return try await op()
            } catch {
                last = error
                log.warning("Command failed (attempt \(attempt, privacy: .public)/\(retries, privacy: .public)): \(String(describing: error), privacy: .public)")
            }
            if attempt < retries {
                respQueue.drain()
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
        }
        throw last ?? SoundcoreError.device("Command retry failed after \(retries) attempts")
    }

    // MARK: high-level commands

    /// 0x01/0x01 — full device info (battery buckets, storage, fw, SN, box…).
    @discardableResult
    func getDeviceInfo() async throws -> SoundcoreDeviceInfo {
        try await runExclusive {
            try await cmdRetry {
                let pkt = try await sendExpect(
                    type: SoundcoreRxCmd.deviceInfoType,
                    id: SoundcoreRxCmd.deviceInfoId
                ) {
                    SoundcoreCommands.getDeviceInfo()
                }
                let info = SoundcoreDeviceInfo.parsePacket(pkt.raw)
                self.lastDeviceInfo = info
                return info
            }
        }
    }

    /// 0x01/0xA6 — UTC unix seconds + timezone offset hours.
    func syncTime(to date: Date = Date()) async throws {
        try await runExclusive {
            try await cmdRetry {
                let tzHours = TimeZone.current.secondsFromGMT(for: date) / 3600
                _ = try await sendExpect(
                    type: SoundcoreRxCmd.deviceInfoType,
                    id: SoundcoreRxCmd.syncTimeId
                ) {
                    SoundcoreCommands.syncTime(unixSeconds: UInt32(date.timeIntervalSince1970), timezoneHours: tzHours)
                }
            }
        }
    }

    /// 0x18/0x82 payload 01 — start recording.
    func startRecording() async throws {
        try await runExclusive {
            try await cmdRetry {
                _ = try await sendExpect(
                    type: SoundcoreRxCmd.audioType,
                    id: SoundcoreRxCmd.audioControlId
                ) { SoundcoreCommands.startRecord() }
            }
        }
    }

    /// 0x18/0x82 payload 02 — pause recording (finalizes the take into a file).
    func pauseRecording() async throws {
        try await runExclusive {
            try await cmdRetry {
                _ = try await sendExpect(
                    type: SoundcoreRxCmd.audioType,
                    id: SoundcoreRxCmd.audioControlId
                ) { SoundcoreCommands.pauseRecord() }
            }
        }
    }

    /// File list with fallback: newer firmware answers 0x1B/0x0E, older ones
    /// (and — observed on real hardware — the recording state in general)
    /// only answer the legacy 0x1A/0x0E, if at all. Try 0x1B once, then 0x1A.
    func listFilesCompat(page: Int = 0) async throws -> SoundcoreFileList {
        try await runExclusive {
            do {
                let pkt = try await sendExpect(
                    type: SoundcoreRxCmd.transportTypeAlt,
                    id: SoundcoreRxCmd.fileListId,
                    timeout: 6
                ) { SoundcoreCommands.listFilesWithEndTime(page: page) }
                return SoundcoreFileList.parse(pkt.payload, withEndTime: true)
            } catch {
                log.warning("0x1B list timeout, falling back to 0x1A: \(String(describing: error), privacy: .public)")
            }
            let pkt = try await sendExpect(
                type: SoundcoreRxCmd.transportType,
                id: SoundcoreRxCmd.fileListId,
                timeout: 8
            ) { SoundcoreCommands.listFiles(page: page) }
            return SoundcoreFileList.parse(pkt.payload, withEndTime: false)
        }
    }

    /// 0x1A/0x10 — delete one recording **on the card**.
    ///
    /// ⚠️ 应答只代表「命令被收到」：豆在录音/传输占用时不真的删（真机 2026-10-27）。
    /// 真正的成功判定在 `SoundcoreLink.deleteRecording` 里靠回读文件列表仲裁，
    /// 这里把应答原样记下来（status flag 用来排查"设备拒绝"）。
    func deleteFile(_ fileId: UInt32) async throws {
        try await runExclusive {
            try await cmdRetry {
                let pkt = try await sendExpect(
                    type: SoundcoreRxCmd.transportType,
                    id: SoundcoreRxCmd.deleteId
                ) { SoundcoreCommands.deleteFile(fileId: fileId) }
                log.info(
                    "delete \(fileId, privacy: .public) reply flag=\(pkt.successFlag, privacy: .public) \(pkt.raw.soundcoreHex, privacy: .public)"
                )
            }
        }
    }

    // MARK: Wi‑Fi 快传 (0x1A/0x05 / 0x1A/0x02，PROTOCOL.md §6.4–6.5)

    /// Device 1A05 reply endpoint: AP gateway IP (reversed octets @9..12 of the
    /// **full** frame) + WebSocket port (u16le @13..14). Port of Kotlin
    /// `SoundcoreBleClient.WifiEndpoint` parsing.
    struct WifiEndpoint: Equatable {
        let ip: String
        let port: Int
    }

    /// Step 1–2 of Wi‑Fi fast transfer: BLE `1A05` with the phone-chosen
    /// credentials; the device starts its transfer server and replies with
    /// `ip:port` (typically 192.168.43.1:443).
    func startWifiExport(ssid: String, psk: String) async throws -> WifiEndpoint {
        try await runExclusive {
            let pkt = try await sendExpect(
                type: SoundcoreRxCmd.transportType,
                id: SoundcoreRxCmd.wifiConfigId,
                timeout: 45
            ) { SoundcoreCommands.sendWifiConfig(ssid: ssid, password: psk) }
            guard pkt.isSuccess else {
                throw SoundcoreError.device("设备拒绝 Wi‑Fi 配置（flag=\(pkt.successFlag)）")
            }
            let raw = [UInt8](pkt.raw)
            guard raw.count >= 15 else {
                throw SoundcoreError.malformed("1A05 reply too short: \(raw.count)B")
            }
            let ip = "\(raw[12]).\(raw[11]).\(raw[10]).\(raw[9])"
            let port = Int(raw[13]) | (Int(raw[14]) << 8)
            guard (1...65535).contains(port) else {
                throw SoundcoreError.malformed("bad port \(port)")
            }
            log.info("device SoftAP endpoint: \(ip, privacy: .public):\(port, privacy: .public) (ssid=\(ssid, privacy: .public))")
            return WifiEndpoint(ip: ip, port: port)
        }
    }

    /// 0x1A/0x02 — close the device's Wi‑Fi transfer mode (also sent after
    /// export). Best-effort: a failure here does not affect the result.
    func closeWifiMode() async {
        do {
            try await runExclusive {
                _ = try await sendExpect(
                    type: SoundcoreRxCmd.transportType,
                    id: SoundcoreRxCmd.wifiCloseId,
                    timeout: 5
                ) { SoundcoreCommands.closeWifiMode() }
            }
        } catch {
            log.warning("closeWifiMode (ignored): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: offline file pull (0x1A/0x07 head → 0x08 slices → 0x0A done)

    // One on-wire slice record: seq(4) + flags(1) + data(160) [+ pad(1)].
    private static let sliceRecord = 165
    private static let sliceData = 160
    private static let headTimeout: TimeInterval = 15
    /// Realtime/file pull silent timeout — upstream uses 90 s inactivity, not a total cap.
    private static let pullIdleTimeout: TimeInterval = 90

    /// Pull one offline recording over BLE, decrypting via the session key.
    ///
    /// Mirrors upstream `BleFilePull`: head may be missing (firmware that
    /// skips it) — decryption stays off then and the raw payload is returned.
    /// The idle timeout is **inactivity**-based, not a total cap.
    func pullFile(
        fileId: UInt32,
        expectedSize: UInt32 = 0,
        progress: ((_ received: Int, _ expected: Int) -> Void)? = nil
    ) async throws -> Data {
        try await runExclusive {
            // ★ 2026-10-28（用户："传输的录音有一段直接卡住"）：实时会话异常收尾时
            // realtimeFileId 可能残留（linkLost 分支、liveStop 被 10s 兜底取消）——
            // dispatchTransport 会把之后所有切片路由进没人消费的实时桥，pullFile
            // 就永远收不到数据，90 秒后报"传输不完整"。拉取前强制解除实时绑定。
            if let stale = realtimeFileId {
                log.info("pullFile: clearing stale realtime binding file=\(stale, privacy: .public)")
                crypto.clearFile(stale)
                realtimeFileId = nil
            }
            transportQueue.drain()
            var buf = Data()
            var expected = Int(expectedSize)
            var decryptOn = false
            var received = 0
            var sawDone = false
            var sawAnyPacket = false

            try writeFrame(SoundcoreCommands.startTransportAudioFile(fileId: fileId, alreadyTransferred: 0, realtimeFlag: 0))

            let inactivityDeadline = Date().addingTimeInterval(Self.pullIdleTimeout)
            while true {
                if received >= expected && expected > 0 { break }
                let now = Date()
                // 头包窗口：第一条传输包之前最多等 HEAD_TIMEOUT；有包之后只看闲置超时。
                let waitEnd = sawAnyPacket ? inactivityDeadline : min(now.addingTimeInterval(Self.headTimeout), inactivityDeadline)
                let remaining = waitEnd.timeIntervalSinceNow
                if remaining <= 0 {
                    if received > 0 { break }
                    throw SoundcoreError.device(
                        sawAnyPacket
                            ? "File pull stalled: \(received)/\(expected) bytes"
                            : "No data from device for file \(fileId)"
                    )
                }
                let data: Data
                do {
                    data = try await transportQueue.pop(timeout: remaining)
                } catch {
                    if received > 0 || sawAnyPacket { break }
                    throw SoundcoreError.device("No data from device for file \(fileId)")
                }
                sawAnyPacket = true
                let pkt = SoundcorePacket.from(bytes: data)
                switch pkt.cmdId {
                case SoundcoreRxCmd.fileHeadId:
                    if let secret = SoundcoreFileSecretKey.parseFrame(pkt.raw) {
                        if secret.fileId != fileId {
                            // 设备把传输通道给了另一条录音（典型：豆子还在录音，
                            // 推送当前录音的头）。历史文件此时拉不动，直接中止并解释。
                            crypto.clearFile(fileId)
                            throw SoundcoreError.device(
                                "设备正在回传另一条录音（file \(secret.fileId)）——录音豆还在录音，" +
                                    "先按一下暂停结束当前录音再下载历史录音"
                            )
                        }
                        if secret.fileSize > 0 && secret.fileSize != 0xFFFFFFFF {
                            expected = Int(secret.fileSize)
                        }
                        decryptOn = crypto.initFileDecrypt(
                            fileId: fileId,
                            encryptedFileKey: secret.encryptedFileKey,
                            sessionNonce: secret.sessionNonce,
                            nonce: secret.nonce
                        )
                        log.info("head id=\(secret.fileId, privacy: .public) size=\(expected, privacy: .public) decrypt=\(decryptOn, privacy: .public)")
                    }
                case SoundcoreRxCmd.fileSliceId, SoundcoreRxCmd.fileSliceMarkId:
                    received += writeSlices(pkt.raw, fileId: fileId, decrypt: decryptOn) { _, _, chunk in
                        buf.append(chunk)
                    }
                    progress?(received, expected)
                case SoundcoreRxCmd.fileDoneId:
                    sawDone = true
                default:
                    break
                }
                if sawDone { break }
            }
            crypto.clearFile(fileId)
            if expected > 0 && expected != 0xFFFFFFFF && Double(received) < Double(expected) * 0.95 {
                throw SoundcoreError.device(
                    "Incomplete file pull: \(received)/\(expected) bytes — nothing deleted from the card"
                )
            }
            if received == 0 {
                throw SoundcoreError.device("No audio data received for file \(fileId)")
            }
            return buf
        }
    }

    // MARK: realtime stream (0x1A/0x07 realtimeFlag=1 → live slices)

    private var realtimeFileId: UInt32?

    /// Decrypted realtime Opus slices (160 B each, in order). Emitted only
    /// while `startRealtime` is active. Unused by the v1 UI but the dispatch
    /// routing must stay aware of realtime mode (inline decrypt), matching the
    /// verified Kotlin client.
    var onRealtimeFrame: ((_ fileId: UInt32, _ sequence: Int, _ data: Data) -> Void)?

    /// ★ 8.3.6 复核：realtime 切片的 flags bit0 = **打标**（豆身上的按键）。该标记
    /// 只在实时流里出现，离线文件不带。`sequence` 是切片序号——offset = seq × 20 ms。
    var onRealtimeMark: ((_ fileId: UInt32, _ sequence: Int) -> Void)?

    /// Realtime 传输收到 0x1A/0x0A done——设备自己结束了这一段录音。
    /// 订阅方（`SoundcoreLink` 的 live 桥）用它把音频流正常收尾。
    var onRealtimeEnd: ((_ fileId: UInt32?) -> Void)?

    /// The file id the realtime transport is currently bound to (`nil` = idle).
    /// Exposed for `SoundcoreLink.addMarkNow` — the in-app mark needs the same
    /// key the device-side marks are filed under.
    var activeRealtimeFileId: UInt32? { realtimeFileId }

    /// Start (or switch to) live BLE audio for `fileId` — upstream
    /// `RealtimeBleStream.startForFile`. `alreadyTransferred` supports resume.
    func startRealtime(fileId: UInt32, alreadyTransferred: Int = 0) async throws {
        realtimeFileId = fileId
        transportQueue.drain()
        try writeFrame(
            SoundcoreCommands.startTransportAudioFile(
                fileId: fileId,
                alreadyTransferred: UInt32(max(0, alreadyTransferred)),
                realtimeFlag: 1
            )
        )
        log.info("realtime requested file=\(fileId, privacy: .public) offset=\(alreadyTransferred, privacy: .public)")
    }

    /// Stop live streaming and release the file decryptor.
    func stopRealtime() async {
        guard let id = realtimeFileId else { return }
        realtimeFileId = nil
        crypto.clearFile(id)
        log.info("realtime stopped file=\(id, privacy: .public)")
    }

    // MARK: dispatch (mirrors Kotlin `dispatchNotification`)

    private func dispatch(_ data: Data) {
        let packets = parser.feed(data)
        for pkt in packets {
            if pkt.cmdType == SoundcoreRxCmd.transportType || pkt.cmdType == SoundcoreRxCmd.transportTypeAlt {
                dispatchTransport(pkt)
            } else if pkt.cmdType == SoundcoreRxCmd.deviceInfoType {
                dispatchDeviceInfo(pkt)
            } else if pkt.cmdType == SoundcoreRxCmd.audioType,
                      pkt.cmdId == SoundcoreRxCmd.audioControlId,
                      !pkt.payload.isEmpty {
                let state = Int(pkt.payload[pkt.payload.startIndex])
                pushedRecording = (state == 0x01)
                respQueue.push(data)
            } else {
                log.info("pkt type=0x\(String(format: "%02X", pkt.cmdType), privacy: .public) id=0x\(String(format: "%02X", pkt.cmdId), privacy: .public) len=\(pkt.payload.count, privacy: .public)")
                respQueue.push(data)
            }
        }
    }

    private func dispatchDeviceInfo(_ pkt: SoundcorePacket) {
        switch pkt.cmdId {
        case SoundcoreRxCmd.deviceInfoId:
            let info = SoundcoreDeviceInfo.parsePacket(pkt.raw)
            lastDeviceInfo = info
            pushedRecording = info.recording
            if info.battery != nil { pushedBatteryPercent = info.battery }
            pushedCharging = info.charging
            respQueue.push(pkt.raw)
        case SoundcoreRxCmd.batteryId:
            // Live battery push: payload = micBattery, caseBattery (§6.1).
            if pkt.payload.count >= 1 {
                let mic = SoundcoreDeviceInfo.batteryRemaining(Int(pkt.payload[pkt.payload.startIndex]))
                if let mic { pushedBatteryPercent = mic }
            }
            respQueue.push(pkt.raw)
        case SoundcoreRxCmd.chargingId:
            // Live charging push: payload = micCharging, caseCharging (§6.1).
            if pkt.payload.count >= 1 {
                pushedCharging = Int(pkt.payload[pkt.payload.startIndex]) == 1
            }
            respQueue.push(pkt.raw)
        default:
            respQueue.push(pkt.raw)
        }
    }

    /// Transport routing: while realtime is active, slices decrypt inline and
    /// emit to `onRealtimeFrame`; otherwise everything lands on
    /// `transportQueue` for `pullFile`. Head/done always go through
    /// `transportQueue` too so a concurrent pull sees them — pull drains the
    /// queue first.
    private func dispatchTransport(_ pkt: SoundcorePacket) {
        let activeFileId = realtimeFileId
        switch pkt.cmdId {
        // 命令回复型：文件列表(0x0E)、删除(0x10)、BT 传输状态(0x0F)、Wi‑Fi(0x02/0x05)
        // 必须回 respQueue 给 sendExpect 匹配——早期 Android 实现把整个
        // 0x1A/0x1B 家族都塞进 transportQueue，列表回复到了却没人消费，
        // 命令层假超时（真机 2026-10-27 教训）。
        case SoundcoreRxCmd.fileListId,
             SoundcoreRxCmd.deleteId,
             SoundcoreRxCmd.btStatusId,
             SoundcoreRxCmd.wifiCloseId,
             SoundcoreRxCmd.wifiConfigId:
            respQueue.push(pkt.raw)

        case SoundcoreRxCmd.recordStatusId:
            if pkt.payload.count >= 4 {
                let b = [UInt8](pkt.payload)
                let newId = soundcoreReadU32Le(b, 0)
                if newId > 0 {
                    lastNewFileId = newId
                    pushedRecording = true
                }
            }

        case SoundcoreRxCmd.fileHeadId:
            // Realtime 模式下 head 必须就地解密初始化（upstream `_onPacket`）：
            // transportQueue 在实时期间没人消费，留给它会导致切片永远是密文。
            if let activeFileId {
                if let secret = SoundcoreFileSecretKey.parseFrame(pkt.raw) {
                    let ok = crypto.initFileDecrypt(
                        fileId: secret.fileId,
                        encryptedFileKey: secret.encryptedFileKey,
                        sessionNonce: secret.sessionNonce,
                        nonce: secret.nonce
                    )
                    if ok && secret.fileId != activeFileId { realtimeFileId = secret.fileId }
                    log.info("realtime head id=\(secret.fileId, privacy: .public) decrypt=\(ok, privacy: .public)")
                }
            } else {
                transportQueue.push(pkt.raw)
            }

        case SoundcoreRxCmd.fileDoneId:
            // Realtime 模式下 done = 设备结束了当前录音（0x1A/0x0A）——先通知
            // live 桥收尾，再照旧进 transportQueue（并发 pull 场景也要看得到）。
            if realtimeFileId != nil {
                onRealtimeEnd?(realtimeFileId)
            }
            transportQueue.push(pkt.raw)

        case SoundcoreRxCmd.fileSliceId, SoundcoreRxCmd.fileSliceMarkId:
            if let activeFileId {
                let decryptOn = crypto.hasFileDecryptor(activeFileId)
                writeSlices(pkt.raw, fileId: activeFileId, decrypt: decryptOn) { seq, flags, chunk in
                    if flags & 0x01 != 0 {
                        self.onRealtimeMark?(activeFileId, seq)
                    }
                    self.onRealtimeFrame?(activeFileId, seq, chunk)
                }
            } else {
                transportQueue.push(pkt.raw)
            }

        default:
            log.info("transport-unmatched id=0x\(String(format: "%02X", pkt.cmdId), privacy: .public) len=\(pkt.payload.count, privacy: .public)")
            transportQueue.push(pkt.raw)
        }
    }

    /// Parse repeating slice records from a transport frame and feed each
    /// decrypted 160-B chunk (with its wire sequence and flags byte) to `sink`.
    /// Layout (from offset 9): `[seq u32le][flags u8][160 data][pad u8?]` —
    /// Kotlin `_writeSlices`. Returns total bytes written to `sink`.
    @discardableResult
    private func writeSlices(
        _ frame: Data,
        fileId: UInt32,
        decrypt: Bool,
        sink: (_ sequence: Int, _ flags: UInt8, _ chunk: Data) -> Void
    ) -> Int {
        let b = [UInt8](frame)
        var written = 0
        var i = 9
        while b.count - i >= Self.sliceRecord {
            let seq = soundcoreReadU32Le(b, i)
            i += 4
            let flags = b[i]
            i += 1
            let dataEnd = i + Self.sliceData
            guard dataEnd <= b.count else { break }
            var chunk = Data(b[i..<dataEnd])
            i = dataEnd
            if i < b.count { i += 1 } // pad byte
            if decrypt {
                guard let plain = crypto.decryptChunk(fileId: fileId, sequence: Int(seq), data: chunk) else { continue }
                chunk = plain
            }
            sink(Int(seq), flags, chunk)
            written += chunk.count
        }
        return written
    }
}

// MARK: - CBPeripheralDelegate

extension SoundcoreClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.failHandshake(error)
                return
            }
            guard let svc = peripheral.services?.first(where: { $0.uuid == SoundcoreUuids.d3200Service }) else {
                log.error("D3200 service not found, services=\(String(describing: peripheral.services), privacy: .public)")
                self.failHandshake(SoundcoreError.device("D3200 service not found on peripheral"))
                return
            }
            peripheral.discoverCharacteristics([SoundcoreUuids.write, SoundcoreUuids.readNotify], for: svc)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.failHandshake(error)
                return
            }
            for ch in service.characteristics ?? [] {
                if SoundcoreUuids.isWrite(ch.uuid) { self.writeChar = ch }
                if SoundcoreUuids.isRead(ch.uuid) { self.notifyChar = ch }
            }
            guard let notify = self.notifyChar else {
                log.error("notify char 8888 missing — write=\(self.writeChar != nil, privacy: .public)")
                self.failHandshake(SoundcoreError.device("notify characteristic 8888 missing"))
                return
            }
            log.info("enabling notify on 8888…")
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard characteristic.uuid == SoundcoreUuids.readNotify else { return }
            if let error {
                self.failHandshake(error)
                return
            }
            // Notification enabled — the GATT handshake (completeHandshake) is done.
            if characteristic.isNotifying, let cont = self.handshakeContinuation {
                self.handshakeContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        Task { @MainActor in self.dispatch(data) }
    }

    private func failHandshake(_ error: Error) {
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: error)
        }
    }
}
