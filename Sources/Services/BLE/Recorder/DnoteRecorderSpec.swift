import CoreBluetooth
import Foundation

// MARK: - D·NOTE adapter
//
// `DnoteProtocol` / `PacketCodec` / `DnoteAdvertisement` are existing implementations, **this file does not modify them**,
// Just translate them "translate" into the protocol-agnostic `RecorderProtocolSpec` shape.
// Thus `BluetoothCoordinator` can gradually be refactored to spec-oriented programming, while D·NOTE's behavior remains unchanged
// — migration period both interfaces coexist, can roll back at any issue.

/// Wrap `PacketCodec`'s `[PID][CMD][LEN][PAYLOAD]` into `RecorderFrameCodec`.
struct DnoteFrameCodec: RecorderFrameCodec {
    func encode(cmd: UInt8, payload: Data) -> Data? {
        guard payload.count <= 0xFF else { return nil }
        // PacketCodec.encode contains precondition(payload.count <= 0xFF),
        // Therefore we must guard it here first, preventing the upper layer from passing a long payload that would cause a crash.
        return PacketCodec.encode(cmd: cmd, payload: payload)
    }

    func decode(_ data: Data) -> RecorderFrame? {
        guard let f = PacketCodec.decode(data) else { return nil }
        // D·NOTE has no "message type" layer; type is fixed at 0.
        return RecorderFrame(type: 0, cmd: UInt16(f.cmd), length: f.length, payload: f.payload)
    }

    func encodeJSON(cmd: UInt8, _ object: [String: Any]) -> Data? {
        try? PacketCodec.encodeJSON(cmd: cmd, object)
    }
}

/// Protocol specifications for D·NOTE (V05 / V03 / R101 / P101 series).
enum DnoteRecorderSpec: RecorderProtocolSpec {

    static let identifier = "dnote"
    static let family = "D·NOTE"

    // MARK: GATT

    static var serviceUUIDs: [CBUUID] {
        [DnoteProtocol.serviceUUID, DnoteProtocol.serviceUUIDShort]
    }
    static var rxCharacteristic: CBUUID { DnoteProtocol.rxCharUUID }
    static var txCharacteristic: CBUUID { DnoteProtocol.txCharUUID }

    // MARK: Broadcast identification
    //
    // D·NOTE's identification string is:
    //   Manufacturer data = [CID(0x22A3, LE → A3 22)][BID(2)][PID(2)][FW(2)][HW(2)][BAT(1)][PWR(1)][SID(3)]
    //   And (BID, PID) must match `DnoteProduct.catalog`.
    // No fallback based on Bluetooth name — the name can be changed by the user, so it cannot be used for identity verification.

    static func parseAdvertisement(
        manufacturerData: Data?,
        localName: String?,
        serviceUUIDs: [CBUUID]?
    ) -> RecorderAdvertisement? {
        guard let mfg = manufacturerData,
              let adv = DnoteAdvertisement.parse(mfg),
              let product = DnoteProduct.match(bid: adv.bid, pid: adv.pid)
        else { return nil }

        return RecorderAdvertisement(
            protocolID: identifier,
            family: product.family,
            modelName: product.modelName,
            firmware: String(format: "v%d.%d", (adv.firmware >> 8) & 0xFF, adv.firmware & 0xFF),
            hardware: String(format: "%d.%d", (adv.hardware >> 8) & 0xFF, adv.hardware & 0xFF),
            battery: Int(adv.battery),
            powerState: Int(adv.powerState),
            identity: adv.deviceSID,
            raw: [
                "bid": Int(adv.bid),
                "pid": Int(adv.pid),
                "firmwareRaw": Int(adv.firmware),
                "hardwareRaw": Int(adv.hardware),
                "localName": localName ?? "",
            ]
        )
    }

    // MARK: Frame and command

    static var frameCodec: RecorderFrameCodec { DnoteFrameCodec() }

    static var commands: RecorderCommandSet {
        RecorderCommandSet(
            startRecording: DnoteProtocol.Cmd.startRec,
            stopRecording: DnoteProtocol.Cmd.stopRec,
            recordingStatus: DnoteProtocol.Cmd.recStatus,
            recordingStartedEvent: DnoteProtocol.Cmd.recStarted,
            recordingStoppedEvent: DnoteProtocol.Cmd.recStopped,
            liveStream: DnoteProtocol.Cmd.stream,
            fileTransfer: DnoteProtocol.Cmd.xfer,
            deviceInfo: DnoteProtocol.Cmd.deviceInfo,
            switchInfo: DnoteProtocol.Cmd.switchInfo,
            fileList: DnoteProtocol.Cmd.fileList,
            fileDelete: DnoteProtocol.Cmd.fileDelete,
            syncTime: DnoteProtocol.Cmd.syncTime,
            extended: [
                "massStorage": DnoteProtocol.Cmd.massStorage,
                "led": DnoteProtocol.Cmd.led,
                "motor": DnoteProtocol.Cmd.motor,
                "noiseCancel": DnoteProtocol.Cmd.noiseCancel,
                "btNameShort": DnoteProtocol.Cmd.btNameShort,
                "btNameLong": DnoteProtocol.Cmd.btNameLong,
                "wifiAP": DnoteProtocol.Cmd.wifiAP,
                "saveWAV": DnoteProtocol.Cmd.saveWAV,
                "vad": DnoteProtocol.Cmd.vad,
                "micGain": DnoteProtocol.Cmd.micGain,
                "nrLevel": DnoteProtocol.Cmd.nrLevel,
                "idleOff": DnoteProtocol.Cmd.idleOff,
                "factoryReset": DnoteProtocol.Cmd.factoryReset,
                "formatDisk": DnoteProtocol.Cmd.formatDisk,
                "shutdown": DnoteProtocol.Cmd.shutdown,
                "bind": DnoteProtocol.Cmd.bind,
                "queryBond": DnoteProtocol.Cmd.queryBond,
                "encryptSet": DnoteProtocol.Cmd.encryptSet,
                "encryptQuery": DnoteProtocol.Cmd.encryptQuery,
            ]
        )
    }

    // MARK: Wi‑Fi fast transfer (192.168.88.1:6718, frame header 0xAA, text command)

    static var wifiTransfer: RecorderWifiProfile? { .dnote }

    // MARK: Pairing and encryption

    /// 16‑byte app-chosen pairing identifier (from v1.47 devices refuse recording without pairing)
    static var bondIDLength: Int? { DnoteProtocol.bondIDLength }
    /// ChaCha20 key length; from v1.47 devices encrypt recording files on the device side
    static var fileEncryptionKeyLength: Int? { DnoteProtocol.chachaKeyLength }

    /// ★ Pre‑save access control — implementation for V05E resides in `DnoteClipCipher`:
    /// `"encryt"` magic number + 60‑byte envelope + ChaCha20 + verify block, 32‑byte key stored per SN in the keychain.
    static var clipCipher: RecorderClipCipher.Type? { DnoteClipCipher.self }

    /// Verified on real devices. See `docs/` and the README for protocol specifications.
    static var isVerified: Bool { true }

    /// Official release: long‑term real‑device usage, `.general`.
    static var exposure: RecorderExposure { .general }
}
