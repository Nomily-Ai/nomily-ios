import SwiftUI

// `String.fullwidthNormalized` / `credentialNormalized` 见 AppConfig.swift ——
// 凭据归一化属于传输层，不放 UI 文件，免得只有这一条路记得清洗。


/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 存储分层 · WebDAV 目的地）
///
/// The NAS form, ported: preset picker (群晖/威联通/绿联/飞牛/极空间/Nextcloud/
/// 坚果云/其他) → the four connection fields → 「也传录音」 → probe → sync-now.
/// Presets only prefill port/https + a setup hint; the protocol underneath is
/// plain WebDAV for every one of them.
/// ★ 2026-10-30（用户："不要列表式的选择服务器类型的服务商，归纳到一个
/// webdav，点击按照类型选择，选择在弹页面设置"）：WebDAV 的唯一入口是一个
/// 弹层——先挑服务器类型，再在弹层内推入配置页。
struct WebDAVSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var configService: ConfigService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(WebDAVPresets.all, id: \.label) { item in
                        NavigationLink {
                            WebDAVView(initialPreset: item.label)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(item.tint.gradient)
                                    )
                                Text(item.label)
                                Spacer(minLength: 8)
                                if configService.config.webdav?.preset == item.label {
                                    Image(systemName: "checkmark")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.appAccent)
                                }
                            }
                        }
                    }
                } header: {
                    Text(L10n.WebDAV.serverType)
                } footer: {
                    Text(L10n.WebDAV.setupFooter)
                }
            }
            .navigationTitle(L10n.WebDAV.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 预设的唯一数据源：弹层与配置页共用（标签/端口/HTTPS/占位符/引导文案 + 弹层图标）。
enum WebDAVPresets {
    struct Item {
        let label: String
        let port: Int
        let https: Bool
        let hostPlaceholder: String
        let hint: String
        let symbol: String
        let tint: Color
    }

    static let all: [Item] = [
        Item(label: "群晖", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "先在套件中心装好「WebDAV Server」，用 DSM 账号登录",
             symbol: "shippingbox.fill", tint: .blue),
        Item(label: "威联通", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "在 App Center 启用 WebDAV 后使用",
             symbol: "shippingbox.fill", tint: .indigo),
        Item(label: "绿联", port: 9443, https: true, hostPlaceholder: "192.168.1.10",
             hint: "在绿联云的设置里开启 WebDAV",
             symbol: "shippingbox.fill", tint: .green),
        Item(label: "飞牛", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "fnOS 应用中心启用 WebDAV 后使用",
             symbol: "shippingbox.fill", tint: .teal),
        // ★ 2026-10-30：极空间实测（Z4Pro，5005 HTTP 认证通过 + 个人空间可写）。
        //   关键规则：**WebDAV 根目录不可写**（MKCOL/PUT 一律 400/401），可写的根是
        //   用户的个人空间 `/sataXX-账号/`——目录必须填到个人空间下面。
        //   5006 HTTPS 是自签证书 → 必须开「允许自签」。目录填错时测试连接会
        //   自动扫描根目录定位个人空间并回填。
        Item(label: "极空间", port: 5005, https: false, hostPlaceholder: "192.168.1.10 或 100.x.y.z",
             hint: "系统设置 → 文件与共享服务 → WebDAV 打开。HTTP 默认 5005；用 HTTPS(5006) 需开「允许自签证书」。目录填个人空间下的路径（形如 /sata11-你的账号/nomily），填错也没关系——测试连接会自动定位",
             symbol: "externaldrive.fill", tint: .orange),
        Item(label: "Nextcloud", port: 443, https: true, hostPlaceholder: "cloud.example.com",
             hint: "填 Nextcloud 域名，路径含 /remote.php/dav/files/用户名/",
             symbol: "cloud.fill", tint: .cyan),
        Item(label: "坚果云", port: 443, https: true, hostPlaceholder: "dav.jianguoyun.com",
             hint: "路径填 /dav；密码要用「应用密码」（账户安全里生成），不是登录密码",
             symbol: "cloud.fill", tint: .blue),
        Item(label: "其他 WebDAV", port: 443, https: true, hostPlaceholder: "服务器地址",
             hint: "任意标准 WebDAV 服务",
             symbol: "server.rack", tint: .gray),
    ]

    static func item(named label: String) -> Item? {
        all.first { $0.label == label }
    }
}

struct WebDAVView: View {
    @EnvironmentObject private var configService: ConfigService
    @ObservedObject private var sync = WebDAVSyncService.shared

    /// ★ 2026-10-30（用户："归纳到一个 webdav，点击按照类型选择，在弹页面设置"）：
    /// 从 WebDAVSetupSheet 选完类型跳进来时带上预设；已有配置时忽略（以配置为准）。
    var initialPreset: String? = nil

    /// Form-local editable copy — committed to config on save, password lives
    /// in the Keychain via ConfigService's strip/restore.
    @State private var host = ""
    /// ★ 2026-10-30（用户："端口要支持输入而不是+−这样方式"）：从 Stepper 改成
    /// 纯文本框——NAS 用户手里拿的是现成端口号（5005/5006/9443…），加减点不到位。
    @State private var portText = "443"
    @State private var useHTTPS = true
    /// ★ 2026-10-30（极空间 HTTPS 5006 实测自签证书）：信任自签的开关。
    @State private var allowSelfSigned = false
    @State private var username = ""
    @State private var password = ""
    @State private var basePath = "/nomily"
    @State private var syncAudio = false
    @State private var preset = ""

    @State private var probing = false
    @State private var probe: (ok: Bool, text: String)?

    /// `portText` → 有效端口；非法（空/越界）返回 nil，由调用方报错。
    private var parsedPort: Int? {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(p) else { return nil }
        return p
    }

    /// 主机框占位符跟随预设（极空间提示"或 100.x.y.z"等）。
    private var hostPlaceholder: String {
        WebDAVPresets.item(named: preset)?.hostPlaceholder ?? L10n.WebDAV.host
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.WebDAV.preset, selection: $preset) {
                    Text(L10n.WebDAV.presetUnpicked).tag("")
                    ForEach(WebDAVPresets.all, id: \.label) { item in
                        Text(item.label).tag(item.label)
                    }
                }
                .onChange(of: preset) { newValue in
                    guard let item = WebDAVPresets.item(named: newValue) else { return }
                    portText = String(item.port)
                    useHTTPS = item.https
                    basePath = newValue == "坚果云" ? "/dav"
                        : newValue == "Nextcloud" ? basePath
                        : "/nomily"
                }
            } header: {
                Text(L10n.WebDAV.serverType)
            } footer: {
                if let hint = WebDAVPresets.item(named: preset)?.hint {
                    Text(hint)
                }
            }

            Section {
                TextField(hostPlaceholder, text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    // ★ 2026-10-30：极空间客户端里点「复制」拿到的是完整 URL
                    //   （http://192.168.15.102:5005）——回车/保存时自动拆出协议和端口。
                    .onSubmit { applyPastedEndpoint() }
                TextField(L10n.WebDAV.portField, text: $portText)
                    .keyboardType(.numberPad)
                    .onChange(of: portText) { newValue in
                        let digits = newValue.filter { $0.isNumber }.prefix(5)
                        if String(digits) != newValue { portText = String(digits) }
                    }
                Toggle(L10n.WebDAV.https, isOn: $useHTTPS)
                Toggle(L10n.WebDAV.allowSelfSigned, isOn: $allowSelfSigned)
                TextField(L10n.WebDAV.username, text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(L10n.WebDAV.password, text: $password)
                TextField(L10n.WebDAV.basePath, text: $basePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text(L10n.WebDAV.connection)
            } footer: {
                Text(L10n.WebDAV.basePathFooter)
            }

            Section {
                Toggle(L10n.WebDAV.syncAudio, isOn: $syncAudio)
            } footer: {
                Text(L10n.WebDAV.syncAudioFooter)
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text(L10n.WebDAV.test)
                        if probing { Spacer(); ProgressView() }
                    }
                }
                .disabled(probing || host.isEmpty || username.isEmpty || password.isEmpty)
                if let probe {
                    Label {
                        Text(probe.text)
                    } icon: {
                        Image(systemName: probe.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(probe.ok ? Color.green : Color.red)
                    }
                }
            }

            Section {
                Button {
                    Task { await syncNow() }
                } label: {
                    HStack {
                        Text(L10n.WebDAV.syncNow)
                        if sync.isRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(sync.isRunning)
                if let report = sync.lastReport {
                    Text(report)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.WebDAV.syncNowFooter)
            }

            // ★ 2026-10-29 (饭耳移植 · 规格 #10): one privacy sentence per page.
            Section {
                PrivacyNote(flavor: .backup)
            }
        }
        .navigationTitle(L10n.WebDAV.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    // MARK: - Load / save

    private func load() {
        let cfg = configService.config.webdav
        host = cfg?.host ?? ""
        portText = String(cfg?.port ?? 443)
        useHTTPS = cfg?.useHTTPS ?? true
        allowSelfSigned = cfg?.allowSelfSigned ?? false
        username = cfg?.username ?? ""
        password = cfg?.password ?? ""
        basePath = cfg?.basePath ?? "/nomily"
        syncAudio = cfg?.syncAudio ?? false
        // ★ 2026-10-30：从类型选择弹层跳进来且还没有配置时，预选该类型——
        // onChange(of: preset) 会跟着把端口/HTTPS/目录预填好。
        preset = cfg?.preset ?? initialPreset ?? ""
    }

    private func save() {
        applyPastedEndpoint()
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedBase = basePath.trimmingCharacters(in: .whitespaces)
        guard trimmedHost.isEmpty == false, let port = parsedPort else {
            // 主机清空 = 移除整个目的地；只填了主机但端口非法 → 不落盘（保留旧配置），
            // 错误留给状态行，避免静默存进一条连不上的脏配置。
            if !trimmedHost.isEmpty {
                probe = (false, L10n.WebDAV.badPort)
            } else {
                configService.config.webdav = nil
            }
            configService.saveNow()
            return
        }
        configService.config.webdav = WebDAVConfig(
            host: trimmedHost,
            port: port,
            useHTTPS: useHTTPS,
            username: username.trimmingCharacters(in: .whitespaces).credentialNormalized,
            basePath: trimmedBase.isEmpty ? "/nomily" : trimmedBase,
            preset: preset.isEmpty ? nil : preset,
            // ★ 2026-10-30：进 Keychain 之前就清干净，别把不可见字符存下去。
            password: password.credentialNormalized.isEmpty ? nil : password.credentialNormalized,
            syncAudio: syncAudio,
            allowSelfSigned: allowSelfSigned
        )
        configService.saveNow()
    }

    // MARK: - Endpoint parsing


    /// ★ 2026-10-30：把粘贴进主机框的完整 URL 拆开——`http://192.168.15.102:5005`
    /// → 主机 `192.168.15.102`、端口 `5005`、HTTPS 关。极空间/群晖客户端的「复制」
    /// 按钮给的都是这种串，逐字重抄是最容易错的一步。
    /// ★ 二稿：裸 `ip:端口`（没有 `://`）也拆——调用点都是"提交时刻"
    /// （回车/测试/保存），不存在打字打一半的问题；顺手把全角数字/冒号
    /// 归一成半角（中文键盘最容易埋的雷）。
    private func applyPastedEndpoint() {
        var text = host.trimmingCharacters(in: .whitespaces).fullwidthNormalized
        // 全角冒号＼数字先归一，再走同一条解析路径。
        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            if scheme == "https" {
                useHTTPS = true
            } else if scheme == "http" {
                useHTTPS = false
            }
            text = String(text[schemeRange.upperBound...])
            // 末尾可能带着路径（…:5005/dav）——路径归 basePath 管，这里只留主机和端口。
            if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        }
        if let colon = text.lastIndex(of: ":"),
           let p = Int(text[text.index(after: colon)...]),
           (1...65535).contains(p) {
            portText = String(p)
            text = String(text[..<colon])
        }
        host = text
    }

    // MARK: - Actions

    private func test() async {
        applyPastedEndpoint()
        guard let port = parsedPort else {
            probe = (false, L10n.WebDAV.badPort)
            return
        }
        probing = true
        probe = nil
        defer { probing = false }

        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces).fullwidthNormalized

        // ★ 2026-10-30：密码里混进看不见的字符（复制带来的零宽符、结尾换行、
        //   全角小数点）时，用户自己再怎么重打也是同样的结果。网络层已经统一
        //   清洗，这里把这件事说出来，并把清洗后的值写回输入框。
        let passwordCleaned = password != password.credentialNormalized
        if passwordCleaned { password = password.credentialNormalized }
        func annotate(_ text: String) -> String {
            passwordCleaned ? text + "（密码里的空格/不可见字符已自动清理）" : text
        }

        func make(_ path: String) -> WebDAVClient {
            WebDAVClient(
                host: trimmedHost,
                port: port,
                useHTTPS: useHTTPS,
                username: trimmedUser,
                password: password,
                basePath: path,
                allowSelfSigned: allowSelfSigned
            )
        }

        var basePath = basePathText()
        // ★ 2026-10-30（用户："点击测试链接极空间提示 401"）：极空间的个人空间
        //   目录名是 `/sata<卷>-<账号>/`，猜不出来。目录还停在默认值时先扫根目录
        //   自动定位——不限服务商，反正根上没有 sata 命名就返回 nil。
        if basePath == "/nomily",
           let space = await make("/").discoverPersonalSpace(username: trimmedUser) {
            basePath = space + "/nomily"
            self.basePath = basePath
        }

        do {
            let ms = try await make(basePath).testConnection()
            probe = (true, annotate(basePath == basePathText()
                ? L10n.WebDAV.testOk(ms)
                : L10n.WebDAV.testOkDiscovered(ms, basePath)))
            return
        } catch {
            // ★ 自愈重试：目录填错时极空间报 401/404，话术再好也不如直接修好。
            //   扫根目录找个人空间，切过去再试一次；成功就把新目录回填表单。
            if let space = await make("/").discoverPersonalSpace(username: trimmedUser) {
                let retryPath = space + "/nomily"
                if retryPath != basePath,
                   let ms = try? await make(retryPath).testConnection() {
                    self.basePath = retryPath
                    probe = (true, annotate(L10n.WebDAV.testOkDiscovered(ms, retryPath)))
                    return
                }
            }
            probe = (false, annotate(error.localizedDescription))
        }
    }

    private func basePathText() -> String {
        basePath.trimmingCharacters(in: .whitespaces).isEmpty ? "/nomily" : basePath
    }

    private func syncNow() async {
        save() // commit the form first — sync reads config
        await sync.syncAll(config: configService.config)
    }
}
