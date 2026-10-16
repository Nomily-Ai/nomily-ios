import CoreMotion
import Foundation
import SwiftUI

/// The two toggles: "shake to start recording" + "double tap to start/stop recording".
///
/// Storing it **separately** from `WatchRingStyleStore` is deliberate: that one's `reset()` is "restore the default
/// appearance", and having "restore default appearance" reset the recording behaviour too would be surprising — the user tapped
/// restore-default on the colour page, and the recording method changed.
final class WatchRecordingPrefs: ObservableObject {
    static let shared = WatchRecordingPrefs()

    private static let key = "watch.shake_to_record.v1"
    /// ★ 2026-10-15 revision six: double tap (pinching index finger and thumb). **A separate key** —
    /// the two gestures misfire in completely different scenarios (shake is "raise and lower the wrist", pinch is "wanting to press but missing"),
    /// and sharing one toggle would turn off one along with the other.
    private static let pinchKey = "watch.pinch_to_record.v1"

    /// Defaults **on**: what the user wants is for this action to work right away; if they really think it misfires,
    /// they can turn it off on the settings page (right below the version number).
    @Published var shakeToRecord: Bool {
        didSet { defaults.set(shakeToRecord, forKey: Self.key) }
    }

    /// Defaults **on** (the user specifically asked for this capability).
    ///
    /// ⚠️ Only watchOS 11+ can really turn it off: on 10.1~10.x Double Tap is system behaviour,
    /// with no API to intercept it (see `PrimaryHandGesture`). The settings page only shows this row on 11+,
    /// so as not to offer a switch that does nothing on 10.x.
    @Published var pinchToRecord: Bool {
        didSet { defaults.set(pinchToRecord, forKey: Self.pinchKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⚠️ Must use `object(forKey:)` to tell "was it ever set": `bool(forKey:)` returns
        // false when the key is absent, so "default on" would silently become "default off", and the user could never
        // turn it on — every cold launch returns to false.
        self.shakeToRecord = (defaults.object(forKey: Self.key) as? Bool) ?? true
        self.pinchToRecord = (defaults.object(forKey: Self.pinchKey) as? Bool) ?? true
    }
}

/// "Shake the watch hard" detection.
///
/// ## Why the raw accelerometer rather than `deviceMotion.userAcceleration`
/// All we care about is "the wrist got yanked hard". The raw accelerometer's **magnitude** is always 1g at rest
/// (gravity), **rotating** the wrist can't change it (only the direction of gravity in the sensor's coordinate frame changes),
/// and only **translation** pushes the magnitude up — exactly the physical signature of a "shake".
/// So a single `|a| > threshold` criterion suffices, and it also avoids the branch where `deviceMotion` may be
/// unavailable on some models (`userAcceleration` requires an attitude solve first).
///
/// ## Why it requires "two threshold crossings in a row within a time window"
/// Raising and lowering the wrist, tapping the edge of a desk, buckling the strap when putting the watch on — all produce **one** sharp peak;
/// a real "shake twice" necessarily crosses twice in a row within a second. Requiring two costs about 0.1 s
/// of latency in detection, and buys not starting recording by itself while walking or typing.
///
/// ## Why the gyroscope alone won't do
/// The gyroscope only measures angular velocity; a motion like "turn the wrist to look at the watch" has high angular velocity but tiny acceleration,
/// so using it as the criterion would misfire every time you check the time.
final class WatchShakeDetector {
    /// Only crossing this acceleration (in g) counts as one "impact". At rest it's 1g; walking peaks
    /// never reach 2.3, while deliberately flicking the wrist easily exceeds 3g.
    private static let threshold: Double = 2.3
    /// Two impacts must fall within this time window to count as a "shake".
    private static let burstWindow: TimeInterval = 0.9
    /// Goes quiet for a spell after triggering, so one shake isn't split into "on→off→on".
    private static let cooldown: TimeInterval = 2.0
    /// 25Hz is enough to tell "shake" from "bump" (one impact lasts about 100~200ms).
    /// Higher is just wasted power — this page stays on constantly, and the sampling rate is the big item on the battery bill.
    private static let updateInterval: TimeInterval = 1.0 / 25.0

    private let manager = CMMotionManager()
    private var onShake: (() -> Void)?
    /// Impact timestamps along the trace, keeping only those within `burstWindow`.
    private var peaks: [Date] = []
    /// Whether the previous sample was already above the threshold — used to count only the "crossing upward" event.
    private var aboveThreshold = false
    private var lastFire = Date.distantPast

    var isRunning: Bool { manager.isAccelerometerActive }

    /// Start listening. `handler` is called on the **main queue**.
    ///
    /// Idempotent: if it's already running, just swap the handler rather than restarting sampling (restarting re-warms the die,
    /// and the first few tens of milliseconds of data are inaccurate).
    func start(_ handler: @escaping () -> Void) {
        onShake = handler
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        peaks.removeAll()
        aboveThreshold = false
        manager.accelerometerUpdateInterval = Self.updateInterval
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.acceleration
            self.handle(magnitude: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
        }
    }

    func stop() {
        onShake = nil
        peaks.removeAll()
        aboveThreshold = false
        manager.stopAccelerometerUpdates()
    }

    private func handle(magnitude: Double) {
        guard magnitude > Self.threshold else {
            aboveThreshold = false
            return
        }
        // One impact keeps several consecutive samples above the threshold. Record only on the **first** crossing,
        // otherwise one impact gets counted five or six times and the "two to count as a shake" bar amounts to nothing.
        guard !aboveThreshold else { return }
        aboveThreshold = true

        let now = Date()
        peaks.append(now)
        peaks.removeAll { now.timeIntervalSince($0) > Self.burstWindow }
        guard peaks.count >= 2, now.timeIntervalSince(lastFire) >= Self.cooldown else { return }
        peaks.removeAll()
        lastFire = now
        onShake?()
    }
}
