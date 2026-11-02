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
        let encryptMagic = Data("encryt".utf8)
        let isOpus = lower.hasSuffix(".opus")
        let isWav = lower.hasSuffix(".wav")

        // 1: encrypted-clip envelope → decrypt + wrap raw OPUS frames.
        // ★ 2026-11-02: 按**魔数**而不是后缀判断——固件换容器命名（如 .m4a）时
        //   旧逻辑会把密文当普通文件落到 raw，用户侧表现为「下载成功但打不开」。
        if ChaCha20.isEncryptedClip(data) {
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

        // 2: already-plain container → copy verbatim. 魔数优先于后缀：
        //    OggS / RIFF / MP4(`ftyp`) / ADTS-AAC(0xFF Fx) 都是自描述容器。
        if data.prefix(4) == oggMagic || data.prefix(4) == riffMagic {
            let url = try writeReady(data, name: name)
            return .ready(url, .alreadyPlain)
        }
        // MP4/M4A: bytes 4…8 == "ftyp"
        if data.count > 8, data.subdata(in: 4..<8) == Data("ftyp".utf8) {
            let url = try writeReady(data, name: name)
            return .ready(url, .alreadyPlain)
        }
        // ADTS AAC (.aac / 固件改用裸 AAC 流时)
        if data.count > 2, data[data.startIndex] == 0xFF,
           (data[data.index(after: data.startIndex)] & 0xF6) == 0xF0 {
            let url = try writeReady(data, name: name)
            return .ready(url, .alreadyPlain)
        }

        // 3: bare OPUS frames → wrap. 只有 .opus 后缀才做这个假设；
        //    其它后缀的未知内容宁可留 raw（保持旧行为），不要把垃圾包成 Ogg。
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
