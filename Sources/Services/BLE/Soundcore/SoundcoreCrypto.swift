import CommonCrypto
import CryptoKit
import Foundation

// MARK: - soundcore Work / D3200（飞书录音豆）crypto
//
// Faithful Swift port of Kotlin `SoundcoreCrypto.kt` (which itself ports
// Feishu `KeyManager` / `CryptoManager` / `AesCtrStreamDecrypt`):
//
// 1. App generates an ECDH P-256 keypair.
// 2. BLE `0x2E/0x01` sends the app public key (65-byte uncompressed SEC1).
// 3. Device replies with its public key (65B @9) + shared secret (32B @74).
// 4. sessionKey = HKDF-SHA256(ECDH_shared, salt={1,2,3}, info={1,2,3}, 32).
// 5. Per file head: AES-CTR-decrypt `encryptedFileKey` with sessionKey +
//    sessionNonce → plaintext must start with ASCII `soundcored3200`
//    followed by the 32-byte fileKey.
// 6. Each 160-B slice: AES-CTR(fileKey, IV = nonce[0:12] ‖ BE_uint32(seq*10)).
//
// CryptoKit has no AES-CTR on iOS 16, so CTR is built manually on CommonCrypto
// one-shot AES-ECB per 16-byte counter block, XORed with the payload — the
// counter layout mirrors `SoundcoreCrypto.kt` exactly (big-endian increment
// over the full 16-byte block).

enum SoundcoreError: LocalizedError {
    case notConnected
    case timeout
    case malformed(String)
    case device(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "soundcore 设备未连接"
        case .timeout: return "soundcore 设备响应超时"
        case .malformed(let s): return "soundcore 帧解析失败：\(s)"
        case .device(let s): return s
        }
    }
}

/// ECDH (secp256r1) + HKDF + AES-CTR session for D3200 offline files.
/// Port of Kotlin `SoundcoreDeviceCrypto`.
final class SoundcoreDeviceCrypto: @unchecked Sendable {
    static let keyLength = 32
    static let sessionNonceLength = 16
    /// 14 bytes ASCII — every unwrapped per-file key starts with this.
    static let fileKeyMagic = "soundcored3200"
    /// magic(14) + fileKey(≥32)
    static let fileKeyPlainMin = 46

    private let lock = NSLock()
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var sessionKeyStorage: Data?
    private var fileDecryptors: [UInt32: SoundcoreCtrStream] = [:]

    var hasSession: Bool { lock.withLock { sessionKeyStorage?.count == Self.keyLength } }
    var sessionKey: Data? { lock.withLock { sessionKeyStorage } }

    /// Generate (or reuse) the app ECDH keypair; returns the 65-B public key.
    func ensureKeyPair() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let key = privateKey ?? P256.KeyAgreement.PrivateKey()
        privateKey = key
        // x963Representation = 0x04 ‖ X ‖ Y — exactly the 65-byte uncompressed
        // SEC1 point the device expects.
        return key.publicKey.x963Representation
    }

    /// Complete the handshake after RX 0x2E/0x01. `deviceSharedKey` is the
    /// device's copy of the ECDH secret — verifying it against our own is the
    /// handshake's sanity check (upstream does a hex-string compare).
    func completeHandshake(devicePublicKey: Data, deviceSharedKey: Data) -> Bool {
        _ = ensureKeyPair()
        guard let shared = computeEcdhShared(devicePublicKey) else { return false }
        let devicePadded = Self.leftPad(deviceSharedKey, Self.keyLength)
        guard shared == devicePadded else { return false }
        let key = Self.hkdfSha256(
            ikm: shared,
            salt: Data([1, 2, 3]),
            info: Data([1, 2, 3]),
            length: Self.keyLength
        )
        lock.lock()
        sessionKeyStorage = key
        lock.unlock()
        return true
    }

    /// ECDH shared secret = X coordinate of (priv · peerPub), 32 bytes
    /// (CryptoKit returns the fixed-width coordinate already left-padded).
    func computeEcdhShared(_ peerPublicUncompressed: Data) -> Data? {
        lock.lock()
        let priv = privateKey
        lock.unlock()
        guard let priv else { return nil }
        var raw = peerPublicUncompressed
        if raw.count > 65 { raw = raw.prefix(65) }
        if raw.count == 64 { raw = Data([0x04]) + raw } // raw X‖Y → uncompressed point
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: raw) else { return nil }
        guard let secret = try? priv.sharedSecretFromKeyAgreement(with: peer) else { return nil }
        return secret.withUnsafeBytes { Data($0) }
    }

    /// Unwrap the per-file key from the 1A/07 head material.
    func initFileDecrypt(fileId: UInt32, encryptedFileKey: Data, sessionNonce: Data, nonce: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessionKeyStorage, session.count == Self.keyLength else { return false }
        if fileDecryptors[fileId] != nil { return true }
        guard sessionNonce.count == Self.sessionNonceLength else { return false }

        guard let plain = Self.aesCtrDecrypt(encryptedFileKey, key: session, iv: sessionNonce) else { return false }
        guard plain.count >= Self.fileKeyPlainMin else { return false }
        let magic = String(decoding: plain.prefix(Self.fileKeyMagic.count), as: UTF8.self)
        guard magic == Self.fileKeyMagic else { return false }
        var fileKey = plain.dropFirst(Self.fileKeyMagic.count)
        guard fileKey.count >= 16 else { return false }
        if fileKey.count >= Self.keyLength { fileKey = fileKey.prefix(Self.keyLength) }
        let n = nonce.count >= 12 ? Data(nonce.prefix(min(16, nonce.count))) : nonce
        fileDecryptors[fileId] = SoundcoreCtrStream(fileKey: Data(fileKey), nonce: n)
        return true
    }

    /// Decrypt one 160-B slice of `fileId` at packet `sequence`; nil if not ready.
    func decryptChunk(fileId: UInt32, sequence: Int, data: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return fileDecryptors[fileId]?.decryptChunk(data, index: sequence)
    }

    func hasFileDecryptor(_ fileId: UInt32) -> Bool {
        lock.withLock { fileDecryptors[fileId] != nil }
    }

    func clearFile(_ fileId: UInt32) {
        lock.withLock { fileDecryptors.removeValue(forKey: fileId) }
    }

    func resetSession() {
        lock.lock()
        sessionKeyStorage = nil
        fileDecryptors.removeAll()
        lock.unlock()
    }

    // ── helpers ──

    static func leftPad(_ data: Data, _ length: Int) -> Data {
        if data.count == length { return data }
        if data.count > length { return data.suffix(length) }
        return Data(repeating: 0, count: length - data.count) + data
    }

    /// AES-CTR (JCE AES/CTR/NoPadding ≡ SIC stream cipher; encrypt == decrypt).
    static func aesCtrDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == 16 || key.count == 24 || key.count == 32 else { return nil }
        let padded = iv.count == 16 ? iv : leftPad(iv, 16)
        var counter = [UInt8](padded)
        let keyBytes = [UInt8](key)
        let input = [UInt8](data)
        var out = Data(capacity: input.count)
        var i = 0
        while i < input.count {
            let keystream = ecbEncryptBlock(counter, key: keyBytes)
            let n = min(16, input.count - i)
            for j in 0..<n { out.append(input[i + j] ^ keystream[j]) }
            i += n
            // Big-endian increment over the full 16-byte counter block.
            var carry = 1
            for p in stride(from: 15, through: 0, by: -1) {
                let v = Int(counter[p]) + carry
                counter[p] = UInt8(v & 0xFF)
                carry = v >> 8
                if carry == 0 { break }
            }
        }
        return out
    }

    /// One-shot AES-ECB of a single 16-byte block (CTR keystream generation).
    private static func ecbEncryptBlock(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var dataIn = block
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            key, key.count, nil,
            &dataIn, dataIn.count,
            &out, out.count, &moved
        )
        precondition(status == kCCSuccess, "CCCrypt AES-ECB failed: \(status)")
        return out
    }

    /// HKDF-SHA256 (extract + expand, RFC 5869) — CryptoKit, iOS 14+.
    static func hkdfSha256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        // RFC 5869: an empty salt is equivalent to zeros of the hash length.
        let saltData = salt.isEmpty ? Data(repeating: 0, count: 32) : salt
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: saltData,
            info: info,
            outputByteCount: length
        )
        return key.withUnsafeBytes { Data($0) }
    }
}

/// Per-file AES-CTR stream (Feishu `AesCtrStreamDecrypt`).
///
/// IV for chunk `index`: nonce[0..12) ‖ BE_uint32(index * 10)
/// — 160-byte chunks are exactly 10 AES blocks each.
struct SoundcoreCtrStream {
    let fileKey: Data
    let nonce: Data

    func buildCounter(blockIndex: Int) -> Data {
        var iv = [UInt8](repeating: 0, count: 16)
        let n = [UInt8](nonce)
        for i in 0..<min(12, n.count) { iv[i] = n[i] }
        let c = blockIndex * 10
        iv[12] = UInt8((c >> 24) & 0xFF)
        iv[13] = UInt8((c >> 16) & 0xFF)
        iv[14] = UInt8((c >> 8) & 0xFF)
        iv[15] = UInt8(c & 0xFF)
        return Data(iv)
    }

    func decryptChunk(_ data: Data, index: Int) -> Data? {
        SoundcoreDeviceCrypto.aesCtrDecrypt(data, key: fileKey, iv: buildCounter(blockIndex: index))
    }
}
