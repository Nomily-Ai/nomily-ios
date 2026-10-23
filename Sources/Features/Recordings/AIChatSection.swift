import SwiftUI

/// Bottom-of-page AI Q&A, grounded in **this recording only** (DingTalk's recording page ends
/// with the same block).
///
/// ★ (2026-10-19) Split in two on purpose: the answers scroll with the page, the **input bar is
/// pinned to the bottom** via `safeAreaInset`. A question box that scrolls away is a question box
/// nobody uses — DingTalk pins it for the same reason.
@MainActor
final class AIChatModel: ObservableObject {
    @Published var messages: [AIChatSection.Message] = []
    @Published var draft = ""
    @Published var busy = false
    @Published var errorText: String?

    /// Set by the host once the summary/transcript are loaded. Empty = no Q&A block at all.
    var context = ""

    var isAvailable: Bool { !context.isEmpty }

    var canSend: Bool {
        isAvailable && !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send(config: AppConfig) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        errorText = nil
        messages.append(AIChatSection.Message(isUser: true, text: question))
        busy = true

        let history = messages
            .map { ($0.isUser ? "User: " : "Assistant: ") + $0.text }
            .joined(separator: "\n")
        let material = context

        Task { @MainActor in
            defer { busy = false }
            do {
                let outcome = try await LLMCompletionService.completeResilient(
                    systemPrompt: L10n.ClipDetail.aiAskSystem,
                    userContent: """
                    RECORDING MATERIAL
                    \(material)

                    CONVERSATION
                    \(history)
                    """,
                    config: config,
                    // The user is waiting for an answer, not for a chunk-merge pass.
                    allowChunking: false
                )
                messages.append(AIChatSection.Message(isUser: false, text: outcome.completion.text))
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

struct AIChatSection: View {

    @ObservedObject var model: AIChatModel

    struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
    }

    var body: some View {
        Section {
            ForEach(model.messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.isUser ? L10n.ClipDetail.aiAskYou : L10n.ClipDetail.aiAskAssistant)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(message.text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }

            if model.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.ClipDetail.aiAskThinking)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text(L10n.ClipDetail.aiAskTitle)
                Spacer()
                if !model.messages.isEmpty {
                    Button(L10n.ClipDetail.aiAskClear) {
                        model.messages.removeAll()
                        model.errorText = nil
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                }
            }
        } footer: {
            if model.messages.isEmpty {
                Text(L10n.ClipDetail.aiAskFooter)
            }
        }
    }
}

/// The pinned bar. Lives outside the Form so it never scrolls away.
struct AIChatInputBar: View {

    @ObservedObject var model: AIChatModel
    @EnvironmentObject private var configService: ConfigService

    var body: some View {
        HStack(spacing: 10) {
            TextField(L10n.ClipDetail.aiAskPlaceholder, text: $model.draft, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit { model.send(config: configService.config) }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )

            Button {
                model.send(config: configService.config)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
