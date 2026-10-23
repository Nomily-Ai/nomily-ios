import SwiftUI

/// Recording-scoped AI Q&A: the model, the floating ask bar on the detail page,
/// and the conversation sheet it opens.
///
/// History:
/// * (2026-10-19) DingTalk shape — answers in the page, input pinned at the bottom.
/// * 2026-10-23 ("ai 问答是直接一个聊条框不要直接全部占满底部"): one compact bar.
/// * 2026-10-23 ("这个布局排版都是有问题的需要优化"): the expanding-bubbles bar was
///   itself the layout problem — with the keyboard up it covered the player and
///   left a void between the last bubble and the field. Plaud's own solution is
///   the one adopted here: the detail page keeps a **short bar**, and tapping it
///   opens a real conversation sheet with its own input. Nothing overlays the
///   transcript or the summary any more.
@MainActor
final class AIChatModel: ObservableObject {

    struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
    }

    @Published var messages: [Message] = []
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
        messages.append(Message(isUser: true, text: question))
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
                messages.append(Message(isUser: false, text: outcome.completion.text))
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func clear() {
        messages.removeAll()
        errorText = nil
    }
}

// MARK: - The floating bar on the detail page

/// The bottom strip. It is a **button that looks like an input**, not an input:
/// tapping it opens the conversation sheet.
///
/// Plaud's box is the reference — page-coloured fill, a thin accent hairline, a
/// soft shadow, grey placeholder text. The old version put the whole chat in
/// here, which is what pushed the page around and left a gap above the keyboard.
struct AIChatAskBar: View {

    var placeholder: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(placeholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                // Plaud's ask box wears a green→purple→blue hairline; it is what
                // makes the box read as "AI" rather than as a search field.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color(red: 0.30, green: 0.78, blue: 0.55),
                                Color(red: 0.55, green: 0.45, blue: 0.95),
                                Color(red: 0.35, green: 0.65, blue: 0.95),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.2
                    )
            )
            .shadow(color: .black.opacity(0.07), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(.bar)
    }
}

// MARK: - The conversation sheet

/// Full conversation, opened from `AIChatAskBar`. Content sits above the input,
/// the input rides the keyboard — no in-page overlay, no capped bubble area.
struct AIChatSheet: View {

    @ObservedObject var model: AIChatModel
    var placeholder: String

    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.messages.isEmpty && !model.busy {
                            emptyState
                        }
                        ForEach(model.messages) { message in
                            bubble(message).id(message.id)
                        }
                        if model.busy {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(L10n.ClipDetail.aiAskThinking)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        if let errorText = model.errorText {
                            Text(errorText)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.busy) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { inputRow }
            .navigationTitle(L10n.ClipDetail.aiAskTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !model.messages.isEmpty {
                        Button(L10n.ClipDetail.aiAskClear) { model.clear() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.ClipDetail.aiAskDone) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear { inputFocused = true }
        }
        .presentationDragIndicator(.visible)
    }

    /// Empty state doubles as the grounding note the inline section used to show.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.ClipDetail.aiAskEmptyTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Text(L10n.ClipDetail.aiAskFooter)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    @ViewBuilder
    private func bubble(_ message: AIChatModel.Message) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            Text(message.text)
                .font(.callout)
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(message.isUser
                              ? Color.accentColor.opacity(0.16)
                              : Color(uiColor: .secondarySystemBackground))
                )
            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $model.draft, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .submitLabel(.send)
                .onSubmit { model.send(config: configService.config) }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )

            Button {
                model.send(config: configService.config)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(model.canSend ? Color.accentColor : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
            .padding(.bottom, 3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
    }
}
