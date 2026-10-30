import CoreBluetooth
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ble.soundcorelink")

// MARK: - soundcore Work D3200（飞书录音豆）RecorderLink adapter
//
// Thin `RecorderLink` implementation over `SoundcoreClient`, riding the same
// pipeline as TicNote (`BluetoothCoordinator.connectRecorder` →
// `RecorderSheet` download/delete/record). The D3200-specific protocol layer
// (framing / crypto / Ogg muxing / file pull) lives in
// `Sources/Services/BLE/Soundcore/`.
//
// 红线（用户决策 2026-10-27）：豆要与飞书 App 长期并行使用。本适配层**不实现
// unbind**（协议默认实现抛 `.unsupported`），`SoundcoreClient` 从未发送
// bind/unbind（0x0B/0x87）或 reset（0x01/0xB8）。
@MainActor
final class SoundcoreLink: NSObject, RecorderLink {

    static var protocolID: String { SoundcoreRecorderSpec.identifier }

    /// The GATT client doing all protocol work (sibling of `DnoteClient`).
    let client: SoundcoreClient

    var peripheral: CBPeripheral { client.peripheral }
    var displayName: String { client.displayName }
    var isConnected: Bool { client.isConnected }
    var negotiatedMTU: Int { client.negotiatedMTU }

    /// Low-frequency read-only poll so the link never idles out and the
    /// pushed-battery surface stays fresh (see `RecorderLink.startKeepAlive`).
    private var keepAliveTask: Task<Void, Never>?
    private static let keepAliveInterval: TimeInterval = 30

    // MARK: live（实时转录）状态 — see `extension SoundcoreLink: LiveAudioSource`

    /// Realtime frames → ASR 消费者的桥。仅 `liveAudio` 活跃期间非 nil。
    var liveSink: AsyncThrowingStream<Data, Error>.Continuation?
    /// 首帧/闲置看门狗。与 `liveGeneration` 配对，过期轮次自行退出。
    private var liveWatchdog: Task<Void, Never>?
    /// 当前 live 会话的设备端 fileId（0x1A/0x06 推送或列表的 currTransportTimestamp）。
    private var liveFileId: UInt32?
    /// 会话代际——`onTermination`/回调带着旧代际到达时不得影响新一轮。
    private var liveGeneration = 0
    /// `liveStop`/teardown 置位；置位后所有桥接回调直接丢弃。
    private var liveStopping = false
    private var gotLiveFrame = false
    private var liveLastFrameAt = Date()
    /// 最近一个切片的序号——App 内打点的 offset 锚点（seq × 20 ms）。
    private var liveLastSeq = -1

    /// ★ 2026-10-30（用户："把后台划了重新打开，录音时长就重新开始计算了"）：
    /// 最近一次确认的「豆上正在录的文件」id。来源优先级见 `recordingElapsed`；
    /// keep-alive 在录音中且未知时用列表的 `currentTransportTimestamp` 补一次
    /// （豆自己按键开录、App 划掉重连的场景只有列表能给）。
    private var currentFileId: UInt32?

    init(peripheral: CBPeripheral, central: CBCentralManager) {
        self.client = SoundcoreClient(peripheral: peripheral, central: central)
    }

    // MARK: connection

    func completeHandshake() async throws {
        try await client.completeHandshake()
        // ECDH session — mandatory for file decryption, best-effort like the
        // Android client (info/list/record still work without it; a failed
        // handshake only means pulls would come back as ciphertext).
        let ok = await client.handshake()
        if !ok {
            log.warning("ECDH handshake failed — file pulls will not decrypt")
        }
    }

    func handleDisconnect(error: Error?) {
        stopKeepAlive()
        client.handleDisconnect(error: error)
    }

    func syncTime(to date: Date) async throws {
        try await client.syncTime(to: date)
    }

    // MARK: recordings

    func listRecordings() async throws -> [RecorderRecording] {
        let list = try await client.listFilesCompat()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        // ★ 2026-10-28（用户："历史录音提示还在录制中……其实早就结束了"）：
        // 「在录」判定必须以**设备当前是否在录音**为前提。此前只看
        // `endTime == 0`，而固件对已结束的文件也大量写 0（截图中 10-27 那条同样
        // 被误判），于是那些文件既不能删也不能传，永远卡在"结束录音后再传输"。
        let deviceRecording = client.pushedRecording ?? client.lastDeviceInfo?.recording ?? false
        return list.files.map { entry in
            let startedAt = entry.fileIdAsEpochSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let title = startedAt.map { formatter.string(from: $0) } ?? "录音 \(entry.fileId)"
            // 正在录的那条：列表回包里"当前传输时间戳"就是它的 fileId（endTime 也为 0）。
            // 设备没在录音时，这些信号一律不算——宁可让设备在删除/传输时自己拒绝，
            // 也不要把历史录音永久锁住。
            let inProgress = deviceRecording
                && (list.currentTransportTimestamp == entry.fileId || entry.endTime == 0)
            // 时长：设备报的毫秒原值（8.3.6 复核：列表第三字段就是 durationMs）。
            // 在录的那条用 currTransportFileDuration（实时增长，§6.2）。
            let durationMs: Int
            if inProgress, let live = list.currentTransportDuration, live > 0 {
                durationMs = Int(live)
            } else {
                durationMs = entry.durationMs
            }
            var raw: [String: AnyHashable] = [
                "durationMs": durationMs,
                "inProgress": inProgress,
            ]
            if let endTime = entry.endTime { raw["endTime"] = Int(endTime) }
            return RecorderRecording(
                id: String(entry.fileId),
                displayTitle: title,
                // 官方口径的估算字节数（durationMs/20×166）——真大小在 1A07 头里，
                // pull 时会用 head 的 fileSize 覆盖这个初值。
                sizeBytes: entry.estimatedSizeBytes,
                startedAt: startedAt,
                // fileId is the device-side identifier for pull/delete (0x1A/0x07 / 0x10).
                sessionID: entry.fileId,
                raw: raw
            )
        }
    }

    func fetchRecording(
        _ recording: RecorderRecording,
        progress: (@MainActor (Double) -> Void)?
    ) async throws -> Data {
        guard let fileId = UInt32(recording.id) else {
            throw RecorderLinkError.malformed("bad D3200 file id: \(recording.id)")
        }
        // ★ 与 deleteRecording 同口径：豆在录这一条时传输通道被占用，拉它要么
        // 拉到一半的音频、要么把通道让给当前录音（表现为长时间无响应"卡住"）。
        // 明确拒绝，让用户先结束录音。
        if recording.raw["inProgress"] as? Bool == true {
            throw SoundcoreError.device("这条录音还在录制中，结束录音（再按一下豆）后再传输")
        }
        return try await client.pullFile(
            fileId: fileId,
            expectedSize: UInt32(max(0, recording.sizeBytes))
        ) { received, expected in
            guard expected > 0 else { return }
            progress?(min(1, Double(received) / Double(expected)))
        }
    }

    /// Raw 160-B Opus frames → 可直接播放的音频。
    ///
    /// ★ 2026-10-27（用户："录音都是 0s…里面的录音听着也有问题"）：不再走
    /// `Mp3Convert` 的 Ogg→mp3（那是 PLAUD 16 kHz/80 B 的口径，豆是 48 kHz/160 B，
    /// 解出来既变调又没时长元数据）。现在逐帧 `JXOpusDecoder` 解成 PCM 再封 AAC/m4a
    /// —— 时长精确、iOS 16 起全系统可播（详见 `SoundcoreTranscoder`）。
    /// 转码失败回落 `.opus`（iOS 17 可播、转写不受影响），fail-open。
    func containerize(_ raw: Data, for recording: RecorderRecording) throws -> RecorderClip {
        if let out = SoundcoreTranscoder.transcode(raw) {
            return RecorderClip(
                data: out.data,
                fileExtension: out.fileExtension,
                duration: out.durationSeconds > 0 ? out.durationSeconds : nil,
                formatNote: out.formatNote
            )
        }
        let ogg = try SoundcoreOgg.muxRawFrames(raw)
        let duration = Double(SoundcoreOgg.rawDurationMs(raw.count)) / 1000.0
        return RecorderClip(
            data: ogg,
            fileExtension: "opus",
            duration: duration > 0 ? duration : nil,
            formatNote: "Opus 48 kHz mono (D3200)"
        )
    }

    /// 删除豆上的一条录音（0x1A/0x10），**删完回读列表仲裁**。
    ///
    /// ★ 2026-10-27（用户："点击删除还没办法删除在卡片的录音"）：0x1A/0x10 的应答
    /// 只说明「命令收到了」，豆在录音/传输占用时不会真的删，之前把应答当成功，
    /// 列表刷新后录音还在，用户看到的就是"点了没反应"。现在：
    ///  1. 正在录的那条直接拒绝（官方实现同样锁住，豆也不接受删在录文件）；
    ///  2. 发完命令回读文件列表，fileId 还在就抛错——报告的是设备的真实状态。
    func deleteRecording(_ recording: RecorderRecording) async throws {
        guard let fileId = UInt32(recording.id) else {
            throw RecorderLinkError.malformed("bad D3200 file id: \(recording.id)")
        }
        if recording.raw["inProgress"] as? Bool == true {
            throw SoundcoreError.device("这条录音还在录制中，先结束录音（按一下豆/暂停）再删除")
        }
        try await client.deleteFile(fileId)

        // 回读仲裁：列表拿不到就算"无法确认"，不误报失败（删可能已经生效）。
        guard let list = try? await client.listFilesCompat() else {
            log.warning("delete \(fileId, privacy: .public): re-list unavailable, result unverified")
            return
        }
        if list.files.contains(where: { $0.fileId == fileId }) {
            throw SoundcoreError.device(
                "录音豆没有删除这条录音（\(fileId)）——它可能还在录制/传输中，稍后重试"
            )
        }
    }

    /// Device-pushed new-recording id (0x1A/0x06) — the bean's analogue of
    /// TicNote's `0x18` session push, used by auto-transfer matching.
    var lastSessionID: UInt32? { client.lastNewFileId }

    // MARK: record control (0x18/0x82)

    func startRecording() async throws {
        try await client.startRecording()
    }

    /// Pause = finalize the take on the device (payload 0x02).
    func stopRecording() async throws {
        try await client.pauseRecording()
    }

    // MARK: device info / recording status

    func readDeviceInfo() async throws -> RecorderDeviceInfo {
        let info = try await client.getDeviceInfo()
        var storage: RecorderStorageInfo?
        if let total = info.totalMemoryKb, let free = info.freeMemoryKb, total > 0 {
            storage = RecorderStorageInfo(
                totalBytes: Int64(total) * 1024, // device reports kilobytes
                freeBytes: Int64(free) * 1024
            )
        }
        // ★ 2026-10-29（用户："录音豆和卡片/充电盒是两个设备，要显示两个电量"）：
        // D3200 的设备信息本来就带两个电量——`battery`（豆本体）和 `boxBattery`
        // （充电盒）。以前 `??` 合并只显示一个；现在主行显示豆本体，第二行显示充电盒。
        let beanBattery = info.battery
        let caseBattery = beanBattery != nil ? info.boxBattery : nil
        return RecorderDeviceInfo(
            batteryPercent: beanBattery ?? info.boxBattery,
            isCharging: Optional(info.charging),
            storage: storage,
            rawReplies: [:],
            notes: info.firmwareVersion.isEmpty
                ? []
                : ["固件 \(info.firmwareVersion) · SN \(info.serialNumber)"],
            secondaryBatteryPercent: caseBattery,
            secondaryBatteryLabel: "充电盒"
        )
    }

    func readRecordingStatus() async throws -> RecorderRecordingStatus {
        // Prefer the device-pushed state (0x18/0x82 + device-info recording
        // flag, refreshed by keep-alive); fall back to one full info read when
        // nothing has been pushed yet this connection.
        let recording: Bool?
        if let pushed = client.pushedRecording {
            recording = pushed
        } else if let info = client.lastDeviceInfo {
            recording = info.recording
        } else {
            recording = try await client.getDeviceInfo().recording
        }
        // ★ 2026-10-30：把「豆上这段已录多久」一并交给上层（fileId 推导，见
        // `recordingElapsed`）。没有它，`RecorderSessionModel` 在重连后只能
        // 锚定"现在"，秒表从 0 重数——正是用户报的 bug。
        return RecorderRecordingStatus(isRecording: recording, deviceElapsed: recordingElapsed)
    }

    // MARK: pushed state (device-triggered pushes → UI)

    var pushedRecordingState: Bool? {
        client.pushedRecording ?? client.lastDeviceInfo?.recording
    }

    var pushedBatteryPercent: Int? { client.pushedBatteryPercent }

    var pushedChargingState: Bool? { client.pushedCharging }

    /// ★ 2026-10-30（用户："把后台划了，重新打开录音时长就是重新开始计算了"）：
    /// 豆的 **fileId 就是这段录音开始那一刻的 Unix 秒**（`LiveModel` 一直这么用，
    /// 日志里的 fileId 与录音日期一一对应），所以
    ///
    ///     已录时长 = 当前时间 − fileId
    ///
    /// 是豆侧真相，且**不需要豆回报任何新东西**——重连后第一个切片就能对表。
    /// 此前 `RecorderLink.pushedElapsed` 走协议默认 `nil`、`readRecordingStatus`
    /// 也不填 `deviceElapsed`，`RecorderSessionModel` 对 D3200 无钟可采，
    /// 重开后秒表只能锚定"现在"——秒表从 0 重数且永不追上，就是本 bug。
    ///
    /// fileId 来源优先级：实时转录的活动文件（最权威）→ live 会话缓存 →
    /// 列表确认的当前文件 → 开始录音推送。非录音态返回 nil（不供旧值）。
    /// 负数 / 超过一天 = 豆时钟不可信，宁可不给（宁缺毋滥，避免秒表乱跳）。
    private var recordingElapsed: TimeInterval? {
        guard pushedRecordingState == true else { return nil }
        let fid = client.activeRealtimeFileId ?? liveFileId ?? currentFileId ?? client.lastNewFileId
        guard let fid, fid > 0 else { return nil }
        let elapsed = Date().timeIntervalSince1970 - TimeInterval(fid)
        guard elapsed >= 0, elapsed < 86_400 else { return nil }
        return elapsed
    }

    /// `RecorderSessionModel.pollOnce` 每秒读它来校准秒表（覆盖协议默认的 `nil`）。
    var pushedElapsed: TimeInterval? { recordingElapsed }

    // MARK: keep-alive

    func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            // ★ 2026-10-30：先干活再睡——首拍立即执行。划掉 App 重开时若豆正在录，
            // 第一拍就把 fileId 要回来（`currentFileId`），秒表马上对上豆的钟；
            // 旧写法先睡 30 s，重开后头半分钟秒表还是错的。
            while !Task.isCancelled {
                guard let self, self.client.isConnected else {
                    try? await Task.sleep(nanoseconds: UInt64(Self.keepAliveInterval * 1_000_000_000))
                    continue
                }
                // getDeviceInfo is read-only and refreshes the pushed battery /
                // storage surfaces while it keeps the link alive.
                _ = try? await self.client.getDeviceInfo()
                // ★ 录音中 → 刷新「正在录的文件」id（列表的 currentTransportTimestamp
                //   是权威来源，覆盖豆自己按键开录/换段的情况）。失败保留旧值。
                if self.pushedRecordingState == true,
                   let list = try? await self.client.listFilesCompat(),
                   let fid = list.currentTransportTimestamp {
                    self.currentFileId = fid
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.keepAliveInterval * 1_000_000_000))
            }
        }
    }

    func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    // MARK: in-app mark（App 内打点，镜像 `DingTalkA1Link.addMarkNow`）

    /// 实时转录期间由 App 打一个点。offset 锚定最近收到的切片（20 ms/片）。
    @discardableResult
    func addMarkNow() -> Bool {
        guard !liveStopping, let fid = client.activeRealtimeFileId ?? liveFileId else { return false }
        let offset = max(0, Double(liveLastSeq + 1) * 0.02)
        A1MarkStore.add(A1Mark(offset: offset, at: Date()), toFile: fid)
        TicNoteDiagLog.log("D3200 MARK", "＋ app mark \(String(format: "%.0f", offset))s (seq \(liveLastSeq))")
        return true
    }
}

// MARK: - LiveAudioSource（实时转录跟随设备）
//
// LiveView 通过 `bluetooth.recorderLink as? any LiveAudioSource` 选取实时页的音源——
// 豆的链路一旦遵循该协议，实时转录页就自动跟随当前连接的设备（TicNote / A1 / D3200
// 同一套 ASR 管线，由 `opusProfile` 区分分帧口径，见 `OpusOgg.Profile`）。
//
// 音频桥：`SoundcoreClient.onRealtimeFrame`（解密后的整包 160 B）→ AsyncThrowingStream
// → LiveModel → ASR。三件事也挂在这条桥上：
//   ① 打标（flags bit0）→ `A1MarkStore`，offset = seq × 20 ms；
//   ② 设备自己结束（0x1A/0x0A done）→ 流正常收尾（LiveModel 按"设备停止"分支处理）；
//   ③ 看门狗：首帧超时 / 掉线 / 长时间静音且设备未在录音 → 提前报错收尾。
extension SoundcoreLink: LiveAudioSource {

    var opusProfile: OpusOgg.Profile { .soundcore }

    /// 实时切片在 `SoundcoreClient.dispatchTransport` 里已就地解密（与 upstream 一致），
    /// 到这里都是明文 160 B 包。
    var liveClipKey: Data? { nil }

    var isAvailable: Bool { isConnected }

    var liveLastSessionKey: String? { liveFileId.map(String.init) }

    func liveIsRecording() async -> Bool? {
        if let pushed = pushedRecordingState { return pushed }
        guard let status = try? await readRecordingStatus() else { return nil }
        return status.isRecording
    }

    func liveListFiles() async -> [LiveDeviceFile]? {
        guard let list = try? await listRecordings() else { return nil }
        // ⚠️ 名字必须带 `.opus`：LiveModel 保存时直接用这个名字交给
        // `PostDownload.process`，而它只对 `.opus` 结尾的文件做封装并写入
        // `decryptedDir`（录音列表读的就是那里）。此前用纯 fileId 当名字，
        // 实时录音就落到了 audioDir 根目录、没有扩展名 —— 列表里永远看不到。
        return list.map {
            LiveDeviceFile(name: "\($0.id).opus", size: $0.sizeBytes, sessionID: $0.sessionID)
        }
    }

    // MARK: Start

    func liveStartNew() async throws {
        // 上一轮的 fileId 必须清掉：fileId 是 epoch 秒，残留会把新一段的实时流
        // 请求到旧文件上（与 TicNote 清 sid 同一个坑）。
        liveFileId = nil
        liveLastSeq = -1
        TicNoteDiagLog.log("D3200 LIVE", "startNew: sending start-record")
        try await startRecording()

        // 豆在开始录音时通过 0x1A/0x06 推送新 fileId；轮询等待，超时回退到列表。
        let previous = client.lastNewFileId
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let fid = client.lastNewFileId, fid != previous {
                liveFileId = fid
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if liveFileId == nil,
           let list = try? await client.listFilesCompat(),
           let current = list.currentTransportTimestamp {
            liveFileId = current
            TicNoteDiagLog.log("D3200 LIVE", "startNew: 0x1A/0x06 push missing — fileId from list: \(current)")
        }
        guard let newFid = liveFileId else {
            TicNoteDiagLog.log("D3200 LIVE", "✗ started recording but no fileId push / list entry within 3 s")
            throw LiveStartError.noSessionID
        }
        TicNoteDiagLog.log("D3200 LIVE", "new take fileId=\(newFid)")
    }

    func liveAttach() async throws {
        liveLastSeq = -1
        // 接管豆上已经在录的段：fileId 从列表的"当前传输时间戳"取——它是设备此刻
        // 真正在录的文件，权威。lastNewFileId 是推送缓存，可能残留上一段（过期
        // 就会实时流接到旧录音上，转录出来的全是上一段的内容），只做兜底。
        let recording: Bool?
        if let pushed = pushedRecordingState {
            recording = pushed
        } else {
            recording = (try? await readRecordingStatus())?.isRecording
        }
        guard recording == true else { throw LiveStartError.deviceNotRecording }

        var fid: UInt32?
        if let list = try? await client.listFilesCompat() {
            fid = list.currentTransportTimestamp
        }
        if fid == nil { fid = client.lastNewFileId }
        guard let fid else { throw LiveStartError.noSessionID }
        liveFileId = fid
        TicNoteDiagLog.log("D3200 LIVE", "attach fileId=\(fid)")
    }

    // MARK: Audio pipeline

    /// 豆的实时流是连续 CBR（约 50 帧/s，静音也发帧），不卡流——包计数时钟就是准的，
    /// 无需设备时长查询（与 TicNote 同理）。
    func liveDeviceElapsed() async -> TimeInterval? { nil }

    func liveAudio(firstFrameTimeout: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        liveGeneration &+= 1
        let generation = liveGeneration
        liveStopping = false
        gotLiveFrame = false
        liveLastFrameAt = Date()

        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { c in
            cont = c
        }
        cont.onTermination = { [weak self] _ in
            // 消费方（LiveModel）停了——在主 actor 上拆除路由并释放实时传输。
            // 代际检查防止旧一轮的 termination 误杀新一轮（同 TicNote/A1）。
            Task { @MainActor in
                guard let self, self.liveGeneration == generation else { return }
                self.teardownLiveRouting()
                await self.client.stopRealtime()
            }
        }
        liveSink = cont

        guard let fileId = liveFileId else {
            TicNoteDiagLog.log("D3200 LIVE", "✗ liveAudio without a fileId — start/attach first")
            liveSink = nil
            cont.finish(throwing: LiveStartError.noSessionID)
            return stream
        }

        // 桥 ①：解密整包 → ASR。
        client.onRealtimeFrame = { [weak self] _, seq, chunk in
            guard let self, self.liveGeneration == generation, !self.liveStopping else { return }
            if !self.gotLiveFrame {
                self.gotLiveFrame = true
                TicNoteDiagLog.log("D3200 LIVE", "first frame (seq \(seq))")
            }
            self.liveLastFrameAt = Date()
            self.liveLastSeq = seq
            self.liveSink?.yield(chunk)
        }
        // 桥 ②：豆身上的按键打标（flags bit0，8.3.6 复核）。
        client.onRealtimeMark = { [weak self] fid, seq in
            guard let self else { return }
            let offset = max(0, Double(seq) * 0.02)
            A1MarkStore.add(A1Mark(offset: offset, at: Date()), toFile: fid)
            TicNoteDiagLog.log("D3200 MARK", "＋ \(String(format: "%.0f", offset))s (seq \(seq))")
        }
        // 桥 ③：设备自己结束了这段（0x1A/0x0A done）——流正常收尾。
        client.onRealtimeEnd = { [weak self] fid in
            guard let self, self.liveGeneration == generation, !self.liveStopping else { return }
            TicNoteDiagLog.log("D3200 LIVE", "device finished the take (file \(fid.map(String.init) ?? "?")) — ending stream")
            self.teardownLiveRouting()
            cont.finish()
        }

        // 打开实时传输。head 回包就地初始化解密（dispatchTransport）。
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.client.startRealtime(fileId: fileId)
            } catch {
                guard self.liveGeneration == generation, !self.liveStopping else { return }
                TicNoteDiagLog.log("D3200 LIVE", "✗ startRealtime failed: \(String(describing: error))")
                self.teardownLiveRouting()
                cont.finish(throwing: error)
            }
        }

        // 看门狗：首帧超时 → 报错；中途掉线 → linkLost；静音且设备没在录音 → 收尾
        // （豆是连续 CBR，静音即未录音；正常结束一般会先走 0x1A/0x0A 的桥 ③）。
        liveWatchdog = Task { @MainActor [weak self] in
            let firstDeadline = Date().addingTimeInterval(firstFrameTimeout)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                guard let self, self.liveGeneration == generation, !self.liveStopping else { return }

                if !self.gotLiveFrame {
                    guard Date() >= firstDeadline else { continue }
                    TicNoteDiagLog.log("D3200 LIVE", "✗ no realtime frame within \(Int(firstFrameTimeout)) s")
                    self.teardownLiveRouting()
                    await self.client.stopRealtime()
                    cont.finish(throwing: RecorderLinkError.timeout)
                    return
                }

                guard self.isConnected else {
                    TicNoteDiagLog.log("D3200 LIVE", "✗ BLE link lost mid-stream")
                    self.teardownLiveRouting()
                    await self.client.stopRealtime()
                    cont.finish(throwing: RecorderLinkError.linkLost)
                    return
                }

                let silent = Date().timeIntervalSince(self.liveLastFrameAt)
                if silent >= 5 {
                    // 轻查询（优先走缓存的推送状态），确认设备确实没在录再收尾。
                    let recording = await self.liveIsRecording()
                    guard self.liveGeneration == generation, !self.liveStopping else { return }
                    if recording == false {
                        TicNoteDiagLog.log("D3200 LIVE", "stream silent \(Int(silent)) s and device not recording — ending")
                        self.teardownLiveRouting()
                        await self.client.stopRealtime()
                        cont.finish()
                        return
                    }
                }
            }
        }
        return stream
    }

    // MARK: Stop

    func liveStop() async -> LiveStopOutcome {
        let fid = client.activeRealtimeFileId ?? liveFileId
        teardownLiveRouting()
        await client.stopRealtime()
        // 让设备结束这一段（0x1A/0x06 payload 0x02）。设备已自己停过时是无害的重复。
        try? await stopRecording()
        // ★ 保留 fid（不清空）：LiveModel 的调用顺序是 stop() → liveStop() →
        //   saveAndCleanup → liveContainerize —— sidecar（打点）要在容器化时用这个
        //   fid 才写得出来。下一次 liveStartNew/liveAttach 会先清掉再取新值。
        liveFileId = fid
        // 同 liveListFiles：名字带 `.opus`，否则 PostDownload 会把它当"未知格式"
        // 丢在 audioDir 根目录，列表里看不到（详见 liveListFiles 的注释）。
        let file = fid.map { LiveDeviceFile(name: "\($0).opus", size: 0, sessionID: $0) }
        return LiveStopOutcome(file: file, deviceInitiated: false)
    }

    // MARK: Post-process

    func liveFetch(file: LiveDeviceFile,
                   progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Data {
        guard let fid = file.sessionID else {
            throw RecorderLinkError.unsupported("live file has no fileId")
        }
        let recording = RecorderRecording(
            id: String(fid),
            displayTitle: "录音 \(fid)",
            sizeBytes: file.size,
            startedAt: Date(timeIntervalSince1970: TimeInterval(fid)),
            sessionID: fid,
            raw: [:]
        )
        let raw = try await fetchRecording(recording) { fraction in
            let total = max(file.size, 1)
            progress(Int(Double(total) * fraction), total)
        }
        // "修复"拿到的字节会直接交给 PostDownload（名字以 .opus 结尾）——必须是
        // Ogg 容器；裸 160 B 帧会被按 40 B 误切（同 TicNote/A1 的理由）。
        return try SoundcoreOgg.muxRawFrames(raw)
    }

    func liveDelete(file: LiveDeviceFile) async throws {
        guard let fid = file.sessionID else {
            throw RecorderLinkError.unsupported("live file has no fileId")
        }
        let recording = RecorderRecording(
            id: String(fid),
            displayTitle: "录音 \(fid)",
            sizeBytes: file.size,
            startedAt: Date(timeIntervalSince1970: TimeInterval(fid)),
            sessionID: fid,
            raw: ["inProgress": AnyHashable(false)]
        )
        try await deleteRecording(recording)
    }

    /// 累积的 160 B 包 → Ogg-Opus（`SoundcoreOgg`，preSkip 3840 / serial 'ARKR'，
    /// 与卡片下载路径完全同一条封装）。顺带把这次录音期间攒下的打点写成 sidecar，
    /// 详情页即可显示可跳转的时间点（与 A1 实时保存同一机制）。
    func liveContainerize(_ raw: Data, name: String) throws -> Data {
        guard !raw.isEmpty else { throw RecorderLinkError.malformed("live audio is empty") }
        let ogg = try SoundcoreOgg.muxRawFrames(raw)
        guard !ogg.isEmpty else {
            throw RecorderLinkError.malformed("Ogg muxing failed (\(raw.count) B)")
        }
        if let fid = liveFileId {
            A1MarkStore.writeSidecar(fid: fid, clipBase: (name as NSString).deletingPathExtension)
        }
        return ogg
    }

    // MARK: live internals

    /// 拆掉三条桥 + 看门狗。幂等；不触碰 GATT（`stopRealtime` 由调用方决定是否发）。
    private func teardownLiveRouting() {
        liveStopping = true
        liveWatchdog?.cancel()
        liveWatchdog = nil
        client.onRealtimeFrame = nil
        client.onRealtimeMark = nil
        client.onRealtimeEnd = nil
        liveSink = nil
    }
}
