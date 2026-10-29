import CoreBluetooth
import Foundation

// MARK: - soundcore Work / D3200（飞书录音豆）binary framing, commands, models
//
// Faithful Swift port of the verified Kotlin protocol layer:
//   · nomily-android `core/protocol/SoundcoreFrames.kt`
//   · nomily-android `core/protocol/SoundcoreCommands.kt`
//   · nomily-android `core/protocol/SoundcoreModels.kt`
// (protocol reference: `03-逆向/录音豆/ref/Soundcore/PROTOCOL.md` §4–§6.3)
//
// TX: `08 EE 00 00 00 | cmdType | cmdId | len_lo | len_hi | payload… | checksum`
// RX: `09 FF 00 00    | status  | cmdType | cmdId | len_lo | len_hi | payload… | checksum`
//
// checksum = 低 8 位字节和（对不含校验字节的前缀求和）。
//
// ★ 红线（用户决策 2026-10-27，设备要与飞书 App 长期并行）：本文件**故意不移植**
// `bind()` / `unbind()`（0x0B/0x87）与 `resetDevice()`（0x01/0xB8）——这四类命令
// 会改变设备的绑定/持久状态，可能影响原厂 App。其余命令（信息、录音控制、
// 文件传输、加密握手）均为无持久副作用的读/会话级操作。

enum SoundcoreFrame {
    static let txMagic: [UInt8] = [0x08, 0xEE, 0x00, 0x00, 0x00]

    /// Minimum RX packet size: magic(4)+status(1)+type(1)+id(1)+len(2)+csum(1).
    static let minRxLength = 10

    static func checksum(_ data: [UInt8], end: Int? = nil) -> UInt8 {
        let upper = end ?? data.count
        var sum = 0
        for i in 0..<upper { sum = (sum + Int(data[i])) & 0xFF }
        return UInt8(sum)
    }

    static func verifyChecksum(_ packet: Data) -> Bool {
        let bytes = [UInt8](packet)
        guard bytes.count >= 2 else { return false }
        return checksum(bytes, end: bytes.count - 1) == bytes[bytes.count - 1]
    }

    static func isRxHeader(_ data: [UInt8], offset: Int) -> Bool {
        guard data.count >= offset + 4 else { return false }
        return data[offset] == 0x09 && data[offset + 1] == 0xFF
            && data[offset + 2] == 0x00 && data[offset + 3] == 0x00
    }

    /// Build a phone → device command frame.
    static func encode(cmdType: UInt8, cmdId: UInt8, payload: Data = Data()) -> Data {
        let payloadBytes = [UInt8](payload)
        let bodyLen = 5 + 2 + 2 + payloadBytes.count + 1 // magic+type+id + len + payload + csum
        var out = [UInt8](repeating: 0, count: bodyLen)
        for (i, b) in txMagic.enumerated() { out[i] = b }
        out[5] = cmdType
        out[6] = cmdId
        out[7] = UInt8(bodyLen & 0xFF)
        out[8] = UInt8((bodyLen >> 8) & 0xFF)
        for (i, b) in payloadBytes.enumerated() { out[9 + i] = b }
        out[bodyLen - 1] = checksum(out, end: bodyLen - 1)
        return Data(out)
    }
}

/// One parsed RX packet.
struct SoundcorePacket {
    let raw: Data
    let statusByte: UInt8
    let cmdType: UInt8
    let cmdId: UInt8
    let payload: Data

    var successFlag: Int { Int(statusByte) & 0x0F }
    var isSuccess: Bool { successFlag == 1 || statusByte == 1 }

    static func from(bytes: Data) -> SoundcorePacket {
        let b = [UInt8](bytes)
        let payload: Data
        if b.count > SoundcoreFrame.minRxLength {
            payload = Data(b[9..<(b.count - 1)])
        } else {
            payload = Data()
        }
        return SoundcorePacket(
            raw: bytes,
            statusByte: b[4],
            cmdType: b[5],
            cmdId: b[6],
            payload: payload
        )
    }
}

/// Stream reassembler for the notify characteristic — feed whatever GATT
/// delivers (frames may be split or coalesced arbitrarily), collect complete
/// packets. Port of Kotlin `SoundcoreFrameParser`.
final class SoundcoreFrameParser {
    private var buffer: [UInt8] = []
    /// 诊断：成功解出的包数 / 校验和失败被丢掉的包数 / 找不到帧头而丢弃的字节数。
    /// ★ 2026-10-28：大文件传输每轮都在 ~50 MiB 处停，需要排除"我们自己在丢包"
    /// 这种可能——这三个数能直接证明设备发了多少、我们认了多少。
    private(set) var parsedPackets = 0
    private(set) var checksumRejects = 0
    private(set) var discardedBytes = 0

    func feed(_ data: Data) -> [SoundcorePacket] {
        buffer.append(contentsOf: [UInt8](data))
        var results: [SoundcorePacket] = []
        var i = 0
        while i + SoundcoreFrame.minRxLength <= buffer.count {
            var found = -1
            for j in i...(buffer.count - SoundcoreFrame.minRxLength) {
                if SoundcoreFrame.isRxHeader(buffer, offset: j) {
                    found = j
                    break
                }
            }
            if found < 0 { break }
            discardedBytes += found - i
            i = found
            if i + 9 > buffer.count { break }
            let totalLen = Int(buffer[i + 7]) | (Int(buffer[i + 8]) << 8)
            if totalLen < SoundcoreFrame.minRxLength {
                i += 1
                continue
            }
            if i + totalLen > buffer.count { break } // incomplete — wait for more
            let slice = Array(buffer[i..<(i + totalLen)])
            if SoundcoreFrame.verifyChecksum(Data(slice)) {
                results.append(SoundcorePacket.from(bytes: Data(slice)))
                parsedPackets += 1
            } else {
                checksumRejects += 1
            }
            i += totalLen
        }
        if i > 0 { buffer.removeFirst(i) }
        // ★ 2026-10-28：长度字段一旦读错（例如固件的 WS 帧 len 只算 payload），
        // 解析器会一直"等更多数据"，缓冲越积越大、后面的帧全被吞掉——表现就是
        // "WS 在收数据，但一个字节都没解析出来"。给一个上限兜底：超了就清空重来。
        if buffer.count > 1_048_576 {
            discardedBytes += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }
        return results
    }

    func reset() {
        buffer.removeAll()
        parsedPackets = 0
        checksumRejects = 0
        discardedBytes = 0
    }
}

// MARK: LE readers/writers

func soundcoreReadU16Le(_ b: [UInt8], _ o: Int) -> Int {
    Int(b[o]) | (Int(b[o + 1]) << 8)
}

func soundcoreReadU32Le(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
}

func soundcoreU16Le(_ v: Int) -> Data {
    Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
}

func soundcoreU32Le(_ v: UInt32) -> Data {
    Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
}

extension Data {
    /// Hex dump for logs (Kotlin `toHex()`).
    var soundcoreHex: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

// MARK: High-level command builders (Kotlin `SoundcoreCommands`)

enum SoundcoreCommands {
    // ── Device info (type 0x01) ──
    static func getDeviceInfo() -> Data {
        SoundcoreFrame.encode(cmdType: 0x01, cmdId: 0x01)
    }

    /// UTC unix seconds + timezone offset byte (hours, signed).
    static func syncTime(unixSeconds: UInt32, timezoneHours: Int) -> Data {
        var payload = soundcoreU32Le(unixSeconds)
        payload.append(UInt8(timezoneHours & 0xFF))
        return SoundcoreFrame.encode(cmdType: 0x01, cmdId: 0xA6, payload: payload)
    }

    // ── Audio control (type 0x18 id 0x82) ──
    static func startRecord() -> Data {
        SoundcoreFrame.encode(cmdType: 0x18, cmdId: 0x82, payload: Data([0x01]))
    }

    static func pauseRecord() -> Data {
        SoundcoreFrame.encode(cmdType: 0x18, cmdId: 0x82, payload: Data([0x02]))
    }

    // ── File transport (type 0x1A / 0x1B) ──
    static func listFiles(page: Int = 0) -> Data {
        SoundcoreFrame.encode(cmdType: 0x1A, cmdId: 0x0E, payload: soundcoreU16Le(page))
    }

    /// Newer firmware answers the file list with per-file end time.
    static func listFilesWithEndTime(page: Int = 0) -> Data {
        SoundcoreFrame.encode(cmdType: 0x1B, cmdId: 0x0E, payload: soundcoreU16Le(page))
    }

    static func deleteFile(fileId: UInt32) -> Data {
        SoundcoreFrame.encode(cmdType: 0x1A, cmdId: 0x10, payload: soundcoreU32Le(fileId))
    }

    static func startBtTransport(isIos: Bool) -> Data {
        SoundcoreFrame.encode(cmdType: 0x1A, cmdId: 0x0F, payload: Data([isIos ? 0x01 : 0x00]))
    }

    static func stopBtTransport(isIos: Bool) -> Data {
        SoundcoreFrame.encode(cmdType: 0x1A, cmdId: 0x11, payload: Data([isIos ? 0x01 : 0x00]))
    }

    /// Request one audio file (or its tail) over BLE GATT:
    /// payload = `alreadyTransferred: u32le | fileId: u32le | realtimeFlag: u8`.
    /// The head reply (0x1A/0x07) carries the encrypted file key — see
    /// `SoundcoreFileSecretKey`.
    static func startTransportAudioFile(fileId: UInt32, alreadyTransferred: UInt32 = 0, realtimeFlag: UInt8 = 0) -> Data {
        var payload = soundcoreU32Le(alreadyTransferred)
        payload.append(soundcoreU32Le(fileId))
        payload.append(realtimeFlag)
        return SoundcoreFrame.encode(cmdType: 0x1A, cmdId: 0x07, payload: payload)
    }

    // ── Wi‑Fi 快传 (PROTOCOL.md §6.4–6.5，port of Kotlin `SoundcoreCommands`) ──
    /// 0x1A/0x05 — deliver phone-chosen SoftAP credentials (`WiFi-{ms}` / `{ms}`).
    /// The **device** opens the hotspot and answers with its AP gateway IP +
    /// WebSocket port (`SoundcoreClient.startWifiExport` parses the reply).
    static func sendWifiConfig(ssid: String, password: String) -> Data {
        let ssidBytes = Array(ssid.utf8)
        let pwdBytes = Array(password.utf8)
        var payload = Data([UInt8(ssidBytes.count & 0xFF)])
        payload.append(contentsOf: ssidBytes)
        payload.append(UInt8(pwdBytes.count & 0xFF))
        payload.append(contentsOf: pwdBytes)
        return SoundcoreFrame.encode(cmdType: 0x1A, cmdId: 0x05, payload: payload)
    }

    /// 0x1A/0x02 — close the device's Wi‑Fi transfer mode (sent after export).
    static func closeWifiMode() -> Data {
        SoundcoreFrame.encode(cmdType: 0x1A, cmdId: 0x02)
    }

    // ── Encrypt handshake (type 0x2E) ──
    /// Send the app's ECDH P-256 public key (65-byte uncompressed SEC1).
    static func notifyEncryptPublicKey(_ publicKeyBytes: Data) -> Data {
        SoundcoreFrame.encode(cmdType: 0x2E, cmdId: 0x01, payload: publicKeyBytes)
    }
}

/// Known RX type/id pairs for dispatch (Kotlin `SoundcoreRxCmd`).
enum SoundcoreRxCmd {
    static let deviceInfoType: UInt8 = 0x01
    static let deviceInfoId: UInt8 = 0x01
    static let batteryId: UInt8 = 0x03
    static let chargingId: UInt8 = 0x04
    static let syncTimeId: UInt8 = 0xA6

    static let audioType: UInt8 = 0x18
    static let audioControlId: UInt8 = 0x82

    static let transportType: UInt8 = 0x1A
    static let transportTypeAlt: UInt8 = 0x1B
    static let wifiCloseId: UInt8 = 0x02
    static let wifiConfigId: UInt8 = 0x05

    /// New file / transport status while recording (Feishu realtime).
    static let recordStatusId: UInt8 = 0x06
    static let fileHeadId: UInt8 = 0x07
    static let fileSliceId: UInt8 = 0x08
    static let fileDoneId: UInt8 = 0x0A
    static let fileListId: UInt8 = 0x0E
    static let btStatusId: UInt8 = 0x0F
    static let deleteId: UInt8 = 0x10
    static let fileSliceMarkId: UInt8 = 0x12

    static let encryptType: UInt8 = 0x2E
    static let encryptHandshakeId: UInt8 = 0x01
}

/// GATT / advertisement identifiers (Kotlin `SoundcoreUuids`, PROTOCOL.md §3).
enum SoundcoreUuids {
    /// Advertised primary service; Feishu matches this → "D3200".
    static let d3200Service = CBUUID(string: "020CF5DA-0000-1000-8000-00805F9B34FB")
    static let write = CBUUID(string: "00007777-0000-1000-8000-00805F9B34FB")
    static let readNotify = CBUUID(string: "00008888-0000-1000-8000-00805F9B34FB")
    static let cccd = CBUUID(string: "00002902-0000-1000-8000-00805F9B34FB")

    /// Tolerant match: firmware/stack variants may shorten the base UUID.
    static func isD3200Service(_ uuid: String) -> Bool {
        uuid.lowercased().replacingOccurrences(of: "-", with: "").contains("020cf5da")
    }

    static func isWrite(_ uuid: CBUUID) -> Bool {
        uuid.uuidString.uppercased().contains("00007777")
    }

    static func isRead(_ uuid: CBUUID) -> Bool {
        uuid.uuidString.uppercased().contains("00008888")
    }
}

// MARK: Data models (Kotlin `SoundcoreModels.kt`)

/// Device info snapshot. Port of Kotlin `SoundcoreDeviceInfo`.
struct SoundcoreDeviceInfo {
    var connectStatus: Int?
    var battery: Int?
    var charging: Bool = false
    var firmwareVersion: String = ""
    var serialNumber: String = ""
    var totalMemoryKb: UInt32?
    var freeMemoryKb: UInt32?
    var boxBattery: Int?
    var boxCharging: Bool = false
    var boxMac: String = ""
    var boxFirmware: String = ""
    var wifiFirmware: String = ""
    var recording: Bool = false
    var rawHex: String = ""

    var displayBatteryPercent: Int {
        battery ?? boxBattery ?? 0
    }

    /// D3200 reports one of ten battery buckets: 0 → 10% … 9 → 100%.
    /// Literal percentages above the bucket range are preserved (firmwares
    /// that report real percentages); values >100 keep the low 7 bits when
    /// that lands in range (Kotlin `_clampPct`).
    static func batteryRemaining(_ raw: Int?) -> Int? {
        guard let clamped = clampPct(raw) else { return nil }
        return clamped <= 9 ? (clamped + 1) * 10 : clamped
    }

    private static func clampPct(_ v: Int?) -> Int? {
        guard let v else { return nil }
        if v > 100 {
            let masked = v & 0x7F
            return masked <= 100 ? masked : 100
        }
        return max(0, v)
    }

    private static func formatMac(_ macBytes: [UInt8]) -> String {
        let six = macBytes
        guard six.count >= 6 else { return "" }
        let allSame = six.allSatisfy { $0 == six[0] }
        let allZero = six.allSatisfy { $0 == 0 }
        if allSame || allZero { return "" }
        return six.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func asciiZ(_ bytes: [UInt8]) -> String {
        var slice = bytes
        if let end = slice.firstIndex(of: 0) { slice = Array(slice[..<end]) }
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Parse using Feishu absolute offsets on the **full** frame
    /// (`DeviceInfoDispatch.onParseDeviceInfo`, payload starts at 9).
    static func parsePacket(_ raw: Data) -> SoundcoreDeviceInfo {
        let hex = raw.soundcoreHex
        let b = [UInt8](raw)
        if b.count < 20 { return SoundcoreDeviceInfo(rawHex: hex) }
        var o = 9
        func u8() throws -> Int {
            guard o < b.count else { throw SoundcoreError.malformed("u8 @\(o)") }
            defer { o += 1 }
            return Int(b[o])
        }
        func take(_ n: Int) -> [UInt8] {
            let end = min(o + n, b.count)
            let s = Array(b[o..<end])
            o = end
            return s
        }
        do {
            let connectStatus = try u8()
            let battery = batteryRemaining(try u8()) ?? 0
            let chargingStatus = try u8()
            let fw = asciiZ(take(5))
            let sn = asciiZ(take(16)).lowercased()
            let totalMem = soundcoreReadU32Le(b, o); o += 4
            let freeMem = soundcoreReadU32Le(b, o); o += 4
            let boxChargingFlag = try u8()
            let boxFw = asciiZ(take(5))
            let boxBatteryRaw = try u8()
            let boxMac = formatMac(take(6))

            var wifiFw = ""
            var recording = false
            if o + 5 + 1 <= b.count - 1 {
                for _ in 0..<5 { _ = try u8() } // color, autoOff switch/index, pickup light, box light
                if o < b.count - 1 { recording = try u8() == 1 }
                if o + 5 <= b.count - 1 { wifiFw = asciiZ(take(5)) }
            }
            return SoundcoreDeviceInfo(
                connectStatus: connectStatus,
                battery: battery,
                charging: chargingStatus == 1,
                firmwareVersion: fw,
                serialNumber: sn,
                totalMemoryKb: totalMem,
                freeMemoryKb: freeMem,
                boxBattery: batteryRemaining(Int(boxBatteryRaw)),
                boxCharging: boxChargingFlag == 1,
                boxMac: boxMac,
                boxFirmware: boxFw,
                wifiFirmware: wifiFw,
                recording: recording,
                rawHex: hex
            )
        } catch {
            // Fallback: payload-only parse (mic battery = first payload bytes).
            let payload = b.count > 10 ? Array(b[9..<(b.count - 1)]) : []
            return parsePayload(Data(payload), rawHex: hex)
        }
    }

    /// Payload-only parse (starts at frame offset 9).
    static func parsePayload(_ payload: Data, rawHex: String = "") -> SoundcoreDeviceInfo {
        let b = [UInt8](payload)
        if b.count < 3 { return SoundcoreDeviceInfo(rawHex: rawHex) }
        var o = 0
        func u8() -> Int {
            defer { o += 1 }
            return Int(b[o])
        }
        func take(_ n: Int) -> [UInt8] {
            let end = min(o + n, b.count)
            let s = Array(b[o..<end])
            o = end
            return s
        }
        let connectStatus = u8()
        let battery = batteryRemaining(u8()) ?? 0
        let chargingStatus = u8()
        let fw = b.count >= 8 ? asciiZ(take(5)) : ""
        let sn = b.count >= 24 ? asciiZ(take(16)).lowercased() : ""

        var totalMem: UInt32?
        var freeMem: UInt32?
        var boxCharging = false
        var boxFw = ""
        var boxBattery: Int?
        var boxMac = ""
        if o + 8 <= b.count {
            totalMem = soundcoreReadU32Le(b, o); o += 4
            freeMem = soundcoreReadU32Le(b, o); o += 4
        }
        if o < b.count { boxCharging = u8() == 1 }
        if o + 5 <= b.count { boxFw = asciiZ(take(5)) }
        if o < b.count { boxBattery = batteryRemaining(u8()) }
        if o + 6 <= b.count { boxMac = formatMac(take(6)) }
        return SoundcoreDeviceInfo(
            connectStatus: connectStatus,
            battery: battery,
            charging: chargingStatus == 1,
            firmwareVersion: fw,
            serialNumber: sn,
            totalMemoryKb: totalMem,
            freeMemoryKb: freeMem,
            boxBattery: boxBattery,
            boxCharging: boxCharging,
            boxMac: boxMac,
            boxFirmware: boxFw,
            rawHex: rawHex
        )
    }
}

/// One entry of the device-side recording list.
///
/// ## ★ 2026-10-28（8.3.6 反编译复核，`obf/i.java` AudioTransportImp）
///
/// 列表条目第三个 u32 **不是字节数，是时长毫秒**（之前 `PROTOCOL.md` §6.2/6.3
/// 写成 size 是错的）。官方拿到后：
///
/// ```java
/// int durRaw = u32(i + 8);                    // 时长毫秒
/// new FileInfoModel(fileId, endTime,
///         durRaw / 20 * 166,   // ← 第 3 参"size" = 估算字节数，只做进度条分母
///         durRaw,              // ← 第 4 参 duration = 毫秒原值
///         0);
/// ```
///
/// 所以：`durationMs` 直接照抄报文；字节数只能**估**（duration × 8.3 ≈ 官方口径），
/// 真字节数在 `1A 07` 文件头里（`u32 @13`，拉取时覆盖）。时长显示 / 归并一次录音
/// 的多分段，都以 `durationMs` 为准（官方 `HardwareFileSyncManager` 按
/// `fileId(n) − endTime(n−1) ≤ tolerance` 归并、总时长 = 各段之和）。
struct SoundcoreFileEntry: Equatable {
    let fileId: UInt32
    /// 报文第三个 u32 —— **时长毫秒**（历史名 sizeBytes 已废弃）。
    let rawValue: UInt32
    let endTime: UInt32?

    /// 设备上报的时长（毫秒）——显示直接用它，不要做任何换算。
    var durationMs: Int { Int(rawValue) }

    /// 估算字节数（官方口径 `durationMs / 20 × 166`，160 B/20 ms 粗化成 166）。
    /// 只用于进度条分母；真大小以 `1A 07` 头里的 fileSize 为准。
    var estimatedSizeBytes: Int { Int(rawValue) / 20 * 166 }

    /// fileId is a unix-seconds stamp on this firmware (>1e9, <2e10).
    var fileIdAsEpochSeconds: UInt32? {
        fileId > 1_000_000_000 ? fileId : nil
    }
}

/// Parsed reply to `listFilesWithEndTime` / `listFiles`. Port of Kotlin `SoundcoreFileList`.
struct SoundcoreFileList {
    let files: [SoundcoreFileEntry]
    let fileCount: Int
    let currentTransportTimestamp: UInt32?
    let currentTransportDuration: UInt32?

    static func parse(_ payload: Data, withEndTime: Bool) -> SoundcoreFileList {
        let b = [UInt8](payload)
        guard b.count >= 2 else {
            return SoundcoreFileList(files: [], fileCount: 0, currentTransportTimestamp: nil, currentTransportDuration: nil)
        }
        let count = soundcoreReadU16Le(b, 0)
        var o = 2
        var files: [SoundcoreFileEntry] = []
        // 1B 0E：fileId + endTime + durationMs（12B）；1A 0E：fileId + durationMs（8B）。
        // ★ 第三个字段是**时长毫秒**不是字节数（8.3.6 反编译复核，见 SoundcoreFileEntry）。
        let entrySize = withEndTime ? 12 : 8
        for _ in 0..<count {
            guard o + entrySize <= b.count else { break }
            let fileId = soundcoreReadU32Le(b, o); o += 4
            var endTime: UInt32?
            if withEndTime {
                endTime = soundcoreReadU32Le(b, o); o += 4
            }
            let durationMs = soundcoreReadU32Le(b, o); o += 4
            if durationMs > 0 { files.append(SoundcoreFileEntry(fileId: fileId, rawValue: durationMs, endTime: endTime)) }
        }
        var currTs: UInt32?
        var currDur: UInt32?
        if o + 8 <= b.count {
            currTs = soundcoreReadU32Le(b, o)
            currDur = soundcoreReadU32Le(b, o + 4)
        }
        return SoundcoreFileList(files: files, fileCount: count, currentTransportTimestamp: currTs, currentTransportDuration: currDur)
    }
}

/// Parsed 1A/07 file head (≥97 bytes when encrypted) — the carrier of the
/// per-file key material (Kotlin `SoundcoreFileSecretKey`).
///
/// Layout from offset 9 (payload origin): fileId u32le @9, fileSize u32le @13,
/// nonce 16B @17, encryptedFileKey 46B @33, sessionNonce 16B @79, err u8 @95.
struct SoundcoreFileSecretKey {
    let fileId: UInt32
    let fileSize: UInt32
    let nonce: Data
    let encryptedFileKey: Data
    let sessionNonce: Data
    let errorCode: Int

    static let minFrameLength = 97

    static func parseFrame(_ raw: Data) -> SoundcoreFileSecretKey? {
        let b = [UInt8](raw)
        guard b.count >= minFrameLength else { return nil }
        return SoundcoreFileSecretKey(
            fileId: soundcoreReadU32Le(b, 9),
            fileSize: soundcoreReadU32Le(b, 13),
            nonce: Data(b[17..<33]),
            encryptedFileKey: Data(b[33..<79]),
            sessionNonce: Data(b[79..<95]),
            errorCode: b.count > 95 ? Int(b[95]) : 0
        )
    }
}
