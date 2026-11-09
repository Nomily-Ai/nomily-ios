import SwiftUI

/// 录音豆（D3200）Wi‑Fi 快传的**独立页面** —— 对标 V05E 的 `FastTransferSheet`：
/// 阶段状态 + 每文件进度行 + 取消/关闭，而不是藏在列表底栏里的一行字。
///
/// 传输逻辑仍住在 `RecorderSheet.runSoundcoreWifiExport()`（要接资料库入库、
/// 删除豆上录音等一整套流程）；本页只是它的展示层，`model` 由那边填充。
///
/// 2026-10-29（用户："传输的时候需要参考 V05E 的那个 WiFi 快传，直接弹出一个页面
/// 出来展示 WiFi 快传"）。
struct SoundcoreWifiTransferSheet: View {
    @ObservedObject var model: SoundcoreWifiTransferModel
    var onCancel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.WifiXfer.statusSection) {
                    HStack(spacing: 8) {
                        Image(systemName: model.phase.icon)
                            .foregroundStyle(model.phase.tint)
                        Text(model.stageTitle).bold()
                    }
                    if let detail = model.stageDetail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let ssid = model.ssid {
                    Section(L10n.WifiXfer.hotspotSection) {
                        LabeledContent(L10n.WifiXfer.hotspotName, value: ssid)
                        LabeledContent(L10n.WifiXfer.password, value: model.psk ?? "")
                    }
                }

                if !model.rows.isEmpty {
                    Section(L10n.WifiXfer.filesPending(model.rows.count)) {
                        ForEach(model.rows) { row in
                            SoundcoreWifiFileRow(row: row)
                        }
                    }
                }

                if model.phase == .working {
                    Section {
                        Label(L10n.WifiXfer.foregroundHint, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        if model.phase == .working {
                            onCancel()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Text(model.phase == .working ? L10n.WifiXfer.cancelTransfer : L10n.WifiXfer.close)
                            .frame(maxWidth: .infinity)
                    }
                    .tint(model.phase == .working ? .red : .accentColor)
                }
            }
            .navigationTitle(L10n.WifiXfer.navTitle)
            .navigationBarTitleDisplayMode(.inline)
            // 传输中别让下滑手势把页面关掉——否则用户以为传输没了。
            .interactiveDismissDisabled(model.phase == .working)
        }
    }
}

// MARK: - row

private struct SoundcoreWifiFileRow: View {
    let row: SoundcoreWifiTransferModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name).font(.body.monospaced())
                Spacer()
                // ★ 2026-10-29（用户："显示 57.4MB，快传页显示 60.1MB"）：设备列表用
                // `字节 / 1_048_576`（MiB 标成 MB），这里原来用十进制 MB——同一个数
                // 两套单位。统一成列表口径，数字对得上。
                Text(Self.sizeLabel(row.size))
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch row.status {
            case .pending:
                Text(L10n.WifiXfer.waiting).font(.caption2).foregroundStyle(.secondary)
            case .downloading(let got):
                let frac = row.size > 0 ? min(1, Double(got) / Double(row.size)) : 0
                ProgressView(value: frac)
                Text("\(Self.sizeLabel(got)) / \(Self.sizeLabel(row.size))")
                    .font(.caption2).foregroundStyle(.secondary)
            case .saved:
                Label(L10n.WifiXfer.savedLibrary, systemImage: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            case .savedPartial(let note):
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    /// 与设备列表 `detail()` 同口径：字节 / 1_048_576，"MB" 标签。
    static func sizeLabel(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

// MARK: - model

@MainActor
final class SoundcoreWifiTransferModel: ObservableObject, Identifiable {
    struct Row: Identifiable {
        let id: UInt32
        let name: String
        let size: Int
        var status: Status

        enum Status {
            case pending
            case downloading(got: Int)
            case saved
            /// 存了但只有一部分（设备单会话 ~50 MiB 上限）。
            case savedPartial(String)
            case failed(String)
        }
    }

    enum Phase {
        case working, done, failed, cancelled

        var icon: String {
            switch self {
            case .working: return "arrow.triangle.2.circlepath"
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .cancelled: return "stop.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .working: return .accentColor
            case .done: return .green
            case .failed: return .orange
            case .cancelled: return .secondary
            }
        }
    }

    @Published var rows: [Row] = []
    @Published var stageTitle = L10n.WifiXfer.stagePreparing
    @Published var stageDetail: String?
    @Published var error: String?
    @Published var phase: Phase = .working
    @Published var ssid: String?
    @Published var psk: String?

    private var indexById: [UInt32: Int] = [:]

    func setFiles(_ files: [(id: UInt32, name: String, size: Int)]) {
        rows = files.map { Row(id: $0.id, name: $0.name, size: $0.size, status: .pending) }
        indexById = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
    }

    /// 把导出器的进度镜像到页面上。
    func apply(_ p: SoundcoreWifiExporter.Progress) {
        stageDetail = p.message
        switch p.phase {
        case .openAp:
            stageTitle = L10n.WifiXfer.stageConfigHotspot
        case .waitJoin:
            stageTitle = L10n.WifiXfer.stageJoinHotspot
        case .connectWs:
            stageTitle = L10n.WifiXfer.stageConnecting
        case .transferring:
            stageTitle = L10n.WifiXfer.stageTransferring
            if p.currentFile > 0, p.currentFile <= rows.count {
                rows[p.currentFile - 1].status = .downloading(got: p.fileBytes)
            }
        case .done:
            stageTitle = L10n.WifiXfer.stageDone
            phase = .done
        case .error:
            stageTitle = L10n.WifiXfer.stageFailed
            error = p.message
            phase = .failed
        }
    }

    func markSaved(fileId: UInt32, partial: Bool, coverage: Double) {
        guard let idx = indexById[fileId], idx < rows.count else { return }
        rows[idx].status = partial
            ? .savedPartial(L10n.WifiXfer.partialSaved(Int((coverage * 100).rounded())))
            : .saved
    }

    func markFailed(fileId: UInt32, message: String) {
        guard let idx = indexById[fileId], idx < rows.count else { return }
        rows[idx].status = .failed(message)
    }

    func finish(error: String?) {
        if let error, !error.isEmpty {
            self.error = error
            if phase == .working { phase = .failed }
        } else if phase == .working {
            phase = .done
            stageTitle = L10n.WifiXfer.stageDone
        }
    }

    /// 用户点了"取消传输"。
    func markCancelled() {
        phase = .cancelled
        stageTitle = L10n.WifiXfer.stageCancelled
    }

    /// 导出中途抛错：把还在"传输中"的行标成失败（没轮到的保持"等待传输"）。
    func failUnfinished(message: String) {
        for i in rows.indices {
            if case .downloading = rows[i].status {
                rows[i].status = .failed(message)
            }
        }
    }
}
