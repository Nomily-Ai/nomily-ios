import Foundation

// MARK: - Recording file's "pre‑save access control" — abstract D·NOTE(V05E) logic into a protocol‑agnostic form
//
// D·NOTE (V05E, firmware v1.47+) defines the processing logic as:
//
//   1. **Query device first**: `encryptQuery`(0xA3) → `deviceEncryptionOn`;
//   2. Device says **off** → process as plaintext, **do not** look up the keychain;
//   3. Device says **on** → must retrieve a 32‑byte key using **SN**:
//        · Key present → decrypt + **verify signature** (V05E's 60‑byte envelope includes a verify block);
//        · No key → **reject save**, and guide the user to set a passcode;
//   4. Unknown state (not yet read) → do the best effort: use whatever the keychain provides, and report an error if decryption fails.
//
// The key property of this logic is **fail‑closed**: if any step is uncertain, never allow ciphertext
// to be stored as WAV in the user library — otherwise the user would receive a recording that can never be opened,
// and the original device-side file may have already been cleared by a “transfer‑then‑delete” policy.
//
// This file only adds **new** content, does not modify existing files; wiring details are in `docs/RecorderProtocolMigration.md`.

// MARK: - A protocol's complete declaration of whether/how a recording file is encrypted

/// Each protocol implements its encryption facts in this shape, and upper layers depend only on the semantics.
/// The two meanings of a `nil` key length must be distinguished:
///   · This protocol **does not perform** device‑side encryption (also the case when V05E's `deviceEncryptionOn == false`);
///   · Or the protocol **does** encrypt but we have not reverse‑engineered it yet — the latter is distinguished by `envelopeName` and
///     `RecorderClipGate`'s `.opaque` branch, and must never be conflated.
protocol RecorderClipCipher {
    /// Human‑readable envelope name, appears in logs and error messages. Example: `"encryt (ChaCha20)"`.
    static var envelopeName: String { get }

    /// This protocol **does** encrypt recordings (regardless of whether the local device can decrypt them).
    ///
    /// The sole purpose of this flag is to make `RecorderClipGate` fail‑closed when the **device state is unknown**.
    /// The default value is `true` — deliberately choosing the “prefer to reject” side:
    /// If a third card is added later and this is omitted, the behavior will be “refuse to save” rather than “store ciphertext as a recording”.
    static var encryptsClips: Bool { get }

    /// Whether this protocol **has** an encryption toggle that the App can enable/disable.
    ///
    /// · D·NOTE (V05E) **has**: `encryptSet`(0xA2) to write keys, `encryptQuery`(0xA3) to read status,
    ///   so `deviceEncryptionOn == false` is a **meaningful** input → process as plaintext.
    /// · TicNote **does not have**: the real device only sent 0x01/0x03/0x04/0x06/0x08/0x09/0x0C/0x1A/0x1C/0x1D,
    ///   no command to turn encryption on/off can be found, it is always encrypted. Therefore
    ///   `deviceEncryptionOn == false` is a **contradictory** input for it, and the access control must treat it as an exception rather than “just process as plaintext”.
    static var hasEncryptionToggle: Bool { get }

    /// Key length (bytes) for device‑side file encryption. `nil` = this protocol does not participate in device‑side encryption.
    static var keyLength: Int? { get }

    /// Pure content sniffing: whether this data carries this protocol's encryption envelope.
    /// **Only the content may be inspected, not the filename/extension.**
    static func isEncryptedClip(_ data: Data) -> Bool

    /// Decryption. Throwing an error indicates “wrong key” or “not this protocol's envelope” —
    /// the caller must treat it as a **failure**, and must not fall back to “use as plaintext”.
    static func decrypt(_ data: Data, key: Data) throws -> Data
}

extension RecorderClipCipher {
    /// Default fail‑closed: protocols that do not state otherwise are treated as “will encrypt”.
    static var encryptsClips: Bool { true }
    /// Default assumes a toggle (consistent with V05E); protocols with constant encryption should explicitly set it to `false`.
    static var hasEncryptionToggle: Bool { true }
}

// MARK: - Implementation for D·NOTE / V05E (wrapping existing ChaCha20, behavior unchanged)

/// V05E: `"encryt"` magic number + 60‑byte header (magic 6B + SN 18B + nonce 12B + verify 24B),
/// ChaCha20 stream cipher decrypts starting at offset 36, and verifies that the first 24 plaintext bytes equal the original header.
struct DnoteClipCipher: RecorderClipCipher {
    static var envelopeName: String { "encryt (ChaCha20, 60‑byte envelope)" }
    /// V05E's encryption is a **device‑side toggle** (`encryptSet` 0xA2 / `encryptQuery` 0xA3).
    /// When the toggle is on, files must contain the `"encryt"` magic number; when off, they are plaintext.
    /// The `true` flag is to make it fail‑closed when the "state is unread".
    static var encryptsClips: Bool { true }
    static var keyLength: Int? { DnoteProtocol.chachaKeyLength }   // 32

    static func isEncryptedClip(_ data: Data) -> Bool {
        ChaCha20.isEncryptedClip(data)
    }

    static func decrypt(_ data: Data, key: Data) throws -> Data {
        try ChaCha20.decryptClip(data, key: key)
    }
}

// MARK: - TicNote implementation (✅ Round 6 correction: payload **is not encrypted**, it is a plaintext Opus packet stream)

/// TicNote NE-79: recording payload **is not ciphertext**, it is a series of **fixed‑length Opus packets**.
///
/// ## First correct the misjudgment of round 5
///
/// In round 5, it was judged ciphertext based on “five pieces of evidence”. **All five were invalid criteria**:
///
/// | Test at the time | Result at the time | Why invalid |
/// |---|---|---|
/// | Shannon entropy 7.9791, 256/256 byte values fully used | “opaque” | CELT/SILK's **arithmetic encoder output is inherently near uniform**, so entropy inevitably maxes out |
/// | gzip 1.0004 / xz 1.0002 | “incompressible → ciphertext” | Compressed audio **is already incompressible** |
/// | 160 B record unique byte count 119.2 ≈ random expectation | “not any real codec” | Same as above, the expected value after arithmetic coding is naturally 119 |
/// | 16‑byte block repeat rate 0 | “not AES‑ECB” | Can only rule out ECB, cannot rule out “not a cipher at all” |
/// | All 5 Ogg containers yielded white noise (zero‑crossing rate 0.5465) | “not plaintext Opus” | **All framing assumptions were wrong**, incorrect slicing inevitably produces noise |
///
/// ## Actual criteria
///
/// 1. **All three TOC fields are constant**. When interpreted as 160 B per packet, the first byte of all 3522 packets is `0xBC`
///    → `config=23` (CELT / wideband / 20 ms), `stereo=1`, frame code `0`, with no exceptions.
///    Changing the interpretation (taking TOC as the 2nd byte, or slicing at 80 B) immediately degrades to a **uniform distribution** of `config` covering 0…31
///    — a real encoder would not hop bandwidth between NB/MB/WB/hybrid.
///    → This is the signature of a **fixed‑configuration CELT encoder**, random bytes cannot produce such a coincidence.
/// 2. **The first byte is always `< 0x80`** (96 possible values, H=4.66) → exactly the silence flag of a CELT frame
///    (`logp=15`, normally 0); the following 6 bits are the coarse energy of band0. Cryptography offers no explanation for this.
/// 3. **Official APK itself acknowledges** (`apk/ticnote-2.3.4.apk`, `classes6.dex`):
///    `com.mobvoi.wifi_plugin.socket.Opus2Ogg` packages this raw stream as **1600 B per page / 10 packets per page**
///    160 B packets (**Ogg segment table writes `0xA0`**) into Ogg Opus, granule increments per page `+9600`
///    → **Each packet = 960 samples @48 kHz = 20 ms**; `com.mobvoi.audio_plugin.AudioConvertPlugin`
///    has `convertOpus2WavWithFrameSize` default `frameSize = 160` (log text `frameSize=160 bytes/frame`).
/// 4. **The actual decoded output is human voice**. 160 B/packet → Ogg → ffmpeg measurement: RMS **0.0675**, peak 2.35,
///    spectral flatness **0.2096** (white noise would be 1.0), duration **70.44 s**, bitrate **64 kbps**;
///    Feeding the same pipeline with random or shuffled bytes results in **garbled output with RMS 199 / 7867**.
/// 5. **Apple AudioToolbox natively confirms** (`afinfo`):
///    `2 ch, 48000 Hz, opus`、`3522 packets`、`64000 bits per second`、
///    `packet size upper bound: 160`、`duration 70.44 s`。
///
/// → Therefore this type **does not perform any decryption**, retaining only one meaningful safeguard: **verify whether it resembles that Opus stream**
/// (`TicNoteOpusStream.looksLikeOpus(_:)`). If it looks like → save as plaintext; if not → reject saving.
struct TicNoteClipCipher: RecorderClipCipher {
    static var envelopeName: String { "none (plaintext Opus packet stream)" }

    /// ✅ **Payload has no encryption**. BLE never sends `encryptSet`‑type toggle commands,
    /// and the payload structure fully matches the output characteristics of the CELT arithmetic encoder.
    static var encryptsClips: Bool { false }

    /// No toggle exists.
    static var hasEncryptionToggle: Bool { false }

    /// No key required.
    static var keyLength: Int? { nil }

    /// Constant `false` — the payload is never ciphertext.
    /// To determine whether "these bytes constitute a TicNote recording", use
    /// `TicNoteOpusStream.looksLikeOpus(_:)` — that is a **format** check, not an **encryption** determination.
    static func isEncryptedClip(_ data: Data) -> Bool { false }

    static func decrypt(_ data: Data, key: Data) throws -> Data {
        // The contract stipulates "non‑encrypted payloads must not call decrypt". This is not an error fallback but an explicit statement:
        // There has never been anything to decrypt.
        throw RecorderClipError.notEncrypted
    }
}

// MARK: - Access control decision results

enum RecorderClipOutcome: Equatable {
    /// Device does not perform device‑side encryption → save as‑is.
    case plaintext
    /// Decrypted, deliver as plaintext.
    case decrypted(Data)
    /// Device declares encryption, but this SN's key is unavailable on this machine → **reject save**, guide to set a passcode.
    case keyMissing
    /// Key present but decryption fails (wrong key / data corruption) → **reject save**.
    case wrongKey
    /// Payload confirmed as ciphertext, but this protocol does not know where the envelope or key comes from → **cannot decrypt**.
    /// This is TicNote's current conclusion; upper layers should disable the download entry point, or clearly inform the user.
    case opaque(envelope: String)
}

enum RecorderClipError: LocalizedError, Equatable {
    case envelopeUnknown(String)
    case keyLengthMismatch(expected: Int, got: Int)
    case notEncrypted

    var errorDescription: String? {
        switch self {
        case .envelopeUnknown(let name):
            return "This recorder encrypts its clips, but the envelope (\(name)) and key are not known yet."
        case .keyLengthMismatch(let expected, let got):
            return "Wrong key length: expected \(expected) bytes, got \(got)."
        case .notEncrypted:
            return "The data does not carry this recorder's encryption envelope."
        }
    }
}

// MARK: - Access control

/// Single entry point: given a freshly downloaded raw byte sequence, decide whether it can be saved.
///
/// **Caller contract**: only `.plaintext` / `.decrypted` may be written to the user library;
/// `.keyMissing` / `.wrongKey` / `.opaque` must **not be saved**, nor delete the device‑side original.
enum RecorderClipGate {

    /// - Parameters:
    ///   - raw: the **raw** bytes just retrieved from the device (unprocessed).
    ///   - cipher: the encryption fact of this protocol.
    ///   - deviceEncryptionOn: the device‑reported encryption toggle. `nil` = not yet read (state unknown).
    ///   - key: the key retrieved by SN; `nil` if absent.
    static func evaluate(
        raw: Data,
        cipher: RecorderClipCipher.Type,
        deviceEncryptionOn: Bool?,
        key: Data?
    ) -> RecorderClipOutcome {

        // ── 1. Content has envelope → guaranteed encrypted, must decrypt ──────────────────
        if cipher.isEncryptedClip(raw) {
            return decryptOrFail(raw, cipher: cipher, key: key)
        }

        // ── 2. Content lacks this protocol's envelope ────────────────────────────────
        switch deviceEncryptionOn {
        case .some(false):
            // Device says "no encryption". If this protocol **has no** encryption toggle at all (constant encryption, like TicNote),
            // this input is self‑contradictory — prefer to trust the data over the state, fail‑closed.
            if cipher.encryptsClips && !cipher.hasEncryptionToggle {
                return .opaque(envelope: cipher.envelopeName)
            }
            return .plaintext

        case .some(true):
            // ★ Branch added in round 6: protocol **explicitly declares it does not encrypt** (`encryptsClips == false`,
            //   as in TicNote's plaintext Opus). At this point "device says encrypt" is a **false report**,
            //   and the plaintext is allowed through — otherwise a good recording would be classified as opaque and rejected.
            //
            //   Why trust the protocol declaration over device state: `encryptsClips` is **this protocol's
            //   static and verified fact** (TicNote has official APK + ffmpeg + afinfo third‑party verification),
            //   whereas `deviceEncryptionOn` is merely a runtime read that may be outdated.
            guard cipher.encryptsClips else { return .plaintext }

            // Device says encrypt, but the data lacks this protocol's envelope.
            // If this protocol doesn't even know the key length, it means we haven't reverse‑engineered this ciphertext yet → explicitly report opaque.
            guard let expected = cipher.keyLength else {
                return .opaque(envelope: cipher.envelopeName)
            }
            if let key, key.count != expected {
                return .wrongKey
            }
            return decryptOrFail(raw, cipher: cipher, key: key)

        case .none:
            // State unknown: **default fail‑closed** (stricter than V05E's "best effort" in the documentation, intentional).
            //
            // Reason: `deviceEncryptionOn` is read early in the real flow via 0xA3 / 0x1D after connection,
            // so it is almost never nil during download; but if it is nil while the device has encryption on,
            // the cost of "best effort → treat as plaintext" is **the user can never retrieve that recording** (the device‑side original
            // may have been cleared by a “transfer‑then‑delete” policy). Better to have the upper layer show "device state not yet read".
            if cipher.encryptsClips {
                guard let expected = cipher.keyLength else {
                    // Even the key length is unknown → no way to decrypt, explicitly report opaque
                    return .opaque(envelope: cipher.envelopeName)
                }
                guard let key else { return .keyMissing }
                guard key.count == expected else { return .wrongKey }
                return decryptOrFail(raw, cipher: cipher, key: key)
            }
            return .plaintext
        }
    }

    private static func decryptOrFail(
        _ raw: Data,
        cipher: RecorderClipCipher.Type,
        key: Data?
    ) -> RecorderClipOutcome {
        if let expected = cipher.keyLength {
            guard let key else { return .keyMissing }
            guard key.count == expected else { return .wrongKey }
        } else {
            // Even the key length is unknown → no way to decrypt; must never pretend it is plaintext.
            guard key != nil else { return .opaque(envelope: cipher.envelopeName) }
            return .opaque(envelope: cipher.envelopeName)
        }
        do {
            return .decrypted(try cipher.decrypt(raw, key: key!))
        } catch {
            // Wrong key or data corruption — both must be treated as failures, not fall back to plaintext.
            return .wrongKey
        }
    }

    /// Whether the upper layer is allowed to deliver this result to the user. Only these two branches are permissible.
    static func isDeliverable(_ outcome: RecorderClipOutcome) -> Bool {
        switch outcome {
        case .plaintext, .decrypted: return true
        case .keyMissing, .wrongKey, .opaque: return false
        }
    }
}
