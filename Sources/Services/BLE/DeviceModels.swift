import Foundation

/// Mirrors the JSON returned by CMD 0x80. Only the fields the UI consumes
/// today are surfaced as typed properties; the raw dictionary is retained for
/// forward compatibility (firmware sometimes adds keys).
struct DeviceInfo: Equatable {
    let raw: [String: AnyHashable]

    var serial: String?         { raw["sn"] as? String }
    var firmware: String?       { raw["v"] as? String }
    var deviceTime: String?     { raw["time"] as? String }
    var bluetoothName: String?  { raw["bt"] as? String }
    var bluetoothMAC: String?   { raw["btaddr"] as? String }
    var battery: Int?           { (raw["bat"] as? NSNumber)?.intValue }
    var isCharging: Bool        { (raw["usb"] as? NSNumber)?.intValue == 1 }
    var isRecording: Bool       { (raw["rec"] as? NSNumber)?.intValue == 1 }
    var recordingMode: Int?     { (raw["recmode"] as? NSNumber)?.intValue }
    var freeMB: Int?            { (raw["df"] as? NSNumber)?.intValue }
    var totalMB: Int?           { (raw["total_df"] as? NSNumber)?.intValue }
    var wifiAPOn: Bool          { (raw["wifiap"] as? NSNumber)?.intValue == 1 }
    var wifiSTAOn: Bool         { (raw["wifista"] as? NSNumber)?.intValue == 1 }

    init(json: [String: Any]) {
        var hashable: [String: AnyHashable] = [:]
        for (k, v) in json {
            if let h = v as? AnyHashable { hashable[k] = h }
        }
        self.raw = hashable
    }

    init(raw: [String: AnyHashable]) {
        self.raw = raw
    }

    /// Returns a copy with `key` set to `value`. Used to reflect state
    /// deltas carried by notifications (e.g. CMD 0x55 → `rec=0`) without
    /// waiting for the next `getDeviceInfo` round-trip.
    func setting(_ key: String, to value: AnyHashable) -> DeviceInfo {
        var updated = raw
        updated[key] = value
        return DeviceInfo(raw: updated)
    }
}

/// Mirrors the JSON returned by CMD 0x81.
struct SwitchInfo: Equatable {
    let raw: [String: AnyHashable]

    var massStorage: Bool   { intFlag("ms") }
    var led: Bool           { intFlag("led") }
    var motor: Bool         { intFlag("motor") }
    var noiseCancel: Bool   { intFlag("nc") }
    var saveWAV: Bool       { intFlag("wav") }
    var vad: Bool           { intFlag("vad") }
    var micGain: Int        { (raw["gain"] as? NSNumber)?.intValue ?? 0 }
    var noiseReduction: Int { (raw["nn"]   as? NSNumber)?.intValue ?? 0 }
    var idleOff: UInt32     { (raw["autoff"] as? NSNumber)?.uint32Value ?? 0 }

    var idleOffIsNever: Bool { idleOff == DnoteProtocol.idleOffNever }

    init(json: [String: Any]) {
        var hashable: [String: AnyHashable] = [:]
        for (k, v) in json {
            if let h = v as? AnyHashable { hashable[k] = h }
        }
        self.raw = hashable
    }

    private func intFlag(_ key: String) -> Bool {
        (raw[key] as? NSNumber)?.intValue == 1
    }
}

/// One entry in the device's recorded-file list (CMD 0x90 reply).
/// Mirrors the `{index, name, size, end}` JSON object emitted by the device.
struct DeviceFile: Identifiable, Equatable, Hashable {
    let index: Int
    let name: String
    let size: Int

    var id: String { name }
    var displayTitle: String { RecordingName.displayTitle(for: name) }
}
