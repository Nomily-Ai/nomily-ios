import Foundation

/// Resolves the 32-byte ChaCha20 key for a downloaded clip. Does NOT
/// prompt — UI surfaces a
/// "Set encryption passphrase" sheet when this returns nil while the
/// device's `deviceEncryptionOn` is true.
///
/// Decision table (caller observes `client.deviceEncryptionOn`):
///   device says OFF     → return nil; the post-download pipeline will
///                          either treat the file as plaintext or wrap raw
///                          OPUS frames. No Keychain lookup.
///   device says ON      → look up Keychain by SN; nil if none stored.
///   state unknown (nil) → return whatever Keychain has (best-effort);
///                          callers can still try decryption silently.
enum KeyResolver {
    /// Synchronous Keychain lookup. SN is taken from `client.lastDeviceInfo`
    /// when available; if the SN isn't known yet, returns nil and skips
    /// the Keychain read entirely (we'd have no account-scope key anyway).
    ///
    /// `@MainActor` because `DnoteClient`'s published state lives on the
    /// main actor. All current callers (LiveModel, FastTransferSheet.Model,
    /// RecordingsView) are themselves main-actor-isolated, so this stays
    /// a synchronous call from their perspective.
    @MainActor
    static func key(for client: DnoteClient) -> Data? {
        // OFF: skip Keychain
        if client.deviceEncryptionOn == false { return nil }
        guard let sn = client.lastDeviceInfo?.serial, !sn.isEmpty else { return nil }
        return PassphraseStore.load(sn: sn)
    }

    /// "Initialization incomplete": the firmware forces encryption, but this device lacks the corresponding passcode‑derived key.
    /// During this period the device writes recordings with a key unknown to the device, so the app cannot start a new recording.
    ///
    /// The criterion itself is persistent — the key resides in the Keychain, so the conclusion remains the same after app restart or reinstall,
    /// therefore we do not store a separate "completed" flag: such a flag could diverge from the actual state, which is exactly the acceptance item
    /// that guards against "re‑entering after exit should not falsely report as set".
    ///
    /// When the encryption state is unknown (`nil`, 0xA1 not yet read) we return false: better to let it pass than to lock the recording button
    /// because a single missed read would lock the recording button.
    @MainActor
    static func setupIncomplete(for client: DnoteClient) -> Bool {
        guard client.deviceEncryptionOn == true else { return false }
        guard let sn = client.lastDeviceInfo?.serial, !sn.isEmpty else { return false }
        return PassphraseStore.load(sn: sn) == nil
    }
}
