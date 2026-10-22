import Foundation
import SwiftUI

/// User-given names for the diarized speakers of a recording.
///
/// ★ 2026-10-22 ("还要支持修改说话人的名称"): the ASR vendor labels speakers with bare
/// ids — Azure returns `"1"`, `"2"`, … — and the transcript then reads
/// "说话人 1" forever, even though the user was in the room and knows it was 张伟.
/// This store keeps the mapping `speaker id → name` **per clip** and every surface
/// that prints a speaker asks it first: transcript rows, the filter chips, the
/// share/export text, and the AI Q&A context (so a summary written after renaming
/// says "张伟" too).
///
/// Design notes:
///
/// * **Stored beside the transcript, not inside it.** `<base>.speakers.json` is a
///   sidecar. A re-transcription overwrites `.asr.json`; the names describe the
///   people in the room and must survive that.
/// * **Per clip, not global.** The same "speaker 1" in two recordings is usually
///   two different people (a meeting and a phone call), so a global map would
///   silently mislabel the second one. Renaming is a per-recording act, exactly
///   like re-titling one note.
/// * **Nothing is destructive.** Clearing a field deletes the override and the
///   page falls back to "说话人 1". The transcript itself is never rewritten, so
///   "reset" always gets the original labels back.
@MainActor
final class SpeakerNameStore: ObservableObject {

    static let shared = SpeakerNameStore()

    /// clip name (audio file name) → raw speaker id → user name.
    @Published private(set) var maps: [String: [String: String]] = [:]

    private init() {}

    /// Read the sidecar **without** touching the shared store.
    ///
    /// The summary/translation queue runs off the main actor and only needs the
    /// map once, to render speaker names into the prompt — making it hop to a
    /// `@MainActor` singleton for that would be a needless dependency (and an
    /// await) on a background job.
    nonisolated static func namesOnDisk(for clip: String) -> [String: String] {
        let url = StorageLocations.speakerNamesURL(for: clip)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    // MARK: Reading

    /// Load once per clip. Cheap (a small JSON) and idempotent.
    func load(clip: String) {
        guard maps[clip] == nil else { return }
        let url = StorageLocations.speakerNamesURL(for: clip)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            maps[clip] = [:]
            return
        }
        maps[clip] = decoded
    }

    func names(for clip: String) -> [String: String] {
        maps[clip] ?? [:]
    }

    /// The name to print for a raw speaker id — the user's, or the vendor's label.
    func display(_ speaker: String, clip: String) -> String {
        if let name = maps[clip]?[speaker], !name.isEmpty { return name }
        return L10n.ClipDetail.speaker(speaker)
    }

    // MARK: Writing

    /// Rename one speaker. An empty (or whitespace-only) name clears the override,
    /// which is how "reset" is expressed — there is no separate state to reset to.
    func rename(_ name: String, speaker: String, clip: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var map = maps[clip] ?? [:]
        if trimmed.isEmpty {
            map.removeValue(forKey: speaker)
        } else {
            map[speaker] = trimmed
        }
        maps[clip] = map
        persist(clip: clip)
    }

    func resetAll(clip: String) {
        maps[clip] = [:]
        // Remove the file entirely rather than writing `{}`: a clip that was never
        // renamed should look untouched on disk.
        try? FileManager.default.removeItem(at: StorageLocations.speakerNamesURL(for: clip))
    }

    private func persist(clip: String) {
        let url = StorageLocations.speakerNamesURL(for: clip)
        let map = maps[clip] ?? [:]
        if map.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Editor

/// Rename the speakers of one recording.
///
/// Every row is a text field that applies as you type (the same contract as
/// renaming a contact): there is no Save button to forget, and "Done" only closes
/// the sheet. The line count next to each speaker is there to answer "which one is
/// speaker 2?" — with four participants and no audio playing, that is the question
/// the sheet exists to solve.
struct SpeakerRenameSheet: View {
    let clip: String
    /// Raw ids in the order they first appear, plus how many lines each one has.
    let speakers: [(id: String, lines: Int)]

    @ObservedObject private var store = SpeakerNameStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(speakers, id: \.id) { speaker in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField(L10n.ClipDetail.speaker(speaker.id),
                                          text: binding(for: speaker.id))
                                    .textInputAutocapitalization(.words)
                                    .autocorrectionDisabled()
                                Text(L10n.ClipDetail.speakerLineCount(speaker.lines))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !(drafts[speaker.id] ?? "").isEmpty {
                                Button {
                                    drafts[speaker.id] = ""
                                    store.rename("", speaker: speaker.id, clip: clip)
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.ClipDetail.resetSpeakerName)
                            }
                        }
                    }
                } footer: {
                    Text(L10n.ClipDetail.speakerEditHint).font(.footnote)
                }

                if !store.names(for: clip).isEmpty {
                    Section {
                        Button(role: .destructive) {
                            drafts = [:]
                            store.resetAll(clip: clip)
                        } label: {
                            Text(L10n.ClipDetail.resetSpeakerNames)
                        }
                    }
                }
            }
            .navigationTitle(L10n.ClipDetail.renameSpeakers)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
            .onAppear {
                store.load(clip: clip)
                // Seed the fields with what is already stored (not with the vendor
                // label): an untouched field must stay empty so the placeholder
                // reads as the original name.
                drafts = store.names(for: clip)
            }
        }
    }

    private func binding(for speaker: String) -> Binding<String> {
        Binding(
            get: { drafts[speaker] ?? "" },
            set: { new in
                drafts[speaker] = new
                store.rename(new, speaker: speaker, clip: clip)
            }
        )
    }
}
