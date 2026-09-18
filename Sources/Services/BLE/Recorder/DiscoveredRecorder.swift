import CoreBluetooth
import Foundation

// MARK: - Protocol-agnostic scan results
//
// The division of labor with `DiscoveredPeripheral` (**deliberately split into two types, not duplication**):
//
//   · `DiscoveredPeripheral` is a **D·NOTE‑specific** snapshot: it carries the `DnoteProduct` enum,
//     `deviceSID`, firmware/hardware/battery, and it has run on real devices for a long time, persisted by `ConfigService`
//     Persisted by `deviceSIDHex`. **Do not modify it**, to keep D·NOTE's scan/connection/binding
//     behavior unchanged word‑for‑word in this change set — the biggest fear during migration is to "conveniently unify everything".
//   · `DiscoveredRecorder` is a **registry‑driven** generic shape: it only knows
//     `RecorderAdvertisement` (protocol‑agnostic), any new card just needs to be registered into
//     `RecorderProtocolRegistry` will appear in the scan list, no need to modify this file.
//
// The relationship is "coexistence" rather than "replacement". Once D·NOTE's connection chain also switches to `RecorderLink`, `DiscoveredPeripheral` can converge into a view of `DiscoveredRecorder`.
// 

/// A recorder card identified via the registry and already containing sufficient information in its advertisement.
///
/// Note: **this type does not mean "connected"**, only that the advertisement was recognized.
/// After connection, you obtain a `RecorderLink`.
struct DiscoveredRecorder: Identifiable, Hashable {

    /// The peripheral UUID assigned by iOS. **Not** the card identity — it changes when you switch phones or reinstall the app,
    /// Only suitable for deduplication and list keys within the current session.
    let id: UUID
    let peripheral: CBPeripheral

    /// The protocol that identifies it (registry entry).
    let protocolID: String
    /// Protocol‑agnostic identification result: family / model / firmware / battery / identity bytes.
    let advertisement: RecorderAdvertisement

    var localName: String?
    var rssi: Int
    var lastSeen: Date

    /// Card identity (TicNote = UTF‑8 bytes of an ASCII SN; D·NOTE = 3‑byte SID).
    /// Much more stable than `id`, suitable as a key for "remember this device".
    var identityHex: String {
        advertisement.identity.map { String(format: "%02X", $0) }.joined()
    }

    /// Human‑readable identity: if it can be decoded as UTF‑8, show the original text (as with TicNote's SN),
    /// otherwise fall back to hexadecimal.
    var identityText: String {
        if let s = String(data: advertisement.identity, encoding: .utf8), !s.isEmpty,
           s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
            return s
        }
        return identityHex
    }

    /// The name **reported by the card itself**: prefer the BLE advertisement name (may have been changed by the user in firmware),
    /// otherwise use the registry's "family + model".
    ///
    /// ⚠️ This should not be used directly in the UI — use `displayName`. Keeping the card's original wording unchanged here,
    /// because it is also used elsewhere (`RecorderIdentityStore` stores it,
    /// and during troubleshooting you need to distinguish "what the card says" from "what the user calls it").
    var name: String {
        if let local = localName, !local.isEmpty { return local }
        return advertisement.displayName
    }

    /// The name **to display** in the UI: prioritize the alias the user gave this card in the app, then fall back to the card's own name.
    ///
    /// ## Why "alias first" instead of directly modifying `name`
    /// Changing `name` would cause the "card‑reported name" to disappear from this type, even though it is used in two places
    /// (`RecorderIdentityStore.remember` and troubleshooting logs). By extracting a `displayName`
    /// the semantics become clean:
    /// ```
    /// name        ← the name spoken by the card in the advertisement (firmware truth)
    /// displayName ← what to display (user preference first)
    /// ```
    ///
    /// ## Why the alias is looked up here instead of at each call site
    /// The display name is used at seven call sites (scan list, two sheet titles, one line on the card info page, etc.).
    /// Having each call site use `alias ?? name` will eventually miss one — the symptom is "after renaming, some place still shows the old name"
    /// still showing the old name", and that kind of bug is hard to detect. Centralizing it here means changing `displayName` updates everywhere.
    ///
    /// ⚠️ The premise is that **the key must be based on the card's identity** (`identityHex` preferred, peripheral UUID as fallback),
    /// see `RecorderAliasStore.key` — if you use a global name field,
    /// the name given to card A would overwrite card B (the user explicitly requested not to hard‑code a single card).
    var displayName: String {
        RecorderAliasStore.shared.alias(for: self) ?? name
    }

    /// Whether the user has given this card a name (the card info page uses this to decide whether to show "restore card name").
    var hasAlias: Bool {
        RecorderAliasStore.shared.alias(for: self) != nil
    }

    var modelName: String { advertisement.modelName }

    /// The gray subtitle line in the list. **Only show what is available**, do not fill with estimated values
    /// (TicNote's firmware version is not present in the BLE protocol; it can only be retrieved via cloud deviceInfo after connection)
    var detailLine: String {
        var parts: [String] = ["SN \(identityText)"]
        if let fw = advertisement.firmware { parts.append(fw) }
        if let battery = advertisement.battery { parts.append("\(battery)%") }
        return parts.joined(separator: " · ")
    }

    /// Whether this protocol has been verified on a real device.
    var isVerifiedOnDevice: Bool {
        RecorderProtocolRegistry.spec(for: protocolID)?.isVerified ?? false
    }

    /// Whether the Bluetooth **read path** (discovery/list/download) has run on a real device.
    /// The detail page banner uses this, not `isVerifiedOnDevice` — the two have diverged for TicNote
    /// already forked (read path ✅, fast transfer ⛔), mixing a single flag banner would be misleading.
    var isReadingVerifiedOnDevice: Bool {
        RecorderProtocolRegistry.spec(for: protocolID)?.isReadingVerified ?? false
    }

    static func == (lhs: DiscoveredRecorder, rhs: DiscoveredRecorder) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
