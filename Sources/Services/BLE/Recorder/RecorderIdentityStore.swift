import CoreBluetooth
import Foundation

// MARK: - Remember "who this card is"
//
// ## Why is it needed (user reports "not smooth enough, have to keep tapping reconnect")
//
// The current reconnection has only one path: **scan → wait for broadcast → match by peripheral UUID → connect**
// (`BluetoothCoordinator.reconnectRecorder`). The problem with this path is not that it's written incorrectly,
// but that it **relies on the card actively broadcasting**, and this card's broadcast is power‑saving — measured intervals can reach 152 seconds
// (see the long comment in `BluetoothCoordinator.connectRecorder`). Thus the user sees
// "tap does nothing, need to tap repeatedly", and finally a timeout tells them "short‑press the record button to wake up"
//
// ## Why cache **those fields from the broadcast** instead of just storing a UUID
//
// `TicNoteLink`'s initializer signature is `init(peripheral:central:serialNumber:)`, and
// `**SN can only be obtained from the broadcast** (`DiscoveredRecorder.identityText`). SN is also
// `**the sole source of Wi‑Fi fast‑transfer credentials** (`SSID = "TicNote-" + last 4 digits of SN`, `password = last 8 digits of SN`).`
// So "connect without scanning" if it only includes the UUID, the link can connect, but the fast‑transfer button will never light up —
// The symptom looks exactly like "the card does not provide credentials"
//
// Therefore we store **the raw broadcast identity bytes (hex)** here, not the decoded string:
// `DiscoveredRecorder.identityText`'s UTF‑8 decoding rule (only letters/digits/`-`/`_` are considered text)
// so it can be reused as‑is, without introducing a second decoding rule at the cache layer.
//
// ## Why look up by `peripheralUUID` while also keeping an `identityHex`
//
// The peripheral UUID assigned by iOS **changes when the phone is swapped / the app is reinstalled**, so it can only serve as
// "the fast‑path key for the current phone". The `recordID` in the ledger uses exactly this
// (`RootView.connectRecorderDevice(id:)` → `reconnectRecorder(recordID:)`).
// the comparison is `link.peripheral.identifier.uuidString`, so the primary key must be it.
// Keeping `identityHex` is only for logs/troubleshooting to match "which card".

/// The "who this card is" remembered after a successful connection
///
/// "Once successfully connected" timing is intentional: **only truly connected** qualifies for this cache ——
/// Just scanning (where `DiscoveredRecorder` exists in `discoveredRecorders`) does not count,
/// because at that moment we don't know if it can connect.
struct RecorderIdentity: Codable, Equatable {

    /// The UUID assigned by iOS to this peripheral (lowercase standard form, matching `UUID.uuidString`).
    /// **Changes with device/app reinstall** — so it only serves as the "local fast‑path" key.
    var peripheralUUID: String

    /// Protocol registry entry (`RecorderProtocolSpec.identifier`). At connection time, select implementation based on it,
    /// using the wrong one yields `RecorderLinkError.unsupported`, instead of silently connecting incorrectly.
    var protocolID: String

    /// The **raw identity bytes** (hex) from the broadcast. TicNote is the ASCII SN encoded in UTF‑8.
    /// Store hex instead of text, see the top of this file.
    var identityHex: String

    var family: String
    var modelName: String
    /// Broadcast name (may be changed by the user in firmware). Empty string = no broadcast name at that time.
    var localName: String
    /// RSSI from the last successful connection, used only for display/troubleshooting.
    var rssi: Int

    var lastConnectedAt: Date

    /// The most convenient display name, consistent with the choice used for `DiscoveredRecorder.name`.
    var displayName: String {
        localName.isEmpty ? "\(family) \(modelName)" : localName
    }

    /// Identity bytes. If hex cannot be decoded, give an empty `Data` (`DiscoveredRecorder.identityHex` will become empty,
    /// so `identityText` falls back to an empty string → fast‑transfer button stays off, instead of getting an incorrect SN).
    var identity: Data { Data(hexString: identityHex) ?? Data() }
}

/// Persistence of the recorder card identity. Stored in `UserDefaults.standard`.
///
/// ## Why use `UserDefaults` instead of the `ConfigService` suite
/// `ConfigService` (ledger) stores a **user‑visible device list**, fields (name /
/// DEVICE_SID / bond_id) have no overlap with what we need here; moreover its write points are scattered across
/// the binding/pairing process. What we need here is a **pure technical cache**: overwrite when connected, ignore when not connected,
/// rebuild when broken — inserting into the ledger would just add a bunch of fields users shouldn't see.
///
/// Uses the same storage domain as `@AppStorage("ticnote.delete_after_transfer")`, without introducing a new container.
@MainActor
final class RecorderIdentityStore {

    static let shared = RecorderIdentityStore()

    private static let storageKey = "ticnote.recorder_identity.v1"

    /// Keep only a few entries at most. Real phones won't be connected to many cards simultaneously;
    /// Keeping too many just adds the judgment of "which one is the one I want". Newer entries come first.
    private static let limit = 8

    private let defaults: UserDefaults
    private(set) var identities: [RecorderIdentity] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Read

    /// Fetch by iOS peripheral UUID (main reconnection path).
    func identity(peripheralUUID: String) -> RecorderIdentity? {
        identities.first { $0.peripheralUUID.caseInsensitiveCompare(peripheralUUID) == .orderedSame }
    }

    /// Fetch by the card's real identity (covers cases where peripheralUUID changes after device/app reinstall).
    func identity(identityHex: String) -> RecorderIdentity? {
        guard !identityHex.isEmpty else { return nil }
        return identities.first { $0.identityHex.caseInsensitiveCompare(identityHex) == .orderedSame }
    }

    // MARK: Write

    /// Record the next successful connection. Existing records with the same UUID or same identity will be **replaced** (not appended) —
    /// otherwise the same card connecting 20 times would leave 20 nearly identical records, and the first one would have stale RSSI.
    func remember(_ identity: RecorderIdentity) {
        identities.removeAll {
            $0.peripheralUUID.caseInsensitiveCompare(identity.peripheralUUID) == .orderedSame
                || (!identity.identityHex.isEmpty
                    && $0.identityHex.caseInsensitiveCompare(identity.identityHex) == .orderedSame)
        }
        identities.insert(identity, at: 0)
        if identities.count > Self.limit { identities.removeLast(identities.count - Self.limit) }
        persist()
    }

    /// Record once from a scan result (called after successful connection).
    func remember(_ recorder: DiscoveredRecorder) {
        remember(RecorderIdentity(
            peripheralUUID: recorder.id.uuidString,
            protocolID: recorder.protocolID,
            identityHex: recorder.identityHex,
            family: recorder.advertisement.family,
            modelName: recorder.advertisement.modelName,
            localName: recorder.localName ?? "",
            rssi: recorder.rssi,
            lastConnectedAt: Date()
        ))
    }

    /// Forget a record (used when a connection fails and it's confirmed "this is not that card").
    func forget(peripheralUUID: String) {
        let before = identities.count
        identities.removeAll {
            $0.peripheralUUID.caseInsensitiveCompare(peripheralUUID) == .orderedSame
        }
        if identities.count != before { persist() }
    }

    // MARK: Persist

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        // If it can't be decoded, treat as never stored — this is a **rebuildable cache**, not worth erroring over or clearing other user data.
        identities = (try? JSONDecoder().decode([RecorderIdentity].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(identities) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
