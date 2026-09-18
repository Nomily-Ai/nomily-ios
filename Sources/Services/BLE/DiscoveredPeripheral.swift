import CoreBluetooth
import Foundation

/// SwiftUI-friendly snapshot of a D·NOTE peripheral the scanner has seen.
/// Every entry has already passed the manufacturer-data filter (CID 0x22A3 +
/// known BID/PID), so `product` and `deviceSID` are always populated.
struct DiscoveredPeripheral: Identifiable, Hashable {
    let id: UUID
    let peripheral: CBPeripheral
    /// Raw BLE local name from the advertisement. Carried for display only —
    /// the scan filter never matches against this string.
    var localName: String?
    var rssi: Int
    var product: DnoteProduct
    /// 3 raw bytes; rendered as uppercase hex for display & persistence.
    var deviceSID: Data
    var firmware: UInt16
    var hardware: UInt16
    var battery: UInt8
    var powerState: UInt8
    var lastSeen: Date

    var deviceSIDHex: String {
        deviceSID.map { String(format: "%02X", $0) }.joined()
    }

    var firmwareString: String {
        String(format: "v%d.%d", (firmware >> 8) & 0xFF, firmware & 0xFF)
    }

    /// User-facing label: prefer the BLE local name (which may be user-customised
    /// via the firmware) and fall back to the catalog display name.
    var name: String {
        if let local = localName, !local.isEmpty { return local }
        return product.displayName
    }

    static func == (lhs: DiscoveredPeripheral, rhs: DiscoveredPeripheral) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
