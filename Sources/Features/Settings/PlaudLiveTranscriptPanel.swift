import SwiftUI
import UIKit

/// Live transcript panel for the PLAUD card.
///
/// ## Why this is a view of its own (2026-10-22, "it cannot keep up with me")
/// The previous UI was a two-line footnote in the recording section:
///
/// ```swift
/// Text(direct.liveTranscript).lineLimit(6)
/// ```
///
/// `lineLimit` keeps the **first** six lines and drops everything after them, so
/// once six sentences had been recognised the panel stopped changing — the
/// engine was still working, the screen just never showed it. That reads exactly
/// like "the transcript lags behind the speaker", which is how it was reported.
///
/// This panel:
/// * renders **segments** (not one joined string), each with the card's own
///   timestamp (`mm:ss`), so the line you hear is the line at the bottom;
/// * **auto-scrolls to the newest line** on every commit and on every partial
///   hypothesis update;
/// * keeps the text after the recording stops (the take you just finished is
///   what you want to read), and says so;
/// * says **why** it is empty instead of showing an empty box — no permission
///   and no offline model are different problems with different fixes;
/// * expands into a full-screen sheet with a copy button.
struct PlaudLiveTranscriptPanel: View {
    @ObservedObject var direct: PlaudDirectService
    @State private var expanded = false

    private let bottomAnchor = "plaud-live-bottom"

    private var hasText: Bool {
        !direct.liveSegments.isEmpty || !direct.livePartial.isEmpty
    }

    private var isLive: Bool { direct.isRecording || direct.liveStreaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $expanded) {
            PlaudTranscriptSheet(direct: direct)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.footnote)
                .foregroundStyle(Color.appAccent)
            Text(L10n.Plaud.liveTranscript)
                .font(.caption.weight(.semibold))
            if isLive {
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 5, height: 5)
                    Text(L10n.Plaud.liveBadge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if hasText {
                Button {
                    expanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Plaud.liveExpand)
            }
        }
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if hasText {
            transcript
        } else if let notice = direct.liveASRNotice {
            Text(notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if isLive {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L10n.Plaud.liveWaiting)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(L10n.Plaud.liveIdle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(direct.liveSegments) { segment in
                        PlaudLiveLine(stamp: PlaudLiveLine.stamp(segment.at),
                                      text: segment.text,
                                      isPartial: false)
                    }
                    if !direct.livePartial.isEmpty {
                        // The in-flight hypothesis: dimmed and tinted so it is
                        // obvious which words are not final yet.
                        PlaudLiveLine(stamp: PlaudLiveLine.stamp(direct.liveSegments.last?.at ?? 0),
                                      text: direct.livePartial,
                                      isPartial: true)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 168)
            .onAppear { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            .onChange(of: direct.liveSegments.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: direct.livePartial) { _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
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

/// The whole take, scrollable, with a copy button — the panel is deliberately
/// short (it sits inside a list row), this is where you actually re-read it.
struct PlaudTranscriptSheet: View {
    @ObservedObject var direct: PlaudDirectService
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if direct.liveTranscript.isEmpty {
                        Text(L10n.Plaud.liveIdle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(direct.liveSegments) { segment in
                            PlaudLiveLine(stamp: PlaudLiveLine.stamp(segment.at),
                                          text: segment.text,
                                          isPartial: false)
                        }
                        if !direct.livePartial.isEmpty {
                            PlaudLiveLine(stamp: PlaudLiveLine.stamp(direct.liveSegments.last?.at ?? 0),
                                          text: direct.livePartial,
                                          isPartial: true)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
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
