import SwiftUI

/// ★ 2026-11-02（用户："应该是数据与存储位置，保存路径是这台 iPhone 或者
/// iCloud，然后才是 NAS，然后就是文件夹 app 里面这样"）：
/// 存储入口的**总枢纽**——四个落点按用户指定的层级顺序排布：
///
///   1. 这台 iPhone   —— 主存储，录音/转写/摘要永远先落在这里，不可关闭；
///   2. iCloud 云盘   —— 自动云备份（经文件夹导出实现，选 iCloud 云盘内文件夹）；
///   3. NAS (WebDAV)  —— 私有服务器自动备份；
///   4. 文件夹 App    —— 导出到"文件"App 里的任意位置。
///
/// 「录音与转写」设置页顶部原来的三行（WebDAV / 导出到文件夹 / 存储占用）
/// 收敛成本页一个入口；每行右侧带当前状态，不用点进去就知道配没配。
struct StorageLocationsView: View {
    @EnvironmentObject private var configService: ConfigService
    // 文件夹备份状态（自动备份徽标要实时反映开关）。
    @ObservedObject private var folderExport = FolderExportService.shared
    // ★ 2026-10-30：WebDAV 入口是类型选择弹层（与录音与转写页共用）。
    @State private var showWebDAVSetup = false

    var body: some View {
        Form {
            Section {
                // 1. 这台 iPhone —— 主存储。转写后的音频/文本都在 decryptedDir，
                //    点进去看占用明细。
                NavigationLink {
                    StorageUsageView()
                } label: {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(L10n.StorageLocations.iphone, systemImage: "iphone")
                            Text(L10n.StorageLocations.iphoneDesc)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 2. iCloud 云盘 —— 自动云备份的首选落点。FolderBackupView 首次
                //    进入会自动打开选择器，起点就是 iCloud 云盘根目录。
                NavigationLink {
                    FolderBackupView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(L10n.StorageLocations.icloud, systemImage: "icloud")
                            Spacer()
                            if folderExport.autoEnabled {
                                Text(L10n.FolderExport.autoOn)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if let name = folderExport.folderName {
                                Text(name)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(L10n.StorageLocations.icloudDesc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // 3. NAS —— WebDAV 类型选择弹层，选完进对应预设的配置页。
                Button {
                    showWebDAVSetup = true
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(L10n.StorageLocations.nas, systemImage: "server.rack")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let webdav = configService.config.webdav, webdav.isConfigured {
                                Text(webdav.preset ?? webdav.host)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(L10n.WebDAV.unconfigured)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(L10n.StorageLocations.nasDesc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // 4. 文件夹 App —— 任意位置导出（第三方网盘、外接盘等）。
                NavigationLink {
                    FolderBackupView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(L10n.StorageLocations.folder, systemImage: "folder")
                            Spacer()
                            if let name = folderExport.folderName, !folderExport.autoEnabled {
                                Text(name)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(L10n.StorageLocations.folderDesc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(L10n.StorageLocations.sectionHeader)
            } footer: {
                Text(L10n.StorageLocations.footer)
            }
        }
        .navigationTitle(L10n.StorageLocations.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWebDAVSetup) {
            WebDAVSetupSheet()
        }
    }
}
