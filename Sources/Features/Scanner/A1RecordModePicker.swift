import SwiftUI

// MARK: - A1RecordMode
//
// ★ (2026-10-19) The card's five **recording modes**, copied one-for-one from DingTalk's
// device-settings sheet (screenshot replica; display names live in the .strings files):
//
//   1. General       — badge Call recording / voice boost — standard HD pickup, AI noise reduction
//   2. Meeting       — badge 8 m pickup            — for meeting rooms, mid/long-range pickup
//   3. Face-to-face  — badge Side mute             — card faces the user, other directions muted
//   4. AI Visual Notes — badge Direction (beta)    — makes sound visible, direction aware
//   5. Lossless      — badge No NR · 48 kHz        — high fidelity, records everything at 48 kHz
//
// ## What this actually is, protocol-wise
//
// `0x0100` params (as reversed so far) only carries `incognitomode` / `aikey_option` /
// `cap_*` — **no** record-mode key. DingTalk's five modes are therefore most likely a
// named preset **on the app side** (possibly composed of ASR/handling settings plus a
// firmware param we haven't seen). So this round:
//
//   * the choice is persisted app-side (`AppConfig.a1RecordMode`),
//   * `DingTalkA1Link.dumpAllParams()` dumps a full `0x0100 get` reply into the diag log
//     on the next real-device session, and the real key (if any) gets wired then —
//     never guess a key and write it blind (nil ≠ 0; unknown = unsupported = don't send).
enum A1RecordMode: String, CaseIterable, Identifiable {

    case general
    case meeting
    case faceToFace
    case visual
    case lossless

    var id: String { rawValue }

    /// Tolerant read: an unknown persisted tag (older/newer build) falls back to the
    /// card's own default instead of crashing the picker.
    static func from(_ raw: String?) -> A1RecordMode {
        A1RecordMode(rawValue: raw ?? "") ?? .general
    }

    /// The value the card stores in its `mode` parameter (`0x0100 get` reply).
    ///
    /// Ordering follows DingTalk's own list; `0` is the card's factory default, which matches
    /// General being first. Unverified beyond that — `setRecordMode` reads the table back and
    /// only reports success when the stored value equals this one.
    var cardValue: Int {
        A1RecordMode.allCases.firstIndex(of: self) ?? 0
    }

    var name: String {
        switch self {
        case .general:    NSLocalizedString("a1.recordmode.general.name", value: "General", comment: "A1 recording mode")
        case .meeting:    NSLocalizedString("a1.recordmode.meeting.name", value: "Meeting", comment: "A1 recording mode")
        case .faceToFace: NSLocalizedString("a1.recordmode.facetoface.name", value: "Face-to-face", comment: "A1 recording mode")
        case .visual:     NSLocalizedString("a1.recordmode.visual.name", value: "AI Visual Notes", comment: "A1 recording mode")
        case .lossless:   NSLocalizedString("a1.recordmode.lossless.name", value: "Lossless", comment: "A1 recording mode")
        }
    }

    /// The small chip at the row's trailing edge (DingTalk shows one per mode). `nil` = none.
    var badge: String? {
        switch self {
        case .general:    NSLocalizedString("a1.recordmode.general.badge", value: "Calls / voice boost", comment: "A1 mode badge")
        case .meeting:    NSLocalizedString("a1.recordmode.meeting.badge", value: "8 m pickup", comment: "A1 mode badge")
        case .faceToFace: NSLocalizedString("a1.recordmode.facetoface.badge", value: "Side mute", comment: "A1 mode badge")
        case .visual:     NSLocalizedString("a1.recordmode.visual.badge", value: "Beta · direction", comment: "A1 mode badge")
        case .lossless:   NSLocalizedString("a1.recordmode.lossless.badge", value: "No NR · 48 kHz", comment: "A1 mode badge")
        }
    }

    /// The one-line description under the name (DingTalk's row subtitle).
    var subtitle: String {
        switch self {
        case .general:
            NSLocalizedString("a1.recordmode.general.subtitle",
                              value: "Standard HD pickup with AI noise reduction",
                              comment: "A1 mode description")
        case .meeting:
            NSLocalizedString("a1.recordmode.meeting.subtitle",
                              value: "For meeting rooms — mid/long-range pickup",
                              comment: "A1 mode description")
        case .faceToFace:
            NSLocalizedString("a1.recordmode.facetoface.subtitle",
                              value: "Card faces you; sound from other directions is muted",
                              comment: "A1 mode description")
        case .visual:
            NSLocalizedString("a1.recordmode.visual.subtitle",
                              value: "See where sound comes from — direction aware",
                              comment: "A1 mode description")
        case .lossless:
            NSLocalizedString("a1.recordmode.lossless.subtitle",
                              value: "High fidelity — records everything at 48 kHz, no reduction",
                              comment: "A1 mode description")
        }
    }

    /// SF Symbol per mode (no card asset exists for these).
    var icon: String {
        switch self {
        case .general:    return "waveform"
        case .meeting:    return "person.3"
        case .faceToFace: return "person.wave.2"
        case .visual:     return "scope"
        case .lossless:   return "hifispeaker.2"
        }
    }
}

// MARK: - L10n surface

extension L10n.A1 {
    enum RecordMode {
        static var sectionTitle: String {
            NSLocalizedString("a1.recordmode.title", value: "Recording Mode", comment: "Card settings row")
        }
        static var pickerTitle: String {
            NSLocalizedString("a1.recordmode.picker_title", value: "Recording Mode", comment: "Picker page title")
        }
        static var footer: String {
            NSLocalizedString(
                "a1.recordmode.footer",
                value: "Picked while the card is connected, the mode is written to the card right away. Offline, the choice is only saved in the app.",
                comment: "Picker page footer — explains online vs offline behaviour")
        }
        static var savedOffline: String {
            NSLocalizedString("a1.recordmode.saved_offline",
                              value: "Saved in the app — connect the card to apply it.",
                              comment: "Picker status when the card is not connected")
        }
        static var applying: String {
            NSLocalizedString("a1.recordmode.applying", value: "Writing to the card…",
                              comment: "Picker status while the set command is in flight")
        }
        static var applied: String {
            NSLocalizedString("a1.recordmode.applied", value: "Applied — the card confirmed the new value.",
                              comment: "Picker status on a verified write")
        }
        static var applyFailed: String {
            NSLocalizedString("a1.recordmode.apply_failed",
                              value: "The card didn't confirm the change. Saved in the app only.",
                              comment: "Picker status when the write or the read-back failed")
        }
    }
}

// MARK: - Card-settings row

/// The single row in the card info page (DingTalk A1 branch): current mode + chevron,
/// pushing the picker page.
///
/// ★ (2026-10-19) **Push, not sheet.** The card info page is itself presented as a sheet
/// (`RecorderSheet.cardInfoSheet`), and a `.sheet` presented from inside a sheet gets its
/// first tap swallowed by the in-flight presentation — on a real device that read as
/// "tapping Recording Mode does nothing". Both shells already own a `NavigationStack` (the sheet
/// shell and RecorderSheet's own), so a `NavigationLink` works in both and matches
/// DingTalk, which also pushes a full page rather than stacking a dialog.
struct A1RecordModeSection: View {

    /// The live link, when the card is connected — the only thing that can actually write
    /// `mode` to the card. `nil` = offline: the choice is still saved, it just isn't applied.
    let link: DingTalkA1Link?

    @EnvironmentObject private var configService: ConfigService

    private var current: A1RecordMode {
        A1RecordMode.from(configService.config.a1RecordMode)
    }

    var body: some View {
        Section {
            NavigationLink {
                A1RecordModePicker(link: link)
            } label: {
                LabeledContent {
                    Text(current.name)
                        .foregroundStyle(.secondary)
                } label: {
                    Label(L10n.A1.RecordMode.sectionTitle, systemImage: current.icon)
                }
            }
        } header: {
            Text(L10n.A1.RecordMode.sectionTitle)
        }
    }
}

// MARK: - Picker

/// One row per mode: icon, name, trailing badge chip, one-line description, checkmark on
/// the selected row — same shape as DingTalk's five-row sheet.
///
/// Pushed by `A1RecordModeSection`, so it deliberately has **no** `NavigationStack` and no
/// Done button of its own — the back button comes from the enclosing stack.
struct A1RecordModePicker: View {

    let link: DingTalkA1Link?

    @EnvironmentObject private var configService: ConfigService
    /// Result of the last "write to card" attempt — shown under the list so the user can tell
    /// "saved in the app" from "actually applied on the card".
    @State private var applyNote: String?

    private var current: A1RecordMode {
        A1RecordMode.from(configService.config.a1RecordMode)
    }

    var body: some View {
        List {
            Section {
                ForEach(A1RecordMode.allCases) { mode in
                    Button {
                        select(mode)
                    } label: {
                        row(mode)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.A1.RecordMode.footer)
                    if let applyNote {
                        Text(applyNote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.A1.RecordMode.pickerTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ mode: A1RecordMode) {
        guard mode != current else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        configService.config.a1RecordMode = mode.rawValue
        configService.saveNow()
        guard let link else {
            applyNote = L10n.A1.RecordMode.savedOffline
            return
        }
        applyNote = L10n.A1.RecordMode.applying
        Task {
            let ok = await link.setRecordMode(mode)
            applyNote = ok ? L10n.A1.RecordMode.applied : L10n.A1.RecordMode.applyFailed
        }
    }

    @ViewBuilder
    private func row(_ mode: A1RecordMode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: mode.icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(mode.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if let badge = mode.badge {
                        Text(badge)
                            .font(.caption2)
                            .foregroundStyle(mode == .visual ? Color.orange : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color(uiColor: .secondarySystemBackground))
                            )
                    }
                }
                Text(mode.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if mode == current {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }
}
