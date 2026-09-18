import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "launch")

/// Composition root. Holds long-lived services (BLE, config, library) and is
/// injected as an `@EnvironmentObject` at the root.
@MainActor
final class AppEnvironment: ObservableObject {
    let bluetooth: BluetoothCoordinator
    let config: ConfigService
    let library: Library
    let transcription: TranscriptionService
    /// UI language override. Built from `config.json` so the choice survives
    /// relaunches; `nil` inside means follow the system.
    let localization: LocalizationService
    let watch: WatchSyncService
    @Published var isStreaming = false
    @Published var isBLETransferring = false
    /// Set by DeviceFilesView while the Device segment is on screen.
    /// RootView calls it when the user confirms switching away mid-transfer.
    var cancelBLETransfers: (() -> Void)?
    @Published var navigateToASRProviders = false
    @Published var navigateToLLMProviders = false
    /// Set by the device-tab encryption-onboarding banner to deep-link
    /// straight into Recordings settings with the passphrase sheet open.
    @Published var navigateToRecordingsSettings = false
    @Published var openPassphraseSheet = false
    /// Set by recording UI when an unpaired-device error needs to open the
    /// current device sheet and expose its pairing banner.
    @Published var openDeviceSheetForPairing = false

    /// The live composition root, for the one caller SwiftUI's environment
    /// can't reach: `ToggleRecordingIntent` runs in this process but outside
    /// any view hierarchy. Weak so it can't outlive the scene that owns it, and
    /// read-only so nothing else is tempted to reach for services this way
    /// instead of taking them as `@EnvironmentObject`.
    private(set) static weak var shared: AppEnvironment?

    init() {
        // This runs before SwiftUI's first frame, so anything slow in here is
        // time the user spends staring at the launch screen. Timed per service
        // rather than in total: when the launch screen hangs, "which one" is
        // the only question worth answering (see README → Logs).
        let startedAt = Date()
        let config = ConfigService()
        let afterConfig = Date()
        let bluetooth = BluetoothCoordinator()
        let afterBluetooth = Date()
        let library = Library()
        let afterLibrary = Date()
        let transcription = TranscriptionService(config: config)
        let afterTranscription = Date()
        self.bluetooth = bluetooth
        self.config = config
        self.library = library
        self.transcription = transcription
        self.localization = LocalizationService(selected: config.config.appLanguage)
        self.watch = WatchSyncService(
            config: config,
            library: library,
            transcription: transcription
        )
        // Activated here rather than from a view: the watch can wake this app
        // in the background, and the session has to be live before the first
        // clip arrives. The WatchConnectivity work itself is
        // dispatched off the main thread — see `WatchSyncService.activate`.
        self.watch.activate()
        Self.shared = self
        let done = Date()
        log.notice("""
            environment ready in \(Self.ms(startedAt, done)) ms \
            (config=\(Self.ms(startedAt, afterConfig)) \
            ble=\(Self.ms(afterConfig, afterBluetooth)) \
            library=\(Self.ms(afterBluetooth, afterLibrary)) \
            asr=\(Self.ms(afterLibrary, afterTranscription)) \
            watch=\(Self.ms(afterTranscription, done)))
            """)
    }

    private static func ms(_ from: Date, _ to: Date) -> Int {
        Int(to.timeIntervalSince(from) * 1000)
    }
}
