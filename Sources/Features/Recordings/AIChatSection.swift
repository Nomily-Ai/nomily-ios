import SwiftUI

/// Bottom-of-page AI Q&A, grounded in **this recording only** (DingTalk's recording page ends
/// with the same block). The transcript and summary travel as the whole context — no retrieval
/// tricks: a one-hour meeting fits in ~35 k characters, and a grounded answer beats a clever
/// one that quotes a different recording.
struct AIChatSection: View {

    @EnvironmentObject private var configService: ConfigService

    /// Everything the model may use. Built by the host (`summary` + transcript text).
    let context: String

    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var busy = false
    @State private var errorText: String?

    struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
    }

    private var canSend: Bool {
        !busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Section {
            ForEach(messages) { message in
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

            if busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.ClipDetail.aiAskThinking)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 8) {
                TextField(L10n.ClipDetail.aiAskPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        } header: {
            HStack {
                Text(L10n.ClipDetail.aiAskTitle)
                Spacer()
                if !messages.isEmpty {
                    Button(L10n.ClipDetail.aiAskClear) {
                        messages.removeAll()
                        errorText = nil
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                }
            }
        } footer: {
            Text(L10n.ClipDetail.aiAskFooter)
        }
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        errorText = nil
        messages.append(Message(isUser: true, text: question))
        busy = true

        // Snapshot before the request: `messages` grows while the call is in flight.
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
                    config: configService.config,
                    // Never chunk here: the user is waiting for an answer, not for a merge pass.
                    allowChunking: false
                )
                messages.append(Message(isUser: false, text: outcome.completion.text))
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
