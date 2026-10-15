import SwiftUI

// MARK: - Standalone pages reached from the corner badges
//
// ★ Second revision, 2026-10-15: these four pages used to be "a small menu expanded in place on the home screen", which the user
// explicitly rejected — "tapping the 4 menus should open a separate page". After switching to pages:
//
//   · The home screen is cleared out, leaving only "time + ring + 4 corner badges" — the same structure as the Health app's
//     Activity rings page (the user's words were "just follow the Apple Health layout");
//   · The **gradient**, which used to occupy a corner badge of its own, merged into the color page — a gradient was always about "how color is used",
//     and shouldn't sit beside color holding its own slot;
//   · The **language** text link that used to hang at the bottom of the home screen moved in, taking the vacated corner badge;
//   · **Version + restore defaults** merged into a "Settings" page — both are low-frequency actions touched only occasionally.
//
// ★ Fifth revision, 2026-10-15: the breathing light also merged into the top-left page (color/gradient and it both answer "what does the ring look like"),
// and the top right was given to **transfer history** (`WatchTransferHistoryView`) —
// that's status, not appearance, and never belonged squeezed in with the color settings.
//
// The language page reuses `WatchLanguageView` (which also handles rebuilding `LocalizedWatchRoot`),
// rather than duplicating it here.

// MARK: - Appearance (color + gradient + breathing light)

/// Appearance page: palette + gradient + breathing light speed.
///
/// ★ Fifth revision, 2026-10-15: the breathing light **merged in** (user: "move the breathing light speed from the top right into
/// the top-left menu"). All three answer "what does the ring look like"; splitting them across two corner badges only makes users
/// bounce between two pages to adjust — and with only four levels, a whole corner badge for the breathing light is a luxury,
/// the top-right slot is better spent on **transfer history**, which genuinely needs its own page.
///
/// A small ring preview at the top. **Deliberately not `WatchRingControl`** — that's a button,
/// with comet, ripples, and a timer, and tapping it starts a recording; here we only want to "glance at whether the colors look right".
struct WatchColorStyleView: View {
    @ObservedObject private var store = WatchRingStyleStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                WatchRingPreview(style: store.style)
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                    spacing: 8
                ) {
                    ForEach(WatchRingPalette.allCases) { palette in
                        Button {
                            store.style.palette = palette
                        } label: {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: palette.colors,
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().strokeBorder(
                                        Color.white,
                                        lineWidth: store.style.palette == palette ? 2 : 0
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(palette.rawValue)
                    }
                }

                // Gradient. Two capsules, same set as the breathing-light row.
                pillRow([false, true].map { on in
                    (label: on ? L10n.Watch.styleGradientOn : L10n.Watch.styleGradientOff,
                     selected: store.style.gradient == on,
                     action: { store.style.gradient = on })
                })

                // ★ Breathing light speed. **That small heading is a must**: `off/slow/medium/fast` on its own
                // can't say what it controls (the gradient row's "solid/gradient" speaks for itself,
                // this one can't). The heading costs two characters in Chinese at most — far cheaper than making users guess.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Watch.styleBreathing)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    pillRow(WatchBreathing.allCases.map { option in
                        (label: option.label,
                         selected: store.style.breathing == option,
                         action: { store.style.breathing = option })
                    })
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(L10n.Watch.styleAppearance)
    }

    /// A row of equal-width capsule selectors.
    ///
    /// Extracted because the gradient and breathing light rows **must look exactly identical** — on the watch face, two rows of
    /// selection controls differing in the slightest (corner radius, spacing, selected background) read as two
    /// different controls, and users will assume their behavior differs too.
    private func pillRow(
        _ options: [(label: String, selected: Bool, action: () -> Void)]
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(action: option.action) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(
                                option.selected
                                    ? store.style.palette.solid.opacity(0.9)
                                    : Color.white.opacity(0.12)
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Transfer history

/// Transfer history page (the old top-right "breathing light" slot).
///
/// ★ New in the fifth revision, 2026-10-15 (user: "the top right is the watch's transfer history").
///
/// A single screen can hold only "what this is, whether it made it, and when", so just three rows:
/// title / status + size / time. The failure reason folds into the status row — that's the one thing
/// users **genuinely want to know** when they open this page ("why didn't it transfer").
struct WatchTransferHistoryView: View {
    @ObservedObject private var log = WatchTransferLog.shared

    var body: some View {
        Group {
            if log.records.isEmpty {
                // Empty state. The moment this page gets opened most often is exactly "just installed / just rebooted",
                // and showing nothing would make people think the feature is broken.
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(L10n.Watch.transferEmpty)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                List {
                    ForEach(log.records) { record in
                        row(record)
                    }
                }
            }
        }
        .navigationTitle(L10n.Watch.transferHistory)
        .toolbar {
            if !log.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        log.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(L10n.Watch.transferClear)
                }
            }
        }
    }

    private func row(_ record: WatchTransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)

            HStack(spacing: 4) {
                Image(systemName: symbol(record.state))
                    .font(.system(size: 10, weight: .bold))
                Text(label(record.state))
                    .font(.system(size: 11, weight: .semibold))
                if record.bytes > 0 {
                    Text(WatchFormat.bytes(record.bytes))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(tint(record.state))

            if let detail = record.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Text(Self.stamp.string(from: record.updatedAt))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func label(_ state: WatchTransferRecord.State) -> String {
        switch state {
        case .queued:    return L10n.Watch.transferQueued
        case .delivered: return L10n.Watch.transferDelivered
        case .stored:    return L10n.Watch.transferStored
        case .failed:    return L10n.Watch.transferFailed
        }
    }

    private func symbol(_ state: WatchTransferRecord.State) -> String {
        switch state {
        case .queued:    return "clock"
        case .delivered: return "paperplane"
        case .stored:    return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ state: WatchTransferRecord.State) -> Color {
        switch state {
        case .queued:    return .secondary
        case .delivered: return .orange
        case .stored:    return .green
        case .failed:    return .red
        }
    }

    /// Times are **absolute**. Relative time ("5 minutes ago") is meaningless here —
    /// what users come here asking is "when did that one from this morning transfer".
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Settings

/// Settings page: version + shake toggle + restore default appearance.
///
/// The build number still doubles as "did the build I just made actually reach the watch" — watch updates are pushed opportunistically by the iPhone,
/// lagging the iPhone's install by several minutes (see the note at the top of `WatchAboutView`).
struct WatchSettingsView: View {
    @ObservedObject private var store = WatchRingStyleStore.shared
    @ObservedObject private var prefs = WatchRecordingPrefs.shared

    var body: some View {
        List {
            HStack {
                Text(L10n.Settings.version)
                Spacer(minLength: 4)
                Text(WatchAboutView.appVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // ★ Shake. Flipping the toggle notifies the home screen via `WatchRecordingPrefs`
            // to start/stop capture (the home screen holds it as an `@ObservedObject`) —
            // no CoreMotion gets touched here.
            Toggle(isOn: $prefs.shakeToRecord) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Watch.shakeToRecord)
                    Text(L10n.Watch.shakeToRecordHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // ★ Sixth revision: two-finger tap (index finger and thumb pinched together).
            //
            // ⚠️ **Shown only on watchOS 11+**. On 10.1–10.x the system itself assigns the two-finger tap
            //   to the page's primary button, and no API can intercept it — on such watches a "can't-turn-off
            //   the gesture" toggle is worse than none at all (the user flips it, nothing happens, and they'll conclude the whole
            //   gesture feature is broken).
            if #available(watchOS 11.0, *) {
                Toggle(isOn: $prefs.pinchToRecord) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.Watch.pinchToRecord)
                        Text(L10n.Watch.pinchToRecordHint)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                store.reset()
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text(L10n.Watch.styleReset)
                }
                .foregroundStyle(store.style.palette.solid)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Resets only the appearance (color / gradient / breathing light), leaving language and recordings untouched —
            // so no confirmation is needed; picking the wrong color again is easy enough.
            // (The shake toggle is therefore deliberately not in this store either; see `WatchRecordingPrefs`.)
        }
        .navigationTitle(L10n.Watch.menuSettings)
    }
}

// MARK: - Preview

/// The small ring preview at the top of the color page: the outer ring takes the current gradient colors, the center the current fill.
///
/// Shares `WatchRingStyle.ringAngularGradient` with the main ring — writing the color logic twice
/// would eventually drift (especially the three-color palette and "gradient off" branches).
private struct WatchRingPreview: View {
    let style: WatchRingStyle

    var body: some View {
        ZStack {
            Circle()
                .inset(by: 5)
                .stroke(style.ringAngularGradient,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))

            Circle()
                .inset(by: 17)
                .fill(Color(white: 0.10))

            Circle()
                .inset(by: 17)
                .fill(style.centerFill)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
