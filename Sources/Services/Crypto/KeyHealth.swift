import CryptoKit
import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "key-health")

// MARK: - 设备密钥健康状态
//
// ★ 2026-11-04（用户："能否在 Nomily 链接的时候增加检查密钥当前是否符合，否则导致
//   录音能够传输但是无法解密"）。
//
// 背景：V05E 的固件规则是「加密开启且已有钥匙时，必须先解除才能设新钥匙，解除必须
// 带对旧钥匙」。所以设备上的钥匙可能来自官方 App 或另一台手机，而本机 Keychain 里
// 那把（口令派生）跟它对不上。以前这种状态没有任何提示，用户只在"下载完成、条目
// 变灰、打不开"的时候才发现——那时设备上的原件可能已经按"传完即删"清掉了。
//
// 这个文件把"钥匙到底对不对"变成一个可以在**连接时**就知道的状态：
//
//   · 判定不猜：用设备自己写在信封里的校验块（`encryt` + SN，24 字节）验证；
//   · 判定不靠连线：第一次成功解密后把 60 字节信封头存成 KCV，之后每次连接都是
//     纯本地比对，不发一条 BLE 命令、不下载一个字节；
//   · 判定不说谎：Keychain 读不到（锁屏）与"没设过"是两种状态，不能混成一句
//     "请设置密码"。
//
// 为什么 KCV 只存信封头：信封头是密文，里面除了 `encryt` 魔数、设备 SN、nonce，
// 就是 24 字节的校验块——它不泄露任何音频内容，也**不能**反推出钥匙。丢了也只
// 意味着"下次要重新验证一次"，没有机密性损失。

/// 连接后的密钥状态。`.verified` 与 `.mismatch` 都需要一个可比的样本（KCV）。
enum DeviceKeyHealth: Equatable {
    /// 还没连过设备 / 设备状态没读到。
    case unknown
    /// 设备明确说没加密——此时本机有没有钥匙都无所谓。
    case notEncrypted
    /// 设备开着加密，本机没有钥匙（或从未在这台手机上设过）。
    case noKey
    /// 钥匙在 Keychain 里，但这一刻读不出来（锁屏 / 需要重新授权）。
    case unreadable(OSStatus)
    /// 有钥匙，但没有可比对的样本：这台设备还没有一条成功解密过的记录。
    case unverified(fingerprint: String)
    /// 钥匙与设备一致。
    case verified(fingerprint: String)
    /// 钥匙与设备**不一致**——用它传下来的每一条录音都打不开。
    case mismatch(fingerprint: String)

    /// 钥匙指纹（SHA256 前 3 字节）。给用户看，用来判断"这台手机和设备是不是同一把"。
    var fingerprint: String? {
        switch self {
        case .unverified(let value), .verified(let value), .mismatch(let value): return value
        default: return nil
        }
    }

    /// 需要用户处理的状态。
    var needsAttention: Bool {
        switch self {
        case .noKey, .mismatch, .unreadable: return true
        default: return false
        }
    }

    var isMismatch: Bool {
        if case .mismatch = self { return true }
        return false
    }

    /// 能不能放心地让用户开始传输。`.unverified` 放行——它只是"还没验证过"，
    /// 不是"验证失败"，拦下来反而会让第一次使用永远走不动。
    var allowsTransfer: Bool {
        switch self {
        case .mismatch: return false
        default: return true
        }
    }
}

// MARK: - KCV（钥匙校验样本）

/// 一台设备一条：60 字节信封头 + 当时那把钥匙的指纹。
///
/// `fingerprint` 不是用来验证的（验证靠 `header` 本身），而是用来回答一个用户会问
/// 的问题："设备上那把是不是我上次用的那把？"
struct KeyCheck: Codable, Equatable {
    var sn: String
    var header: Data
    var fingerprint: String
    var savedAt: Date
}

enum KeyCheckStore {

    /// `Documents/KeyChecks/<sn>.json`。不进 Keychain：里面是密文头，不是密钥；
    /// 放文件里也方便导出诊断。
    nonisolated private static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("KeyChecks", isDirectory: true)
    }

    nonisolated private static func url(sn: String) -> URL {
        // SN 里有 `/` 之类会破坏路径；信封里的 SN 是 18 字节可打印字符，但还是
        // 过一遍白名单，避免哪天固件换个编码把目录写穿。
        let safe = sn.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    nonisolated static func load(sn: String) -> KeyCheck? {
        guard let data = try? Data(contentsOf: url(sn: sn)),
              let check = try? JSONDecoder().decode(KeyCheck.self, from: data),
              check.header.count >= ChaCha20.headerLength else { return nil }
        return check
    }

    nonisolated static func save(_ check: KeyCheck) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(check) else { return }
        try? data.write(to: url(sn: check.sn), options: .atomic)
    }

    nonisolated static func clear(sn: String) {
        try? FileManager.default.removeItem(at: url(sn: sn))
    }
}

// MARK: - 服务

@MainActor
final class KeyHealthService: ObservableObject {

    static let shared = KeyHealthService()

    @Published private(set) var state: DeviceKeyHealth = .unknown
    /// 当前判定的设备 SN。界面用它判断"这个状态是不是这台设备的"。
    @Published private(set) var sn: String = ""
    @Published private(set) var checkedAt: Date?

    private init() {}

    // MARK: 指纹与验证

    /// 钥匙指纹：SHA256 前 3 字节，6 位十六进制。
    ///
    /// 只给"人眼比对"用，不参与任何密码学判断——所以 24 位足够，也不必保密：
    /// 从指纹反推 32 字节钥匙在计算上不可行。
    nonisolated static func fingerprint(_ key: Data) -> String {
        let digest = SHA256.hash(data: key)
        return digest.prefix(3).map { String(format: "%02X", $0) }.joined()
    }

    /// 用信封头验证一把钥匙。
    ///
    /// `ChaCha20.decryptClip` 会把 `verify` 块（24 字节）解出来，跟明文头
    /// （`encryt` + SN）逐字节比——这正是固件设计的校验位。所以只拿 60 字节
    /// 信封头就能判到底，不需要整条录音。
    nonisolated static func matches(_ key: Data, header: Data) -> Bool {
        guard key.count == DnoteProtocol.chachaKeyLength else { return false }
        guard header.count >= ChaCha20.headerLength else { return false }
        do {
            _ = try ChaCha20.decryptClip(header, key: key)
            return true
        } catch {
            return false
        }
    }

    /// 从信封里取设备 SN（`encryt` 之后 18 字节）。
    ///
    /// 这是**设备自己写的**，不是我们从 `getDeviceInfo` 猜的，所以它可以拿来当
    /// "这条录音到底是哪台设备录的"的硬证据。
    nonisolated static func envelopeSN(_ envelope: Data) -> String? {
        guard envelope.count >= ChaCha20.snOffset + ChaCha20.snLength else { return nil }
        let raw = envelope.subdata(in: ChaCha20.snOffset..<(ChaCha20.snOffset + ChaCha20.snLength))
        let text = String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return text.isEmpty ? nil : text
    }

    // MARK: 连接时判定

    /// 连接成功后调用（`BluetoothCoordinator.refreshBondStateAndPrompt` 里 0xA3 之后）。
    ///
    /// 全程**不发额外的 BLE 命令**：加密状态由调用方刚读过，SN 来自设备信息，
    /// 钥匙比对只读 Keychain 与本地 KCV。所以它可以挂在每次连接后面，不会拖慢连接。
    func evaluate(client: DnoteClient) async {
        guard let encryptionOn = client.deviceEncryptionOn else {
            // 0xA3 没读成。不要判"没设密码"——那会把一次读失败说成用户的配置问题。
            finish(.unknown)
            return
        }

        var serial = client.lastDeviceInfo?.serial ?? ""
        if serial.isEmpty {
            // 只有这一条会发命令，而且只在 SN 缺失时。`getDeviceInfo` 是连接后
            // 本来就要读的，算不上额外负担。
            _ = try? await client.getDeviceInfo()
            serial = client.lastDeviceInfo?.serial ?? ""
        }
        sn = serial

        guard encryptionOn else {
            finish(.notEncrypted)
            return
        }

        guard !serial.isEmpty else {
            log.info("key health: device encrypted but serial unknown — cannot judge")
            finish(.unknown)
            return
        }

        let lookup = PassphraseStore.loadDetailed(sn: serial)
        guard let key = lookup.key else {
            if lookup.status == errSecItemNotFound {
                finish(.noKey)
            } else {
                // 锁屏时 Keychain 返回 errSecInteractionNotAllowed。钥匙还在，
                // 只是这一刻摸不到——这句话不能跟"没设过"混为一谈。
                log.info("key health: keychain read blocked status=\(lookup.status)")
                finish(.unreadable(lookup.status))
            }
            return
        }

        let fingerprint = Self.fingerprint(key)
        if let check = KeyCheckStore.load(sn: serial), check.header.count >= ChaCha20.headerLength {
            finish(Self.matches(key, header: check.header)
                ? .verified(fingerprint: fingerprint)
                : .mismatch(fingerprint: fingerprint))
        } else {
            // 有钥匙但没样本：这台设备还没有一条成功解密过。第一次传输之后
            // `rememberSuccess` 会把 KCV 落下来，从此每次连接都能秒判。
            finish(.unverified(fingerprint: fingerprint))
        }
    }

    /// 落状态 + 记日志。所有分支都走这里，避免"某个 return 忘了记日志"。
    ///
    /// ★ 2026-11-04：这条日志要写进 `Documents/ticnote-ble.log`。os_log 在真机上
    /// 拉不出来（没有 Console 就看不了），而排查"为什么录不了音"恰恰需要这一行——
    /// 它是唯一能区分"没钥匙 / 钥匙不对 / 锁屏读不到"的证据。
    private func finish(_ newState: DeviceKeyHealth) {
        state = newState
        checkedAt = Date()
        log.info("key health: \(String(describing: newState), privacy: .public) sn=\(self.sn, privacy: .public)")
        TicNoteDiagLog.log("KEY", "health=\(Self.label(newState)) sn=\(self.sn)")
    }

    /// 状态的英文短名（写进日志用，不本地化）。
    nonisolated private static func label(_ state: DeviceKeyHealth) -> String {
        switch state {
        case .unknown:              return "unknown"
        case .notEncrypted:         return "device-off"
        case .noKey:                return "no-key"
        case .unreadable(let code): return "keychain-blocked(\(code))"
        case .unverified(let fp):   return "unverified(\(fp))"
        case .verified(let fp):     return "verified(\(fp))"
        case .mismatch(let fp):     return "MISMATCH(\(fp))"
        }
    }

    // MARK: 从真实解密结果学习

    /// 解密成功后调用：把信封头存成这台设备的 KCV。
    ///
    /// 只在**真的解开了一条**之后存——这是唯一能证明"这把钥匙就是设备那把"的证据，
    /// 比任何握手返回值都可靠。
    nonisolated static func rememberSuccess(envelope: Data, key: Data) {
        guard ChaCha20.isEncryptedClip(envelope) else { return }
        guard let serial = envelopeSN(envelope) else { return }
        let header = envelope.prefix(ChaCha20.headerLength)
        guard matches(key, header: Data(header)) else { return }

        let fingerprint = fingerprint(key)
        KeyCheckStore.save(KeyCheck(
            sn: serial,
            header: Data(header),
            fingerprint: fingerprint,
            savedAt: Date()
        ))
        Task { @MainActor in
            let service = KeyHealthService.shared
            guard service.sn == serial else { return }
            service.state = .verified(fingerprint: fingerprint)
            service.checkedAt = Date()
        }
        TicNoteDiagLog.log("KEY", "kcv-saved sn=\(serial) fp=\(fingerprint)")
    }

    /// 设备上的钥匙被本机改写之后调用（rotate / set 成功）。
    ///
    /// KCV 记的是"旧钥匙配这台设备"。钥匙一换，旧 KCV 立刻变成一条**假的**
    /// mismatch 证据——所以必须一起清掉，让下一次连接回到 `.unverified`，
    /// 等第一条新录音解密成功再重建。
    nonisolated static func forgetCheck(sn: String) {
        KeyCheckStore.clear(sn: sn)
    }

    /// 断开连接时回落，避免界面挂着一台已经不在的设备的结论。
    func reset() {
        state = .unknown
        sn = ""
        checkedAt = nil
    }
}
