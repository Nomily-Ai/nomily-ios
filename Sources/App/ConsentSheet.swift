import SwiftUI

/// 免责声明 / 使用须知（★ 2026-11-03）。
///
/// 用户原话："是否需要在增加一个免责条款，让用户同意点击之类的，参考 Plaud 或者其他主流 APP 这个同意事项……手表只放短提示"。
///
/// ## 为什么必须有一次显式同意
/// 这个 App 的核心动作是**录别人的声音**，产出物是**模型生成的文字**。这两件事各有一条
/// 真实的法律/事实风险：录音要取得在场各方同意（各地法律差别很大），AI 转写与摘要会出错。
/// Plaud、Otter、飞书妙记这类产品都会在首启放一页「同意」，不是为了免责好看，而是让用户
/// 在**第一次按下录音键之前**知道这两件事。
///
/// ## 三个实现约束
/// 1. **只问一次**：同意状态存在 `UserDefaults`（`consent.notice.v1`）。每次启动都弹的
///    "同意"等于没同意，用户只会闭眼点掉。
/// 2. **可回看**：设置 → 关于 → 免责声明与使用须知，用的是同一份文案（`LegalNoticeView`），
///    不另写一份"简版"——两份文案迟早会说的不是一回事。
/// 3. **不阻断老用户太久**：同意页只占一屏，条款正文可滚动，同意按钮始终在底部可见。
enum NomilyConsent {
    /// 同意状态。**所有判定都走这里**，别在各视图里各读各的 `UserDefaults` 键。
    static let storageKey = "consent.notice.v1"

    /// 文案版本。条款内容有实质修改时 +1，并在 `ConsentGate` 里按 `version` 重新征得同意。
    /// （目前只有 v1；扩条款时把 key 改成 `consent.notice.v2` 即可让所有人重新同意一次。）
    static let version = 1

    static var isAccepted: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    static func accept() {
        UserDefaults.standard.set(true, forKey: storageKey)
    }
}

/// 首次启动的同意页。**同意之前不进入 App**。
///
/// ⚠️ 与 `WelcomeSheet` 共用同一个 `fullScreenCover`（见 `RootView`）：先同意、再欢迎。
///    两个 cover 串着弹会撞上 SwiftUI 的"presenting while presenting"警告，
///    所以这里不自己开 cover，而是让宿主切换内容。
struct ConsentSheet: View {
    var accept: () -> Void

    /// 点过「不同意」之后才出现的说明。不是错误提示，而是"你现在还差哪一步"。
    @State private var declined = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    ForEach(Array(ConsentClause.all.enumerated()), id: \.offset) { index, clause in
                        clauseCard(index: index + 1, clause: clause)
                    }
                    if declined {
                        Text(L10n.Consent.declinedNote)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 40)
                .padding(.bottom, 16)
            }

            footer
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.appAccent.gradient)
                )
                .accessibilityHidden(true)
            Text(L10n.Consent.title)
                .font(.title2.weight(.semibold))
            Text(L10n.Consent.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func clauseCard(index: Int, clause: ConsentClause) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(index)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.appAccent))
                Text(clause.title)
                    .font(.subheadline.weight(.semibold))
            }
            Text(clause.body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                NomilyConsent.accept()
                accept()
            } label: {
                Text(L10n.Consent.accept)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(role: .cancel) {
                withAnimation { declined = true }
            } label: {
                Text(L10n.Consent.decline)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

/// 设置里的回看页：和首启同意页**同一份条款**，只是没有同意按钮。
struct LegalNoticeView: View {
    var body: some View {
        List {
            Section {
                Text(L10n.Consent.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(L10n.Consent.legalTitle) {
                ForEach(Array(ConsentClause.all.enumerated()), id: \.offset) { index, clause in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(index + 1). \(clause.title)")
                            .font(.subheadline.weight(.semibold))
                        Text(clause.body)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 3)
                }
            }
            Section {
                HStack {
                    Text(L10n.Consent.statusLabel)
                        .font(.footnote)
                    Spacer()
                    Text(NomilyConsent.isAccepted
                         ? L10n.Consent.statusAccepted
                         : L10n.Consent.statusPending)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(NomilyConsent.isAccepted ? .green : .orange)
                }
            }
        }
        .navigationTitle(L10n.Consent.aboutRow)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一条条款。文案集中在 `L10n.Consent`，两种视图共用，杜绝"两处各写一版"。
struct ConsentClause {
    let title: String
    let body: String

    static var all: [ConsentClause] {
        [
            ConsentClause(title: L10n.Consent.recordingTitle, body: L10n.Consent.recordingBody),
            ConsentClause(title: L10n.Consent.aiTitle, body: L10n.Consent.aiBody),
            ConsentClause(title: L10n.Consent.dataTitle, body: L10n.Consent.dataBody),
        ]
    }
}
