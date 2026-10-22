import SwiftUI

/// The 实时 (Live) tab when a PLAUD card is the device in play.
///
/// ## Why PLAUD does not go through `LiveModel`
/// `LiveModel`'s whole ASR chain is **Opus packet** based (Azure / whisper
/// server / `OnDeviceLiveASR` all take `opusProfile.packetBytes` frames). The
/// PLAUD card hands us decoded **PCM** through the SDK's sync-file channel, and
/// there is no PCM→Opus encoder on this platform (`AudioConverter` with
/// `kAudioFormatOpus` is broken — see the A1 notes). So the card cannot feed
/// that chain without a codec, and wrapping it in a fake `LiveAudioSource`
/// would have meant a second, parallel save/transfer pipeline on top of the
/// one the card already has (the take lands on the card and is pulled into the
/// library by `PlaudDirectService`).
///
/// What this screen is, then: the live transcript of the card's current take,
/// on the tab the user expects it on ("实时转写是点击底部的实时转写会"), with the
/// card's own clock, the level meter, the record button and the marks.
///
/// ★ 2026-10-22, moved out of the device page on request: the transcript used to
///   live under the recording section in `PlaudCardFilesView`.
struct PlaudLiveScreen: View {
    @ObservedObject private var direct = PlaudDirectService.shared
    @State private var showFullTranscript = false
    /// Epoch anchor for `TimelineView` — `.now` re-phases on every body
    /// evaluation and makes the seconds stutter (the trap `RecorderControl`
    /// documents).
    private let tickAnchor = Date(timeIntervalSince1970: 0)

    private var isConnected: Bool { direct.phase.isConnected }
    private var hasText: Bool { !direct.liveSegments.isEmpty || !direct.livePartial.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            controls
            transcriptHeader
            transcriptBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $showFullTranscript) {
            PlaudTranscriptSheet(direct: direct)
        }
    }

    // MARK: - Card identity

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.body)
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(direct.displayName)
                    .font(.subheadline.weight(.medium))
                Text(isConnected ? L10n.Plaud.stateConnected : L10n.Plaud.stateDisconnected)
                    .font(.caption2)
                    .foregroundStyle(isConnected ? Color.appAccent : .secondary)
            }
            Spacer()
            if let battery = direct.battery, isConnected {
                Label("\(battery)%",
                      systemImage: direct.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Clock + button + marks

    private var controls: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: tickAnchor, by: 1)) { context in
                Text(PlaudCardFilesView.elapsedText(direct, at: context.date))
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(direct.isRecording ? Color.red : Color.primary)
            }
            if direct.isRecording || direct.liveStreaming {
                LevelMeter(level: direct.liveLevel)
                    .frame(height: 6)
                    .padding(.horizontal, 48)
            }
            HStack(spacing: 10) {
                Button {
                    // A paused take is still alive on the card — "record" would
                    // start a SECOND file behind the user's back.
                    if direct.isRecording || direct.isPaused {
                        direct.stopRecording()
                    } else {
                        direct.startRecordingWhenReady()
                    }
                } label: {
                    Label(direct.isRecording || direct.isPaused ? L10n.Plaud.stopRecord : L10n.Plaud.startRecord,
                          systemImage: direct.isRecording || direct.isPaused ? "stop.circle.fill" : "record.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(direct.isRecording || direct.isPaused ? .red : .accentColor)
                .disabled(direct.phase.isBusy)

                // ★ 2026-10-22 (user: "不能只有录音开始跟结束，还要有暂停"):
                // the card's SDK has pause/resume and the firmware reports
                // `bleRecordPause`, so the live page offers it too. Pause keeps
                // the take (and its transcript) alive — this is not "stop then
                // start a second file".
                if direct.isRecording || direct.isPaused {
                    Button {
                        if direct.isPaused {
                            direct.resumeRecording()
                        } else {
                            direct.pauseRecording()
                        }
                    } label: {
                        Label(direct.isPaused ? L10n.Plaud.resumeRecord : L10n.Plaud.pauseRecord,
                              systemImage: direct.isPaused ? "play.circle.fill" : "pause.circle.fill")
                            .font(.headline)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            if direct.isPaused {
                Text(L10n.Plaud.pausedHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !isConnected {
                Button {
                    direct.reconnect()
                } label: {
                    Label(L10n.Plaud.reconnect, systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
            if let notice = direct.recordNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            marksRow
        }
        .padding(.vertical, 10)
    }

    /// Marks pressed on the card. ★ 2026-10-22 on request: nothing is shown at
    /// all while there is no count — the old row said "the card reports marks
    /// when the take ends" for the whole recording, which is noise. What the
    /// user wanted instead is the **time** of each mark, shown right here next
    /// to the clock.
    @ViewBuilder
    private var marksRow: some View {
        if direct.recordMarkCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text(L10n.Plaud.marksCount(direct.recordMarkCount))
                    .font(.caption)
                    .foregroundStyle(.orange)
                ForEach(Array(direct.markTimestamps.prefix(6).enumerated()), id: \.offset) { _, time in
                    Text(PlaudLiveLine.stamp(time))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                }
                if direct.markTimestamps.count > 6 {
                    Text("+\(direct.markTimestamps.count - 6)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Transcript

    private var transcriptHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.footnote)
                .foregroundStyle(Color.appAccent)
            Text(L10n.Plaud.liveTranscript)
                .font(.caption.weight(.semibold))
            // Which engine is producing this text — "使用的 Azure 的" must have a
            // visible answer instead of a guess.
            if !direct.liveASRProvider.isEmpty {
                Text(L10n.Plaud.liveEngine(direct.liveASRProvider))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            if direct.isRecording {
                HStack(spacing: 3) {
                    Circle().fill(Color.red).frame(width: 5, height: 5)
                    Text(L10n.Plaud.liveBadge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if hasText {
                Button {
                    showFullTranscript = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Plaud.liveExpand)
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Saving into the library

    /// "方便结束后保存到资料库": the transcript is written next to the clip the
    /// card produces (that is the only place it can live — the clip page reads
    /// `<name>.txt` / `<name>.asr.json`), so this footer tells the truth about
    /// where that stands instead of offering a button that cannot work yet.
    @ViewBuilder
    private var saveFooter: some View {
        HStack(spacing: 6) {
            if let saved = direct.liveTranscriptSavedTo {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L10n.Plaud.liveSaved)
                    .foregroundStyle(.secondary)
                Text(saved)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.tertiary)
            } else if direct.isRecording {
                Image(systemName: "bookmark")
                    .foregroundStyle(.secondary)
                Text(L10n.Plaud.liveSaveNeedsClip)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: direct.isSyncing ? "arrow.down.circle" : "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
                Text(L10n.Plaud.liveSavePending)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if !direct.isSyncing {
                    Button(L10n.Plaud.liveSaveAction) {
                        direct.saveLiveTranscriptToLibrary()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
            if direct.liveTranscriptSavedTo == nil, direct.isRecording == false {
                Spacer(minLength: 0)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if hasText {
            VStack(spacing: 0) {
                PlaudLiveTranscriptList(segments: direct.liveSegments,
                                        partial: direct.livePartial,
                                        markers: direct.liveMarkers)
                saveFooter
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        } else {
            VStack(spacing: 8) {
                Spacer()
                if let notice = direct.liveASRNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !isConnected {
                    Text(L10n.Plaud.liveNeedConnect)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if direct.isRecording {
                    ProgressView().controlSize(.small)
                    Text(L10n.Plaud.liveWaiting)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.Plaud.liveIdle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }
}
