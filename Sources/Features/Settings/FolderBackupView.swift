import SwiftUI
import UniformTypeIdentifiers

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 保存位置 · 文件 App 路线）
///
/// Pick any folder (iCloud Drive / 我的 iPhone / 网盘 App 目录 / Obsidian 库),
/// export transcripts — and optionally audio — there. Companion destination to
/// the WebDAV page; same on-disk layout (`transcripts/` + `audio/`).
///
/// ★ 2026-10-30（用户："增加自动上传到 iCloud…缺少引导"）：加了「自动备份」
/// ——转写完成即写入所选文件夹；目标选 iCloud 云盘里的文件夹时，这就是
/// 自动上传 iCloud。开关状态持久化在 FolderExportService 里（自动路径
/// 没有 UI 在场，状态必须跟着服务走）。
struct FolderBackupView: View {
    @ObservedObject private var exporter = FolderExportService.shared
    @EnvironmentObject private var configService: ConfigService

    @State private var showPicker = false

    var body: some View {
        Form {
            Section {
                Button {
                    showPicker = true
                } label: {
                    HStack {
                        Text(L10n.FolderExport.pickFolder)
                        Spacer()
                        if let name = exporter.folderName {
                            Text(name).foregroundStyle(.secondary)
                        } else {
                            Text(L10n.FolderExport.noFolder).foregroundStyle(.secondary)
                        }
                    }
                }
                if exporter.hasFolder {
                    Button(role: .destructive) {
                        exporter.clear()
                    } label: {
                        Text(L10n.FolderExport.clearFolder)
                    }
                }
            } header: {
                Text(L10n.FolderExport.destination)
            } footer: {
                Text(L10n.FolderExport.pickFooter)
            }

            // ★ 2026-10-30：自动备份。放在目的地之后、手动导出之前——这是
            // 主路径（打开就全自动），手动导出只是补跑历史。
            Section {
                Toggle(L10n.FolderExport.auto, isOn: $exporter.autoEnabled)
            } footer: {
                Text(L10n.FolderExport.autoFooter)
            }

            Section {
                Toggle(L10n.FolderExport.syncAudio, isOn: $exporter.syncAudio)
            } footer: {
                Text(L10n.FolderExport.syncAudioFooter)
            }

            Section {
                Button {
                    Task { await exporter.exportAll() }
                } label: {
                    HStack {
                        Text(L10n.FolderExport.exportNow)
                        if exporter.isRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(exporter.isRunning || !exporter.hasFolder)
                if let report = exporter.lastReport {
                    Text(report)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.FolderExport.exportFooter)
            }

            // ★ 2026-10-29 (饭耳移植 · 规格 #10): one privacy sentence per page.
            Section {
                PrivacyNote(flavor: .backup)
            }
        }
        .navigationTitle(L10n.FolderExport.title)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                exporter.store(from: url)
            }
        }
    }
}
