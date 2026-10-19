import CoreBluetooth
import Foundation

// MARK: - DingTalk A1 adapter
//
// Third card family in the registry, after D·NOTE and TicNote.
//
// What makes the A1 different from both of them is **not** the frame format (it is the
// easiest of the three: a length field, big-endian, JSON bodies) but the fact that it needs a
// **per-device credential** before it will answer anything interesting. `0x0008` hands out a
// challenge to anyone; `0x0133` must present an AES token derived from a secret that DingTalk
// minted when the card was bound. See `DingTalkA1Credential` for where that comes from and why
// it cannot be derived.
//
// Because of that, this spec can be "recognised" with no credential at all — which is exactly
// what scanning needs — while `DingTalkA1Link` refuses to pretend it can talk when there is no
// credential on file. The two concerns are kept apart on purpose: recognising a card must never
// depend on the user having done the import step yet, or the card simply wouldn't appear in the
// list and there would be nothing to explain.

enum DingTalkA1Spec: RecorderProtocolSpec {

    static let identifier = "dingtalk-a1"
    static let family = "DingTalk A1"

    // MARK: GATT

    static var serviceUUIDs: [CBUUID] { [DingTalkA1GATT.service] }
    static var rxCharacteristic: CBUUID { DingTalkA1GATT.commandCharacteristic }
    static var txCharacteristic: CBUUID { DingTalkA1GATT.notifyCharacteristic }

    // MARK: Broadcast identification
    //
    // Two independent signals, either of which is enough:
    //
    //   · the **service UUID** in the advertisement — ⚠️ iOS hands us the 16-bit form, i.e.
    //     `uuidString == "FE3C"`, **not** `0000FE3C-0000-…`. Comparing against the long form
    //     (or using `hasPrefix("0000FE3C")`) silently never matches. This cost an hour during
    //     the first scan.
    //   · the advertised name `DingTalk A1`, used only as a fallback for the case where the
    //     packet carries no service list at all (some Android stacks strip it; iOS sometimes
    //     delivers the name first and the service list in a later report).
    //
    // Identity = the manufacturer data, which on this card is the ASCII tail of the serial
    // number (`30 36 35 35` → `"0655"`, the last four characters of
    // `2010A1K262001N000655`). It is stable across reinstallations — unlike the peripheral UUID —
    // so it is what "remember this card" keys on, exactly like TicNote's SN bytes.
    static func parseAdvertisement(
        manufacturerData: Data?,
        localName: String?,
        serviceUUIDs: [CBUUID]?
    ) -> RecorderAdvertisement? {
        let hasService = (serviceUUIDs ?? []).contains { uuid in
            uuid.uuidString.uppercased().contains("FE3C")
        }
        let hasName = (localName ?? "").hasPrefix("DingTalk A1")
        guard hasService || hasName else { return nil }

        let tail = (manufacturerData ?? Data()).filter { byte in
            byte >= 0x30 && byte <= 0x39
        }
        let snTail = String(decoding: tail, as: UTF8.self)

        var raw: [String: AnyHashable] = [
            "snTail": snTail,
            "sawService": hasService,
            "sawName": hasName,
        ]
        if let localName { raw["localName"] = localName }

        return RecorderAdvertisement(
            protocolID: identifier,
            family: family,
            // ⚠️ Deliberately empty. The SN tail used to be stuffed in here, and the device
            // page then rendered "SN …0655 · 0655" (model + identity are joined by the caller).
            // The identity is already shown by every subtitle that wants it; the model slot
            // stays empty so `displayName` stays the clean "DingTalk A1".
            modelName: "",
            firmware: nil,
            hardware: nil,
            battery: nil,
            powerState: nil,
            // Never empty: `DiscoveredRecorder.identityHex` is the "remember this card" key,
            // and two A1s in range must not collapse into one row. Without manufacturer data
            // the name is the only thing left, and it is still better than an empty key.
            identity: tail.isEmpty ? Data("DingTalkA1".utf8) : tail,
            raw: raw
        )
    }

    // MARK: Frame and command

    static var frameCodec: RecorderFrameCodec { DingTalkA1FrameCodecAdapter() }

    /// ⚠️ `.unknown` is the **honest** value, not an oversight.
    ///
    /// `RecorderCommandSet` is a `UInt8` table and every A1 command is 16-bit with a non-zero
    /// high byte (`0x0110`, `0x0133`). Filling the table with truncated low bytes would give
    /// future callers numbers that are simply wrong. Capabilities are therefore expressed by
    /// `DingTalkA1Link`'s overrides; anything it cannot do throws `.unsupported`, which is the
    /// same shape the abstraction layer uses for every other card.
    static var commands: RecorderCommandSet { .unknown }

    /// No Wi-Fi fast channel. The A1's whole transfer story is BLE.
    static var wifiTransfer: RecorderWifiProfile? { nil }

    // MARK: Pairing and encryption

    /// The A1 has no "bond id" of our own — the account binding lives on DingTalk's side.
    static var bondIDLength: Int? { nil }
    /// Recordings are stored in the DTYJ container. Whether the payload inside is encrypted is
    /// a **per-file** property we detect at parse time (`DingTalkA1Audio`), not a key we hold.
    static var fileEncryptionKeyLength: Int? { nil }
    static var clipCipher: RecorderClipCipher.Type? { nil }

    // MARK: Evidence level

    /// Real card `2010A1K262001N000655` / `V1.6.98`: `0x0008` → AES token → `0x0133`
    /// returned **code 200**, `0x0132` reported battery 100 % / idle / storage, and `0x0110`
    /// answered `code 200` with an empty index. So authentication and the read handshake are
    /// no longer theoretical.
    static var isVerified: Bool { true }

    /// The **download** half (0x0111 → 0x0114 → 0x0115 → DTYJ → Ogg) has not been run against
    /// a card with a recording on it yet — there were none. Claiming otherwise here would make
    /// the detail page's banner lie, which is precisely why this flag exists separately from
    /// `isVerified`.
    static var isReadingVerified: Bool { false }

    /// `.beta`: it works, evidence exists, but "transfer a recording" is still the last mile.
    /// Hidden would mean the card can't even be found, which is no longer true.
    static var exposure: RecorderExposure { .beta }
}

/// Bridges the 16-bit command space into the abstraction layer's `UInt8` codec.
///
/// The abstraction's `encode(cmd: UInt8, …)` exists so different protocols can share one
/// signature; for the A1 it can only ever express the `0x00xx` half of the space (which
/// contains exactly one command we use, `0x0008`). `DingTalkA1Link` therefore never calls
/// through this adapter — it uses `DingTalkA1FrameCodec.frame(cmd:)`. The adapter exists to
/// satisfy `RecorderProtocolSpec.frameCodec` and to keep `decode` available, which *is*
/// protocol-complete (the header is the same for every command).
struct DingTalkA1FrameCodecAdapter: RecorderFrameCodec {

    func encode(cmd: UInt8, payload: Data) -> Data? {
        // Deliberately no truncation of `cmd` into the high byte: a caller asking for `0x10`
        // here means "command 0x0010", and `DingTalkA1Cmd` has no such case. Returning nil is
        // the fail-closed answer — silently sending something else is how a card ends up in a
        // state nobody can explain.
        guard let known = DingTalkA1Cmd(rawValue: UInt16(cmd)) else { return nil }
        return DingTalkA1FrameCodec.frame(cmd: known, seq: 0, payload: payload)
    }

    func decode(_ data: Data) -> RecorderFrame? {
        DingTalkA1FrameCodec.decode(data)
    }

    func encodeJSON(cmd: UInt8, _ object: [String: Any]) -> Data? {
        guard let known = DingTalkA1Cmd(rawValue: UInt16(cmd)) else { return nil }
        return DingTalkA1FrameCodec.frame(cmd: known, seq: 0, json: object)
    }
}
