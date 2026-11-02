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
                                // ★ 2026-10-30：有官方 App 图标就用真图标（App Store
                                //   抓的原 图，圆角由这里裁）；没品牌的回退 SF Symbol。
                                if let appIcon = item.appIcon {
                                    Image(appIcon)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                } else {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .fill(item.tint.gradient)
                                        )
                                }
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
/// ★ 2026-10-30（用户："nas 的名称需要把他们的 APP 图标附带上"）：`appIcon` 是
/// 从 App Store 拿到的各家官方 App 图标（Assets 里的 imageset，512px 原图缩到
/// 180px）；`其他 WebDAV` 没有品牌，回退到 SF Symbol。
enum WebDAVPresets {
    struct Item {
        let label: String
        let port: Int
        let https: Bool
        let hostPlaceholder: String
        let hint: String
        let symbol: String
        let tint: Color
        var appIcon: String? = nil
    }

    static let all: [Item] = [
        Item(label: "群晖", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "先在套件中心装好「WebDAV Server」，用 DSM 账号登录",
             symbol: "shippingbox.fill", tint: .blue, appIcon: "NASynology"),
        Item(label: "威联通", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "在 App Center 启用 WebDAV 后使用",
             symbol: "shippingbox.fill", tint: .indigo, appIcon: "NASQNAP"),
        Item(label: "绿联", port: 9443, https: true, hostPlaceholder: "192.168.1.10",
             hint: "在绿联云的设置里开启 WebDAV",
             symbol: "shippingbox.fill", tint: .green, appIcon: "NASUGREEN"),
        Item(label: "飞牛", port: 5006, https: true, hostPlaceholder: "192.168.1.10",
             hint: "fnOS 应用中心启用 WebDAV 后使用",
             symbol: "shippingbox.fill", tint: .teal, appIcon: "NASFeiniu"),
        // ★ 2026-10-30：极空间实测（Z4Pro，5005 HTTP 认证通过 + 个人空间可写）。
        //   关键规则：**WebDAV 根目录不可写**（MKCOL/PUT 一律 400/401），可写的根是
        //   用户的个人空间 `/sataXX-账号/`——目录必须填到个人空间下面。
        //   5006 HTTPS 是自签证书 → 必须开「允许自签」。目录填错时测试连接会
        //   自动扫描根目录定位个人空间并回填。
        Item(label: "极空间", port: 5005, https: false, hostPlaceholder: "192.168.1.10 或 100.x.y.z",
             hint: "系统设置 → 文件与共享服务 → WebDAV 打开。HTTP 默认 5005；用 HTTPS(5006) 需开「允许自签证书」。目录填个人空间下的路径（形如 /sata11-你的账号/nomily），填错也没关系——测试连接会自动定位",
             symbol: "externaldrive.fill", tint: .orange, appIcon: "NASZSpace"),
        // ★ 2026-10-30（Nextcloud 引导）：公网服务，和局域网 NAS 的填法完全
        //   不同——域名 + 应用密码 + 自动目录，不再要求用户手拼 remote.php 路径。
        Item(label: "Nextcloud", port: 443, https: true, hostPlaceholder: "cloud.example.com",
             hint: "① 主机填域名，例如 cloud.example.com（自建且证书自签就打开「允许自签证书」）；② 密码用「应用密码」：登录网页版 → 右上角头像 → 设置 → 安全 → 设备和会话 → 创建新应用密码，登录密码不行；③ 目录不用填，会自动用 /remote.php/dav/files/你的用户名/Nomily/",
             symbol: "cloud.fill", tint: .cyan, appIcon: "NASNextcloud"),
        Item(label: "坚果云", port: 443, https: true, hostPlaceholder: "dav.jianguoyun.com",
             hint: "路径填 /dav；密码要用「应用密码」（账户安全里生成），不是登录密码",
             symbol: "cloud.fill", tint: .blue, appIcon: "NASNutstore"),
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
    /// ★ 2026-11-02（用户拿分享链接当 WebDAV 地址）：粘贴的是网页分享链接
    ///   （`/f/<id>`、`/s/<token>`）时给出纠正引导，而不是默默存一条必挂的配置。
    @State private var pasteNote: String?
    /// ★ 2026-11-02（用户："上传指定文件夹需要有选择而不固定"）：服务器文件夹
    ///   浏览选择器。
    @State private var showingFolderPicker = false

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

    /// ★ 2026-10-30（用户："同步到 Nextcloud 这个需要优化一下，他不是本地的
    ///   局域网，需要增加引导跟对应设置"）：Nextcloud 是公网服务，WebDAV 根
    ///   永远带用户名（`/remote.php/dav/files/<用户名>/`）——这是新手最容易卡死
    ///   的一步（填错就 404/401，且报错看不出原因）。所以选了 Nextcloud 就
    ///   **不显示目录框**，路径由用户名自动推导；老配置里已手填过 remote.php
    ///   路径的仍然尊重原值。
    private var isNextcloud: Bool { preset == "Nextcloud" }

    /// 实际生效的服务器目录：Nextcloud 自动推导，其余照旧。
    /// ★ 2026-11-02：推导到 `<用户名>/Nomily/` 子目录——files 根直接堆
    ///   transcripts/、audio/ 会把网盘根目录弄乱，与其他 NAS 的 /nomily 一致。
    private var effectiveBasePath: String {
        if isNextcloud {
            let user = username.trimmingCharacters(in: .whitespaces).credentialNormalized
            if !user.isEmpty, !basePath.contains("remote.php") {
                return "/remote.php/dav/files/\(user)/Nomily/"
            }
        }
        return basePathText()
    }

    var body: some View {
        Form {
            // ★ 2026-10-30（用户："在服务器类型选择了对应的设备里面就不要设置
            //   服务商可以选择了"）：类型选择只发生在弹层里，进到本页不再出现
            //   「服务商」Picker——预设的端口/HTTPS/目录在 load() 里按 initialPreset
            //   预填，品牌提示挪到连接区的 footer。

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
                // ★ 2026-11-02（用户："上传指定文件夹需要有选择而不固定"）：
                //   目录统一「可看可改可浏览」——Nextcloud 显示推导结果并提供
                //   「恢复自动」，其余服务商保留手输框；所有类型都能点
                //   「在服务器上选择…」进文件夹浏览弹层。
                if isNextcloud {
                    HStack {
                        Text(effectiveBasePath)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if basePath.contains("remote.php") {
                            Button(L10n.WebDAV.resetFolder) { basePath = "" }
                                .font(.footnote)
                        }
                    }
                } else {
                    TextField(L10n.WebDAV.basePath, text: $basePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button {
                    prepareFolderPicker()
                } label: {
                    Label(L10n.WebDAV.browseFolders, systemImage: "folder.badge.gearshape")
                }
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                          || username.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text(L10n.WebDAV.connection)
            } footer: {
                // 品牌引导文案跟着预设走（原来挂在已删除的服务商 Picker 下面）。
                // ★ 2026-11-02（用户："需要增加引导如何获取对应的账号密码而不是
                // 登录密码之类的"）：凭据引导统一放在品牌提示**前面**——用户先
                // 看到账号密码去哪拿，再看品牌细节。
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(L10n.WebDAV.credentialGuide)
                    } icon: {
                        Image(systemName: "person.text.rectangle")
                    }
                    if isNextcloud {
                        Text("目录默认是 /remote.php/dav/files/你的用户名/Nomily/，可以点「在服务器上选择文件夹」换成任意已有目录。" + L10n.WebDAV.basePathFooter)
                    } else if let hint = WebDAVPresets.item(named: preset)?.hint {
                        Text(hint + "\n\n" + L10n.WebDAV.basePathFooter)
                    } else {
                        Text(L10n.WebDAV.basePathFooter)
                    }
                }
            }

            // ★ 2026-11-02：粘贴了分享链接时的即时纠正（见 pasteNote）。
            if let note = pasteNote {
                Section {
                    Label {
                        Text(note)
                    } icon: {
                        Image(systemName: "link.badge.plus")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
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
        .sheet(isPresented: $showingFolderPicker) {
            WebDAVFolderPicker(
                client: makeFormClient(),
                initialPath: effectiveBasePath
            ) { picked in
                basePath = picked
                probe = (true, "目录已设为 \(picked)")
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    /// 用表单当前值构建浏览用的 client（端口非法时兜底 443——入口已拦过）。
    private func makeFormClient() -> WebDAVClient {
        WebDAVClient(
            host: host.trimmingCharacters(in: .whitespaces),
            port: parsedPort ?? 443,
            useHTTPS: useHTTPS,
            username: username,
            password: password,
            basePath: basePathText(),
            allowSelfSigned: allowSelfSigned
        )
    }

    /// 进文件夹选择器前先把粘贴的整串端点拆掉（主机框里可能是完整 URL）。
    private func prepareFolderPicker() {
        applyPastedEndpoint()
        guard parsedPort != nil else {
            probe = (false, L10n.WebDAV.badPort)
            return
        }
        showingFolderPicker = true
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
        // ★ 2026-10-30：从类型选择弹层跳进来且还没有配置时，预选该类型并把
        //   端口/HTTPS/目录预填好（原来靠已删除的 Picker onChange 触发）。
        preset = cfg?.preset ?? initialPreset ?? ""
        if cfg == nil, let p = initialPreset {
            applyPresetDefaults(p)
        }
        pasteNote = nil
    }

    /// 弹层选完类型进来的一次性预填（端口 / HTTPS / 目录）。
    private func applyPresetDefaults(_ label: String) {
        guard let item = WebDAVPresets.item(named: label) else { return }
        portText = String(item.port)
        useHTTPS = item.https
        basePath = label == "坚果云" ? "/dav"
            : label == "Nextcloud" ? basePath
            : "/nomily"
    }

    private func save() {
        applyPastedEndpoint()
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
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
            // ★ 2026-10-30：Nextcloud 的目录由用户名推导（/remote.php/dav/files/<用户名>/），
            //   不能把表单里那格（本来就隐藏了）的默认 /nomily 存下去。
            basePath: effectiveBasePath,
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
            // ★ 2026-10-30（Nextcloud 引导）：末尾可能带着路径——
            //   `https://cloud.example.com/remote.php/dav/files/alice/` 整串粘进来
            //   时，主机后面的部分不能直接扔：Nextcloud 的路径里藏着用户名，
            //   其他 NAS 的路径就是目录。交给 applyPastedPath 处理。
            if let slash = text.firstIndex(of: "/") {
                let pathPart = String(text[slash...])
                text = String(text[..<slash])
                applyPastedPath(pathPart)
            }
        }
        if let colon = text.lastIndex(of: ":"),
           let p = Int(text[text.index(after: colon)...]),
           (1...65535).contains(p) {
            portText = String(p)
            text = String(text[..<colon])
        }
        host = text
    }

    /// ★ 2026-10-30（Nextcloud 引导）：粘贴的 URL 里主机后面的路径怎么用。
    ///   · `/remote.php/dav/files/<用户名>/` → 用户名直接回填（Nextcloud 客户端
    ///     复制的 WebDAV 地址就是这个形状），目录走自动推导，不用动；
    ///   · `/remote.php/webdav…`（旧版端点）→ 目录原样保留；
    ///   · 其他路径（坚果云 /dav、群晖 /home 等）→ 目录原样保留；
    ///   · `/` → 没有信息，忽略。
    /// ★ 2026-11-02（用户实测踩到）：`/f/<数字>`、`/s/<token>`、`/d/<…>` 是
    ///   Nextcloud 的**网页分享/文件页**链接，不是 WebDAV 端点——拿它当地址
    ///   测试只会得到 401/404。识别出来给纠正引导，目录保持原值不动。
    private static let sharePathRegex = try? NSRegularExpression(
        pattern: #"^/(f|s|d)/[A-Za-z0-9._-]+/?$"#)

    private func applyPastedPath(_ path: String) {
        if let re = Self.sharePathRegex,
           re.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil {
            pasteNote = "你粘贴的是网页分享链接，不是 WebDAV 地址。主机只填域名（如 doc.oazon.com），用户名填你的账号，密码用「应用密码」——目录会自动生成，不需要这条链接。"
            return
        }
        pasteNote = nil
        let filesMarker = "/remote.php/dav/files/"
        if path.hasPrefix(filesMarker) {
            let user = path.dropFirst(filesMarker.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !user.isEmpty { username = String(user) }
            basePath = filesMarker + user + "/"
        } else if path.hasPrefix("/remote.php/webdav") {
            basePath = "/remote.php/webdav/"
        } else if !path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
            basePath = path.hasSuffix("/") ? path : path + "/"
        }
        // 根路径（"/"）没有可提取的信息，忽略。
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

        var basePath = effectiveBasePath
        // ★ 2026-10-30（用户："点击测试链接极空间提示 401"）：极空间的个人空间
        //   目录名是 `/sata<卷>-<账号>/`，猜不出来。目录还停在默认值时先扫根目录
        //   自动定位——不限服务商，反正根上没有 sata 命名就返回 nil。
        //   Nextcloud 的路径已在 effectiveBasePath 推导好，跳过这个分支。
        if !isNextcloud, basePath == "/nomily",
           let space = await make("/").discoverPersonalSpace(username: trimmedUser) {
            basePath = space + "/nomily"
            self.basePath = basePath
        }

        do {
            let ms = try await make(basePath).testConnection()
            probe = (true, annotate(basePath == effectiveBasePath
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

/// ★ 2026-11-02（用户："上传指定文件夹需要有选择而不固定"）：服务器文件夹
/// 浏览选择器。PROPFIND Depth 1 逐层下钻，「使用这个目录」提交给表单。
/// client 由表单当前值构建——换了主机/账号先回车提交再进来
/// （`prepareFolderPicker` 已做端点拆分），弹层里只管浏览。
private struct WebDAVFolderPicker: View {
    let client: WebDAVClient
    let initialPath: String
    var onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var dirs: [WebDAVClient.DirectoryEntry] = []
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onPick(WebDAVClient.normalizedDirPath(path))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L10n.WebDAV.useThisFolder, systemImage: "checkmark.circle.fill")
                                .font(.body.weight(.semibold))
                            Text(path.isEmpty ? initialPath : path)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .disabled(loading)
                    if path != "/" {
                        Button {
                            Task { await go(to: parentPath) }
                        } label: {
                            Label(L10n.WebDAV.parentFolder, systemImage: "arrow.uturn.backward")
                        }
                        .disabled(loading)
                    }
                }
                Section {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    } else if dirs.isEmpty {
                        Text(L10n.WebDAV.noSubfolders)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(dirs) { dir in
                            Button {
                                Task { await go(to: dir.path) }
                            } label: {
                                Label(dir.name, systemImage: "folder.fill")
                                    .foregroundStyle(.primary)
                            }
                            .disabled(loading)
                        }
                    }
                } header: {
                    Text(L10n.WebDAV.subfolders)
                } footer: {
                    Text(L10n.WebDAV.pickFolderFooter)
                }
            }
            .navigationTitle(L10n.WebDAV.pickFolder)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if path.isEmpty {
                path = WebDAVClient.normalizedDirPath(initialPath)
                await load()
            }
        }
    }

    private var parentPath: String {
        let trimmed = path.dropLast()              // 去掉结尾 /
        if let idx = trimmed.lastIndex(of: "/") {
            let parent = String(trimmed[...idx])
            return parent == "/" ? "/" : parent
        }
        return "/"
    }

    private func go(to newPath: String) async {
        path = WebDAVClient.normalizedDirPath(newPath)
        await load()
    }

    private func load() async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            dirs = try await client.listDirectories(at: path)
        } catch {
            dirs = []
            errorText = error.localizedDescription
        }
    }
}
