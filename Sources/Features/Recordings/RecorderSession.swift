import Combine
import SwiftUI
import UIKit

// MARK: - Recording session (the sole state source for the header recording button)
//
// ## Why this layer is needed
//
// "Recording" tab's top red dot button previously only served D·NOTE: it directly reads
// `DnoteClient.lastDeviceInfo?.isRecording`, but TicNote uses `RecorderLink`
// (a completely different abstraction), so **the same button does not exist at all on TicNote** ——
// The phenomenon users see is "device scanned, but the recording button disappeared".
//
// This layer abstracts "recording start/stop + duration" into a device‑independent matter:
//
// | | D·NOTE (V05E) | TicNote |
// |---|---|---|
// | Start/Stop | `DnoteClient.startRecording()` | `RecorderLink.startRecording()` |
// | Is recording | `lastDeviceInfo.isRecording` (device reports itself) | **No resolvable field** → local anchor |
// | Duration | `getRecordingStatus()["recd"]` (device reports itself) | local anchor (device rarely reports, see below) |
// | Polling | 1 Hz | 1 Hz |
//
// ## ★ Duration: Why "copying V05E" doesn't work on TicNote
//
// V05E's duration **entirely comes from the device** (`recd`, milliseconds), the client does not compute it itself — therefore its
// `RecordingsView` contains that `Text(formatElapsed(ms))` which is "device pushes once, UI updates once".
//
// During recording, TicNote's card **remains silent**: among the full 8543 ATT frames on a real device, those containing session total byte count
// `0x17` appears only **2 times**, and both are **one‑time** session notifications (the start‑recording moment), not periodic reports.
// Copying V05E results in the clock always staying at 0:00 — which is exactly what users reported
// "Recording duration does not increase".
//
// Therefore the rule here is **device value takes precedence, local anchor as fallback**:
//   * If the device reports a **larger** value (e.g., the card started recording before we sent the command) → trust the device,
//     and shift the local anchor forward, letting the clock continue from the device value;
//   * If the device reports nothing → the local anchor proceeds normally by seconds.
// The local anchor is `startedAt`, driven by `TimelineView` redrawing every second — **does not depend on any state changes**.
//
// ## ★ Another genuine bug that was fixed
//
// The old implementation wrote `Text(Self.elapsed(from: started))` on the device page: this string is only recomputed when
// **the body re‑evaluates** then, and there is no `@State` changing each second during recording,
// so it fundamentally never changes. `TimelineView(.periodic)` is the correct solution for this.
@MainActor
final class RecorderSessionModel: ObservableObject {

    // MARK: Goal

    /// Target device for recording control.
    ///
    /// ⚠️ The entire enum is marked `@MainActor`: `identity` needs to read `RecorderLink.peripheral`
    /// and `DnoteClient.peripheral`, and both are isolated to the main thread in their respective classes
    /// (CoreBluetooth properties may only be accessed on the main thread). Nested types **do not** inherit the outer class's isolation,
    /// so they must be annotated themselves — omitting it causes a compile error (the first attempt failed here).
    @MainActor
    enum Target {
        case dnote(DnoteClient)
        case card(any RecorderLink)

        /// Stability identifier — used when swapping devices to decide whether to clear the state.
        /// Use `peripheral.identifier` instead of the object address: reconnection creates a **new**
        /// `TicNoteLink` instance; comparing by address would treat a brief reconnection of the same card as a card change,
        /// and the recording state would be unnecessarily cleared.
        var identity: String {
            switch self {
            case .dnote(let client): return "dnote:\(client.peripheral.identifier.uuidString)"
            case .card(let link):    return "card:\(link.peripheral.identifier.uuidString)"
            }
        }
    }

    // MARK: External state

    /// Whether the card is recording.
    ///
    /// ⚠️ In TicNote this is **local state + device correction**, not the "device truth" ——
    /// The card lacks a resolvable "is recording" field (`0x03` / `0x06` responses are identical during recording and idle,
    /// real device 4 samples are byte‑for‑byte identical). This must be documented in code,
    /// otherwise the next developer will assume it is a trustworthy device report.
    @Published private(set) var isRecording = false

    @Published private(set) var busy = false

    /// Local anchor: the moment recording starts. **Duration is "now − it"**, updated by the UI each second.
    @Published private(set) var startedAt: Date?

    /// Device‑reported recorded duration (seconds). `nil` = device did not report.
    @Published private(set) var deviceElapsed: TimeInterval?

    /// Card‑side explanatory hint (e.g., "card did not confirm recording command"). **Not an error** ——
    /// The command was indeed sent, but it's unknown whether the card acknowledged it; users need to know this distinction.
    @Published private(set) var notice: String?

    /// Actual failure (write failure / link broken / card unsupported).
    @Published var alert: RecorderSessionAlert?

    /// Card **actively pushes** battery level (`nil` = unknown).
    ///
    /// ★ Users reported "battery visible only after opening the card, then never changes". Now `cardWatchTask`
    /// reads the cache each tick, and `pollTask` sends a `0x09` every second, so it is **live** ——
    /// the UI can bind directly to this value, no need to "tap to refresh".
    @Published private(set) var cardBatteryPercent: Int?

    /// Card **actively pushes** charging status (`nil` = unknown / flag from card unrecognizable).
    ///
    /// ## ★ Why it must exist paired with `cardBatteryPercent` (2026-10-14)
    /// User's exact words:
    /// > "Charging here is still not synchronized, needs adjustment and optimization"
    ///
    /// Troubleshooting conclusion: "**Data is fine, UI reads a stale value**": in real device logs the first byte of `0x09`
    /// flips with plug/unplug continuously (`0x00` not charging ↔ `0x01` charging, only these two samples exist),
    /// but the two display spots on the device page read from `RecorderDeviceView.deviceInfo` — a single source that
    /// is only written by `@State` when "open card info / pull to refresh".
    ///
    /// The battery half already had this live path (`cardBatteryPercent` + `cardWatchTask`),
    /// but charging status was omitted, so it stayed on a snapshot. After adding it, both fields share the same source and frequency:
    /// both "read cache once per second, zero BLE round‑trips".
    ///
    /// ⚠️ **Three states, cannot be collapsed into two**: `nil` means "unknown", UI displays `—`.
    /// Treating it as `false` is asserting something we don't know on behalf of the user ——
    /// and they look at this item precisely to decide "whether to plug in power".
    @Published private(set) var cardCharging: Bool?

    private(set) var target: Target?
    private var pollTask: Task<Void, Never>?
    private var cardWatchTask: Task<Void, Never>?

    /// D·NOTE's subscription chain. See `attach` for why a subscription is used instead of a one‑time snapshot.
    private var dnoteWatch: AnyCancellable?

    // MARK: Assembly

    /// Swap in (or out) the target device. Passing `nil` indicates there is currently no recordable device.
    ///
    /// Repeated calls on the same device are **no‑op** — the view will invoke it each time the body evaluates,
    /// do not clear the state otherwise a redraw during recording would reset the duration to zero.
    func attach(_ newTarget: Target?) {
        if let current = target, let incoming = newTarget, current.identity == incoming.identity {
            return
        }
        let wasRecording = isRecording
        stopPolling()
        stopCardWatch()
        dnoteWatch = nil
        target = newTarget
        startedAt = nil
        deviceElapsed = nil
        notice = nil
        isRecording = false
        cardBatteryPercent = nil
        cardCharging = nil

        switch newTarget {
        case .dnote(let client):
            // ★ Subscribe to the client’s **own** published values, rather than reading a one‑time snapshot here.
            //
            // This matches the old implementation (`RecordControl` computed on each body evaluation
            // `client.lastDeviceInfo?.isRecording`) semantics exactly, and also fixes
            // a potential issue in the old implementation: `RecordingsView` **does not** observe
            // `DnoteClient` (it only observes `bluetooth` / `library` / `env`),
            // so that button is not guaranteed to refresh with `lastDeviceInfo`.
            //
            // Why a one‑time snapshot doesn’t work: when `RecordingsView` appears, `DeviceFilesView`
            // `.task` has just issued `getDeviceInfo()`, at that moment `lastDeviceInfo` is likely
            // nil — thus "the card is actually recording" would be shown as "not recording", and when the user taps again it
            // becomes **stop**. This reverse action is problematic and must be blocked by a subscription.
            dnoteWatch = client.$lastDeviceInfo
                .sink { [weak self] info in
                    // `DnoteClient` is `@MainActor`, and `@Published` emissions also occur on the main thread,
                    // so `assumeIsolated` here is safe — and it avoids one
                    // meaningless thread hop (the hop would delay the "device says stopped" update by one frame to the UI).
                    MainActor.assumeIsolated { self?.noteDeviceRecordingState(info?.isRecording) }
                }
        case .card(let link):
            // ★ 2026-10-10 update: previously this said "the card’s physical button start‑recording has no usable criteria, so we don’t guess".
            //   That conclusion was based on "the card is silent during recording" — **has been overturned**:
            //   During recording the card continuously pushes `0x02` voice frames (~100 frames/s), and when the user long‑presses the card’s
            //   physical key to start recording, the card pushes `0x14`. So now we can **see** the card start recording on its own.
            //
            //   `cardWatchTask` reads the cache once per tick (`pushedRecordingState`, zero I/O),
            //   and only changes state when it changes — no polling needed, and it won’t compete with downloads for `inbox`.
            //
            // ⚠️ Still does not bring `wasRecording` over: after swapping devices, the previous recording’s duration is meaningless.
            _ = wasRecording
            startCardWatch(link)
        case nil:
            break
        }
    }

    /// The device itself reports "recording / not recording".
    ///
    /// * D·NOTE — fed in by a subscription to `client.$lastDeviceInfo` (device pushes 0x54/0x55,
    ///   App’s own command toggles, 30 s slow polling, all three paths modify this value);
    /// * TicNote — fed in by `cardWatchTask` from `pushedRecordingState`
    ///   (voice frame stream + `0x14`/`0x17` events, see `RecorderLink.pushedRecordingState`).
    func noteDeviceRecordingState(_ deviceSays: Bool?) {
        // `nil` = unknown. **Cannot** be treated as "not recording" — that would reset the clock to zero when the device is silent.
        guard let deviceSays, deviceSays != isRecording else { return }
        isRecording = deviceSays
        if deviceSays {
            if startedAt == nil { startedAt = Date() }
            startPolling()
        } else {
            startedAt = nil
            deviceElapsed = nil
            stopPolling()
        }
    }

    // MARK: Card state monitoring (★ so that "pressing the card’s button to start recording" can also be seen by the App)

    /// Monitor the card’s **actively pushed** recording status / battery level.
    ///
    /// ## Why a task **independent of** `pollTask` is needed
    /// `pollTask` runs only when `isRecording == true` — whereas "the card starts recording on its own" happens
    /// **when it is false** (user long‑presses the card’s physical key). Use a constantly‑on,
    /// but **zero I/O each tick** listener to fill this gap.
    ///
    /// ## Why zero I/O is critical
    /// It runs at 1 Hz all day and should not generate any Bluetooth traffic: `pushedRecordingState` /
    /// `pushedBatteryPercent` / `pushedChargingState` read values already cached in `TicNoteLink`
    /// cached values (recorded opportunistically during voice frame switching, cached when `0x09` reply arrives),
    /// **does not send commands, does not touch `inbox`**.
    /// The I/O path remains only `pollTask`, and the single‑consumer constraint on `inbox` stays unchanged.
    ///
    /// ## Why `noteDeviceRecordingState` should not directly call `startPolling`
    /// It can be called, but **must not be invoked from within `pollTask` itself** — that would `cancel()` the current task,
    /// so after the "card stops" it would never be discovered by polling again. Separating the two tasks avoids this loop.
    private func startCardWatch(_ link: any RecorderLink) {
        stopCardWatch()
        cardWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Pure cache read: no I/O, will not contend with list/download for command lock.
                //
                // ⚠️ Assign only when the value changes — `@Published` notifies observers on every assignment,
                //    unconditionally writing once per second equates to rebuilding the entire recording page at 1 Hz.
                let battery = link.pushedBatteryPercent
                if self.cardBatteryPercent != battery { self.cardBatteryPercent = battery }
                // ★ Charging status is emitted **together with battery level in a `0x09` frame**, so this is also a pure cache read.
                //   Both must be synchronized: refreshing only battery without charging would cause "battery moves,
                //   lightning icon stays still" — a half‑dead appearance (exactly what users reported).
                let charging = link.pushedChargingState
                if self.cardCharging != charging { self.cardCharging = charging }
                self.noteDeviceRecordingState(link.pushedRecordingState)
                // The card is truly recording, but we have no anchor yet (e.g., card started recording before the App connected) →
                // first set an anchor, and subsequent `pollOnce` will correct it with the device value.
                if self.isRecording, self.startedAt == nil {
                    self.startedAt = Date()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopCardWatch() {
        cardWatchTask?.cancel()
        cardWatchTask = nil
    }

    // MARK: Derived

    /// Can it be tapped. When `false` the button appears disabled.
    var canToggle: Bool {
        guard !busy, target != nil else { return false }
        // When start recording is blocked by a command, pressing is not allowed (but **must be able to stop** ——
        // Otherwise the user would be stuck in a never‑ending recording state, see `RecordControl`'s old comment).
        return !startBlocked
    }

    /// Start recording is blocked by \"encryption passphrase not set\" (only D·NOTE has this requirement; TicNote firmware has no encryption).
    var startBlocked: Bool {
        guard !isRecording, case .dnote(let client)? = target else { return false }
        return KeyResolver.setupIncomplete(for: client)
    }

    /// Displayed recorded duration (seconds). `nil` = not started recording yet (UI shows 0:00).
    ///
    /// ⚠️ **Calculate only from the local anchor**, no longer compare device values here — device values are
    /// `adoptDeviceElapsed` already converts to "move the anchor forward".
    /// Mixing the two sources here will cause the second hand to jump back and forth between them.
    func elapsed(at now: Date) -> TimeInterval? {
        guard let startedAt else { return nil }
        return max(0, now.timeIntervalSince(startedAt))
    }

    /// Format seconds as a stopwatch (hour component appears only after one hour).
    static func clock(_ seconds: TimeInterval?) -> String {
        let s = max(0, Int((seconds ?? 0).rounded()))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Start/Stop

    func toggle() async {
        guard let target, !busy else { return }
        if startBlocked { return }
        busy = true
        notice = nil
        // Clear the previous failure message. If not cleared, after the user fixes it the button will still show the old error,
        // and they will think this attempt also failed.
        alert = nil
        defer { busy = false }

        if isRecording {
            await stop(target)
        } else {
            await start(target)
        }
    }

    private func start(_ target: Target) async {
        do {
            switch target {
            case .dnote(let client):
                try await client.startRecording()
            case .card(let link):
                try await link.startRecording()
            }
        } catch {
            alert = RecorderSessionAlert(error: error, target: target)
            // Failures also need feedback — and deliberately use a **different** haptic (see `playFailureHaptic`).
            // Only vibrate on the recording‑card path, reason in `playStartStopHaptic`.
            if case .card = target { playFailureHaptic() }
            return
        }

        isRecording = true
        startedAt = Date()
        deviceElapsed = nil
        startPolling()
        // ★ A single vibration on successful start recording. Reaching this point means **real success** for the recording card ——
        //   `link.startRecording()` waits until the card pushes `0x14`/a voice frame before returning (see below).
        if case .card = target { playStartStopHaptic() }

        // On the card side: `link.startRecording()` has already **self‑validated on the protocol layer** ——
        // It waits for `0x14` (card indicates "I am recording") or the first `0x02` voice frame before returning,
        // otherwise throws `.timeout`. So reaching this point means the card really started,
        // **no longer** the previous version's "command sent, App optimistically timed" false success.
        //
        // Read the value again here: adjust the local anchor by **device byte count** (the card may have started recording before we
        // sent the command), and conveniently refresh the battery level once.
        if case .card(let link) = target {
            if let status = try? await link.readRecordingStatus() {
                if let device = status.deviceElapsed { adoptDeviceElapsed(device) }
                // The card's self‑reported status has highest priority: if it says not recording, do not force the red dot.
                if let deviceSays = status.isRecording { noteDeviceRecordingState(deviceSays) }
            }
            cardBatteryPercent = link.pushedBatteryPercent
            // Also supplement the charging status once: this `start()` path just sent `0x09`,
            // the cache now holds the latest; without supplementing, when the red dot appears the lightning icon would still be outdated.
            cardCharging = link.pushedChargingState
            // If we reach here and it still says "not recording", there is only one possibility: the card stopped within 3 seconds after start.
            // Leave a hint so the user doesn't think it is recording.
            if !isRecording {
                notice = "The card acknowledged the command but is no longer recording. "
                       + "It may have stopped on its own — check the card itself."
            }
        }
    }

    private func stop(_ target: Target) async {
        do {
            switch target {
            case .dnote(let client):
                _ = try await client.stopRecording()
            case .card(let link):
                try await link.stopRecording()
            }
        } catch {
            alert = RecorderSessionAlert(error: error, target: target)
            if case .card = target { playFailureHaptic() }
            return
        }
        isRecording = false
        startedAt = nil
        deviceElapsed = nil
        stopPolling()
        // ★ A single vibration on successful stop recording. Uses the same haptic as start recording **identical** (`.medium`), not a different one ——
        //   Start/stop are a symmetric pair; consistent feel makes them feel like two ends of the "same switch".
        //   What truly needs distinction is "success vs failure", which is handled by `playFailureHaptic`.
        if case .card = target { playStartStopHaptic() }
    }

    // MARK: 1 Hz polling (same rule as V05E)

    private func startPolling() {
        stopPolling()
        guard target != nil else { return }
        pollTask = Task { [weak self] in
            // After start recording, **ask immediately once** (the one in `start()`), then once per second.
            // That immediate query occurs in `start()`, so here we sleep first then ask.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                await self?.pollOnce()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Query the device: "still recording, and for how long".
    ///
    /// Failure **silent**: polling once per second would flood the UI with errors; actual failures are
    /// displayed by that `toggle()` call. When the link breaks, the next `toggle()` will report it.
    private func pollOnce() async {
        guard let target else { return }
        switch target {
        case .dnote(let client):
            guard let status = try? await client.getRecordingStatus() else { return }
            // `recd` = device‑reported recorded milliseconds. **This is the true device value**, preferred over the local anchor.
            if let recd = (status["recd"] as? NSNumber)?.doubleValue, recd > 0 {
                adoptDeviceElapsed(recd / 1000)
            }
            // `rec` = device‑reported recording flag (0/1). The device's JSON **does not**
            // `isRecording` key — don't guess by name, the field is called `rec`.
            //
            // ⚠️ This line and the subscription to `client.$lastDeviceInfo` are two independent paths,
            // It is kept because this is a fresh reading "just to ask", while the subscription may lag by one frame.
            if let rec = (status["rec"] as? NSNumber)?.intValue {
                noteDeviceRecordingState(rec != 0)
            }
        case .card(let link):
            // First let the "card push" path bring the status up (pure read cache, zero I/O):
            // When the user presses stop on the card, this can reflect immediately here, without waiting for the command's response.
            noteDeviceRecordingState(link.pushedRecordingState)

            guard let status = try? await link.readRecordingStatus() else { return }
            if let device = status.deviceElapsed {
                adoptDeviceElapsed(device)
            }
            // The status in the response is **after this query**, newer than the cache.
            if let deviceSays = status.isRecording {
                noteDeviceRecordingState(deviceSays)
            }
            // Battery level is refreshed alongside this 1 Hz poll (the protocol layer appends a `0x09` after `0x03`/`0x06`
            // — this is the source of "real‑time synchronized battery".)
            if let battery = link.pushedBatteryPercent, cardBatteryPercent != battery {
                cardBatteryPercent = battery
            }
            // Charging status is in the same frame as battery, synchronized in the same pass — both must be processed together,
            // otherwise during recording you would see a half‑sync "battery rising, lightning icon static" (see `cardCharging`).
            let charging = link.pushedChargingState
            if cardCharging != charging { cardCharging = charging }
        }
    }

    /// Adopt the duration reported by the device.
    ///
    /// ★ Adopt only when the device value is **greater**, and it is "move the local anchor forward" rather than "display the device value directly":
    ///   * The larger case is real — the card may have started recording before we sent the command
    ///     (the user pressed the physical button on the card first), the device value will jump to the correct position;
    ///   * Smaller or equal cases are always ignored — the card's `0x17` is **0 at the moment of start recording**
    ///     (real device #14848 `… 01 01 00 00 00 00`). If unconditionally adopted, the clock would be stuck at this 0
    ///     pinned at 0:00, **which is exactly the bug reported by the user**.
    /// Moving the anchor instead of displaying directly keeps the second hand monotonic — alternating sources would cause jumps.
    private func adoptDeviceElapsed(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        deviceElapsed = seconds
        if let startedAt {
            let local = Date().timeIntervalSince(startedAt)
            if seconds > local + 1 {
                self.startedAt = Date().addingTimeInterval(-seconds)
            }
        } else {
            // No anchor yet (e.g., card recording before App connects) — use the device value as the anchor.
            startedAt = Date().addingTimeInterval(-seconds)
        }
    }

    /// For reuse in the device page: synchronize back the result of a "stop recording" action (e.g., user pressed stop in the recording overlay).
    func noteExternalStop() {
        isRecording = false
        startedAt = nil
        deviceElapsed = nil
        stopPolling()
    }

    // MARK: Haptic feedback for start/stop

    /// A single vibration after the user presses start/stop.
    ///
    /// ## Why the **phone** vibrates instead of "making the card vibrate"
    /// User's original words (2026-10-10):
    /// > When starting and ending recording there should be vibration prompts. The start/stop in the app can record and stop
    /// > and during recording, but there is no vibration.
    ///
    /// This sentence should be answered in two parts, with different conclusions:
    ///
    /// ### The single vibration on the card, **App cannot do** (verified, not untried)
    /// The official App's Chinese documentation makes this clear (`messages_zh_CN.dart`):
    /// * "Press and hold the power button for 2 seconds, TicNote vibrates once, the display shows recording status, indicating recording has started."
    /// * "Press and hold the power button for 2 seconds, TicNote vibrates twice, indicating recording has ended."
    ///
    /// That means it is a **firmware local behavior bound to the power key**; the path the App takes
    /// (`0x14` start recording / `0x17` stop recording) is a different branch in the firmware, without vibration.
    /// Moreover, after translating all **20 command builders** from App→card one by one
    /// (`protocol-notes.md` §6.1, including `0x28 RECORD_START` / `0x2A PAUSE` /
    /// `0x2C RESUME` / `0x2E STOP` / `0x3C DELETE_RECORD` full table),
    /// **none of them is a vibration command**; the 15 handlers from card→App also lack
    /// (the word "vibration" appears in the entire Dart snapshot only in UI haptic calls and
    /// the two product copy lines above).
    ///
    /// Therefore "make the card vibrate for the App's start/stop" **has no protocol basis** — following this repository's usual rule,
    /// do not send a guessed frame just to look finished (the cost of a wrong guess is corrupting the card's state,
    /// and the symptom would masquerade as "card broken").
    ///
    /// ### Yet the user can get what they truly want: **"I pressed it, and it worked" confirmation feeling**
    /// The user presses the **phone**, so placing this single vibration on the phone is an equivalent or even more accurate feedback ——
    /// A phone vibration can convey "success/failure", while a card vibration can only convey "the motor moved".
    ///
    /// ## Why vibrate only for recording cards (`.card`) and not for D·NOTE
    /// D·NOTE's `startRecording()` is **optimistic**: the command is sent and immediately
    /// `isRecording = true` (see `start(_:)`), the card may not have acknowledged and **does not** confirm before returning.
    /// Vibrating there would be lying to the device. TicNote is different ——
    /// `TicNoteLink.startRecording()` waits until the card pushes `0x14` or a voice frame,
    /// if not received it throws `.timeout`, so "vibrated" and "card really started" are the same.
    ///
    /// ⚠️ When "haptic feedback" is turned off in system settings, `UIFeedbackGenerator` silences itself ——
    /// We don't need to add a switch, nor should we (the user already has a system‑level toggle).
    private func playStartStopHaptic() {
        // `.medium` strength feels closest to "pressing a physical key"; `.rigid` is more like a "tab",
        // using it for stop will express "end" as a crisp click, contrasting with start as two different operations.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Failure haptic. Deliberately **different** from success: the user can distinguish "succeeded / failed" without looking at the screen.
    private func playFailureHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Failure prompt

/// The UI shown to the user when start/stop recording fails.
///
/// Define a separate type instead of throwing `Error`: D·NOTE's "not bound" should guide the user to **pair**,
/// rather than showing "operation failed" — those are two completely different things; seeing the latter the user would think the App is broken.
enum RecorderSessionAlert: Identifiable {
    /// D·NOTE not bound: provide an "go pair" exit
    case notBound(deviceName: String)
    /// Other failures: display the reason as‑is (`.unsupported` also follows this — writing it as
    /// "Unsupported" is more accurate than "failed", users won't repeatedly retry an impossible operation)
    case message(String)

    /// ⚠️ Only `init` is `@MainActor` (it reads `DnoteClient.displayName`,
    /// which is main‑thread isolated). The whole enum **cannot** be marked `@MainActor` — otherwise
    /// `Identifiable`'s `id` witness would cross actors, Swift would report "conformance crosses
    /// into main actor‑isolated code" (Swift 6 treats it as an error, now a warning).
    @MainActor
    init(error: Error, target: RecorderSessionModel.Target) {
        if case .dnote(let client) = target,
           let dnote = error as? DnoteError,
           case .notBound = dnote {
            self = .notBound(deviceName: client.displayName)
            return
        }
        if let link = error as? RecorderLinkError, case .unsupported(let detail) = link {
            self = .message("This card can't do that yet — \(detail)")
            return
        }
        self = .message(error.localizedDescription)
    }

    var id: String {
        switch self {
        case .notBound: return "not-bound"
        case .message(let text): return "error-\(text)"
        }
    }

    var title: String {
        switch self {
        case .notBound: return L10n.Pairing.title
        case .message: return L10n.DeviceFiles.operationFailed
        }
    }

    var body: String {
        switch self {
        case .notBound(let name): return L10n.Pairing.message(name)
        case .message(let text): return text
        }
    }
}

// MARK: - Recording control

/// Recording start/stop button + running stopwatch. Placed in the **header** of the "Recording" tab (same row as the segment control).
///
/// Why here instead of the device page: V05E places it this way (`RecordControl` in the tab header),
/// and it has a practical reason — **recording control should not follow the segment control selection**:
/// When the user switches to "Library" to browse recordings, the recording button must stay in place and remain tappable.
/// If hidden in the device page, the button disappears when switching to the library.
///
/// ⚠️ The stopwatch is driven by `TimelineView(.periodic)`, **not** "recalculate only when some @State changes".
/// The latter never changes during recording (no per‑second state), so the clock stays at 0:00 forever ——
/// This is a bug reported by users; do not revert it.
struct RecorderControl: View {

    @ObservedObject var model: RecorderSessionModel

    /// `TimelineView` phase anchor. Use **epoch** instead of `.now`:
    /// `from: .now` resets the phase each time the body is recomputed, causing the second hand to be repeatedly delayed.
    /// Anchoring to the epoch is equivalent to "align to whole seconds", independent of body recomputation count.
    ///
    /// ⚠️ `internal` (not private): the device page status line also uses it — both places must share the **same** phase anchor,
    /// otherwise the button's second hand in the header and the one in the page will be half a beat off, appearing stuck.
    static let tickAnchor = Date(timeIntervalSince1970: 0)

    private var symbolName: String { model.isRecording ? "stop.circle.fill" : "record.circle" }

    private var tint: Color {
        !model.canToggle && !model.isRecording ? .gray : .red
    }

    var body: some View {
        HStack(spacing: 6) {
            if model.isRecording {
                TimelineView(.periodic(from: Self.tickAnchor, by: 1)) { context in
                    Text(RecorderSessionModel.clock(model.elapsed(at: context.date)))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.red)
                        // Fixed width to prevent the button from jumping when the time changes from 9:59 to 10:00
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            Button {
                Task { await model.toggle() }
            } label: {
                ZStack {
                    Image(systemName: symbolName)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundColor(tint)
                        .opacity(model.busy ? 0.3 : 1)
                    if model.busy {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canToggle)
            .accessibilityLabel(model.isRecording ? L10n.DeviceFiles.stopRecording : L10n.Common.recording)
        }
        .animation(.none, value: model.isRecording)
    }
}
