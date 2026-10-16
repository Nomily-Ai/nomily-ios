import Foundation
import HealthKit

// MARK: - Heart rate measured on the watch
//
// ★ 2026-10-16 revision eleven (user's words:
//   "when recording, the rises and falls should overall follow your personal real-time heart rate that the watch reads").
//
// ## What it solves
// Revision ten's waveform used a **hard-coded** heartbeat base shape: ten slots = 0.8 s ≈ **75 bpm**.
// That's "an adult's average resting heart rate", not **this person's** heart rate right now. What the user wants is
// "beat along with my heart" — so this reads real values from HealthKit and uses them to set the waveform's period.
//
// ## ★ Why "poll for the most recent reading" rather than `HKAnchoredObjectQuery`
// An anchored query only fires the moment a **new sample lands in the store**. And on Apple Watch, **outside a workout**,
// the pace at which heart rate is stored is entirely up to the system — at rest it might be one reading every several minutes. So an anchored query
// looks more "real-time" but in practice may **never fire once across a whole recording**, leaving the waveform running on the fallback the entire time
// — an implementation that "looks sophisticated but doesn't actually work".
//
// So this does the opposite: **every 8 seconds, actively ask "what was the most recent heart rate"**.
//   · Sensor delivers quickly → a new value is guaranteed within 8 seconds;
//   · Sensor delivers slowly → you still get the previous one (heart rate barely changes within a few minutes anyway, good enough);
//   · None at all → keep the last value; none from the start → the view side falls back to 75.
// All three cases have a definite, explainable behaviour, which is far more controllable than "wait for a push".
//
// ## ⚠️ You can't get per-second heart rate — that's an Apple limitation, not an oversight here
// The only way to make the heart-rate sensor truly sample at high frequency is to start an `HKWorkoutSession`.
// The cost: a **green workout icon** appears on the watch face, more battery drain, and "recording" is not a workout at all —
// running a workout session for a voice recorder is wrong both in feel and in semantics. On balance it isn't worth it, so we didn't.
// **This note is left for future people (and future me)**: if a user ever says "the heart rate isn't real-time enough",
// the answer is here, not in tweaking that 8 seconds.
//
// ## ⚠️ When permission is denied it degrades silently, with no error
// HealthKit deliberately won't tell you the result for **read** permission (`authorizationStatus(for:)` for read types
// keeps returning `.notDetermined`), so this doesn't even try to judge "was it denied" —
// if it can be read, update; if not, hold the fallback. If the user denies permission, the waveform returns to its original fixed rhythm
// and won't error out or go blank just because "the heart rate can't be read".
@MainActor
final class WatchHeartRateMonitor {
    /// Called back when a new heart rate is read (**always on the main thread**). The parameter is bpm.
    var onUpdate: ((Double) -> Void)?

    private let store = HKHealthStore()

    /// `.heartRate` necessarily exists on this project's deployment target (watchOS 10).
    /// Uses an optional + `guard` rather than a force unwrap — not leaving a crash point for a case that theoretically can't happen.
    private var heartType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .heartRate)
    }

    /// `count/min`, i.e. bpm.
    private let unit = HKUnit.count().unitDivided(by: .minute())

    private var poll: Timer?
    /// The smoothed heart rate. See `ingest`.
    private var smoothed: Double?

    /// How often to ask HealthKit.
    ///
    /// ⚠️ 8 seconds is a trade-off: faster is meaningless (the sensor itself is slow), slower means "I changed position and my heart rate went up"
    ///    takes too long to show up on the waveform. See the block at the top of the file.
    private static let pollInterval: TimeInterval = 8

    /// How old a sample can be and still count as the "current heart rate".
    ///
    /// 15 minutes is deliberately loose: at rest the watch may store just one reading at this pace, and tightening it would make
    /// readings frequently stale and the waveform flip back and forth between two rhythms — worse than using a slightly old value.
    private static let maxSampleAge: TimeInterval = 900

    /// How much weight the new value gets.
    ///
    /// ⚠️ It must be smoothed. Adjacent readings in HealthKit jitter up and down by a few bpm (measurement noise),
    /// and setting the period from raw values would make the waveform's speed jitter along with it — looking like a fault.
    /// 0.35 is the level that "keeps up with real changes without jumping on noise" (converges within about 3 samples).
    private static let smoothing = 0.35

    // MARK: - Permission

    /// Request read permission for heart rate. **Unrelated to recording; just call it once when the home screen appears.**
    ///
    /// ⚠️ Deliberately **not at the start of recording**: popping a system authorisation sheet at that moment would likely
    ///    interrupt the just-started recording (the sheet is a system modal). Placed at home-screen appearance, the user hasn't started recording
    ///    yet, so interrupting costs nothing.
    ///
    /// ⚠️ This method can be safely called on every launch: `getRequestStatusForAuthorization`
    ///    returns `.unnecessary` once the user has answered, and the system won't show the sheet a second time.
    func prepare() {
        guard HKHealthStore.isHealthDataAvailable(), let type = heartType else { return }
        let read: Set<HKObjectType> = [type]
        store.getRequestStatusForAuthorization(toShare: [], read: read) { [weak self] status, _ in
            guard status == .shouldRequest, let self else { return }
            self.store.requestAuthorization(toShare: [], read: read) { _, _ in }
        }
    }

    // MARK: - Following recording start/stop

    /// Start following. **Called when recording starts.**
    func follow() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        stopPolling()
        smoothed = nil

        // Read once immediately, so the waveform doesn't run the fallback for the first few seconds.
        readLatest()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readLatest() }
        }
        // `.common` rather than the default mode: the default mode is paused during scrolling/tracking,
        // and this page has exactly a horizontal paging gesture — the default mode would quietly stop sampling while swiping.
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// Stop following. **Called when recording ends.**
    func unfollow() {
        stopPolling()
        // Doesn't clear `smoothed`: the same person's heart rate is about the same across two recordings,
        // so starting the next take from this value is more continuous than starting from scratch (no value → fallback 75).
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    // MARK: - Read

    private func readLatest() {
        guard let type = heartType else { return }
        let start = Date().addingTimeInterval(-Self.maxSampleAge)
        let query = HKSampleQuery(
            sampleType: type,
            predicate: HKQuery.predicateForSamples(withStart: start, end: nil),
            limit: 1,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        ) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            Task { @MainActor in self?.ingest(bpm) }
        }
        store.execute(query)
    }

    private func ingest(_ bpm: Double) {
        // Obviously unreasonable values are dropped outright: 0 or negative is certainly bad (the typical output when the sensor isn't snug),
        // and a single 0 would freeze the waveform into a flat line.
        guard bpm > 20, bpm < 250 else { return }
        let next = smoothed.map { $0 + (bpm - $0) * Self.smoothing } ?? bpm
        smoothed = next
        onUpdate?(next)
    }
}
