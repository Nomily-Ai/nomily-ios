import SwiftUI

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 存储分层 · WebDAV 目的地）
///
/// The NAS form, ported: preset picker (群晖/威联通/绿联/飞牛/极空间/Nextcloud/
/// 坚果云/其他) → the four connection fields → 「也传录音」 → probe → sync-now.
/// Presets only prefill port/https + a setup hint; the protocol underneath is
/// plain WebDAV for every one of them.
struct WebDAVView: View {
    @EnvironmentObject private var configService: ConfigService
    @ObservedObject private var sync = WebDAVSyncService.shared

    /// Form-local editable copy — committed to config on save, password lives
    /// in the Keychain via ConfigService's strip/restore.
    @State private var host = ""
    @State private var port = 443
    @State private var useHTTPS = true
    @State private var username = ""
    @State private var password = ""
    @State private var basePath = "/nomily"
    @State private var syncAudio = false
    @State private var preset = ""

    @State private var probing = false
    @State private var probe: (ok: Bool, text: String)?

    /// (label, port, https, hostPlaceholder, hint)
    private let presets: [(String, Int, Bool, String, String)] = [
        ("群晖", 5006, true, "192.168.1.10",
         "先在套件中心装好「WebDAV Server」，用 DSM 账号登录"),
        ("威联通", 5006, true, "192.168.1.10",
         "在 App Center 启用 WebDAV 后使用"),
        ("绿联", 9443, true, "192.168.1.10",
         "在绿联云的设置里开启 WebDAV"),
        ("飞牛", 5006, true, "192.168.1.10",
         "fnOS 应用中心启用 WebDAV 后使用"),
        ("极空间", 443, true, "192.168.1.10",
         "在极空间的设置里开启 WebDAV"),
        ("Nextcloud", 443, true, "cloud.example.com",
         "填 Nextcloud 域名，路径含 /remote.php/dav/files/用户名/"),
        ("坚果云", 443, true, "dav.jianguoyun.com",
         "路径填 /dav；密码要用「应用密码」（账户安全里生成），不是登录密码"),
        ("其他 WebDAV", 443, true, "服务器地址", "任意标准 WebDAV 服务"),
    ]

    var body: some View {
        Form {
            Section {
                Picker(L10n.WebDAV.preset, selection: $preset) {
                    Text(L10n.WebDAV.presetUnpicked).tag("")
                    ForEach(presets, id: \.0) { item in
                        Text(item.0).tag(item.0)
                    }
                }
                .onChange(of: preset) { newValue in
                    guard let item = presets.first(where: { $0.0 == newValue }) else { return }
                    port = item.1
                    useHTTPS = item.2
                    basePath = newValue == "坚果云" ? "/dav"
                        : newValue == "Nextcloud" ? basePath
                        : "/nomily"
                }
            } header: {
                Text(L10n.WebDAV.serverType)
            } footer: {
                if let hint = presets.first(where: { $0.0 == preset })?.4 {
                    Text(hint)
                }
            }

            Section {
                TextField(L10n.WebDAV.host, text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper(L10n.WebDAV.port(port), value: $port, in: 1...65535)
                Toggle(L10n.WebDAV.https, isOn: $useHTTPS)
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
        port = cfg?.port ?? 443
        useHTTPS = cfg?.useHTTPS ?? true
        username = cfg?.username ?? ""
        password = cfg?.password ?? ""
        basePath = cfg?.basePath ?? "/nomily"
        syncAudio = cfg?.syncAudio ?? false
        preset = cfg?.preset ?? ""
    }

    private func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedBase = basePath.trimmingCharacters(in: .whitespaces)
        if trimmedHost.isEmpty {
            // Everything cleared = remove the destination entirely.
            configService.config.webdav = nil
        } else {
            configService.config.webdav = WebDAVConfig(
                host: trimmedHost,
                port: port,
                useHTTPS: useHTTPS,
                username: username.trimmingCharacters(in: .whitespaces),
                basePath: trimmedBase.isEmpty ? "/nomily" : trimmedBase,
                preset: preset.isEmpty ? nil : preset,
                password: password.isEmpty ? nil : password,
                syncAudio: syncAudio
            )
        }
        configService.saveNow()
    }

    // MARK: - Actions

    private func test() async {
        probing = true
        probe = nil
        defer { probing = false }
        let client = WebDAVClient(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port,
            useHTTPS: useHTTPS,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password,
            basePath: basePath.trimmingCharacters(in: .whitespaces).isEmpty ? "/nomily" : basePath
        )
        do {
            let ms = try await client.testConnection()
            probe = (true, L10n.WebDAV.testOk(ms))
        } catch {
            probe = (false, error.localizedDescription)
        }
    }

    private func syncNow() async {
        save() // commit the form first — sync reads config
        await sync.syncAll(config: configService.config)
    }
}
