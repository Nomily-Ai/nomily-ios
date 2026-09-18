import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr")

/// Drives the `primary → fallbacks` chain from `config.defaults.asr` for one
/// audio file at a time. Writes `{name}.txt` + `{name}.asr.json` next to the
/// decrypted audio so the artefacts travel together.
@MainActor
final class TranscriptionService: ObservableObject {
    private let config: ConfigService

    /// Filenames currently being transcribed. Observed by views so they can
    /// render a spinner + hide the "Transcribe" button while an auto-path
    /// transcription is running in the background (otherwise the user lands
    /// on Clip detail right after a download and sees the manual button even
    /// though the pipeline is already doing the work).
    @Published private(set) var inFlight: Set<String> = []

    /// Per-file task handles for cancellation. Duplicate calls for the same
    /// key re-use the existing task so two UI surfaces asking for the same
    /// clip don't double up on ASR credits.
    private var tasks: [String: Task<AsrResult, Error>] = [:]

    /// Per-clip provider fallback notices — keyed by audio filename (same
    /// space as `inFlight`). Populated when a provider fails and the chain
    /// falls through to the next one. Cleared when a new transcription for
    /// that clip starts. Observed by ClipDetailView for a non-blocking notice.
    @Published private(set) var fallbackWarnings: [String: [String]] = [:]

    init(config: ConfigService) { self.config = config }

    /// Cancel the in-flight transcription for `name`, if any. The awaiting
    /// call will throw `CancellationError` (or `URLError.cancelled` from
    /// an underlying URLSession call) — both get swallowed by callers that
    /// surface "user cancelled" as idle.
    func cancel(name: String) {
        tasks[name]?.cancel()
    }

    /// Transcribe `fileURL` using the configured provider chain.
    /// Returns the first successful provider's `AsrResult` and writes
    /// the transcript pair to disk; throws the last provider's error if
    /// every provider fails (or `AsrError.empty` when no provider is wired).
    ///
    /// `enforceMinDuration` gates `min_transcribe_duration` to the
    /// auto-transcribe-after-download path. Explicit taps on a Transcribe
    /// button always bypass the gate — user intent overrides the
    /// threshold, which otherwise surfaces a confusing error right after
    /// the user just asked to transcribe a short clip.
    func transcribe(
        fileURL: URL,
        locales: [String]? = nil,
        enforceMinDuration: Bool = false
    ) async throws -> AsrResult {
        let key = fileURL.lastPathComponent

        // Dedupe: a concurrent call for the same clip (e.g., user taps
        // Transcribe while the auto path is already running) waits on the
        // existing task instead of starting a duplicate network round-trip.
        if let existing = tasks[key] {
            return try await existing.value
        }

        let task = Task<AsrResult, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.runPipeline(
                fileURL: fileURL,
                locales: locales,
                enforceMinDuration: enforceMinDuration
            )
        }
        tasks[key] = task
        inFlight.insert(key)

        defer {
            tasks.removeValue(forKey: key)
            inFlight.remove(key)
        }

        return try await task.value
    }

    private func runPipeline(
        fileURL: URL,
        locales: [String]?,
        enforceMinDuration: Bool
    ) async throws -> AsrResult {
        let key = fileURL.lastPathComponent

        if enforceMinDuration {
            let minDuration = config.config.minTranscribeDuration
            if minDuration > 0,
               let duration = OpusOgg.duration(ofOggOpusAt: fileURL),
               duration < Double(minDuration) {
                log.info("skipping \(key, privacy: .public): duration=\(duration)s < min=\(minDuration)s")
                throw AsrError.tooShort(duration: duration, minimum: Double(minDuration))
            }
        }

        // Only include providers that actually have credentials configured.
        // Without this filter, an unconfigured Local provider would always
        // silently shadow the real Azure error (the chain falls through and
        // the last error wins — which is "Local server not configured").
        let chain = providerChain()
        guard !chain.isEmpty else { throw AsrError.noProviderConfigured }

        fallbackWarnings[key] = []

        // Run local VAD before the provider chain so we stop shipping
        // long stretches of silence. VAD returns nil when there's
        // nothing worth trimming (decode failed, no speech detected,
        // savings < 10 %) and the chain falls back to the original
        // file. The trimmed file lives in `tmp/` and is deleted after
        // the chain resolves one way or the other.
        var uploadURL = fileURL
        var tmpVAD: URL?
        var vadRanges: [VADReport.SpeechRange] = []
        if config.config.localVADEnabled {
            if let trimmed = await LocalVAD.processForUpload(source: fileURL) {
                uploadURL = trimmed.url
                tmpVAD = trimmed.url
                vadRanges = trimmed.ranges
            }
        }
        defer {
            if let tmpVAD { try? FileManager.default.removeItem(at: tmpVAD) }
        }

        // Re-encoded copy, from either the up-front conversion or the retry
        // path below. Cleaned up with the VAD temp file when the chain
        // resolves.
        var tmpTranscode: URL?
        defer {
            if let tmpTranscode { try? FileManager.default.removeItem(at: tmpTranscode) }
        }

        // Containers no provider in the chain can decode. CAF is the one QA
        // hit: AVFoundation reads it happily, Azure Fast Transcription does
        // not accept it at all, so it can only ever fail. Transcode before
        // the first attempt rather than burning a round-trip to learn that.
        if Self.alwaysTranscode.contains(uploadURL.pathExtension.lowercased()),
           let converted = await Self.transcodeForUpload(uploadURL) {
            tmpTranscode = converted
            uploadURL = converted
        }

        var lastError: Error?
        for (index, name) in chain.enumerated() {
            try Task.checkCancellation()
            do {
                var result: AsrResult
                do {
                    result = try await runProvider(name, fileURL: uploadURL, locales: locales)
                } catch {
                    // One rescue attempt per chain: when the provider
                    // rejected the *format* (as opposed to failing for
                    // credentials, quota or network reasons), re-encode to
                    // AAC/M4A — which every provider here accepts — and try
                    // the same provider again. This is what makes .opus
                    // variants Azure won't demux transcribe instead of
                    // dead-ending on 422 InvalidAudioFormat.
                    guard Self.isFormatRejection(error),
                          tmpTranscode == nil,
                          let converted = await Self.transcodeForUpload(uploadURL)
                    else { throw error }
                    log.info("provider \(name, privacy: .public) rejected the format; retrying as m4a")
                    tmpTranscode = converted
                    uploadURL = converted
                    result = try await runProvider(name, fileURL: uploadURL, locales: locales)
                }
                if !vadRanges.isEmpty {
                    // Provider timestamps are on the trimmed timeline;
                    // remap them back to the original clip so segment
                    // chips + future seek-to-time land where the user
                    // expects on the on-disk audio.
                    result = Self.remapTimestamps(result, ranges: vadRanges)
                }
                try writeArtefacts(result, audioName: key)
                return result
            } catch {
                // Any flavour of cancellation (CancellationError or
                // URLError.cancelled from URLSession) aborts the chain —
                // don't fall through to the next provider and re-spend ASR
                // credits on a run the user already stopped.
                if Task.isCancelled { throw CancellationError() }
                log.warning("provider \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                lastError = error
                // If there is a next provider, record this failure so the UI
                // can surface it non-intrusively while the fallback runs.
                if index < chain.count - 1 {
                    fallbackWarnings[key, default: []].append(
                        "\(name): \(error.localizedDescription)"
                    )
                }
            }
        }
        throw lastError ?? AsrError.empty
    }

    // MARK: - format rescue

    /// Extensions that are worth transcoding before the first upload because
    /// no configured provider accepts them. Everything else goes up as-is and
    /// only gets converted if the provider actually complains — the device's
    /// own Ogg-Opus is accepted today and must not pay for a needless
    /// re-encode.
    private static let alwaysTranscode: Set<String> = ["caf"]

    /// True when the failure reads as "I can't decode this audio" rather than
    /// "I couldn't do the work". Azure answers 400/415/422 for unsupported or
    /// undecodable payloads; anything else (401, 429, 5xx, transport) must not
    /// trigger a re-encode.
    private static func isFormatRejection(_ error: Error) -> Bool {
        guard case let AsrError.http(status, _) = error else { return false }
        return status == 400 || status == 415 || status == 422
    }

    /// Re-encode to AAC in an M4A container. Returns nil when the platform
    /// can't read the source either — the caller then surfaces the provider's
    /// original error, which is more informative than a transcode failure.
    private static func transcodeForUpload(_ source: URL) async -> URL? {
        let stem = source.deletingPathExtension().lastPathComponent
        do {
            return try await AudioExporter.exportAsM4A(
                source: source,
                suggestedName: "asr-\(stem)-\(UUID().uuidString.prefix(8))"
            )
        } catch {
            log.warning("transcode for ASR failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - chain

    private func providerChain() -> [String] {
        let defaults = config.config.defaults.asr
        var chain = [defaults.primary]
        for fallback in defaults.fallbacks where fallback != defaults.primary {
            chain.append(fallback)
        }
        return chain.filter { !$0.isEmpty && hasCredentials($0) }
    }

    private func hasCredentials(_ name: String) -> Bool {
        switch name.lowercased() {
        case "azure":
            guard let a = config.config.asrProviders.azure else { return false }
            // If this credential set was verified on the settings page and rejected, don’t use it for transcription — that round would inevitably return 401, and the user would see an unexplained failure.
            // Unverified ones can proceed.
            return !a.key.isEmpty && !a.region.isEmpty && a.verification != false
        case "local":
            guard let l = config.config.asrProviders.local else { return false }
            return !l.host.isEmpty && l.port > 0
        default:
            return false
        }
    }

    private func runProvider(_ name: String, fileURL: URL, locales: [String]?) async throws -> AsrResult {
        switch name.lowercased() {
        case "azure":
            guard let azure = config.config.asrProviders.azure,
                  !azure.key.isEmpty, !azure.region.isEmpty else {
                throw AsrError.missingCredentials("Azure")
            }
            // nil/empty → auto-detect (AzureASR omits the key from the
            // request). Non-empty → candidate set, Azure tags each phrase.
            let client = AzureASR(key: azure.key, region: azure.region, locales: locales)
            return try await client.transcribe(fileURL: fileURL)
        case "local":
            guard let local = config.config.asrProviders.local,
                  !local.host.isEmpty, local.port > 0 else {
                throw AsrError.missingCredentials("Local server")
            }
            let client = LocalASR(host: local.host, port: local.port)
            return try await client.transcribe(fileURL: fileURL)
        default:
            throw AsrError.missingCredentials(name)
        }
    }

    // MARK: - VAD timestamp remap

    /// Remaps every segment's `start`/`end` from the trimmed upload
    /// timeline to the original clip timeline, and recomputes
    /// `duration` as the post-remap span. Segments that straddle a
    /// silence gap will have a wider duration than the provider
    /// reported (the gap becomes part of the segment's wall-clock
    /// coverage), which is the right behavior for display and for
    /// tap-to-seek — landing just past the sentence's end on the
    /// original audio matches the chip.
    private static func remapTimestamps(
        _ result: AsrResult, ranges: [VADReport.SpeechRange]
    ) -> AsrResult {
        let mapped = result.segments.map { seg -> AsrSegment in
            let s = LocalVAD.remapToOriginal(seg.start, ranges: ranges)
            let e = LocalVAD.remapToOriginal(seg.end, ranges: ranges)
            return AsrSegment(
                speaker: seg.speaker,
                text: seg.text,
                start: s,
                end: e,
                duration: max(0, e - s)
            )
        }
        return AsrResult(
            text: result.text,
            segments: mapped,
            provider: result.provider,
            locale: result.locale
        )
    }

    // MARK: - artefacts

    private func writeArtefacts(_ result: AsrResult, audioName: String) throws {
        let urls = StorageLocations.transcriptURLs(for: audioName)
        try FileManager.default.createDirectory(
            at: StorageLocations.decryptedDir,
            withIntermediateDirectories: true
        )

        let body = formatTranscript(result)
        try body.data(using: .utf8)?.write(to: urls.txt, options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(result)
        try json.write(to: urls.json, options: .atomic)
        log.info("wrote transcript txt=\(urls.txt.lastPathComponent, privacy: .public) json=\(urls.json.lastPathComponent, privacy: .public)")
    }

    private func formatTranscript(_ result: AsrResult) -> String {
        if result.segments.isEmpty { return result.text }
        return result.segments.map { $0.formatted() }.joined(separator: "\n")
    }
}
