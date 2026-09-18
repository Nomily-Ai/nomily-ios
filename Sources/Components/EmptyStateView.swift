import SwiftUI

/// Lightweight empty-state placeholder that works on iOS 16
/// (`ContentUnavailableView` is iOS 17+).
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String?

    init(_ title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        // Apply group gray even when empty. Otherwise, the navigation bar (transparent material, showing the color underneath) would be white when "no content" and gray when there is content, causing the top bar color to jump when switching states on the same page. The standard is: gray background + white cards across the entire app, regardless of state.
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
