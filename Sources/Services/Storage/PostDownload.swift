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
                // ★ 2026-11-04：解开一条，就把这条信封头记成这台设备的 KCV。
                //   这是唯一能证明"本机这把钥匙就是设备那把"的证据——之后每次
                //   连接都能纯本地判钥匙，不必下载、不必录探针。
                KeyHealthService.rememberSuccess(envelope: data, key: key)
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

// MARK: - 传输 / 解密解耦（★ 2026-11-06）
//
// 背景：`process(_:name:chacha20Key:)` 要求调用方先自己拿到 32 字节密钥。
// 于是**每一条传输路径**（BLE 文件下载、Wi-Fi 快传、直播落盘）都得知道
// `KeyResolver` / `PassphraseStore` / `deviceEncryptionOn` 这三件事，
// 传输代码里长出了一份"解密前戏"。接一台新设备时，改的是传输，动的却是加密。
//
// 这一层把"字节 + 设备身份"作为唯一输入：密钥怎么来、没有密钥怎么办，全部
// 收在这里。传输层从此只回答一个问题——"这段字节该存成什么文件"。
extension PostDownload {
    /// 传输层的统一入口。
    ///
    /// - Parameters:
    ///   - deviceSerial: 设备序列号；密钥按 SN 存在 Keychain 里。
    ///   - encryptionOn: 设备自报的加密状态。`false` = 明确没开，跳过 Keychain
    ///     （省一次读取，也避免"没开加密却命中旧钥匙"的误判）；`nil` = 状态未知，
    ///     按有钥匙就试（与 `KeyResolver.key(for:)` 的判定表一致）。
    @MainActor
    static func ingest(
        _ data: Data,
        name: String,
        deviceSerial: String?,
        encryptionOn: Bool?
    ) throws -> Outcome {
        let key: Data?
        if encryptionOn == false {
            key = nil
        } else if let sn = deviceSerial, !sn.isEmpty {
            key = PassphraseStore.load(sn: sn)
        } else {
            key = nil
        }
        return try process(data, name: name, chacha20Key: key)
    }
}
