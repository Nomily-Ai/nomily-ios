import AVFoundation
import SwiftUI

/// Peak envelope of an audio file — what the detail page's waveform scrubber
/// draws.
///
/// ★ 2026-10-23 ("参考一下页面布局跟结构", Plaud 截图 4029): Plaud's player is a
/// waveform with the played part in ink and the rest in grey, not a slider on a
/// hairline. The data comes from the file itself, so the picture is honest —
/// no invented bars. Files this device cannot decode (some Ogg/Opus streams)
/// return `nil` and the caller keeps the plain slider.
///
/// Extraction runs once per file: results are memoised in memory, and an
/// in-flight task is shared so two players of the same clip do not decode twice.
enum AudioEnvelope {

    private static let lock = NSLock()
    private static var cache: [String: [Float]] = [:]
    private static var inFlight: [String: Task<[Float]?, Never>] = [:]

    static func cached(for url: URL) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return cache[url.path]
    }

    /// `buckets` is the bar count at full width — 360 is one bar per ~1.5 pt on
    /// a 540 pt-wide phone, dense enough to read as a waveform, cheap enough to
    /// draw inside a scroll view.
    static func load(for url: URL, buckets: Int = 360) async -> [Float]? {
        if let hit = cached(for: url) { return hit }

        let task: Task<[Float]?, Never> = {
            lock.lock()
            defer { lock.unlock() }
            if let running = inFlight[url.path] { return running }
            let started = Task.detached(priority: .utility) { extract(url: url, buckets: buckets) }
            inFlight[url.path] = started
            return started
        }()

        let result = await task.value
        lock.lock()
        if let result { cache[url.path] = result }
        inFlight[url.path] = nil
        lock.unlock()
        return result
    }

    private static func extract(url: URL, buckets: Int) -> [Float]? {
        // `AVAudioFile` decodes whatever the system can read and hands back
        // float PCM in the processing format — no manual format negotiation.
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let total = file.length
        guard total > 0 else { return nil }

        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: chunk) else { return nil }
        let framesPerBucket = max(1, Int(total) / buckets)
        let channels = Int(file.processingFormat.channelCount)

        var peaks: [Float] = []
        peaks.reserveCapacity(buckets + 1)
        var running: Float = 0
        var bucketFrames = 0

        while file.framePosition < total {
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil else { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }

            for frame in 0..<frames {
                var peak: Float = 0
                for channel in 0..<channels {
                    peak = max(peak, abs(data[channel][frame]))
                }
                running = max(running, peak)
                bucketFrames += 1
                if bucketFrames >= framesPerBucket {
                    peaks.append(running)
                    running = 0
                    bucketFrames = 0
                }
            }
        }
        if bucketFrames > 0 { peaks.append(running) }

        guard let loudest = peaks.max(), loudest > 0, peaks.count > 1 else { return nil }
        return peaks.map { min(1, $0 / loudest) }
    }
}

/// The waveform itself: symmetric bars, played portion in ink, the rest faded,
/// draggable to scrub. Mirrors `InlineAudioPlayer`'s slider semantics
/// (`beginScrub` / `endScrub`), so the audio controller needs no new API.
struct WaveformScrubber: View {

    var peaks: [Float]
    /// 0…1 position of the playhead.
    var progress: Double
    /// Called continuously while dragging (the caller seeks on release).
    var onScrub: (Double) -> Void
    var onScrubBegan: () -> Void
    var onScrubEnded: (Double) -> Void

    @Environment(\.colorScheme) private var scheme

    private var ink: Color { scheme == .dark ? Color(white: 0.92) : Color(white: 0.12) }
    private var faded: Color { scheme == .dark ? Color(white: 0.45) : Color(white: 0.72) }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let count = max(peaks.count, 1)
            let barWidth = width / CGFloat(count)
            let gap = min(1.6, barWidth * 0.38)

            Canvas { context, size in
                guard !peaks.isEmpty else { return }
                for (index, peak) in peaks.enumerated() {
                    let height = max(2, CGFloat(peak) * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth,
                        y: (size.height - height) / 2,
                        width: max(0.8, barWidth - gap),
                        height: height
                    )
                    let position = Double(index) / Double(count)
                    let colour = position <= progress ? ink : faded
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 3),
                        with: .color(colour)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrubBegan()
                        onScrub(clamp(value.location.x / width))
                    }
                    .onEnded { value in
                        onScrubEnded(clamp(value.location.x / width))
                    }
            )
        }
        .frame(height: 54)
        .accessibilityLabel(L10n.ClipDetail.transcript)
    }

    private func clamp(_ value: CGFloat) -> Double {
        Double(min(1, max(0, value)))
    }
}
