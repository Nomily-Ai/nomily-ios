import SwiftUI
import UniformTypeIdentifiers

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 保存位置 · 文件 App 路线）
///
/// Pick any folder (iCloud Drive / 我的 iPhone / 网盘 App 目录 / Obsidian 库),
/// export transcripts — and optionally audio — there. Companion destination to
/// the WebDAV page; same on-disk layout (`transcripts/` + `audio/`).
struct FolderBackupView: View {
    @ObservedObject private var exporter = FolderExportService.shared
    @EnvironmentObject private var configService: ConfigService

    @State private var showPicker = false
    @State private var syncAudio = false

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

            Section {
                Toggle(L10n.FolderExport.syncAudio, isOn: $syncAudio)
            } footer: {
                Text(L10n.FolderExport.syncAudioFooter)
            }

            Section {
                Button {
                    Task { await exporter.exportAll(syncAudio: syncAudio) }
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
