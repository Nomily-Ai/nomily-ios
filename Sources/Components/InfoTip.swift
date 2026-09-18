import SwiftUI

/// A tappable `?` icon that shows a short informational text in a compact
/// bottom sheet. Use it next to a row label or section header instead of a
/// Section footer when the hint applies to a single option.
struct InfoTip: View {
    let text: String
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "questionmark.circle")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $show) {
            Text(text)
                .font(.callout)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .presentationDetents([.height(160)])
                .presentationDragIndicator(.visible)
        }
    }
}
