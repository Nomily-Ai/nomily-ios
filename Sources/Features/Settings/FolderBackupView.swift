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
    /// ★ 2026-11-02：首次使用（没选过文件夹）进页自动弹选择器——iOS 文件
    /// 浏览器根目录默认就是 iCloud 云盘，选一次即成默认云备份路径。
    @State private var autoOpenedPicker = false

    var body: some View {
        Form {
            Section {
                Button {
                    showPicker = true
                } label: {
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(Color.blue.gradient)
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
                    // ★ 2026-11-02（用户："展示占用内存"）：目的地文件夹的
                    // 文件数 + 总占用，进页/导出后自动刷新。
                    if let usage = exporter.usageText {
                        LabeledContent(L10n.FolderExport.usage) {
                            Text(usage)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button(role: .destructive) {
                        exporter.clear()
                    } label: {
                        Text(L10n.FolderExport.clearFolder)
                    }
                }
            } header: {
                Text(L10n.FolderExport.destination)
            } footer: {
                // ★ 2026-11-02：iCloud 引导（免签名方案——文件浏览器的根目录
                // 默认就是 iCloud 云盘，选一次即可全自动云同步）。
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.FolderExport.icloudHint)
                    Text(L10n.FolderExport.pickFooter)
                }
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

            // ★ 2026-11-09（用户："可以选择上传哪些"）：写哪些产物到所选文件夹。
            Section {
                Toggle(L10nUploadContent.transcript, isOn: $exporter.uploadContent.transcript)
                Toggle(L10nUploadContent.asr, isOn: $exporter.uploadContent.asrJSON)
                Toggle(L10nUploadContent.summary, isOn: $exporter.uploadContent.summary)
                Toggle(L10nUploadContent.todos, isOn: $exporter.uploadContent.todos)
                Toggle(L10nUploadContent.mindMap, isOn: $exporter.uploadContent.mindMap)
                Toggle(L10nUploadContent.chapters, isOn: $exporter.uploadContent.chapters)
                Toggle(L10nUploadContent.bundle, isOn: $exporter.uploadContent.bundle)
            } header: {
                Text(L10nUploadContent.section)
            } footer: {
                Text(L10nUploadContent.footer)
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
        // ★ 2026-11-02：进页统计占用；首次使用自动弹选择器。
        .task {
            exporter.refreshUsage()
            if !exporter.hasFolder, !autoOpenedPicker {
                autoOpenedPicker = true
                showPicker = true
            }
        }
        .refreshable { exporter.refreshUsage() }
        .onChange(of: exporter.lastReport) { _ in
            // 手动导出跑完顺手刷新占用。
            exporter.refreshUsage()
        }
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
