import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "passphrase-verify")

/// Verifies a candidate passphrase by recording a tiny clip on the device,
/// downloading it, and trial-decrypting with the derived key. The encrypted-
/// clip envelope's verify-block (see `ChaCha20.decryptClip`) returns a
/// `verifyMismatch` error on the wrong key, so we know with certainty
/// whether the user typed the right passphrase before we commit anything to
/// the Keychain.
///
/// Flow:
///   1. Start recording (CMD 0x51).
///   2. Sleep ~recordSeconds.
///   3. Stop recording (CMD 0x50) — the device finalises the clip.
///   4. Re-list files and pick the freshest one.
///   5. Download it via BLE.
///   6. Check the "encryt" magic; if absent the device isn't actually
///      encrypting (unexpected), so we treat the key as "no-op verified".
///   7. Call `ChaCha20.decryptClip` with the candidate key:
///      success → return `.matches`
///      `verifyMismatch` → return `.mismatch`
///      anything else → throw.
///   8. Always delete the probe clip from the device to avoid leaving
///      onboarding noise in the user's library.
enum PassphraseVerifier {
    enum Result {
        case matches              // verify-block passed
        case mismatch             // verify-block failed (wrong passphrase)
        case deviceNotEncrypting  // clip has no "encryt" magic — device is OFF
    }

    enum VerifyError: LocalizedError {
        case noFreshClip
        case deviceBusy(String)

        var errorDescription: String? {
            switch self {
            case .noFreshClip:
                return L10n.EncryptionOnboarding.errorProbeNotFound
            case .deviceBusy(let msg):
                return L10n.EncryptionOnboarding.errorDeviceBusy(msg)
            }
        }
    }

    /// Records, downloads, verifies. `recordSeconds` of 2–3 keeps the BLE
    /// download well under 10 s on a typical clip.
    @MainActor
    static func verify(
        passphrase: String,
        sn: String,
        client: DnoteClient,
        recordSeconds: Double = 2.5,
        progress: ((String) -> Void)? = nil
    ) async throws -> (result: Result, derivedKey: Data) {
        progress?(L10n.EncryptionOnboarding.progressDeriving)
        let key = try await Task.detached(priority: .userInitiated) {
            try PassphraseStore.derive(passphrase: passphrase, sn: sn)
        }.value

        // Snapshot the existing list so we can spot the new clip even if the
        // device's "latest" sort ordering is unexpected. This is also the
        // only thing that tells the probe apart from the user's own
        // recordings, so a failed snapshot has to stop the flow — treating
        // it as "no files existed" would make every real recording look
        // fresh, and the probe cleanup would delete one of them.
        guard let listed = try? await client.getFileList() else {
            throw VerifyError.deviceBusy(L10n.EncryptionOnboarding.errorProbeNotFound)
        }
        let before = Set(listed.map(\.name))

        progress?(L10n.EncryptionOnboarding.progressRecording)
        do {
            try await client.startRecording(bypassPassphraseGate: true)
        } catch {
            throw VerifyError.deviceBusy(error.localizedDescription)
        }

        // Use Task.sleep so cancellation propagates if the sheet is dismissed.
        try? await Task.sleep(nanoseconds: UInt64(recordSeconds * 1_000_000_000))

        progress?(L10n.EncryptionOnboarding.progressStopping)
        // The device must not be left recording. A single failed 0x50 used
        // to propagate straight out of here, leaving the pen running after
        // the sheet closed; retry once before giving up.
        let stopResult: [String: Any]
        do {
            stopResult = try await client.stopRecording()
        } catch {
            log.warning("verify: first stop failed (\(String(describing: error), privacy: .public)) — retrying")
            try? await Task.sleep(nanoseconds: 700_000_000)
            do {
                stopResult = try await client.stopRecording()
            } catch {
                throw VerifyError.deviceBusy(error.localizedDescription)
            }
        }
        // The 0x56 status push that accompanies stopRecording usually carries
        // the freshly-finalised clip name; prefer it when present.
        let stoppedName = (stopResult["name"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }

        progress?(L10n.EncryptionOnboarding.progressLocating)
        // Give the firmware a moment to flush the filesystem.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let afterList = try await client.getFileList()
        // The probe is only ever a file that **did not exist** before we
        // pressed record. Never fall back to "the newest file on the device":
        // on an encrypted pen holding real recordings that downloads and then
        // deletes one of the user's own. Nothing to identify means: fail,
        // delete nothing.
        let fresh = afterList.filter { !before.contains($0.name) && !$0.name.isEmpty }
        let probe: DeviceFile
        if let name = stoppedName, let match = fresh.first(where: { $0.name == name }) {
            probe = match
        } else if fresh.count == 1, let only = fresh.first {
            probe = only
        } else if fresh.count > 1, let newest = fresh.max(by: { $0.name < $1.name }) {
            log.warning("verify: \(fresh.count) new files appeared; taking newest \(newest.name, privacy: .public)")
            probe = newest
        } else {
            log.warning("verify: no new file after the probe recording — refusing to touch existing recordings")
            throw VerifyError.noFreshClip
        }
        log.info("verify probe=\(probe.name, privacy: .public) size=\(probe.size)")

        // Safe to delete unconditionally from here on: `probe` is a file
        // this function created. Pass or fail, the user didn't ask for it.
        defer {
            Task { _ = try? await client.deleteFile(probe.name) }
        }

        progress?(L10n.EncryptionOnboarding.progressDownloading)
        let data = try await client.downloadFile(probe.name, expectedSize: probe.size)

        progress?(L10n.EncryptionOnboarding.progressVerifying)
        guard ChaCha20.isEncryptedClip(data) else {
            return (.deviceNotEncrypting, key)
        }
        do {
            _ = try ChaCha20.decryptClip(data, key: key)
            return (.matches, key)
        } catch ChaCha20.DecryptError.verifyMismatch {
            return (.mismatch, key)
        } catch {
            throw error
        }
    }
}
