import Foundation
import Network
import NetworkExtension
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ble.soundcorewifi")

// MARK: - soundcore Work D3200（飞书录音豆）Wi‑Fi 快传
//
// Faithful Swift port of the verified Kotlin `SoundcoreWifiExporter.kt`
// (real-device verified 2026-10-27; PROTOCOL.md §6.4–6.5):
//
// 1. BLE `1A05` with phone-chosen SSID/PSK (`WiFi-{ms}` / `{ms}`) — **the
//    device** opens the SoftAP (credentials are phone-chosen; the device joins
//    as our AP and answers with its own AP gateway, typically 192.168.43.1).
// 2. Phone joins the device hotspot via `NEHotspotConfigurationManager`
//    (`joinOnce = true`; requires the HotspotConfiguration entitlement).
//    If apply() fails (entitlement/provisioning/user denial) we do NOT
//    hard-fail — the flow tolerates the network having been joined manually
//    (设置 → 无线局域网) and proceeds straight to the WebSocket step.
// 3. WebSocket `wss://ip:port` (URLSessionWebSocketTask + trust-all
//    server-trust handler — the device uses a self-signed TLS cert; ATS is
//    NOT disabled globally, the challenge is handled per-connection).
//    UDP keepalive `soundcore-keep-alive-unicast` → ip:32003 every 2 s.
// 4. Per file: **hex TEXT** 18-B file-head request
//    `08 EE 00 00 00 1A 07 12 00 | transferredSize u32le | fileId u32le | 1B`
//    (NO checksum byte) → `1A07` head → `1A08`/`1A12` slices → `1A0A` done.
//    RX reuses the BLE `09 FF` framing — parsed by `SoundcoreFrameParser`.
// 5. Teardown: text `FINISH` → hex `1A0A` transfer-complete (WITH checksum)
//    → remove the hotspot configuration → BLE `1A02` closeWifiMode.
//
// Known real-device facts carried over from the Kotlin reference:
//   · Head may be missing (some firmwares stream straight to slices);
//   · A head for a foreign fileId is ignored;
//   · expected-size update is skipped when size == 0xFFFFFFFF;
//   · completion tolerance: received < expected*0.95 → partial warning.
//
// Decryption reuses the BLE session's per-file key (`SoundcoreDeviceCrypto`)
// — the `1A07` head carries the file key wrapped with the same sessionKey.
@MainActor
final class SoundcoreWifiExporter: NSObject {

    // MARK: types

    enum Phase { case openAp, waitJoin, connectWs, transferring, done, error }

    struct Progress {
        let phase: Phase
        let message: String
        var currentFile: Int = 0
        var totalFiles: Int = 0
        var fileBytes: Int = 0
        var fileTotal: Int = 0
    }

    struct ExportedFile {
        let fileId: UInt32
        /// Decrypted 160-B Opus frames (raw stream, pre-mux).
        let raw: Data
        /// `SoundcoreOgg.muxRawFrames(raw)` — ready to store.
        let ogg: Data
        /// `true` when the transfer ended below the 95 % tolerance.
        let partial: Bool
        /// 实收率（0…1）。`partial` 的文件如果实收率够高（≥50%），
        /// 仍然值得入库——用户宁可拿到 97 分钟也强过什么都没有。
        var coverage: Double = 1
    }

    struct WifiExportError: LocalizedError {
        let message: String
        /// ★ 2026-10-29：热点已加入但豆的传输服务没起来（TCP 443 不通）。
        /// exportAll 据此**自动重开一次会话**再报错——15:10 日志：加入成功、
        /// 探测失败，其实重发 1A05 就能救，不该甩给用户。
        var isTCPDead: Bool = false
        /// ★ 2026-10-30（用户截图"无法加入网络 WiFi-…"）：apply 反复成功但
        /// 始终关联不上——豆的 SoftAP 还没真正广播出来（重开热点比 10 s 慢）。
        /// 与 isTCPDead 同待遇：上层自动重开会话（换新 SSID），不甩给用户。
        var isJoinDead: Bool = false
        var errorDescription: String? { message }
    }

    // MARK: constants (Kotlin companion object)

    private static let joinApTimeoutSeconds: Double = 45
    private static let wsReadyTimeout: Double = 10
    private static let keepalivePort: UInt16 = 32003
    private static let sliceData = 160
    /// 一条切片记录在**线缆**上占的字节数（4 seq + 1 flags + 160 data + 1 pad）。
    ///
    /// 飞书按它记账：`while (len - i >= 166)`、步进 166、进度 `d += 166`
    /// （`h0.h()`）。设备 1A07 头里的 fileSize 也是 166 的整数倍（实测
    /// 60149602 = 362347×166），所以进度与"完整/不完整"必须用线缆字节数。
    private static let sliceWire = 166

    // MARK: state

    /// ★ 2026-10-29 由 `let` 改 `var`：BLE 重连（onNeedBleReconnect）可能产出新的
    /// SoundcoreLink/client（fastReconnect/scan 都会新建实例），旧 client 已死，
    /// 1A05 必须走新 client。文件解密器不用担心：密钥来自 WS 头帧、用**当时
    /// 会话**的密钥解出，新 client + 新 WS 会话会重新走一遍 initFileDecrypt。
    private var client: SoundcoreClient
    /// Dedicated WS-side parser — independent of the GATT notify stream.
    private let parser = SoundcoreFrameParser()

    private var ssid: String?
    /// ★ 2026-10-29：当前会话的密码（错误指引里要展示给用户手动加入用）。
    private var lastPsk: String?
    /// 本次会话拿到的设备热点端点（断线重连用）。
    private var lastEndpoint: SoundcoreClient.WifiEndpoint?
    private var ws: URLSessionWebSocketTask?
    private var wsSession: URLSession?

    private var keepaliveConnection: NWConnection?
    private var keepaliveTask: Task<Void, Never>?
    /// WS 文本心跳（"ping"）——规格书 §8.3 的保活帧；长传输期间防设备侧空闲断开。
    private var wsPingTask: Task<Void, Never>?

    // Per-file collection state (WS callbacks hop onto the MainActor).
    private var activeFileId: UInt32?
    private var decryptOn = false
    private var fileBuf = Data()
    private var fileBytes = 0
    private var fileExpected = 0
    private var headSignalled = false
    private var doneSignalled = false
    /// 下一条期望的切片序号（-1 = 还没收到过）。**只做诊断**——设备会跳号、
    /// 甚至中途回到 0，不能拿它去重（见 `writeSlices` 里的更正）。
    private var nextSeq = -1
    /// seq 不连续的次数（诊断）。
    private var seqJumps = 0
    /// 刚发出续传请求：下一条切片如果 seq 为 0，就说明设备无视了
    /// transferredSize、从头重发，这时才允许清空缓冲。
    private var resumeSeqResetPending = false
    /// 已经判定"设备不认 transferredSize"——再重连也只是重复传开头，别烧流量。
    private var resumeIgnored = false
    private var openSignalled = false
    private var wsFailure: Error?
    private var wsClosed = false
    /// ★ 2026-10-30：socket 死后失败回调可能连环触发（19:20 实测 16 ms 内刷了
    /// 1000+ 条 `ws receive FAILED`）——每条 socket 只记**第一次**失败。
    private var wsFailureLogged = false
    /// ★ 2026-10-28：WS 收帧统计——"卡在传输中"的分诊数据。设备没发 vs
    /// 我们没收，看这三个数就能分开（错误信息里也会带上）。
    private var wsMessages = 0
    private var wsBytesIn = 0
    private var firstMessageKind = "none"
    /// 前 2 条 WS 消息的十六进制前缀（只在诊断文件里）——用来看清设备到底发的是
    /// `09 FF 00 00` 分帧、还是另一种封装，从而判断是"设备没发"还是"我们没认"。
    private var dumpedFirstFrames = 0

    /// `false` = `NEHotspotConfiguration.apply` failed (entitlement /
    /// provisioning / user denial). The UI uses this to offer the manual-join
    /// fallback instead of blaming the device.
    private(set) var hotspotApplySucceeded = true

    /// ★ 2026-10-29：最近一次重开 1A05 会话失败的原因（成功时置 nil）。
    /// 续传失败时把它带进用户可见的进度文案里——"传到 55 MB 就断"本身是
    /// 设备单连接上限（无法避免），用户真正需要知道的是**恢复为什么没成**。
    private(set) var lastResumeFailure: String?

    /// ★ 2026-10-28：自动加入热点失败时的"请用户手动加入"回调（参数：SSID、密码）。
    /// 回调返回后导出器会轮询确认网络是否已切换过去（最长 90 s）——**同一次会话内**
    /// 完成，因为每次导出都会生成新的 SSID/密码，跨会话手动加入没有意义。
    var onNeedManualJoin: ((_ ssid: String, _ psk: String) async -> Void)?

    /// ★ 2026-10-29：每次（重新）建立热点会话时回调（初始 1A05 + restartWifiSession），
    /// 供传输页面展示热点名/密码——不然用户想手动加入时看不到凭据。
    var onSessionStart: ((_ ssid: String, _ psk: String) -> Void)?

    /// ★ 2026-10-29：传输中的阶段性提示（续传/重开会话的每一步）。
    /// 重开一次会话要 1–2 分钟，不给提示用户会以为又卡死了。
    var onStageNote: ((String) -> Void)?

    /// ★ 2026-10-29：重开 1A05 会话前确保 BLE 可用（1A05 只能走蓝牙下发）。
    /// 09:21 实测：传到 92.6% 触发续传时 BLE 已被断掉（"soundcore 设备未连接"），
    /// 没有这步续传必死。回调应尝试重连 BLE，返回**当前可用的 client**（重连
    /// 通常是新实例，旧 client 已死）；返回 nil = 重连失败。
    var onNeedBleReconnect: (() async -> SoundcoreClient?)?

    /// 正在等用户手动加入热点——此时 teardown 不能关掉豆的 Wi‑Fi 模式，
    /// 否则用户按提示去设置里根本找不到这个热点。
    private var manualJoinInProgress = false

    /// Cooperative cancellation — checked between files and inside the
    /// per-file wait loop.
    private var cancelled = false

    init(client: SoundcoreClient) {
        self.client = client
        super.init()
    }

    // MARK: entry point

    /// Export `files` (from the BLE file list) over the device hotspot.
    /// Returns the successfully transferred files as Ogg-Opus containers.
    func exportAll(
        _ files: [SoundcoreFileEntry],
        onProgress: @escaping (Progress) -> Void
    ) async throws -> [ExportedFile] {
        guard !files.isEmpty else { return [] }
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        // 上游默认：ssid = "WiFi-"+currentTimeMillis，pwd = String(ms)。
        let ssid = "WiFi-\(ms)"
        let psk = "\(ms)"
        // ★ 2026-10-29（"WiFi 加入失败"）：SSID 每次导出都是新的（官方口径），
        // 而 joinOnce=false 的旧配置会留在系统里——iOS 在豆开新热点前会反复
        // 自动回连**已经死掉的旧热点**，join 排队/弹授权都被它拖累。开始新一轮
        // 前把上一轮之前的历史配置全部清掉（保留即将用的这个）。
        Self.cleanupPreviousHotspotConfigs(keeping: ssid)
        Self.rememberHotspotSSID(ssid)
        self.ssid = ssid
        lastPsk = psk
        lastResumeFailure = nil
        onSessionStart?(ssid, psk)
        var saved: [ExportedFile] = []
        do {
            // ── 1–2. BLE：下发 AP 凭据（设备开热点），拿回 IP:port ──────
            onProgress(Progress(phase: .openAp, message: "正在配置录音豆热点…"))
            let ep = try await client.startWifiExport(ssid: ssid, psk: psk)
            lastEndpoint = ep
            TicNoteDiagLog.log("D3200 WIFI", "1A05 ok → ap=\(ep.ip):\(ep.port) ssid=\(ssid)")

            // ── 3–4. 加入热点 + WebSocket（失败自动重开一次会话）─────────
            // ★ 2026-10-29（15:10 日志："加入成功但 TCP 443 不通"）：豆反复重开
            // 会话后，AP 广播和传输服务就绪的间隔被拉得很长。这里给一次**自动**
            // 重开（restartWifiSession 内部含 BLE 重连 → 1A05 → 重新加入 → 重连）
            // 的机会，而不是把"WiFi 加入失败"直接甩给用户。
            onProgress(Progress(phase: .waitJoin, message: "正在接入录音豆热点…"))
            var autoRestarted = false
            do {
                try await joinDeviceAp(ssid: ssid, psk: psk)
                TicNoteDiagLog.log("D3200 WIFI", "hotspot applied=\(hotspotApplySucceeded)")
                onProgress(Progress(phase: .connectWs, message: "正在连接录音豆 \(ep.ip):\(ep.port)…"))
                try await connectWs(endpoint: ep)
            } catch let error as WifiExportError where error.isTCPDead || error.isJoinDead {
                TicNoteDiagLog.log("D3200 WIFI",
                    "initial connect hit \(error.isJoinDead ? "unready AP (join dead)" : "dead service") — auto-restarting wifi session once")
                onProgress(Progress(phase: .connectWs, message: error.isJoinDead
                    ? "豆的热点没就绪，正在自动换新热点重试…"
                    : "豆的传输服务没响应，正在自动重开传输会话…"))
                guard await restartWifiSession() else {
                    // restart 内部已记录 lastResumeFailure 原因；把最原始的错抛出去。
                    throw error
                }
                // restartWifiSession 成功路径里已经 startKeepalive + startWsPing。
                autoRestarted = true
            }
            if !autoRestarted {
                startKeepalive(ip: ep.ip)
                startWsPing()
            }
            TicNoteDiagLog.log("D3200 WIFI", "ws connected, keepalive + ping started")

            // ── 5. 逐个文件拉取 ────────────────────────────────────────
            var firstFileError: Error?
            for (index, f) in files.enumerated() {
                if cancelled { break }
                onProgress(Progress(
                    phase: .transferring,
                    message: "正在传输 \(index + 1)/\(files.count)…",
                    currentFile: index + 1,
                    totalFiles: files.count,
                    // 列表里只有估算字节数（durationMs/20×166，官方口径）；真大小
                    // 在 1A07 头里，pullOverWs 收到头后会覆盖 fileExpected。
                    fileTotal: f.estimatedSizeBytes
                ))
                // 一个文件最多跨 8 个 Wi‑Fi 会话拼接。设备健康时单会话 ~50 MiB；
                // ★ 2026-10-29（用户："录音卡住无法完整传输"）：豆状态差时单会话
                // 实测只吐 10–15 MB——60 MB 的录音从 0 传需要 5 段起步，上限太低
                // 会拼到一半主动放弃（= 卡住传不完）。8 段 ≈ 120 MB 容量，且
                // 0 收益的会话有看门狗拦截，不会白烧。
                var acc = Data()
                var accWire = 0
                // ★ 2026-10-29：磁盘断点——上次导出没传完的部分还在，这次直接续。
                if let ck = loadCheckpoint(f.fileId) {
                    acc = ck.raw
                    accWire = ck.wire
                    TicNoteDiagLog.log("D3200 WIFI",
                        "file \(f.fileId): resuming from disk checkpoint \(accWire)B wire / \(acc.count)B raw")
                    onProgress(Progress(
                        phase: .transferring,
                        message: "发现上次的断点（\(Self.sizeText(accWire))），从那里继续…",
                        currentFile: index + 1,
                        totalFiles: files.count,
                        fileBytes: accWire,
                        fileTotal: f.estimatedSizeBytes
                    ))
                }
                var fileError: Error?
                var sessions = 0
                // ★ 2026-10-29：两次连续失败之间一个字节都没多收 → 别再烧会话。
                var prevCatchAccWire: Int?
                // ★ 2026-10-29：段数上限 6→8。豆差状态单会话实测只吐 10–15 MB，
                // 60 MB 的录音从 0 传要 5+ 段；上限太低会拼到一半主动放弃。
                while sessions < 8, !cancelled {
                    sessions += 1
                    do {
                        acc = try await pullOverWs(
                            fileId: f.fileId,
                            knownSize: f.estimatedSizeBytes,
                            seed: acc,
                            startOffset: accWire,
                            onProgress: { got, total in
                                // 真机"卡在传输中"时，用户至少能看到字节在涨/不涨；
                                // 不涨的话下面的看门狗会给出具体阶段。
                                onProgress(Progress(
                                    phase: .transferring,
                                    message: "正在传输 \(index + 1)/\(files.count)… \(Self.sizeText(got))/\(Self.sizeText(total))",
                                    currentFile: index + 1,
                                    totalFiles: files.count,
                                    fileBytes: got,
                                    fileTotal: total
                                ))
                            }
                        )
                        accWire = fileBytes
                        fileError = nil
                    } catch {
                        fileError = error
                        TicNoteDiagLog.log("D3200 WIFI",
                            "file \(f.fileId) session \(sessions) failed: \(error.localizedDescription) (wsFailure=\(wsFailure != nil) closed=\(wsClosed) got=\(acc.count)B)")
                        // ★ 2026-10-29：中途挂掉别急着判死。同一条热点会话里的
                        // WS 重连被实测证明永远失败（09:35 wss 超时）——唯一有效的
                        // 恢复路是**重开 1A05 会话**（新热点凭据）再带偏移续传。
                        // 连续两次失败之间 acc 没涨 → 说明设备已经不认这个文件
                        // 会话了，别再白烧（一次机会试完就停）。
                        if prevCatchAccWire == accWire { break }
                        prevCatchAccWire = accWire
                        if sessions < 8, !cancelled, await restartWifiSession() { continue }
                        break
                    }
                    // 收齐了就收工。
                    if fileExpected <= 0 || fileBytes >= Int(Double(fileExpected) * 0.95) { break }
                    guard sessions < 8 else { break }
                    // ★ 设备每条会话只吐 ~50 MiB 就静默（四轮实测 48.7–50.1 MiB），
                    // 同一会话里续传它不认（19:27：重连成功、偏移正确、20 秒 0 包）。
                    // 所以这里**重开一次 1A05 会话**（新热点凭据），再带偏移续传，
                    // 把剩下那段拼回来。
                    TicNoteDiagLog.log("D3200 WIFI",
                        "file \(f.fileId): session \(sessions) ended at \(accWire)B/\(fileExpected)B — reopening 1A05 for session \(sessions + 1)")
                    if !(await restartWifiSession()) { break }
                }
                let raw = acc
                if let fileError, acc.isEmpty {
                    // 一个字节都没拿到才算这个文件失败。
                    if firstFileError == nil { firstFileError = fileError }
                    if !saved.isEmpty { break }
                    if wsFailure != nil || wsClosed { throw fileError }
                    continue
                }
                guard !raw.isEmpty else {
                    TicNoteDiagLog.log("D3200 WIFI", "file \(f.fileId): 0 bytes — skipping")
                    log.warning("file \(f.fileId, privacy: .public): no data, skipping")
                    await restartWs()
                    continue
                }
                let ogg = try SoundcoreOgg.muxRawFrames(raw)
                let isPartial = fileExpected > 0 && fileBytes < Int(Double(fileExpected) * 0.95)
                let coverage = fileExpected > 0 ? min(1, Double(fileBytes) / Double(fileExpected)) : 1
                TicNoteDiagLog.log("D3200 WIFI", "file \(f.fileId): \(raw.count)B raw → \(ogg.count)B ogg (partial=\(isPartial) coverage=\(String(format: "%.1f", coverage * 100))%)")
                saved.append(ExportedFile(
                    fileId: f.fileId,
                    raw: raw,
                    ogg: ogg,
                    partial: isPartial,
                    coverage: coverage
                ))
                log.info("file \(f.fileId, privacy: .public): \(raw.count)B raw → \(ogg.count)B ogg")

                // 不完整的文件 = 设备这条传输会话已经结束了（四次实测都是这样：
                // 之后无论重连还是发下一个文件的 1A07，设备都一个包不回）。
                // 与其再白等两分钟去撞下一文件，不如把已经到手的先交出去。
                if isPartial {
                    // ★ 2026-10-29：落盘真断点——下次点 Wi‑Fi 快传直接从这儿续，
                    // 不再从 0 开始把 90% 的成果扔掉（09:39 那轮的真实损失）。
                    saveCheckpoint(f.fileId, raw: raw, wire: fileBytes)
                    TicNoteDiagLog.log("D3200 WIFI",
                        "file \(f.fileId): incomplete — device session is done, stopping batch (lastResumeFailure=\(lastResumeFailure ?? "none"))")
                    break
                }
                clearCheckpoint(f.fileId)

                // ★ 2026-10-28：多文件必须**每个文件**发一次 1A0A 再等 600 ms
                // （飞书 `j6.java:34-63` / `s0.java:443-497`：单文件完成 → 1A0A →
                // delay 600 ms → WS 保持连接直接下一个）。原来只在最后一个文件
                // 之后发，设备那边会停在"上一个文件没结束"，第二文件及以后就永远
                // 拿不到数据——这也是"卡在传输中"的一个来源。
                if index < files.count - 1 {
                    try? await sendText(Self.transferCompleteHex(), timeoutSeconds: 3)
                    TicNoteDiagLog.log("D3200 WIFI", "file \(f.fileId): 1A0A sent, 600ms before next file")
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            }

            // ── 6. 结束会话（顺序照抄 Kotlin：FINISH → 停顿 → 1A0A）────
            try? await sendText("FINISH", timeoutSeconds: 3)
            try? await Task.sleep(nanoseconds: 200_000_000)
            try? await sendText(Self.transferCompleteHex(), timeoutSeconds: 3)
            // ★ 2026-10-29：有文件没收完时，把"恢复为什么没成"带给用户——
            // 传到 ~55 MB 断本身是设备单连接上限（预期行为），能不能传完取决于
            // 续传链路；失败原因（蓝牙断了/热点没加上/WS 连不上）才是要修的东西。
            var doneMessage = "已导出 \(saved.count)/\(files.count) 个录音"
            if lastResumeFailure != nil {
                doneMessage += "；最后一段续传未完成（\(lastResumeFailure!)），下次点快传会从断点继续"
            }
            if saved.isEmpty, let firstFileError {
                throw firstFileError
            }
            onProgress(Progress(
                phase: .done,
                message: doneMessage,
                currentFile: saved.count,
                totalFiles: files.count
            ))
            teardown()
            return saved
        } catch {
            TicNoteDiagLog.log("D3200 WIFI", "✗ export failed: \(error.localizedDescription)")
            onProgress(Progress(phase: .error, message: "导出失败：\(error.localizedDescription)"))
            teardown()
            throw error
        }
    }

    /// 字节数 → 人读文本（进度文案用）。
    static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1fMB", Double(bytes) / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.0fKB", Double(bytes) / 1_024) }
        return "\(bytes)B"
    }

    // MARK: disk checkpoint（★ 2026-10-29 真断点）

    /// 跨会话续传在 09:52 的日志里**首次跑通**（新 1A05 会话 + 1A07 带偏移，
    /// 设备从 10.4MB 处继续发，解密字节数严丝合缝）。但旧实现断点只活在内存里：
    /// 导出结束/杀 App 就没了，下次点快传又从 0 开始——用户 90% 的成果直接报废。
    /// 现在把没收完的 raw + 线缆偏移落盘（Documents/wifi-resume/<fileId>.partial
    /// + .meta 文本"fileId wire"），下次导出同一文件直接续。
    private func checkpointURL(_ fileId: UInt32) -> (data: URL, meta: URL) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wifi-resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = dir.appendingPathComponent("\(fileId).partial")
        return (base, base.appendingPathExtension("meta"))
    }

    private func loadCheckpoint(_ fileId: UInt32) -> (raw: Data, wire: Int)? {
        let urls = checkpointURL(fileId)
        guard let metaText = try? String(contentsOf: urls.meta, encoding: .utf8) else { return nil }
        let parts = metaText.split(separator: " ")
        guard parts.count == 2, parts[0] == "\(fileId)",
              let wire = Int(parts[1]), wire > 0,
              let raw = try? Data(contentsOf: urls.data), !raw.isEmpty else {
            try? FileManager.default.removeItem(at: urls.data)
            try? FileManager.default.removeItem(at: urls.meta)
            return nil
        }
        return (raw, wire)
    }

    private func saveCheckpoint(_ fileId: UInt32, raw: Data, wire: Int) {
        guard !raw.isEmpty, wire > 0 else { return }
        let urls = checkpointURL(fileId)
        try? raw.write(to: urls.data, options: .atomic)
        try? "\(fileId) \(wire)".write(to: urls.meta, atomically: true, encoding: .utf8)
        TicNoteDiagLog.log("D3200 WIFI", "file \(fileId): checkpoint saved \(wire)B wire / \(raw.count)B raw")
    }

    private func clearCheckpoint(_ fileId: UInt32) {
        let urls = checkpointURL(fileId)
        try? FileManager.default.removeItem(at: urls.data)
        try? FileManager.default.removeItem(at: urls.meta)
    }

    /// Abort the export in progress (best effort).
    func cancel() {
        cancelled = true
    }

    // MARK: hotspot join (step 3)

    /// 加入豆的热点。
    ///
    /// ★ 2026-10-27（用户："WiFi 快传点击提示无法加入网络"）：豆收到 1A05 后
    /// 要几秒才能把 SoftAP 广播出来，**立刻 apply 会被系统以"无法加入网络"拒绝**
    /// （SSID 还不存在）。所以带间隔重试；但两种情况**立即失败**，重试毫无意义：
    ///  - `userDenied` / `applicationIsNotInForeground` → 用户在系统弹窗点了不允许；
    ///  - `invalidSSID` / `invalidWPAPassphrase` → 凭据本身不合法（固件口径变了）。
    /// 这两种直接把原因抛出去，不再盲试 6 次给用户看 40 秒转圈。
    ///
    /// ★ 2026-10-28（用户："iOS 还是无法继续使用，Android 可以"）：补两件事——
    ///  ① `apply` 返回成功**不代表真的连上了**（DHCP 也可能失败），用
    ///     `NEHotspotNetwork.fetchCurrent` 核对当前 SSID，没连上就继续重试；
    ///  ② 全部失败时不再"假装继续"去连 WS（白等 60 秒），直接抛出一条**可执行**
    ///     的指引：手动加入哪个 SSID、密码是多少。Android 能过、iOS 过不去，
    ///     说明固件的 AP 对 iOS 的自动加入不友好，手动加入是确定的通路。
    /// - Parameter reuseExisting: ★ 2026-10-29（用户："只要一次点击加入即可"）：
    ///   重开会话时**凭据与上次相同**——此时系统里已有这套配置，不再 remove/重建
    ///   （那会触发系统重新授权），先把等待缩短到 5 s，然后**先查是否还挂在热点上**，
    ///   挂着就直接返回（省 20 s 重入网）；`joinOnce` 也改为 false，让系统自动回连。
    private func joinDeviceAp(ssid: String, psk: String, reuseExisting: Bool = false) async throws {
        if reuseExisting {
            if await isOnNetwork(ssid) {
                TicNoteDiagLog.log("D3200 WIFI", "hotspot \(ssid) still joined — skipping re-apply")
                hotspotApplySucceeded = true
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if await isOnNetwork(ssid) {
                TicNoteDiagLog.log("D3200 WIFI", "hotspot \(ssid) rejoined automatically (existing config)")
                hotspotApplySucceeded = true
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return
            }
        } else {
            // ① 先给豆时间把 AP 广播出来（1A05 只是"开始开热点"）。
            // ★ 2026-10-28（飞书 8.3.6 反编译实锤）：官方 App 在发完 1A05 后默认等
            // **10 秒**才去连热点（`wifiConnectionDelayMS`，SDKInitConfig 默认
            // 10000ms，SDKManagerImp r.java:748-750 / D3200Device.Q0）——这就是
            // "飞书的 WiFi 快传在手机上连得非常慢"的真相：不是连得慢，是故意等豆
            // 把 SoftAP 完全起好再动手。我们原来只等 3 s，"无法加入网络"的高发
            // 正是撞在这 3 s 上（AP 还没广播出来，NEHotspotConfiguration 直接拒）。
            // ★ 2026-10-30：**先把同名残留配置摘掉再等**——上一次 apply 失败留下
            // 的"半死配置"会让下一次 apply 在豆 AP 还没起来时白白关联、撞出系统
            // 级"无法加入网络"弹窗（App 拦不掉，只能别去撞）。摘掉后 iOS 不再
            // 对着一个不存在的 SSID 空转，10 s 后豆 AP 起好了再干净地 apply。
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }

        var lastCode: Int?
        // ★ 2026-10-30：连续"apply 成功但没连上"的次数——就是系统弹
        // "无法加入网络"的那条路径（豆 AP 还没起好，关联失败）。
        var notJoinedStreak = 0
        // ★ 2026-10-30：4→5 次。重开会话后豆的 SoftAP 起得比首连慢（14:12 截图
        // 的"无法加入网络"就发生在这里），多一次机会换更高的一次成功率。
        for attempt in 1...5 {
            if cancelled { throw WifiExportError(message: "已取消") }
            // 每次都先移除旧配置：同一 SSID 残留的失败配置会让下一次 apply 直接被拒。
            // ★ 复用凭据时**不 remove**——移除再重加会触发系统重新授权（多弹一次）。
            // ★★ 关联失败过（apply ok 但没连上）也摘——系统弹"无法加入网络"后，
            //     残留的就是这种毒配置，不清掉下一发大概率重蹈覆辙。
            if !reuseExisting || notJoinedStreak > 0 {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
            let config = NEHotspotConfiguration(ssid: ssid, passphrase: psk, isWEP: false)
            // ★ joinOnce=false：配置在会话期间常驻，豆重开热点后系统自动回连；
            // 导出结束 teardown() 会显式 removeConfiguration 清掉。
            config.joinOnce = false
            let error: Error? = await withCheckedContinuation { cont in
                NEHotspotConfigurationManager.shared.apply(config) { cont.resume(returning: $0) }
            }
            if let error {
                lastCode = (error as NSError).code
                TicNoteDiagLog.log("D3200 WIFI", "hotspot apply attempt \(attempt) failed code=\(lastCode ?? -1)")
                log.warning("hotspot apply attempt \(attempt, privacy: .public) failed code=\(lastCode ?? -1, privacy: .public): \(String(describing: error), privacy: .public)")
                switch lastCode {
                case 1: throw WifiExportError(message: "热点名「\(ssid)」不被系统接受（invalidSSID）——豆的固件口径可能变了")
                case 2, 3: throw WifiExportError(message: "热点密码不被系统接受（invalidPassphrase）——豆的固件口径可能变了")
                case 7: throw WifiExportError(message: "你在系统弹窗里拒绝了加入「\(ssid)」。想用快传请在弹窗点\"加入\"，或在 设置 → 无线局域网 手动加入该热点")
                case 8: throw WifiExportError(message: "加入热点的请求必须在 App 前台发起，请回到 Nomily 重试")
                default: break
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            // ② apply 说成功 ≠ 已连上：等 DHCP 后核对 SSID。
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if await isOnNetwork(ssid) {
                hotspotApplySucceeded = true
                TicNoteDiagLog.log("D3200 WIFI", "hotspot joined ssid=\(ssid) (attempt \(attempt))")
                log.info("hotspot joined (ssid=\(ssid, privacy: .public), attempt=\(attempt, privacy: .public))")
                try? await Task.sleep(nanoseconds: 2_000_000_000) // DHCP 稳定期
                return
            }
            // ★ 2026-10-30：走到这里 = 关联失败，iOS 刚弹过（或即将弹）
            // "无法加入网络"。豆的 SoftAP 大概率还在重启中——**退避 8 s**
            // 让它起稳再试，同时清掉这次失败留下的毒配置（下一次循环头部）。
            notJoinedStreak += 1
            TicNoteDiagLog.log("D3200 WIFI",
                "hotspot apply ok but not on \(ssid) (attempt \(attempt), streak=\(notJoinedStreak)) — AP not ready, backing off 8s")
            log.warning("hotspot apply returned ok but current network is not \(ssid, privacy: .public) — retrying after 8s backoff")
            onStageNote?(notJoinedStreak >= 2
                ? "豆的热点还没就绪（系统弹的「无法加入网络」点掉即可），正在等它起稳再试…"
                : "正在等待录音豆的热点就绪…")
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }

        hotspotApplySucceeded = false
        // ★ 2026-10-30：全程"apply 成功但一次都没关联上"= AP 压根没起来，
        // 跟"TCP 探测全败"同性质的会话级死亡——标 isJoinDead 让上层自动
        // 重开会话（换新 SSID，8 s 后自动再来），别把用户丢在弹窗上。
        if notJoinedStreak >= 3 {
            throw WifiExportError(
                message: "录音豆的热点「\(ssid)」迟迟没有就绪（连续 \(notJoinedStreak) 次关联失败）。" +
                    "系统弹的「无法加入网络」点掉即可，Nomily 会自动换新热点再试。",
                isJoinDead: true
            )
        }

        // ③ 自动加入失败 → 请用户手动加入（同一次会话内）。iOS 对这类固件 AP 的
        //    自动加入成功率不高，而手动加入是确定通路；此时豆的热点还开着
        //    （teardown 也会跳过 closeWifiMode，见 manualJoinInProgress）。
        if let onNeedManualJoin {
            manualJoinInProgress = true
            TicNoteDiagLog.log("D3200 WIFI", "auto-join failed — asking user to join \(ssid) manually")
            await onNeedManualJoin(ssid, psk)
            // 轮询确认：用户可能在设置里加完就回来了（期间 App 被挂起，回来时
            // Date() 已过 deadline —— 所以循环后再单独补一次终检）。
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline, !cancelled {
                if await isOnNetwork(ssid) {
                    manualJoinInProgress = false
                    hotspotApplySucceeded = true
                    TicNoteDiagLog.log("D3200 WIFI", "manual join confirmed for \(ssid)")
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // DHCP 稳定期
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if !cancelled, await isOnNetwork(ssid) {
                manualJoinInProgress = false
                hotspotApplySucceeded = true
                TicNoteDiagLog.log("D3200 WIFI", "manual join confirmed for \(ssid) (after deadline)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return
            }
            manualJoinInProgress = false
        }

        throw WifiExportError(message:
            "iOS 没能自动加入录音豆热点「\(ssid)」（已尝试 5 次\(lastCode.map { "，最后错误码 \($0)" } ?? "")。" +
            "请手动加入后重试：设置 → 无线局域网 → 选择「\(ssid)」，密码 \(psk) —— " +
            "连上后回到 Nomily 再点一次快传。若列表里看不到该热点：让豆保持亮灯/靠近手机，等 10 秒再刷新。")
    }

    /// 当前 Wi-Fi 是不是就是这台豆的热点。`fetchCurrent` 在无"访问 Wi-Fi 信息"
    /// 权限时会返回 nil——那只说明"查不到"，不能当成"没连上"（否则会把正常
    /// 流程判死），此时按已加入处理。
    private func isOnNetwork(_ ssid: String) async -> Bool {
        let current: NEHotspotNetwork? = await withCheckedContinuation { cont in
            NEHotspotNetwork.fetchCurrent { cont.resume(returning: $0) }
        }
        guard let current else { return true }
        return current.ssid == ssid
    }

    // MARK: - Hotspot config history（★ 2026-10-29 "WiFi 加入失败"）

    /// App 给豆下发的 SSID 每次导出都是新的（"WiFi-<ms>"，官方口径），而
    /// `joinOnce=false` 的配置会常驻系统——不清理的话 iOS 会在豆开新热点前
    /// 反复自动回连**已经死掉的旧热点**，把新一轮 join 拖死。这里把"本 App
    /// 配过的豆热点名"记在 UserDefaults，每轮开始时清掉除本轮外的全部。
    private static let hotspotHistoryKey = "soundcore.wifi.ssid_history"

    private static func rememberHotspotSSID(_ ssid: String) {
        var list = UserDefaults.standard.stringArray(forKey: hotspotHistoryKey) ?? []
        if !list.contains(ssid) {
            list.append(ssid)
            UserDefaults.standard.set(list, forKey: hotspotHistoryKey)
        }
    }

    private static func cleanupPreviousHotspotConfigs(keeping current: String) {
        let defaults = UserDefaults.standard
        let history = defaults.stringArray(forKey: hotspotHistoryKey) ?? []
        for old in history where old != current {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: old)
            TicNoteDiagLog.log("D3200 WIFI", "removed stale hotspot config for \(old)")
        }
        defaults.set([current], forKey: hotspotHistoryKey)
    }

    // MARK: WebSocket (step 4)

    /// 重建 WS 会话（换了/哑了的时候用）。
    ///
    /// 2026-10-28 实测：一个 60 MB 的大文件传到 91% 时设备停发，我们发出
    /// 1A0A 之后**同一条 WS 上再发 1A07，设备 24 秒一个包都不回**——这条
    /// 会话在设备侧已经作废。只有断开重连才能继续后面的文件。这里只重建
    /// WS（热点不动、BLE 不动），失败就保持原状由上层报错。
    private func restartWs() async {
        guard let ep = lastEndpoint, !cancelled else { return }
        stopWsPing()
        stopKeepalive()
        ws?.cancel(with: .goingAway, reason: nil)
        wsSession?.invalidateAndCancel()
        ws = nil
        wsSession = nil
        wsFailure = nil
        wsClosed = false
        openSignalled = false
        parser.reset()
        // 只做**快速**重连：wss 一次、ws 一次。复用 connectWs 的话是
        // 3 次 × 2 协议 × 10 s 超时 ≈ 最长 70 s——设备已经不理我们的时候
        // （19:20 那轮后续 6 次全超时）纯属白等两分钟。
        for scheme in ["wss", "ws"] {
            if cancelled { return }
            do {
                try await openWs(endpoint: ep, scheme: scheme)
                startKeepalive(ip: ep.ip)
                startWsPing()
                TicNoteDiagLog.log("D3200 WIFI", "ws restarted \(ep.ip):\(ep.port) (\(scheme))")
                return
            } catch {
                TicNoteDiagLog.log("D3200 WIFI", "ws restart \(scheme) failed: \(error.localizedDescription)")
                ws?.cancel(with: .goingAway, reason: nil)
                ws = nil
                wsFailure = nil
                wsClosed = false
                openSignalled = false
            }
        }
        TicNoteDiagLog.log("D3200 WIFI", "ws restart gave up \(ep.ip):\(ep.port)")
    }

    /// 重开一次 Wi‑Fi 传输会话：重新发 1A05（新 SSID/密码 → 豆重启热点）→ 加入新热点
    /// → 连上 WS。**不动 BLE 以外的东西**，凭据与首次完全同一套规则。
    ///
    /// ★ 2026-10-28：同一 AP 会话里续传，设备一个包都不回（19:27 实测：重连成功、
    /// `1A07` 带对偏移发出去，20 秒 0 包）。而每次用户手点重试都会走一遍 1A05，
    /// 新会话照样能正常传——说明设备的"文件传输状态机"是绑在 1A05 会话上的。
    /// 所以要拿剩下那段，只能重开会话，再带偏移请求。
    private func restartWifiSession() async -> Bool {
        lastResumeFailure = nil
        // ★ 2026-10-29：1A05 只能走蓝牙下发。09:21 实测：传到 92.6% 触发续传时
        // BLE 已断（"soundcore 设备未连接"），续传当场死掉。先尽力把蓝牙接回来
        // （重连通常产出新 client——旧的那个已经死了）。
        if let onNeedBleReconnect {
            TicNoteDiagLog.log("D3200 WIFI", "restart: ensuring BLE link before 1A05")
            onStageNote?("蓝牙断了，正在重连录音豆…")
            var fresh = await onNeedBleReconnect()
            if fresh == nil {
                // ★ 2026-10-29（13:46 实锤：3 次×25 s 共 150 s 重连全失败）：
                // 豆的蓝牙迟迟不回来，最可能是**手机还挂在它的热点上**——
                // 只要有客户端连着，豆的 Wi‑Fi 模式就不超时退出，蓝牙广播一直
                // 不恢复。对策：把手机从豆的热点上摘下来（移除热点配置），
                // 豆发现 AP 空了会自己关 Wi‑Fi 模式回到普通模式，蓝牙才回来。
                // 等 12 s 再试一轮；BLE 回来后 1A05 + joinDeviceAp 会重新挂热点。
                TicNoteDiagLog.log("D3200 WIFI",
                    "restart: BLE still down — dropping hotspot config so the bean can exit Wi‑Fi mode")
                if let ssid {
                    NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
                }
                onStageNote?("蓝牙还没回来，正在让豆退出 Wi‑Fi 模式（约 12 秒）…")
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                fresh = await onNeedBleReconnect()
            }
            guard let fresh else {
                lastResumeFailure = "蓝牙已断开且重连失败，无法重开传输会话"
                TicNoteDiagLog.log("D3200 WIFI", "restart: BLE link unavailable — cannot re-issue 1A05")
                return false
            }
            if fresh !== client {
                TicNoteDiagLog.log("D3200 WIFI", "restart: BLE reconnected with a fresh client — switching over")
                client = fresh
            }
        }
        // ★★ 2026-10-30（10:33–10:40 日志实锤）：复用凭据重发 1A05 **100% 被拒**
        // （"1A05 reply too short: 10B"）——豆的传输状态机绑在 1A05 会话上，在旧
        // 热点名上重开必吃 10 B 短帧；随后沿用旧 endpoint 的 TCP 5 次探测也全败。
        // 而**换新 SSID 的 1A05 每次都成功**（14:03 / 14:06 / 15:10 / 15:45，以及
        // 10:39 用户手点重试，attempt 1 全过）。所以重开不再先试复用，直接走这条
        // 被反复验证有效的新 SSID 通路——省掉一轮注定失败的 1A05 + ~30 s 白探测。
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        let newSSID = "WiFi-\(ms)"
        let newPsk = "\(ms)"
        TicNoteDiagLog.log("D3200 WIFI", "restarting wifi session with FRESH ssid=\(newSSID) (reuse attempt always rejected by bean — skipped)")
        onStageNote?("正在重开录音豆的传输会话（约 1 分钟）…")
        // 旧连接先收干净
        stopWsPing()
        stopKeepalive()
        ws?.cancel(with: .goingAway, reason: nil)
        wsSession?.invalidateAndCancel()
        ws = nil
        wsSession = nil
        wsFailure = nil
        wsClosed = false
        openSignalled = false
        wsFailureLogged = false
        parser.reset()
        // 旧热点配置摘掉：豆要开新名，旧的那份只会让 iOS 回连死网络。
        if let old = ssid {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: old)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 豆吐旧 AP 缓冲
        do {
            let ep = try await client.startWifiExport(ssid: newSSID, psk: newPsk)
            lastEndpoint = ep
            // 把新名记进历史（下轮开始时统一清理）。
            Self.rememberHotspotSSID(newSSID)
            ssid = newSSID
            lastPsk = newPsk
            onSessionStart?(newSSID, newPsk)
            onStageNote?("正在接入录音豆新热点…")
            try await joinDeviceAp(ssid: newSSID, psk: newPsk)
            onStageNote?("正在重新连接传输通道…")
            try await connectWs(endpoint: ep)
            startKeepalive(ip: ep.ip)
            startWsPing()
            TicNoteDiagLog.log("D3200 WIFI", "wifi session restarted \(ep.ip):\(ep.port) ssid=\(newSSID)")
            return true
        } catch {
            lastResumeFailure = "重开传输会话失败：\(error.localizedDescription)"
            TicNoteDiagLog.log("D3200 WIFI", "wifi session restart failed: \(error.localizedDescription)")
            return false
        }
    }

    private func connectWs(endpoint: SoundcoreClient.WifiEndpoint) async throws {
        var lastError: Error?
        // ★ 2026-10-29（09:54 实测）：豆的传输模块卡死后 TCP 443 根本不通，但旧
        // 代码仍然 wss×3 + ws×3 白等 70 秒才报错（用户看两次"连接 WiFi 失败"）。
        // 先绑 Wi‑Fi 接口做 TCP 预探测；通 → 才去试 WebSocket。
        // ★ 2026-10-29 第二轮（15:10 日志：加入成功但 443 不通）：豆的传输服务
        // 在 AP 广播出来之后**还要更久才监听**（反复重开会话时尤其慢），3 s×2 的
        // 快速失败会把"还在启动"判成"死了"。放宽到 5 次 × 5 s（≈30 s），
        // 仍不通才标记 isTCPDead 交给上层自动重开会话。
        var probesOK = false
        // ★ 2026-10-30：探测间隔 5s×5 → **2s×3 + 5s×2**。日志（10:33）显示服务真死
        // 时探测是"立刻拒连"，5 s 间隔纯属白等；而服务"还在启动"时需要总窗口 ~30 s，
        // 所以只收紧前 3 次——真死更快判死进重开，慢启动不被误杀。
        probeLoop: for probeAttempt in 1...5 {
            if cancelled { throw WifiExportError(message: "已取消") }
            if await probeTcp(ip: endpoint.ip, port: UInt16(endpoint.port)) {
                probesOK = true
                break probeLoop
            }
            if probeAttempt < 5 {
                try? await Task.sleep(nanoseconds: probeAttempt <= 3 ? 2_000_000_000 : 5_000_000_000)
            }
        }
        if !probesOK {
            TicNoteDiagLog.log("D3200 WIFI", "tcp pre-probe \(endpoint.ip):\(endpoint.port) failed ×5 — service dead, escalating")
            throw WifiExportError(
                message:
                    "连不上录音豆的 Wi‑Fi 服务 \(endpoint.ip):\(endpoint.port)（TCP 探测五次都不通）——" +
                    "豆的热点已加入，但传输服务没有响应。请：① 给录音豆充充电——电量低时豆会频繁掐断传输；" +
                    "② 还不行就把豆重启再试。",
                isTCPDead: true
            )
        }
        // 规格书 §8.3 ④：`wss://` 优先，失败回落 `ws://`（固件/端口组合两种都可能）。
        for scheme in ["wss", "ws"] {
            for attempt in 1...3 {
                if cancelled { throw WifiExportError(message: "已取消") }
                do {
                    try await openWs(endpoint: endpoint, scheme: scheme)
                    TicNoteDiagLog.log("D3200 WIFI", "ws \(scheme)://\(endpoint.ip):\(endpoint.port) connected (attempt \(attempt))")
                    log.info("WS connected \(scheme, privacy: .public)://\(endpoint.ip, privacy: .public):\(endpoint.port, privacy: .public) (attempt \(attempt, privacy: .public))")
                    return
                } catch {
                    lastError = error
                    TicNoteDiagLog.log("D3200 WIFI", "ws \(scheme) attempt \(attempt) failed: \(String(describing: error))")
                    log.warning("WS \(scheme, privacy: .public) attempt \(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    ws?.cancel(with: .goingAway, reason: nil)
                    ws = nil
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        // 两种 scheme 都失败 → 做一次"绑定 Wi-Fi 接口"的 TCP 探测，把原因说清楚。
        let tcpOK = await probeTcp(ip: endpoint.ip, port: UInt16(endpoint.port))
        TicNoteDiagLog.log("D3200 WIFI", "tcp probe \(endpoint.ip):\(endpoint.port) over Wi-Fi → \(tcpOK)")
        let reason = tcpOK
            ? "TCP 能通但 WebSocket 握不上（固件协议可能有变化）"
            : "连不上录像豆的 Wi‑Fi 服务 \(endpoint.ip):\(endpoint.port)——多半是热点没真正加入，或被系统权限拦住"
        let manualHint = hotspotApplySucceeded
            ? "。可在 设置 → 无线局域网 手动加入热点「\(ssid ?? "")」后重试"
            : "。系统没允许自动加入热点"
        throw WifiExportError(message:
            "WebSocket 连接失败：\(lastError?.localizedDescription ?? "未知错误")。\(reason)" +
            "。请确认：① 系统弹窗允许加入「\(ssid ?? "")」；② 设置 → 隐私与安全性 → 本地网络 里 Nomily 是打开的；" +
            "③ 录音豆在附近、电量充足，且未被飞书 App 占用\(manualHint)")
    }

    /// 绑定 Wi-Fi 接口探测 ip:port 是否可达 —— 只为把错误原因说清楚
    /// （URLSession 没有"只走 Wi-Fi"的公开开关，NWConnection 有）。
    private func probeTcp(ip: String, port: UInt16) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi
        params.prohibitedInterfaceTypes = [.cellular]
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: params)
        let result: Bool = await withCheckedContinuation { cont in
            var resumed = false
            func finish(_ ok: Bool) {
                guard !resumed else { return }
                resumed = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { finish(false) }
        }
        log.info("TCP probe \(ip, privacy: .public):\(port, privacy: .public) over Wi-Fi → \(result, privacy: .public)")
        return result
    }

    private func openWs(endpoint: SoundcoreClient.WifiEndpoint, scheme: String) async throws {
        let delegate = WsDelegate(exporter: self)
        let config = URLSessionConfiguration.default
        // 只走 Wi-Fi：热点没有外网，别让系统把请求丢给蜂窝（那样必然连不上内网 IP）。
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = Self.wsReadyTimeout
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        wsSession = session
        guard let url = URL(string: "\(scheme)://\(endpoint.ip):\(endpoint.port)") else {
            throw WifiExportError(message: "热点地址不合法：\(endpoint.ip):\(endpoint.port)")
        }
        var request = URLRequest(url: url)
        // 固件校验 SDK 握手形状（Android 端 okhttp UA）。iOS 的 URLSession
        // 允许按请求覆盖 User-Agent —— 若被系统忽略，握手上没有其他差异，
        // 连接仍应成功（与 Android 参考实现的已知偏差，见报告）。
        request.setValue("okhttp/3.12.13.18", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.wsReadyTimeout

        openSignalled = false
        wsFailure = nil
        wsClosed = false
        wsFailureLogged = false
        let task = session.webSocketTask(with: request)
        ws = task
        task.resume()

        let deadline = Date().addingTimeInterval(Self.wsReadyTimeout)
        while !openSignalled && wsFailure == nil && !wsClosed && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if let failure = wsFailure { throw failure }
        guard openSignalled else { throw WifiExportError(message: "WebSocket 连接超时（\(scheme)）") }
        receiveNext()
    }

    /// Re-arm the single outstanding `receive` (URLSessionWebSocketTask is
    /// one-shot per receive call).
    private func receiveNext() {
        ws?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    // ★ 2026-10-28：**先重新挂上 receive 再处理**。URLSession 的
                    // receive 是一次性的，处理完再挂意味着解析这几毫秒里 socket
                    // 是"没人读"的状态；大文件连续下发时会累积成 TCP 反压，设备
                    // 发送端被堵住（真机上就表现为"传到某个点突然不动"）。
                    self.receiveNext()
                    switch message {
                    case .string(let text):
                        self.wsMessages += 1
                        self.wsBytesIn += text.utf8.count
                        if self.firstMessageKind == "none" { self.firstMessageKind = "text(\(text.prefix(16)))" }
                        self.dumpFrameIfNeeded(label: "text", bytes: Data(text.utf8))
                        self.handleWsText(text)
                    case .data(let data):
                        self.wsMessages += 1
                        self.wsBytesIn += data.count
                        if self.firstMessageKind == "none" { self.firstMessageKind = "binary(\(data.count)B)" }
                        self.dumpFrameIfNeeded(label: "binary", bytes: data)
                        self.handleWsBytes(data)
                    @unknown default:
                        break
                    }
                    // ★ 2026-10-28 修 Bug：这里**不能再挂一次** receive。
                    // 上面已经先挂过了；两处都挂 → 每来一条消息就多一个待收请求，
                    // 13,589 条之后堆了上万个，收帧开始变慢、关闭时刷屏几十条
                    // `Socket未连接`。一条消息只允许一个 outstanding receive。
                case .failure(let error):
                    // ★ 2026-10-30：socket 死后这里可能被连环回调（19:20 实测
                    // 16 ms 1000+ 条），每条 socket 只记一次，然后**立刻掐掉
                    // socket**——不再让死连接继续吐失败事件；传输循环靠
                    // `wsFailure` 走会话重开。
                    guard !self.wsFailureLogged else { return }
                    self.wsFailureLogged = true
                    log.warning("WS receive failed: \(String(describing: error), privacy: .public)")
                    TicNoteDiagLog.log("D3200 WIFI", "ws receive FAILED: \(error.localizedDescription) (msgs=\(self.wsMessages) in=\(self.wsBytesIn)B)")
                    self.wsFailure = error
                    self.ws?.cancel(with: .goingAway, reason: nil)
                    self.ws = nil
                }
            }
        }
    }

    // MARK: UDP keepalive

    /// ★ 2026-10-29：UDP 保活开关。官方 iOS 不发（见 startKeepalive 注释）；
    /// A/B 出问题就改回 true 对比。
    private static let sendsUdpKeepalive = false

    private func startKeepalive(ip: String) {
        stopKeepalive()
        // ★ 2026-10-29（rea 逆向 A/B，文档 §3/§7）：飞书 KMP 在 `platform()=="iOS"`
        // 时**直接 continue 跳过 UDP 保活**（obf.y5.q smali 实锤），官方 iOS 端只靠
        // WS ping/pong 维持。Nomily 之前每 100 ms 发一发（比 Android 官方常用值还密
        // 20 倍），而真机症状恰是"豆传到一半哑掉、seq 疯跳、WS 被掐"——逆向文档
        // 明确建议"遇设备侧异常可尝试关掉对比"。现在**与官方 iOS 行为完全一致**：
        // 不发 UDP。要 A/B 回切，把 sendsUdpKeepalive 改 true 即可。
        guard Self.sendsUdpKeepalive else {
            TicNoteDiagLog.log("D3200 WIFI",
                "udp keepalive disabled (official iOS behavior: WS ping/pong only)")
            return
        }
        // ★ 2026-10-28：显式钉在 Wi‑Fi 上。热点没有外网，系统默认路由可能还是
        // 蜂窝；虽然目标地址只在热点网段可达，钉住接口能排除"保活包发错网卡"
        // 这一类不确定因素（Android 侧同样是把 socket bind 到热点 Network）。
        let params = NWParameters.udp
        params.requiredInterfaceType = .wifi
        let conn = NWConnection(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(rawValue: Self.keepalivePort)!,
            using: params
        )
        keepaliveConnection = conn
        conn.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                log.warning("UDP keepalive failed: \(String(describing: error), privacy: .public)")
                TicNoteDiagLog.log("D3200 WIFI", "udp keepalive failed: \(error.localizedDescription)")
            }
        }
        conn.start(queue: .global(qos: .utility))
        keepaliveTask = Task { [weak self] in
            let payload = Data("soundcore-keep-alive-unicast".utf8)
            var sent = 0
            while !Task.isCancelled {
                sent += 1
                self?.keepaliveConnection?.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        log.warning("UDP keepalive send failed: \(String(describing: error), privacy: .public)")
                    }
                })
                if sent % 300 == 0 {
                    // 每 ~30 s 一条，证明保活在跑（也是"设备静默"时的现场证据）。
                    TicNoteDiagLog.log("D3200 WIFI", "udp keepalive sent=\(sent)")
                }
                // ★ 2026-10-28：飞书 SDK 的 UDP 保活默认 **100 ms** 一次
                // （SDKInitConfig.androidUDPPingTimeIntval 默认值）。这里原来是 2 s，
                // 若固件以"最近有没有收到保活"作为放行条件，2 s 太稀。
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        keepaliveConnection?.cancel()
        keepaliveConnection = nil
    }

    /// 每 5 s 一条 `ping` 文本帧（规格书 §8.3 的保活口径）。设备回什么由
    /// `handleWsText` 记日志；发送失败不影响主流程。
    private func startWsPing() {
        stopWsPing()
        wsPingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                guard let self, let ws = self.ws else { return }
                try? await ws.send(.string("ping"))
            }
        }
    }

    private func stopWsPing() {
        wsPingTask?.cancel()
        wsPingTask = nil
    }

    // MARK: per-file transfer (step 5)

    private func pullOverWs(
        fileId: UInt32,
        knownSize: Int,
        seed: Data = Data(),
        startOffset: Int = 0,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> Data {
        // seed/startOffset：换一次 1A05 会话之后继续同一个文件用——缓冲区不清空，
        // 1A07 直接带上已收的线缆字节数。
        fileBuf = seed
        fileBytes = startOffset
        fileExpected = knownSize
        activeFileId = fileId
        decryptOn = client.crypto.hasFileDecryptor(fileId)
        headSignalled = false
        doneSignalled = false
        wsMessages = 0
        wsBytesIn = 0
        firstMessageKind = "none"
        nextSeq = -1
        seqJumps = 0
        resumeSeqResetPending = false
        resumeIgnored = false
        // 上一个文件的半包留在解析缓冲里会把新文件的帧切歪——换文件先清空。
        parser.reset()

        try await sendHeadRequest(
            hex: Self.headRequestHex(fileId: fileId, transferred: startOffset),
            fileId: fileId)
        TicNoteDiagLog.log("D3200 WIFI",
            "pull start file=\(fileId) expected=\(fileExpected) from=\(startOffset) seed=\(seed.count)B")

        // ★ 2026-10-28（用户："大文件传输还是没完成"）：真机两轮日志放在一起看——
        //   19:00 那轮 socket 收 55,137,267 B 后停；
        //   19:12 那轮 socket 收 54,701,921 B 后停；
        // 而文件是 60,149,602 B。**每次都在 socket ≈55 MB 处断**，不是丢包、不是
        // 我们解析不过来，是单条 WS 连接的传输上限。所以"原地重发 1A07"没用
        // （19:12:59 试过，同一条连接上设备直接哑掉），必须**换一条新连接再续传**：
        // 断开 WS → 重连 → 1A07 带 transferredSize = 已收字节数 → 继续往同一缓冲区追加。
        // 60 MB 的文件因此会 55 MB + 5 MB 跨两条连接拼完；再大就多拼几条（上限 8 条）。
        var lastBytes = 0
        var lastGrowth = Date()
        var firstByteDeadline = Date().addingTimeInterval(12)
        var headResent = false
        var firstProgressReport = Date()
        var lastHeartbeat = Date()
        var resumes = 0
        var resumeStartBytes = 0
        // ★ 2026-10-29：8→4。每次"续传"现在都是重开一次 1A05 会话（1–2 分钟），
        // 60 MB 文件正常只需要 1 次；4 次已兜住"豆状态差"的最坏情况。
        let maxResumes = 4
        let stallWindow: TimeInterval = 20

        while true {
            if doneSignalled { break }
            if fileExpected > 0 && fileBytes >= fileExpected { break }
            if cancelled { break }
            if let failure = wsFailure {
                // ★ 2026-10-29（09:35 实测）：设备中途把 WS 干掉（16 MB 处"网络
                // 连接已中断"）时，旧代码直接 throw——调用方只拿到 seed（空），
                // **已收的 16 MB 全丢**。现在改成 break 返回已收部分：exportAll
                // 把它当"本会话到此为止"，重开 1A05 会话带偏移续传。
                TicNoteDiagLog.log("D3200 WIFI",
                    "file \(fileId): ws failed mid-stream at \(fileBytes)B/\(fileExpected)B (\(failure.localizedDescription)) — returning partial for session resume")
                break
            }
            if wsClosed {
                TicNoteDiagLog.log("D3200 WIFI",
                    "file \(fileId): device closed ws at \(fileBytes)B/\(fileExpected)B — returning partial for session resume")
                break
            }

            if fileBytes != lastBytes {
                lastBytes = fileBytes
                lastGrowth = Date()
                if Date().timeIntervalSince(firstProgressReport) >= 1 {
                    firstProgressReport = Date()
                    onProgress?(fileBytes, max(fileExpected, fileBytes))
                }
            }

            let now = Date()
            // 每 5 s 一条心跳进诊断文件——即使不失败，也能看出"发了没/收了多少"。
            if now.timeIntervalSince(lastHeartbeat) >= 5 {
                lastHeartbeat = now
                TicNoteDiagLog.log("D3200 WIFI",
                    "waiting file \(fileId): \(fileBytes)B/\(fileExpected)B msgs=\(wsMessages) in=\(wsBytesIn)B head=\(headSignalled) decrypt=\(decryptOn) seqJumps=\(seqJumps) resumes=\(resumes) parsed=\(parser.parsedPackets) bad=\(parser.checksumRejects) tail=\(parser.discardedBytes)")
            }
            if fileBytes == 0 {
                if now >= firstByteDeadline {
                    if !headResent {
                        headResent = true
                        TicNoteDiagLog.log("D3200 WIFI",
                            "file \(fileId): no bytes in 12s (msgs=\(wsMessages) head=\(headSignalled) kind=\(firstMessageKind)) — resending 1A07")
                        try? await sendHeadRequest(hex: Self.headRequestHex(fileId: fileId, transferred: 0), fileId: fileId)
                        firstByteDeadline = Date().addingTimeInterval(12)
                    } else {
                        throw WifiExportError(message:
                            "设备没有开始回传文件 \(fileId)：24 秒内 0 字节（已重发一次 1A07；收到 \(wsMessages) 条 WS 消息，首帧 \(firstMessageKind)，文件头 \(headSignalled ? "有" : "无")）。")
                    }
                }
            } else if now.timeIntervalSince(lastGrowth) >= stallWindow {
                // 这条连接已经吐完了（实测socket ≈55 MB 就到头）。换连接 + 续传。
                //
                // 两个"别白烧流量"的保险：
                //  ① 上一次重连之后一个字节都没多收 → 说明换连接也没用，停；
                //  ② 设备无视 transferredSize、从头重发（writeSlices 会置位
                //     resumeIgnored）→ 再重连也只会重复传同一段，停。
                if resumeIgnored || (resumes > 0 && fileBytes <= resumeStartBytes) {
                    // 设备无视了断点偏移（从头重发）→ 磁盘断点已作废，删掉。
                    if resumeIgnored { clearCheckpoint(fileId) }
                    TicNoteDiagLog.log("D3200 WIFI",
                        "file \(fileId): stop reconnecting (ignored=\(resumeIgnored) prevGain=\(fileBytes - resumeStartBytes)B)")
                    break
                }
                if resumes < maxResumes, !cancelled {
                    resumes += 1
                    TicNoteDiagLog.log("D3200 WIFI",
                        "file \(fileId): no growth \(Int(stallWindow))s at \(fileBytes)B/\(fileExpected)B — session restart #\(resumes), resume from \(fileBytes)B")
                    // ★ 2026-10-29：这条连接到头了是设备的单连接上限（~55 MB），
                    // 预期行为不是故障——明确告诉用户接下来在做什么。
                    onStageNote?("这条传输通道到头了（设备单通道上限），正在重开会话续传…")
                    // ★ 2026-10-28：重连前先给设备发 **1A0A**（"这个文件我收到了"）。
                    // 上次实测：不先收尾就重连，新连接上 1A07 一个包都不回——设备
                    // 还认为上一个文件在传，不肯重开。1A0A 之后它才会接新的 1A07。
                    try? await sendText(Self.transferCompleteHex(), timeoutSeconds: 3)
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    // ★ 2026-10-29：再发 **FINISH** 给豆一个干净的"会话结束"信号
                    // （官方 b6.java 收尾 = FINISH → 500ms → 关 WS → 断热点）。
                    // 真机证据：豆断流后蓝牙迟迟不恢复（11:50 / 13:46 两轮重连
                    // 150 s 全失败），最合理解释是它还挂在 Wi‑Fi 传输模式里等人
                    // 收尾——FINISH 让它自己关掉 Wi‑Fi 模式，BLE 广播才会回来。
                    // 反正马上要重开 1A05 会话，旧会话结束没有副作用。
                    try? await sendText("FINISH", timeoutSeconds: 2)
                    resumeStartBytes = fileBytes
                    // ★ 2026-10-29：不再原地 restartWs。同一条 AP 会话里换 WS，
                    // 设备实测永远不吐包（09:35 wss 超时 / 19:27 重连成功但 20 秒
                    // 0 包）——它的文件传输状态机绑在 1A05 会话上。唯一有效的恢复
                    // 路是重开 1A05（新热点凭据）再带偏移续传（09:52 验证通过）。
                    // 原来每次断流都要先白烧 30–60 秒的无效重连，才在外层走到
                    // restartWifiSession；现在直接走有效路径。
                    // ★ 2026-10-30（10:33–10:40 日志实锤）：豆的传输服务半路死掉后，
                    // 第一次重开常失败（BLE 重连后 TCP 探测仍全不通），但**用户手动再
                    // 点一次就总能成功**（10:39 手点 → 5 s 传完剩下 2 MB，complete=true）
                    // ——死掉的只是会话，多试必然成。这里自动补上"再点一次"：
                    // 重开失败 → 等 8 s 再试，最多 3 次；3 次全败才真正交卷。
                    var restarted = false
                    for restartAttempt in 1...3 {
                        if cancelled { break }
                        if await restartWifiSession() {
                            restarted = true
                            break
                        }
                        if restartAttempt < 3 {
                            TicNoteDiagLog.log("D3200 WIFI",
                                "file \(fileId): restart attempt \(restartAttempt) failed (\(lastResumeFailure ?? "unknown")) — retrying in 8s")
                            onStageNote?("重开没成功，8 秒后再试一次…")
                            try? await Task.sleep(nanoseconds: 8_000_000_000)
                        }
                    }
                    if !restarted {
                        TicNoteDiagLog.log("D3200 WIFI",
                            "file \(fileId): session restart failed after 3 attempts (\(lastResumeFailure ?? "unknown")) — stopping at \(fileBytes)B")
                        break
                    }
                    resumeSeqResetPending = fileBytes > 0
                    try? await sendHeadRequest(
                        hex: Self.headRequestHex(fileId: fileId, transferred: fileBytes),
                        fileId: fileId)
                    lastGrowth = Date()
                    lastBytes = fileBytes
                    continue
                }
                TicNoteDiagLog.log("D3200 WIFI",
                    "file \(fileId): stalled at \(fileBytes)B for \(Int(stallWindow))s after \(resumes) reconnects (msgs=\(wsMessages) expected=\(fileExpected))")
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        onProgress?(fileBytes, max(fileExpected, fileBytes))
        client.crypto.clearFile(fileId)
        let complete = fileExpected <= 0 || fileBytes >= Int(Double(fileExpected) * 0.95)
        if !complete {
            log.warning("partial receive \(self.fileBytes, privacy: .public)/\(self.fileExpected, privacy: .public) for \(fileId, privacy: .public)")
        }
        TicNoteDiagLog.log("D3200 WIFI",
            "file \(fileId): done \(fileBytes)B/\(fileExpected)B payload=\(fileBuf.count)B msgs=\(wsMessages) rawIn=\(wsBytesIn)B seqJumps=\(seqJumps) reconnects=\(resumes) complete=\(complete)")
        return fileBuf
    }

    /// 1A07 文件头请求（hex 文本帧）。
    ///
    /// 飞书 `y5.e(fileId, transferredSize)`：`08 EE 00 00 00 1A 07 12 00 |
    /// LE32(transferredSize) | LE32(fileId) | 1B`，无校验字节。`transferredSize`
    /// 是**断点续传**的起点（按 166 B/记录的线缆字节数计），首次传 0。
    static func headRequestHex(fileId: UInt32, transferred: Int) -> String {
        var req: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00, 0x1A, 0x07, 0x12, 0x00]
        req.append(contentsOf: [UInt8](soundcoreU32Le(UInt32(clamping: transferred))))
        req.append(contentsOf: [UInt8](soundcoreU32Le(fileId)))
        req.append(0x1B)
        return req.map { String(format: "%02x", $0) }.joined()
    }

    /// 发 1A07 文件头请求（hex 文本帧）。抽出来给"超时重发"复用。
    private func sendHeadRequest(hex: String, fileId: UInt32) async throws {
        try await sendText(hex, timeoutSeconds: 5)
        TicNoteDiagLog.log("D3200 WIFI", "1A07 sent file=\(fileId) hex=\(hex.prefix(24))…")
        log.info("WS requested file \(fileId, privacy: .public)")
    }

    /// 文本帧发送 + 超时。
    ///
    /// ★ 2026-10-28：`URLSessionWebSocketTask.send` 没有超时语义——连接半死时它会
    /// 一直挂着，整个导出连看门狗循环都进不去，UI 就永远停在「正在传输」。
    /// 这里用 task group 竞速：发送完成 or 超时，谁先到算谁。
    private func sendText(_ text: String, timeoutSeconds: Double) async throws {
        guard let ws else { throw WifiExportError(message: "WebSocket 已断开") }
        let task = ws
        let finished: Bool = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await task.send(.string(text))
                return true
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finished {
            TicNoteDiagLog.log("D3200 WIFI", "send timeout \(Int(timeoutSeconds))s: \(text.prefix(20))…")
            throw WifiExportError(message: "向录音豆发送控制帧超时（\(Int(timeoutSeconds)) 秒未完成）")
        }
    }

    // MARK: WS receive plumbing

    private func handleWsText(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 20 && !t.hasPrefix("09") {
            log.info("WS text: \(t, privacy: .public)")
            // ★ 2026-10-28：设备回的 ACK/pong/1A06 都是短文本，原来只进 os_log，
            // 真机排查时抓不到——现在一并进诊断文件。
            TicNoteDiagLog.log("D3200 WIFI", "ws text short[\(t.count)] \(t.prefix(48))")
            return
        }
        let cleaned = t.filter { $0.isHexDigit }
        guard cleaned.count >= 20, cleaned.count % 2 == 0 else { return }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var it = cleaned.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            bytes.append((Self.hexValue(hi) << 4) | Self.hexValue(lo))
        }
        handleWsBytes(Data(bytes))
    }

    private static func hexValue(_ c: Character) -> UInt8 {
        switch c {
        case "0"..."9": return UInt8(c.asciiValue! - 48)
        case "a"..."f": return UInt8(c.asciiValue! - 87)
        case "A"..."F": return UInt8(c.asciiValue! - 55)
        default: return 0
        }
    }

    /// 已经打过日志的 (cmdType/cmdId) 组合，避免同种包刷屏。
    private var loggedPacketKinds = Set<String>()

    private func handleWsBytes(_ data: Data) {
        for pkt in parser.feed(data) {
            handlePacket(pkt)
        }
    }

    /// 前两条 WS 消息打一条 hex 前缀到诊断文件（之后不再打，避免日志爆掉）。
    private func dumpFrameIfNeeded(label: String, bytes: Data) {
        guard dumpedFirstFrames < 2 else { return }
        dumpedFirstFrames += 1
        let head = bytes.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
        TicNoteDiagLog.log("D3200 WIFI",
            "ws msg#\(wsMessages) \(label) \(bytes.count)B head=[\(head)]")
    }

    private func handlePacket(_ pkt: SoundcorePacket) {
        // ★ 2026-10-28：设备在传输末尾到底说了什么，之前完全看不见。
        // 每种 (type,id) 只打一条，用来判断它是"传完了"(1A0B)、"请切回 BLE"(1A06)
        // 还是干脆不说话 —— 这决定后面该改续传还是改收尾。
        let kind = String(format: "%02x/%02x", pkt.cmdType, pkt.cmdId)
        if loggedPacketKinds.count < 12, !loggedPacketKinds.contains(kind) {
            loggedPacketKinds.insert(kind)
            TicNoteDiagLog.log("D3200 WIFI",
                "ws pkt type/id=\(kind) len=\(pkt.raw.count)B status=\(pkt.statusByte)")
        }
        guard pkt.cmdType == SoundcoreRxCmd.transportType || pkt.cmdType == SoundcoreRxCmd.transportTypeAlt else { return }
        guard let fileId = activeFileId else { return }
        switch pkt.cmdId {
        case SoundcoreRxCmd.fileHeadId:
            if let secret = SoundcoreFileSecretKey.parseFrame(pkt.raw) {
                if secret.fileId != fileId {
                    log.warning("WS head for foreign file \(secret.fileId, privacy: .public) (want \(fileId, privacy: .public)) — ignoring")
                } else {
                    if secret.fileSize > 0 && secret.fileSize != 0xFFFFFFFF {
                        fileExpected = Int(secret.fileSize)
                    }
                    decryptOn = client.crypto.initFileDecrypt(
                        fileId: fileId,
                        encryptedFileKey: secret.encryptedFileKey,
                        sessionNonce: secret.sessionNonce,
                        nonce: secret.nonce
                    )
                    log.info("WS head id=\(secret.fileId, privacy: .public) size=\(self.fileExpected, privacy: .public) decrypt=\(self.decryptOn, privacy: .public)")
                }
            }
            headSignalled = true
        case SoundcoreRxCmd.fileSliceId, SoundcoreRxCmd.fileSliceMarkId:
            fileBytes += writeSlices(pkt.raw, fileId: fileId)
        case SoundcoreRxCmd.fileDoneId:
            log.info("WS file done for \(fileId, privacy: .public) (\(self.fileBytes, privacy: .public) bytes)")
            doneSignalled = true
        default:
            break
        }
    }

    /// Parse repeating slice records from a transport frame.
    ///
    /// ★ 2026-10-28（对照飞书 `h0.h()`）：一条记录在**线缆上就是 166 B**
    /// ——`[seq u32le][flags u8][160B data][pad u8]`，飞书的循环是
    /// `while (len - i >= 166)`、步进 `i = i5 + 160 + 1`，而且进度 `d += 166`
    /// **按 166 计**（不按解出来的 160）。设备 1A07 头里的 fileSize 也正好能被
    /// 166 整除（实测 60149602 = 362347×166），所以进度/完整性判断都必须用
    /// 线缆字节数，否则永远差 3.75%，好录音也会被判"不完整"。
    ///
    /// 返回值是**线缆字节数**（每条 166），不是解密后的 160。
    private func writeSlices(_ frame: Data, fileId: UInt32) -> Int {
        let b = [UInt8](frame)
        var wire = 0
        var i = 9
        while b.count - i >= Self.sliceWire {
            let seqValue = Int(soundcoreReadU32Le(b, i))
            i += 4
            i += 1 // flags（bit0 = 打标）
            let dataEnd = i + Self.sliceData
            guard dataEnd <= b.count else { break }
            var chunk = Data(b[i..<dataEnd])
            i = dataEnd
            if i < b.count { i += 1 } // pad → 每条记录 166

            // ★ 2026-10-28 更正：**序号不能用来去重**。真机日志（19:12）里数据
            // 流到 35 MB 时 seq 自己回到了 0（设备没重发、传输也没停），上一版
            // 据此"清缓冲重来"，把已经收好的 35 MB 直接丢了。所以现在：
            //  - 只有**刚发过续传**的那一次，如果第一条就是 seq 0，才认定设备
            //    无视了 transferredSize、从头重发 → 这时清空是对的；
            //  - 其余情况一律按到达顺序追加，seq 只用于解密和诊断。
            if resumeSeqResetPending {
                resumeSeqResetPending = false
                if seqValue == 0 && fileBytes > 0 {
                    TicNoteDiagLog.log("D3200 WIFI",
                        "resume ignored by device (first seq=0) — restarting file buffer")
                    fileBuf.removeAll(keepingCapacity: true)
                    fileBytes = 0
                    resumeIgnored = true
                }
            }
            if nextSeq >= 0 && seqValue != nextSeq { seqJumps += 1 }
            nextSeq = seqValue + 1

            wire += Self.sliceWire
            if decryptOn {
                guard let plain = client.crypto.decryptChunk(fileId: fileId, sequence: seqValue, data: chunk) else { continue }
                chunk = plain
            }
            fileBuf.append(chunk)
        }
        return wire
    }

    /// Feishu transfer-complete (1A0A) as hex text, checksum included
    /// (Kotlin `transferCompleteHex`).
    private static func transferCompleteHex() -> String {
        var body: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00, 0x1A, 0x0A, 0x0B, 0x00, 0x01]
        var sum = 0
        for b in body { sum = (sum + Int(b)) & 0xFF }
        body.append(UInt8(sum))
        return body.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: teardown (step 6)

    private func teardown() {
        stopWsPing()
        ws?.cancel(with: .goingAway, reason: "done".data(using: .utf8))
        ws = nil
        wsSession?.invalidateAndCancel()
        wsSession = nil
        stopKeepalive()
        // 释放热点配置（joinOnce 本就会在用完断开，显式移除更稳妥）。
        if let ssid {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        // BLE 侧关闭设备的 Wi‑Fi 模式（失败不影响结果）。正在等用户手动加入时
        // 不能关——否则用户按提示去设置里根本找不到这个热点。
        if !manualJoinInProgress {
            Task { [client] in
                await client.closeWifiMode()
            }
        }
    }
}

// MARK: - WebSocket delegate plumbing

/// The URLSession delegate must be an NSObject; the challenge handler is
/// nonisolated and hops back to the exporter's MainActor for the rest.
private final class WsDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {

    weak var exporter: SoundcoreWifiExporter?

    init(exporter: SoundcoreWifiExporter) {
        self.exporter = exporter
        super.init()
    }

    /// Trust-all server-trust handler — the bean uses a self-signed TLS
    /// certificate (firmware cannot provide a chain of trust). We evaluate
    /// with the host's SSL policy for the log trail but accept regardless,
    /// exactly like the Kotlin reference's X509TrustManager. ATS is NOT
    /// disabled globally — this only covers this one wss connection.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(trust, policy)
        var error: CFError?
        let evaluated = SecTrustEvaluateWithError(trust, &error)
        if !evaluated {
            log.warning("server-trust evaluation failed for \(host, privacy: .public) — accepting (self-signed device cert): \(String(describing: error), privacy: .public)")
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            self?.exporter?.wsDidOpen()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            self?.exporter?.wsDidClose(code: closeCode)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in
            self?.exporter?.wsDidFail(error)
        }
    }
}

// MARK: - delegate callbacks (MainActor surface, kept internal for WsDelegate)

extension SoundcoreWifiExporter {

    func wsDidOpen() {
        openSignalled = true
    }

    func wsDidClose(code: URLSessionWebSocketTask.CloseCode) {
        log.info("WS closed code=\(code.rawValue, privacy: .public)")
        TicNoteDiagLog.log("D3200 WIFI", "ws closed code=\(code.rawValue) msgs=\(wsMessages) in=\(wsBytesIn)B")
        wsClosed = true
    }

    func wsDidFail(_ error: Error?) {
        guard let error else { return }
        log.warning("WS task failed: \(String(describing: error), privacy: .public)")
        // ★ 2026-10-28：**连接建立后**的失败原来被 `if !openSignalled` 吞掉了——
        // 于是 WS 死掉、receive 不再重挂，`pullOverWs` 还在按"总超时"空转，
        // UI 就永远停在「正在传输」。现在一律记录，传输循环据此立刻失败。
        TicNoteDiagLog.log("D3200 WIFI", "ws task failed: \(error.localizedDescription) open=\(openSignalled) msgs=\(wsMessages)")
        wsFailure = error
    }
}
