import Foundation
import NetworkExtension
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "hotspot")

/// Wraps `NEHotspotConfigurationManager` so the Fast Transfer flow can ask
/// iOS to join the device's AP temporarily. Requires the
/// `com.apple.developer.networking.HotspotConfiguration` entitlement (set in
/// `project.yml` under `entitlements.properties`) and a paid Apple Developer
/// account.
///
/// On iOS, a configuration applied with `joinOnce=true` auto-removes once
/// the app terminates or the network disconnects — perfect for a one-off
/// transfer session. We also explicitly `removeConfiguration(forSSID:)`
/// in the flow's cleanup so the user's phone hops back to its regular Wi-Fi
/// (or LTE) as soon as we're done.
@MainActor
enum HotspotJoiner {
    /// Apply the hotspot config. The system presents a join prompt the
    /// first time; subsequent sessions in the same app install reconnect
    /// silently as long as the config is still applied.
    ///
    /// - Throws: `HotspotError` on user cancel, missing entitlement, or
    ///   `NEHotspotConfigurationError` forwarded verbatim.
    static func apply(ssid: String, psk: String) async throws {
        // Remove any stale config from a previous attempt so iOS presents
        // the join-confirmation prompt and doesn't silently reuse a config
        // whose underlying connection already failed.
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)

        let config = NEHotspotConfiguration(ssid: ssid, passphrase: psk, isWEP: false)
        config.joinOnce = true
        config.lifeTimeInDays = 1

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                NEHotspotConfigurationManager.shared.apply(config) { error in
                    if let error = error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            log.info("hotspot applied ssid=\(ssid, privacy: .public)")
        } catch let error as NSError {
            if error.domain == NEHotspotConfigurationErrorDomain,
               error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                log.info("hotspot already joined ssid=\(ssid, privacy: .public)")
                return
            }
            if error.domain == NEHotspotConfigurationErrorDomain,
               error.code == NEHotspotConfigurationError.userDenied.rawValue {
                throw HotspotError.userDenied
            }
            // iOS's original text ("Unable to join the network …") is a system English string,
            // unreadable to the user and offers no next step. The raw domain/code is retained in the logs,
            // and the panel replaces it with our own actionable wording.
            log.error("hotspot apply failed: \(error.domain, privacy: .public) code=\(error.code, privacy: .public) \(error.localizedDescription, privacy: .public)")
            throw HotspotError.joinFailed
        }
    }

    /// Remove our hotspot config so the phone leaves the AP.
    static func remove(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        log.info("hotspot removed ssid=\(ssid, privacy: .public)")
    }
}

enum HotspotError: LocalizedError {
    case userDenied
    /// iOS rejected the join request (other `NEHotspotConfigurationError` codes). A typical case is
    /// the device reports `wifiap=1` but the hotspot is not actually broadcasting; the hotspot must be toggled off and on before retrying.
    case joinFailed

    var errorDescription: String? {
        switch self {
        case .joinFailed:
            return NSLocalizedString(
                "hotspot_error.join_failed",
                value: "Couldn't join the device's Wi-Fi hotspot. Tap Retry — the app will restart the hotspot and try again.",
                comment: "Fast transfer: iOS refused to join the recorder's AP"
            )
        case .userDenied:
            return NSLocalizedString(
                "hotspot_error.user_denied",
                value: "You declined the Wi-Fi join prompt. Tap Fast Transfer again to retry.",
                comment: "Fast transfer: user tapped Cancel on the iOS join sheet"
            )
        }
    }
}
