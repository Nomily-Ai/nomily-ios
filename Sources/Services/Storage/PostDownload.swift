import Foundation

/// Shared post-download pipeline. Saves the raw bytes, decrypts when the
/// file starts with the "encryt" magic (firmware v1.50+), and produces a
/// playable Ogg-Opus artefact.
///
/// The key is now sourced from `PassphraseStore` (Keychain), not from
/// `config.chacha20_key`. Callers pass the resolved 32-byte key or `nil`
/// when no key is configured for this device.
enum PostDownload {
    enum Outcome {
        case ready(URL, PostDownload.Source)
        case raw(URL, PostDownload.RawReason)
    }
    enum Source {
        case alreadyPlain
        case decrypted
        case wrappedRawFrames
        case decryptedThenWrapped
    }
    enum RawReason {
        case decryptFailed(String)
        case keyMissing
        case wavWithoutHeader
    }

    @discardableResult
    static func process(
        _ data: Data,
        name: String,
        chacha20Key: Data?
    ) throws -> Outcome {
        try FileManager.default.createDirectory(
            at: StorageLocations.audioDir,
            withIntermediateDirectories: true
        )
        let rawURL = StorageLocations.audioDir.appendingPathComponent(name)
        try data.write(to: rawURL, options: .atomic)

        let lower = name.lowercased()
        let oggMagic = Data("OggS".utf8)
        let riffMagic = Data("RIFF".utf8)
        let isOpus = lower.hasSuffix(".opus")
        let isWav = lower.hasSuffix(".wav")

        // 1: encrypted-clip envelope → decrypt + wrap raw OPUS frames
        if isOpus && ChaCha20.isEncryptedClip(data) {
            guard let key = chacha20Key else {
                return .raw(rawURL, .keyMissing)
            }
            do {
                let frames = try ChaCha20.decryptClip(data, key: key)
                let wrapped = OpusOgg.wrap(rawFrames: frames)
                let url = try writeReady(wrapped, name: name)
                return .ready(url, .decryptedThenWrapped)
            } catch {
                return .raw(rawURL, .decryptFailed(error.localizedDescription))
            }
        }

        // 2: already-plain container → copy verbatim
        if (isOpus && data.prefix(4) == oggMagic) ||
           (isWav && data.prefix(4) == riffMagic) {
            let url = try writeReady(data, name: name)
            return .ready(url, .alreadyPlain)
        }

        // 3: anything else .opus → assume raw OPUS frames; wrap
        if isOpus {
            let wrapped = OpusOgg.wrap(rawFrames: data)
            let url = try writeReady(wrapped, name: name)
            return .ready(url, .wrappedRawFrames)
        }
        return .raw(rawURL, .wavWithoutHeader)
    }

    private static func writeReady(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: StorageLocations.decryptedDir,
            withIntermediateDirectories: true
        )
        let url = StorageLocations.decryptedDir.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
