import SwiftUI

/// ★ 2026-11-02（用户："使用引导需要到对应的 app 的功能模块去，是在对应的模块点击，
/// 不要一整个页面，而是在对应模块指向让用户点击，走一遍流程"）：
///
/// 流程式首用引导：**卡片浮在真实页面上**，按 5 步带用户走完核心链路——
///
/// 0. 录音页：连接设备（主按钮直接拉起扫描）
/// 1. 实时页：实时转写是什么
/// 2. 设置 → ASR 服务商（深链直达，页内就有「去控制台获取 API Key」）
/// 3. 设置 → LLM 服务商（深链直达）
/// 4. 设置 → 录音与转写（WebDAV 备份入口）
///
/// 进度存 UserDefaults（`guide.done.v1` + `guide.step.v1`）：首次启动自动开始，
/// 设置 → 使用引导 可随时重看。卡片由 RootView 挂 overlay（浮在所有被推入的
/// 页面之上），深链的入栈/出栈由 RootView 的 action 闭包驱动。
enum GuideStep: Int, CaseIterable {
    case connectDevice = 0
    case liveTranscribe
    case configureASR
    case configureLLM
    case cloudBackup

    var title: String {
        switch self {
        case .connectDevice:  return L10n.Guide.titleConnect
        case .liveTranscribe: return L10n.Guide.titleLive
        case .configureASR:   return L10n.Guide.titleASR
        case .configureLLM:   return L10n.Guide.titleLLM
        case .cloudBackup:    return L10n.Guide.titleBackup
        }
    }

    var body: String {
        switch self {
        case .connectDevice:  return L10n.Guide.bodyConnect
        case .liveTranscribe: return L10n.Guide.bodyLive
        case .configureASR:   return L10n.Guide.bodyASR
        case .configureLLM:   return L10n.Guide.bodyLLM
        case .cloudBackup:    return L10n.Guide.bodyBackup
        }
    }

    /// 主按钮文案；nil = 该步只有「下一步」。
    var primaryButton: String? {
        switch self {
        case .connectDevice:  return L10n.Guide.actionConnect
        case .liveTranscribe: return nil
        case .configureASR:   return L10n.Guide.actionGo
        case .configureLLM:   return L10n.Guide.actionGo
        case .cloudBackup:    return L10n.Guide.actionGo
        }
    }

    var icon: String {
        switch self {
        case .connectDevice:  return "dot.radiowaves.left.and.right"
        case .liveTranscribe: return "waveform.badge.mic"
        case .configureASR:   return "text.bubble"
        case .configureLLM:   return "sparkles"
        case .cloudBackup:    return "icloud.and.arrow.up"
        }
    }

    var tint: Color {
        switch self {
        case .connectDevice:  return .blue
        case .liveTranscribe: return .teal
        case .configureASR:   return .indigo
        case .configureLLM:   return .purple
        case .cloudBackup:    return .orange
        }
    }

    /// 「第 N 步 · 共 5 步」。
    var progressText: String {
        String(format: L10n.Guide.stepOf, index + 1, GuideStep.allCases.count)
    }

    var index: Int { rawValue }
}

struct GuideCardView: View {
    let step: GuideStep
    /// 主按钮（去连接 / 前往）：RootView 提供深链与扫描拉起。
    var primaryAction: () -> Void = {}
    /// 下一步。
    var advance: () -> Void
    /// 跳过整条引导。
    var skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: step.icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(step.tint.gradient)
                Text(step.progressText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(L10n.Guide.skip, action: skip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(step.title)
                .font(.headline)
            Text(step.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if let primary = step.primaryButton {
                    // ★ 主按钮只触发动作（扫描/深链）；是否推进到下一步由 RootView
                    // 决定——主按钮已经导航时，推进逻辑不该再切 tab。
                    Button(action: primaryAction) {
                        Text(primary)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(step.tint)
                }
                Button {
                    advance()
                } label: {
                    Text(step.primaryButton == nil ? L10n.Guide.next : L10n.Guide.later)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(step.tint.gradient.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
