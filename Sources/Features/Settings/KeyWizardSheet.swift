import SwiftUI

/// ★ 2026-11-02（用户："每个 ASR 跟 LLM 里面不会获取 APIkey，在下面新增一个
/// 不会开通？复制提示词跟粘贴结果，参考饭耳的这个快引导"）：
///
/// 「不会开通？」快引导——面向完全不会去控制台创建 API Key 的用户：
///
///   1. **复制提示词**：把一段预置的中文提示词复制出去，粘给手边任何
///      AI 助手（豆包 / ChatGPT / Siri 写作工具…），让 AI 一步步教他
///      到哪注册、在哪建 Key；
///   2. **粘贴结果**：把 AI 的回复整段粘回来，App 自动从文本里认出
///      凭据（带标签的 `API Key: sk-xxx` 行优先，纯 token 兜底），
///      点「填入」回填到对应输入框。
///
/// 通用组件：LLM 单凭据（`apiKey`）和 ASR 多凭据（AK/SK、APPID…）
/// 共用——`fields` 描述要回填哪些字段，`onApply` 由调用方写进各自的
/// 配置存储。
struct KeyWizardSheet: View {

    struct Field: Identifiable {
        /// 配置存储里的字段 id（如 `apiKey`、`accessKeySecret`）。
        let id: String
        /// 展示名（与配置页输入框一致）。
        let label: String
        /// 匹配 AI 回复里「标签: 值」行的关键词（大小写不敏感）。
        /// 缺省用 `label` 本身——配置页的标签本来就是 "API Key" 这类词。
        var aliases: [String] = []
    }

    let vendorName: String
    /// 要回填的字段（按配置页顺序）。
    let fields: [Field]
    /// 控制台/注册页地址——写进提示词，让 AI 指路有据。
    let consoleURL: URL?
    /// 用户点「填入」后的回写回调。
    let onApply: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pasted = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(L10n.KeyWizard.intro)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // 1. 复制提示词
                    Button {
                        UIPasteboard.general.string = wizardPrompt
                        copied = true
                    } label: {
                        HStack {
                            Label(copied ? L10n.KeyWizard.copied : L10n.KeyWizard.copyPrompt,
                                  systemImage: copied ? "checkmark.circle" : "doc.on.doc")
                                .foregroundStyle(copied ? Color.green : Color.accentColor)
                            Spacer()
                        }
                    }
                    Text(wizardPrompt)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Text(L10n.KeyWizard.step1)
                }

                Section {
                    // 2. 粘贴 AI 的回复
                    TextEditor(text: $pasted)
                        .frame(minHeight: 120)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !detected.isEmpty {
                        ForEach(detected) { hit in
                            LabeledContent(hit.field?.label ?? L10n.KeyWizard.unknownField) {
                                Text(masked(hit.value))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Button {
                            var map: [String: String] = [:]
                            for hit in detected {
                                if let f = hit.field { map[f.id] = hit.value }
                            }
                            onApply(map)
                            dismiss()
                        } label: {
                            Label(L10n.KeyWizard.apply, systemImage: "square.and.arrow.down")
                        }
                    } else if !pasted.isEmpty {
                        Text(L10n.KeyWizard.notFound)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text(L10n.KeyWizard.step2)
                } footer: {
                    Text(L10n.KeyWizard.footer)
                }
            }
            .navigationTitle(L10n.KeyWizard.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }

    // MARK: - Prompt

    private var wizardPrompt: String {
        var lines = [
            String(format: L10n.KeyWizard.promptHead, vendorName)
        ]
        if let url = consoleURL {
            lines.append(String(format: L10n.KeyWizard.promptConsole, url.absoluteString))
        }
        if fields.count == 1 {
            lines.append(String(format: L10n.KeyWizard.promptSingle, fields[0].label))
        } else {
            let names = fields.map(\.label).joined(separator: "、")
            lines.append(String(format: L10n.KeyWizard.promptMulti, names))
        }
        lines.append(L10n.KeyWizard.promptTail)
        return lines.joined(separator: "\n")
    }

    // MARK: - Detection

    struct Hit: Identifiable {
        let value: String
        let field: Field?
        var id: String { value }
    }

    /// 从粘贴的文本里认凭据。两道策略：
    ///  1. **带标签**——逐行找 `标签[:：=] 值`，标签对上 `aliases`/`label`
    ///     的行直接归位（AI 的回复九成是这种）；
    ///  2. **裸 token 兜底**——没有任何标签命中时，抓全文里长得像凭据的
    ///     独立 token，按出现顺序塞进字段（单字段必中；双字段恰好两个
    ///     token 时按顺序配对）。
    private var detected: [Hit] {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var assigned: [String: String] = [:]   // field.id -> value
        var leftovers: [String] = []

        // 值的形态：够长、无空白、不是整句中文。
        let valuePattern = "[A-Za-z0-9_\\-.]{16,}"
        guard let valueRe = try? NSRegularExpression(pattern: valuePattern) else { return [] }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: valuePattern, options: .regularExpression) else { continue }
            let value = String(line[range])
            let labelPart = String(line[..<range.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: ":：=*-#` \t"))
            // 星号打码的行（AI 有时会打码）不能要——真值里不该有 *。
            guard !value.contains("*") else { continue }

            var matched = false
            if !labelPart.isEmpty {
                let hay = labelPart.lowercased()
                for f in fields where assigned[f.id] == nil {
                    let keys = (f.aliases + [f.label]).map { $0.lowercased() }
                    if keys.contains(where: { hay.contains($0) }) {
                        assigned[f.id] = value
                        matched = true
                        break
                    }
                }
            }
            if !matched { leftovers.append(value) }
        }

        // 裸 token 兜底：只在没有带标签命中时启用。
        if assigned.isEmpty {
            // 去重保序。
            var seen = Set<String>()
            leftovers = leftovers.filter { seen.insert($0).inserted }
            if fields.count == 1, let first = leftovers.first {
                assigned[fields[0].id] = first
            } else if fields.count == leftovers.count {
                for (i, f) in fields.enumerated() { assigned[f.id] = leftovers[i] }
            } else if leftovers.count == 1, fields.count == 2,
                      let only = leftovers.first {
                // 一个 token 两个 Key 型字段（如百度只给了一个）——给第一个。
                assigned[fields[0].id] = only
            }
        }

        return fields.compactMap { f in
            assigned[f.id].map { Hit(value: $0, field: f) }
        }
    }

    private func masked(_ v: String) -> String {
        guard v.count > 10 else { return v }
        return v.prefix(6) + "…" + v.suffix(4)
    }
}
