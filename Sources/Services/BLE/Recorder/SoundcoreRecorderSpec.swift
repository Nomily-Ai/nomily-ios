import CoreBluetooth
import Foundation

// MARK: - soundcore Work D3200（飞书录音豆）registry adapter
//
// Ports the verified Android scan matcher (`DeviceScanner.kt` `parseSoundcore`
// / `guidLooksD3200` / `nameLooksSoundcore`) into the protocol-agnostic
// `RecorderProtocolSpec` shape, so the bean rides the same
// scan → `DiscoveredRecorder` → `connectRecorder` → `RecorderSheet` pipeline
// as TicNote / DingTalk A1.
//
// ⚠️ Identity signals are **intentionally lenient** (upstream
// `AdvertisementParser.tryParse`): firmwares split identity across
// serviceUuids / manufacturer data / local name arbitrarily:
//
//  1. any advertised service UUID containing `020cf5da`/`daf50c02` or ending
//     in `f5da` (16-bit short form 0xF5DA) → D3200;
//  2. local name sounding like soundcore/d3200/录音豆 → family;
//  3. manufacturer-data hex containing `f5da`/`020cf5`, or bytes 8…13
//     spelling `sound…`/`scor…` → family.

enum SoundcoreRecorderSpec: RecorderProtocolSpec {

    static let identifier = "soundcore-d3200"
    static let family = "soundcore Work"

    // MARK: GATT

    static var serviceUUIDs: [CBUUID] { [SoundcoreUuids.d3200Service] }
    static var rxCharacteristic: CBUUID { SoundcoreUuids.write }   // App → device (00007777)
    static var txCharacteristic: CBUUID { SoundcoreUuids.readNotify } // device → App (00008888)

    // MARK: Advertisement identification

    static func parseAdvertisement(
        manufacturerData: Data?,
        localName: String?,
        serviceUUIDs: [CBUUID]?
    ) -> RecorderAdvertisement? {
        let name = localName?.trimmingCharacters(in: .whitespaces) ?? ""

        var isD3200 = false
        if let serviceUUIDs {
            isD3200 = serviceUUIDs.contains { guidLooksD3200($0.uuidString) }
        }
        var familyHit = isD3200 || nameLooksSoundcore(name)

        // iOS manufacturer data = companyId (u16 LE) ‖ payload; the Kotlin
        // matcher operates on the payload **after** the company id.
        var macFromMfg: Data = Data()
        if let mfg = manufacturerData, mfg.count > 2 {
            let payload = mfg.dropFirst(2)
            let hex = payload.map { String(format: "%02x", $0) }.joined()
            if hex.contains("f5da") || hex.contains("020cf5") { familyHit = true }
            if payload.count >= 6 && macFromMfg.isEmpty {
                macFromMfg = payload.prefix(6)
            }
            if payload.count >= 14 {
                // Bytes 8–13 may spell ASCII `soundc` (lot filter in the SDK).
                let mark = payload.dropFirst(8).prefix(6)
                    .map { Character(UnicodeScalar($0 & 0x7F)) }
                    .reduce(into: "") { $0.append($1) }
                    .lowercased()
                if mark.contains("sound") || mark.contains("scor") { familyHit = true }
            }
        }

        guard isD3200 || familyHit else { return nil }

        let identity = macFromMfg.isEmpty ? Data(name.utf8) : macFromMfg
        let friendly = friendlyName(localName: name, isD3200: isD3200, mac: macFromMfg)
        return RecorderAdvertisement(
            protocolID: identifier,
            family: friendly,
            modelName: "",
            firmware: nil,
            hardware: nil,
            battery: nil,
            powerState: nil,
            identity: identity,
            raw: ["localName": name]
        )
    }

    /// Full / short / byte-reversed appearances of the D3200 service UUID.
    static func guidLooksD3200(_ uuid: String) -> Bool {
        let s = uuid.lowercased().replacingOccurrences(of: "-", with: "")
        return s.contains("020cf5da")
            || s.contains("daf50c02")
            || s == "f5da"
            || s.hasSuffix("f5da")
            || (s.count >= 8 && String(s.prefix(8)) == "020cf5da")
    }

    static func nameLooksSoundcore(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("soundcore")
            || n.contains("soundcor")
            || n.contains("d3200")
            || (n.contains("work") && n.contains("sound"))
            || name.contains("录音")
            || (n.contains("anker") && n.contains("record"))
    }

    private static func friendlyName(localName: String, isD3200: Bool, mac: Data) -> String {
        if !localName.isEmpty {
            let lower = localName.lowercased()
            if lower.contains("soundcore") || lower.contains("work") || lower.contains("d3200") {
                return localName
            }
            return "soundcore Work (\(localName))"
        }
        if isD3200 {
            if mac.count >= 6 {
                let compact = mac.map { String(format: "%02X", $0) }.joined()
                return "soundcore Work · \(compact.suffix(4))"
            }
            return "soundcore Work"
        }
        if mac.count >= 6 {
            let octets = mac.prefix(3).map { String(format: "%02X", $0) }.joined(separator: ":")
            return "soundcore · \(octets)…"
        }
        return "soundcore device"
    }

    /// 发射前聚合的主键。豆的广播 MAC 是 RPA（随机轮换）且厂商数据并非每帧都带，
    /// identity 在帧间会漂移，所以按**归一化产品名**聚合（与 Android
    /// `DeviceScanner.mergeKey` 一致）：
    /// "soundcore Work" / "soundcore Work · XXXX" / "soundcore Work (XY)" 视为同一台。
    /// 代价：两颗同名同型号的豆会合并为一条——豆默认名不含序列号时官方 App 也一样。
    static func mergeKey(for displayName: String) -> String {
        var key = displayName
        if let idx = key.firstIndex(of: "·") { key = String(key[..<idx]) }
        if let idx = key.firstIndex(of: "(") { key = String(key[..<idx]) }
        return "d3200:" + key.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: Frame / commands metadata (informational; SoundcoreClient is bespoke)

    static var frameCodec: RecorderFrameCodec { SoundcoreFrameCodec() }

    static var commands: RecorderCommandSet {
        RecorderCommandSet(
            startRecording: SoundcoreRxCmd.audioControlId,
            stopRecording: SoundcoreRxCmd.audioControlId,
            recordingStatus: SoundcoreRxCmd.audioControlId,
            recordingStartedEvent: nil,
            recordingStoppedEvent: nil,
            liveStream: nil,
            fileTransfer: SoundcoreRxCmd.fileHeadId,
            deviceInfo: SoundcoreRxCmd.deviceInfoId,
            switchInfo: nil,
            fileList: SoundcoreRxCmd.fileListId,
            fileDelete: SoundcoreRxCmd.deleteId,
            syncTime: SoundcoreRxCmd.syncTimeId,
            extended: [
                "encryptHandshake": SoundcoreRxCmd.encryptHandshakeId,
                "startTransport": SoundcoreRxCmd.fileHeadId,
            ]
        )
    }

    /// v1 scope：BLE only — 本协议不提供 Wi-Fi 快传。
    static var wifiTransfer: RecorderWifiProfile? { nil }

    /// 红线：**不移植绑定**（0x0B/0x87）与复位（0x01/0xB8），豆要和飞书 App 长期并行。
    /// 设备端加密在传输层内透明解密（ECDH 会话密钥），app 侧无需额外密钥。
    static var bondIDLength: Int? { nil }
    static var fileEncryptionKeyLength: Int? { nil }
    static var clipCipher: RecorderClipCipher.Type? { nil }

    /// Read path verified end-to-end on **Android**; the iOS port has not run
    /// on hardware yet — keep the flag honest until it has.
    static var isVerified: Bool { false }
    static var isReadingVerified: Bool { false }

    /// Show in the scan list (the "Beta" badge is no longer rendered by the UI;
    /// the tier only drives registry visibility).
    static var exposure: RecorderExposure { .beta }
}

/// Placeholder codec — the Soundcore framing (`08 EE …` / `09 FF …`) does not
/// fit the generic `RecorderFrameCodec` shape, and `SoundcoreLink` never goes
/// through it. Required by the protocol; deliberately inert.
struct SoundcoreFrameCodec: RecorderFrameCodec {
    func encode(cmd: UInt8, payload: Data) -> Data? { nil }
    func decode(_ data: Data) -> RecorderFrame? { nil }
    func encodeJSON(cmd: UInt8, _ object: [String: Any]) -> Data? { nil }
}
