import Foundation

/// Which known device do we reconnect to, and by which identity. Records
/// written before the DEVICE_SID field existed only carry the iOS peripheral
/// UUID, so both paths have to stay supported — and both callers (RootView's
/// auto-reconnect and the watch command channel) have to agree on the answer.
@MainActor
enum PreferredDevice {
    /// Reconnect using DEVICE_SID when the record has it (portable across
    /// reinstalls and new phones); fall back to the legacy iOS-UUID path so
    /// records written before the SID field existed still auto-reconnect.
    ///
    ///
    /// Note for anyone reconnecting from a background-launched context: the SID
    /// route finds its device by scanning, and `startScan` scans unfiltered
    /// (`withServices: nil`), which iOS silently returns nothing for while an
    /// app is backgrounded. Only the UUID route (`retrievePeripherals` +
    /// connect) works there.
    static func reconnect(
        recordID: String,
        bluetooth: BluetoothCoordinator,
        config: ConfigService
    ) async throws -> DnoteClient {
        if let sidHex = config.config.devices[recordID]?.deviceSID,
           let sid = Data(hexString: sidHex) {
            return try await bluetooth.reconnect(deviceSID: sid)
        }
        guard let uuid = UUID(uuidString: recordID) else { throw DnoteError.notConnected }
        return try await bluetooth.reconnect(deviceID: uuid)
    }
}
