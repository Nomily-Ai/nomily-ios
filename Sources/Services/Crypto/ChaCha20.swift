import Foundation

/// Raw ChaCha20 stream cipher (RFC 8439) plus the v1.50 encrypted-clip
/// envelope parser.
///
/// We don't reuse CryptoKit's `ChaChaPoly` — that's an AEAD with a Poly1305
/// tag, but this firmware uses plain ChaCha20 + the homemade verify-block
/// check. A ~70-line pure-Swift implementation is simpler to audit.
enum ChaCha20 {
    static let magic = Data("encryt".utf8)
    static let headerLength = 60
    static let snOffset = 6
    static let snLength = 18
    static let nonceOffset = 24
    static let nonceLength = 12
    static let verifyOffset = 36
    static let verifyLength = 24

    enum DecryptError: LocalizedError {
        case tooShort
        case badMagic
        case verifyMismatch

        var errorDescription: String? {
            switch self {
            case .tooShort:        return "Encrypted clip is shorter than the 60-byte header."
            case .badMagic:        return "Missing \"encryt\" magic — not an encrypted clip."
            case .verifyMismatch:  return "Wrong key (verify-block didn't match)."
            }
        }
    }

    /// Returns true when `head[:6] == "encryt"`. Pure content inspection.
    static func isEncryptedClip(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    /// Decrypt a v1.50 encrypted clip. Returns the raw OPUS frame stream
    /// (no container). Wrap with `OpusOgg.wrap(rawFrames:)` to produce
    /// a playable Ogg-Opus file.
    static func decryptClip(_ raw: Data, key: Data) throws -> Data {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        guard raw.count >= headerLength else { throw DecryptError.tooShort }
        guard isEncryptedClip(raw)      else { throw DecryptError.badMagic }

        let header = raw.prefix(nonceOffset)                                 // magic + sn
        let nonce  = raw.subdata(in: nonceOffset..<(nonceOffset + nonceLength))
        let body   = raw.subdata(in: verifyOffset..<raw.count)                // verify + audio
        let plain  = streamCipher(body, key: key, nonce: nonce)
        guard plain.prefix(nonceOffset) == header else {
            throw DecryptError.verifyMismatch
        }
        return plain.subdata(in: nonceOffset..<plain.count)
    }

    /// Raw stream-cipher wrapper for tests / hand-rolled decryption flows.
    /// 256-bit key + 96-bit nonce, counter starts at 0.
    static func streamCipher(_ data: Data, key: Data, nonce: Data, counter: UInt32 = 0) -> Data {
        precondition(key.count == 32,  "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == 12,"ChaCha20 nonce must be 12 bytes")

        let keyWords = key.withUnsafeBytes { raw -> [UInt32] in
            (0..<8).map { i in raw.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian }
        }
        let nonceWords = nonce.withUnsafeBytes { raw -> [UInt32] in
            (0..<3).map { i in raw.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian }
        }

        var out = Data(count: data.count)
        var blockCounter = counter
        var offset = 0

        out.withUnsafeMutableBytes { outRaw in
            data.withUnsafeBytes { inRaw in
                let outBuf = outRaw.bindMemory(to: UInt8.self).baseAddress!
                let inBuf = inRaw.bindMemory(to: UInt8.self).baseAddress!
                while offset < data.count {
                    let keystream = block(keyWords: keyWords, nonceWords: nonceWords, counter: blockCounter)
                    let take = min(64, data.count - offset)
                    for i in 0..<take {
                        outBuf[offset + i] = inBuf[offset + i] ^ keystream[i]
                    }
                    offset += take
                    blockCounter &+= 1
                }
            }
        }
        return out
    }

    // MARK: - core

    private static let constants: [UInt32] = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]

    private static func block(keyWords: [UInt32], nonceWords: [UInt32], counter: UInt32) -> [UInt8] {
        var s: [UInt32] = [
            constants[0], constants[1], constants[2], constants[3],
            keyWords[0], keyWords[1], keyWords[2], keyWords[3],
            keyWords[4], keyWords[5], keyWords[6], keyWords[7],
            counter, nonceWords[0], nonceWords[1], nonceWords[2],
        ]
        let initial = s
        for _ in 0..<10 {
            quarter(&s, 0, 4, 8, 12)
            quarter(&s, 1, 5, 9, 13)
            quarter(&s, 2, 6, 10, 14)
            quarter(&s, 3, 7, 11, 15)
            quarter(&s, 0, 5, 10, 15)
            quarter(&s, 1, 6, 11, 12)
            quarter(&s, 2, 7, 8, 13)
            quarter(&s, 3, 4, 9, 14)
        }
        var out = [UInt8](repeating: 0, count: 64)
        for i in 0..<16 {
            let w = s[i] &+ initial[i]
            out[i * 4 + 0] = UInt8(truncatingIfNeeded: w)
            out[i * 4 + 1] = UInt8(truncatingIfNeeded: w >> 8)
            out[i * 4 + 2] = UInt8(truncatingIfNeeded: w >> 16)
            out[i * 4 + 3] = UInt8(truncatingIfNeeded: w >> 24)
        }
        return out
    }

    private static func quarter(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
        s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
        s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x &<< n) | (x &>> (32 &- n))
    }
}
