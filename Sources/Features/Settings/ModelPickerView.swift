import SwiftUI

/// Model list as a **pushed page** with its own search, instead of an inline
/// `Picker`.
///
/// ★ 2026-10-22 (user: "点击 asr 模型或者大语言模型里面选择模型会在最开始的时候往下回弹，
/// 需要再次点击才会正常"): the inline `Picker` inside a `Form` pushed a system
/// selection list whose content was rebuilt from the parent's `@State` while the
/// push animation was still running (`models` arrives from an async fetch, and the
/// "always offer the saved value" rule re-inserts the current model at index 0 on
/// every recomputation). The list re-laid itself out mid-animation, the row that
/// was under the finger moved, and the first tap landed on nothing — the second tap
/// worked because by then the list had settled.
///
/// Two structural fixes, both of which are properties of this view rather than a
/// timing patch:
///
/// 1. **The options are frozen on first appearance** (`frozen`). Whatever the
///    parent does afterwards cannot reorder the list underneath a moving finger.
/// 2. **The rows are plain buttons**, so a tap is a tap — there is no picker
///    presentation to animate in, and nothing to dismiss on the first touch.
///
/// The search field is not decoration: OpenRouter alone lists several hundred
/// models, and scrolling that in a system picker was never usable.
struct ModelPickerView: View {

    let title: String
    /// Candidates, in the order the caller wants them shown.
    let options: [String]
    /// Currently stored value. Rendered with a checkmark; may be absent from
    /// `options` (a hand-typed access point, or a model renamed upstream).
    let current: String
    /// Whether to offer "Select a model" (i.e. clearing the choice is legal).
    let allowsEmpty: Bool
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Snapshot taken on first appearance — see the note above.
    @State private var frozen: [String] = []

    private var rows: [String] {
        guard !query.isEmpty else { return frozen }
        let q = query.lowercased()
        return frozen.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        List {
            if allowsEmpty, query.isEmpty {
                button(title: L10n.LLM.selectModel, value: "", selected: current.isEmpty)
            }
            ForEach(rows, id: \.self) { model in
                button(title: model, value: model, selected: current == model)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: L10n.LLM.modelSearch)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Also include the current value when the caller's list lost it, so
            // the checkmark is never on a row that does not exist.
            if frozen.isEmpty {
                var list = options
                if !current.isEmpty, !list.contains(current) { list.insert(current, at: 0) }
                frozen = list
            }
        }
    }

    private func button(title: String, value: String, selected: Bool) -> some View {
        Button {
            onPick(value)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(value.isEmpty ? .body : .body.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
