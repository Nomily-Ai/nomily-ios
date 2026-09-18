import Combine
import Foundation

// MARK: - Names given to the card by the user (App-side alias)
//
// ## Why "Rename" in this flow is a **local alias** rather than a Bluetooth command
//
// The user wants "the ability to modify the current device's name". After checking both possible paths, the conclusion is:
//
// **① The official App's path goes through the cloud, which we cannot use**
// `MyDeviceLogic::changeName`（`blutter_out/asm/ticnote/modules/my_device/my_device_logic.dart`
// `:10180`) disassembles to: `getDio()` → `_RestClient()` → group `\{"sn": …, \"name\": …\}`
// → `await changeDeviceName()`. In other words, **the name displayed on the card exists in the Mobvoi account cloud**.
// We are a local App; we don't have, nor should we have, that account system.
//
// **② The card's own BLE command table does not contain a "Rename" entry at all**
// `WriteCmd` (`blutter_out/asm/ticnote/util/tools/dartBle/writeBle.dart`) has 27 functions
// Listed individually, they are:
// ```
// writeData convertArr2Buffer writeArr getUTF8Bytes
// syncFile delRecord getSesionList syncFileStop getBatt setUsbMode generalSetting
// readStatus syncTime readSsn firstHander sendToken getStorageVolume recordEnd
// recordStart setOtaFinish setOtaData setOta recordPause recordRestore openWifi
// clearData unbind
// ```
// — **None of setName / setBtName / setDeviceName exist**.
// (The Android SDK side does have `UteBleConnection.setDeviceBluetoothName(String)`,
// but it ends up in the heavily obfuscated `utejxfor` implementation, and `com.yc.nadalsdk` is a **multi-device family**
// public SDK; since the corresponding frame cannot be found in the card's command table, there is no real-device verifiable delivery path.)
//
// **③ Therefore this implementation provides an "App-side alias", and the UI will explain this clearly:
// What changes is **the name displayed in this App**, not the name broadcast by the card.
// This is not bypassing the requirement — the name shown on the card by the official app is also "stored elsewhere and read by the App for display",
// We simply replace the "elsewhere" from the cloud with the local device.
//
// ## Why it must be keyed by **the card's identity**, not a global field
// The user explicitly mentioned: "Future addition of ticnote cards with non-current SN must also be supported; we cannot hard‑code a single current card"
// the current card". Therefore:
//
// * Use the **card's real identity** as the primary key (TicNote = the ASCII SN in the broadcast, `identityHex`),
//   It remains stable across device changes/reinstall — the name persists after changing phones;
// * When `identityHex` is unavailable (old card / broadcast anomaly) fall back to iOS's peripheral UUID,
//   at least it is consistent within this device session;
// * **A global "device name" field is incorrect**: otherwise the name set for card A would overwrite that of card B.
//
// ## Length limit 20
// From the official copy pool (`blutter_out/pp.txt`): `\"Name too long (maximum 20 characters)\"`. 
// The card's own name limit is this number; the alias follows the same limit to avoid a situation where "the App can store 40 characters,
// but syncing to the card would truncate" – two conflicting rules.

/// The display name of the recorder card within **this App**.
///
/// Same approach as `RecorderIdentityStore` (`UserDefaults` + JSON + reconstructable cache),
/// only that side stores "who this card belongs to", while this side stores "what the user calls it".
///
/// ⚠️ Why `ObservableObject`: after renaming, the UI must **immediately** update. `DiscoveredRecorder.displayName`
/// reads from here, but it is a plain computed property; SwiftUI doesn't know to redraw — therefore the store itself
/// is attached as `@ObservedObject` / `@StateObject`; when `@Published` changes, the whole tree refreshes.
///
/// ⚠️ Why **no** `@MainActor` annotation (the sibling `RecorderIdentityStore` has one):
/// The entry point that reads it is `DiscoveredRecorder.displayName`, which is a **non-isolated computed property**
/// (the struct itself has no isolation annotation, yet it must be callable from any rendering path).
/// If annotated with `@MainActor`, that property would need to be changed to something like `MainActor.assumeIsolated`,
/// or duplicate the alias lookup across the seven call sites — the latter is more prone to omissions.
/// The actual constraint is enforced here: **all writes originate from UI actions** (always on the main thread),
/// reads are just a single dictionary lookup (non‑blocking, no I/O).
final class RecorderAliasStore: ObservableObject {

    static let shared = RecorderAliasStore()

    /// The card's own name limit, taken from the official copy (see the "Length limit 20" heading at the top of this file).
    static let maxLength = 20

    private static let storageKey = "ticnote.recorder_alias.v1"

    /// Alias table. Key = `key(identityHex:peripheralUUID:)`, value = the name entered by the user.
    @Published private(set) var aliases: [String: String] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Key

    /// Normalized key.
    ///
    /// * With identity (SN) → use identity, and **normalize case** (`s02510ycy36w3n9h` and
    ///   `S02510YCY36W3N9H` represent the same card, cannot be stored as two entries);
    /// * Without identity → fall back to peripheral UUID, also normalized.
    /// * Both empty → empty string; callers must treat it as "no key" (**must not** use the empty string for read/write,
    ///   otherwise all cards "without readable identity" would share the same name).
    static func key(identityHex: String, peripheralUUID: String = "") -> String {
        let identity = identityHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !identity.isEmpty { return "sn:" + identity }
        let uuid = peripheralUUID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !uuid.isEmpty { return "uuid:" + uuid }
        return ""
    }

    /// Validate user input: trim leading/trailing whitespace; if empty or too long, return `nil` (**do not** truncate —
    /// silent truncation would make the user think their input succeeded).
    static func sanitized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }

    // MARK: Read

    /// Whether a user‑defined name exists (the UI uses this to decide whether to show "Restore card's original name").
    func hasAlias(identityHex: String, peripheralUUID: String = "") -> Bool {
        alias(identityHex: identityHex, peripheralUUID: peripheralUUID) != nil
    }

    /// Fetch alias. `nil` = user has never set one (UI should fall back to the card's own name).
    func alias(identityHex: String, peripheralUUID: String = "") -> String? {
        let k = Self.key(identityHex: identityHex, peripheralUUID: peripheralUUID)
        guard !k.isEmpty else { return nil }
        guard let value = aliases[k], !value.isEmpty else { return nil }
        return value
    }

    // MARK: Write

    /// Naming / renaming / clearing.
    ///
    /// The semantics of the three inputs **must be separated** (this rule came from self‑inspection, not assumption):
    ///
    /// | Input | Action |
    /// |---|---|
    /// | `nil` | **Clear** alias, UI falls back to the card's own name |
    /// | Only whitespace (`"   "`, `""`) | Same as above — user cleared the field, meaning "no alias" |
    /// | After trimming, **too long** | **Reject**, and **keep the original name** |
    ///
    /// The last row is critical: early versions merged "too long" and "clear" into the same path
    /// (`sanitized` returned `nil` for both → fell into `removeValue`),
    /// resulting in the user typing an extra character and clicking save, **the previously good name disappeared**.
    /// This is not "strict validation", it's silent data loss.
    ///
    /// - Returns: after persisting, **the current name of this card** (`nil` = no name: cleared, or never existed).
    ///   When rejected, returns the **unchanged previous value** — the caller can compare to know the write was not applied.
    @discardableResult
    func setAlias(_ name: String?,
                  identityHex: String,
                  peripheralUUID: String = "") -> String? {
        let k = Self.key(identityHex: identityHex, peripheralUUID: peripheralUUID)
        guard !k.isEmpty else { return nil }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)

        // ① Too long → reject, **do not touch** the existing stored name.
        if let trimmed, !trimmed.isEmpty, trimmed.count > Self.maxLength {
            return aliases[k]
        }

        // ② Non‑empty → write; ③ nil / all whitespace → clear.
        if let trimmed, !trimmed.isEmpty {
            aliases[k] = trimmed
        } else {
            aliases.removeValue(forKey: k)
        }
        persist()
        return aliases[k]
    }

    /// Forget a card's name (called when unbinding — the card is handed over, keeping a name is meaningless).
    func forget(identityHex: String, peripheralUUID: String = "") {
        let k = Self.key(identityHex: identityHex, peripheralUUID: peripheralUUID)
        guard !k.isEmpty, aliases[k] != nil else { return }
        aliases.removeValue(forKey: k)
        persist()
    }

    // MARK: Persist

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        // If it cannot be decoded, treat it as never saved — this is a **reconstructable preference**, not worth erroring,
        // and must not inadvertently delete user‑stored data elsewhere (same as `RecorderIdentityStore.load`).
        aliases = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

// MARK: - A gateway for `DiscoveredRecorder`

extension RecorderAliasStore {

    /// Retrieve alias from a scan result. **This is the only entry point the UI should use** ——
    /// It consolidates the "identity first, UUID fallback" rule in one place, avoiding ad‑hoc key construction at each call site.
    func alias(for recorder: DiscoveredRecorder) -> String? {
        alias(identityHex: recorder.identityHex, peripheralUUID: recorder.id.uuidString)
    }

    /// Assign or clear a name for a scan result.
    @discardableResult
    func setAlias(_ name: String?, for recorder: DiscoveredRecorder) -> String? {
        setAlias(name, identityHex: recorder.identityHex, peripheralUUID: recorder.id.uuidString)
    }
}
