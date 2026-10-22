import SwiftUI
import UIKit

// MARK: - The transcript itself (shared by the live page and the sheet)

/// Auto-scrolling list of timestamped live lines.
///
/// ## Why scene-by-scene instead of one joined string (2026-10-22)
/// The old implementation showed `Text(liveTranscript).lineLimit(6)` — and
/// `lineLimit` keeps the **first** six lines, so once six sentences had been
/// recognised the screen never changed again while recognition kept working.
/// That reads exactly like "it cannot keep up with me".
///
/// This list renders `segments` (each with the card's own clock), keeps the
/// newest line in view, and shows the in-flight hypothesis separately.
struct PlaudLiveTranscriptList: View {
    let segments: [PlaudLiveSegment]
    let partial: String
    /// `nil` = fill the available height (the 实时 page); a number = that fixed
    /// height (anywhere the list has to share a screen with other content).
    var height: CGFloat? = nil

    private let bottomAnchor = "plaud-live-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(segments) { segment in
                        PlaudLiveLine(stamp: PlaudLiveLine.stamp(segment.at),
                                      text: segment.text,
                                      isPartial: false)
                    }
                    if !partial.isEmpty {
                        // The in-flight hypothesis is tinted — these words are
                        // not final and will be replaced by the engine.
                        PlaudLiveLine(stamp: PlaudLiveLine.stamp(segments.last?.at ?? 0),
                                      text: partial,
                                      isPartial: true)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .modifier(OptionalHeight(height: height))
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            .onChange(of: segments.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: partial) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
    }
}

private struct OptionalHeight: ViewModifier {
    let height: CGFloat?
    func body(content: Content) -> some View {
        if let height {
            content.frame(height: height)
        } else {
            content.frame(maxHeight: .infinity)
        }
    }
}

// MARK: - One line

struct PlaudLiveLine: View {
    let stamp: String
    let text: String
    let isPartial: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(stamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
            Text(text)
                .font(.callout)
                .foregroundStyle(isPartial ? Color.appAccent.opacity(0.7) : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `mm:ss`, or `h:mm:ss` past the hour — the same shape the recording clock
    /// uses, so a line's stamp is comparable with the timer above it.
    static func stamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Full-screen transcript

/// The whole take, scrollable, with a copy button.
struct PlaudTranscriptSheet: View {
    @ObservedObject var direct: PlaudDirectService
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if direct.liveTranscript.isEmpty {
                    Text(L10n.Plaud.liveIdle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PlaudLiveTranscriptList(segments: direct.liveSegments,
                                            partial: direct.livePartial)
                }
            }
            .navigationTitle(L10n.Plaud.liveTranscript)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = direct.liveTranscript
                        copied = true
                    } label: {
                        Label(copied ? L10n.Plaud.liveCopied : L10n.Plaud.liveCopy,
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(direct.liveTranscript.isEmpty)
                }
            }
        }
    }
}
