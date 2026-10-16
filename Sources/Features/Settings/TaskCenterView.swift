import SwiftUI

/// The **overview** of the four kinds of long job (★ 2026-10-16 revision twelve).
///
/// ## Why this page exists
/// The user's own words: "summaries, translations, transcriptions and audio format conversion ... these can go to the background first
/// and be looked at and analysed once they finish".
///
/// Unpacked, it's two things: **"switch away and it keeps running"** and **"come back and it's visible"**. The former relies on
/// `BackgroundKeeper` plus two persisted queues; the latter has to rely on this page — without it, a finished job only shows up
/// as "that recording in the library now has one more summary", and the user can't tell that it's the queue they just started,
/// nor whether it finished, failed, or never started at all.
///
/// ## Why the four job kinds sit in one list yet come from two sources
/// Transcription is still scheduled by `TranscriptionService` (620 lines, a whole set of already-working semantics:
/// de-duping by filename, `enqueueAndWait`, clearing orphans on launch, ASR-specific retry criteria),
/// while summary / translation / format conversion are in `JobQueue`. This page **flattens both sides' entries into one kind of row**
/// — what's shared is the "overview" layer, not the "scheduling" layer. For the reasoning see the block at the top of `JobQueue`
/// "why transcription wasn't moved in".
///
/// ## The discoverability problem of in-row actions
/// Cancel / remove go through the system-native **swipe** (`.swipeActions`) — it has to coexist with the whole row being tappable
/// (going into the detail page), and buttons crammed into a `NavigationLink`'s label have their taps eaten by the link.
/// The only exception is "Retry": the failed row **can't be tapped into anyway** (no result to look at),
/// so its button sits right in the row, visible.
struct TaskCenterView: View {
    @EnvironmentObject private var jobs: JobQueue
    @EnvironmentObject private var transcription: TranscriptionService

    var body: some View {
        List {
            let active = rows(unfinished: true)
            let finished = rows(unfinished: false)

            if active.isEmpty && finished.isEmpty {
                emptyState
            }
            if !active.isEmpty {
                Section {
                    ForEach(active) { rowView($0) }
                } header: {
                    Text(L10n.Jobs.sectionActive)
                }
            }
            if !finished.isEmpty {
                Section {
                    ForEach(finished) { rowView($0) }
                } header: {
                    Text(L10n.Jobs.sectionFinished)
                }
            }

            Section {
                Text(L10n.Jobs.footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.Jobs.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if jobs.finishedCount > 0 || stuckTranscriptionCount > 0 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Jobs.clearFinished) { clearFinished() }
                }
            }
        }
    }

    /// The count of "gave up after exhausting retries" entries in the transcription queue.
    ///
    /// Why it counts as "completed" too: to the user it's a job that **has a result** (the result being
    /// failure). If "Clear completed" didn't clear it, a row would remain after tapping, looking like nothing happened.
    private var stuckTranscriptionCount: Int {
        transcription.pending.filter { $0.attempts >= TranscriptionService.maxAttempts }.count
    }

    /// Clear completed entries.
    ///
    /// The transcription queue has no notion of "clear" (it dequeues itself on success and stays on failure for
    /// retry), so this does the same thing on its behalf: cancelling the abandoned entries, i.e. wiping them from the ledger.
    /// Since the user tapped "Clear completed", what they want is "I'm done looking at these".
    private func clearFinished() {
        jobs.clearFinished()
        for pending in transcription.pending
        where pending.attempts >= TranscriptionService.maxAttempts {
            transcription.cancel(name: pending.name)
        }
    }

    // MARK: - Row model

    /// One row in the list.
    ///
    /// The two sources (`JobQueue` and the transcription queue) are flattened into one kind of thing **on this page** —
    /// which is exactly why this page exists. Deliberately not made into a shared domain model: that would force the two
    /// queues to share one set of fields, when they inherently need different ones (transcription needs multiple languages,
    /// summary needs a prompt, export needs a format).
    private struct Row: Identifiable {
        enum Origin {
            case job(Job)
            case transcription(TranscriptionService.PendingJob)
        }

        let id: String
        let kind: JobKind
        let clipName: String
        let status: JobQueue.State
        let detail: String?
        let error: String?
        let progress: (done: Int, total: Int)?
        let enqueuedAt: Date
        let origin: Origin
        /// When it can be found, it's used to jump to the detail page; `nil` = the audio is gone (only the text artifact is left, or
        /// even the artifact was deleted). In that case this row isn't tappable.
        let item: LibraryItem?
    }

    /// Concatenate the rows from both sources into one list, in reverse enqueue-time order (newest on top).
    private func rows(unfinished: Bool) -> [Row] {
        var out: [Row] = []

        for job in jobs.jobs {
            guard (job.finishedAt == nil) == unfinished else { continue }
            out.append(Row(
                id: job.id,
                kind: job.kind,
                clipName: job.clipName,
                status: jobs.state(of: job),
                detail: job.detail,
                error: job.lastError,
                progress: progress(of: job),
                enqueuedAt: job.enqueuedAt,
                origin: .job(job),
                item: LibraryItem.readFromDisk(name: job.clipName, duration: nil)
            ))
        }

        // The transcription queue's criteria differ from `JobQueue`'s: it **dequeues on success** (`forget`),
        // so only two kinds remain in `pending` — "running / waiting" and "gave up after exhausting retries".
        // There are no "completed" transcription rows; that's not an omission, that queue simply doesn't keep them.
        for pending in transcription.pending {
            let stuck = pending.attempts >= TranscriptionService.maxAttempts
            guard stuck != unfinished else { continue }
            out.append(Row(
                id: "transcribe:\(pending.name)",
                kind: .transcribe,
                clipName: pending.name,
                status: stuck
                    ? .gaveUp
                    : (transcription.inFlight.contains(pending.name) ? .running : .waiting),
                // Transcription's "variant" is the recognition language (`locales`), in the same slot as the summary's template name.
                detail: pending.locales?.joined(separator: ", "),
                error: pending.lastError,
                progress: nil,
                enqueuedAt: pending.enqueuedAt,
                origin: .transcription(pending),
                item: LibraryItem.readFromDisk(name: pending.name, duration: nil)
            ))
        }

        return out.sorted { $0.enqueuedAt > $1.enqueuedAt }
    }

    private func progress(of job: Job) -> (done: Int, total: Int)? {
        guard let done = job.progressDone, let total = job.progressTotal else { return nil }
        return (done, total)
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        // The failed row doesn't go into the detail page: there's no "result to look at" there, and tapping in would only show a
        // page unrelated to the job. Its point is to surface that "Retry" button.
        if row.status != .gaveUp, let item = row.item {
            NavigationLink {
                ClipDetailView(item: item)
            } label: {
                rowLabel(row)
            }
            .swipeActions(edge: .trailing) { swipeActions(row) }
        } else {
            rowLabel(row)
                .swipeActions(edge: .trailing) { swipeActions(row) }
        }
    }

    @ViewBuilder
    private func rowLabel(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: row.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                Text(row.item?.displayTitle ?? row.clipName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                statusChip(row.status)
            }

            HStack(spacing: 5) {
                Text(row.kind.title)
                if let detail = row.detail, !detail.isEmpty {
                    Text("·")
                    Text(detail)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let error = row.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if let progress = row.progress {
                ProgressView(
                    value: Double(progress.done),
                    total: Double(max(progress.total, 1))
                )
                .progressViewStyle(.linear)
            }

            // The only **in-row** action: retry. For the reasoning see the type's comment.
            if row.status == .gaveUp {
                Button(L10n.Jobs.retry) { retry(row) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusChip(_ state: JobQueue.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .waiting, .done, .gaveUp:
            Text(statusLabel(state))
                .font(.caption2)
                .foregroundStyle(statusColor(state))
        }
    }

    private func statusLabel(_ state: JobQueue.State) -> String {
        switch state {
        case .waiting: return L10n.Jobs.statusWaiting
        case .running: return L10n.Jobs.statusRunning
        case .done: return L10n.Jobs.statusDone
        case .gaveUp: return L10n.Jobs.statusGaveUp
        }
    }

    private func statusColor(_ state: JobQueue.State) -> Color {
        switch state {
        case .waiting, .running: return .secondary
        case .done: return .green
        case .gaveUp: return .orange
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func swipeActions(_ row: Row) -> some View {
        let busy = row.status == .waiting || row.status == .running
        if busy {
            Button(role: .destructive) { cancel(row) } label: {
                Label(L10n.Jobs.cancel, systemImage: "xmark")
            }
        }
        // Only finished entries may be "removed". Wiping a still-queued one straight away would make the user think the job ran,
        // when what they really want is "get rid of it" — that's cancel.
        if !busy {
            Button(role: .destructive) { remove(row) } label: {
                Label(L10n.Jobs.remove, systemImage: "trash")
            }
        }
    }

    private func cancel(_ row: Row) {
        switch row.origin {
        case .job(let job): jobs.cancel(id: job.id)
        case .transcription(let pending): transcription.cancel(name: pending.name)
        }
    }

    private func retry(_ row: Row) {
        switch row.origin {
        case .job(let job): jobs.retry(id: job.id)
        case .transcription(let pending): transcription.retry(name: pending.name)
        }
    }

    private func remove(_ row: Row) {
        switch row.origin {
        case .job(let job): jobs.forget(id: job.id)
        // The transcription queue has no "forget" step: it dequeues itself on success and stays on failure
        // for retry. So for an abandoned transcription row, "remove" is cancel — same effect.
        case .transcription(let pending): transcription.cancel(name: pending.name)
        }
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(L10n.Jobs.empty)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
