import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "live-caption")

/// Live captions for the **phone microphone** recording (★ 2026-10-22, 任务一).
///
/// ## What it borrows
/// The PCM engine abstraction built for the PLAUD card (`PlaudLiveASR`) is
/// source-agnostic: `PlaudAzureLiveTranscriber` takes 16 kHz mono PCM over the
/// Azure Speech WebSocket (with the turn-end protocol handled), and
/// `PlaudLiveTranscriber` is the on-device Apple Speech fallback. This
/// controller wires the phone mic's PCM into the same engine chain, so the
/// provider selection, fallback seeding and clock formatting all behave
/// exactly like the card's live transcript.
///
/// ## Degradation ladder (任务一 requirement 3)
/// 1. Chain pick: user's `defaults.asr` (Azure-capable only — PCM), then
///    on-device.
/// 2. Azure dies mid-take → fall back to on-device and **seed** the text that
///    is already on screen (nothing the user read disappears).
/// 3. Nothing at all (no permission / no model / no Azure) → honest notice,
///    recording keeps going. A recording must never depend on ASR.
///
/// ## Telemetry (任务一 requirement 4)
/// `record_live_caption_show` on the first final line, `record_live_caption_fail`
/// when every engine is unavailable.
@MainActor
final class LiveCaptionController: ObservableObject {

    @Published private(set) var segments: [PlaudLiveSegment] = []
    @Published private(set) var partial: String = ""
    /// "azure" / "ondevice"; empty = no engine (captions off).
    @Published private(set) var providerName: String = ""
    /// Non-fatal notice (fallback happened / model missing). nil = healthy.
    @Published private(set) var notice: String?
    /// True once any text reached the screen this session (telemetry gate).
    private var didShow = false
    private var engine: (any PlaudLiveASR)?

    var hasText: Bool { !segments.isEmpty || !partial.isEmpty }

    /// Build the engine chain and start consuming PCM from the next `append`.
    func start(config: AppConfig) {
        stop()
        guard let engine = makeEngine(config: config) else {
            notice = L10n.Phone.captionUnavailable
            Telemetry.failed("record_live_caption", reason: "no_engine")
            return
        }
        attach(engine)
    }

    func append(_ pcm: Data, elapsed: TimeInterval) {
        engine?.append(pcm, elapsed: elapsed)
    }

    /// Stop consuming. Text stays on screen (same rule as the card's panel).
    func stop() {
        engine?.stop()
        engine = nil
    }

    /// Clear for a new take.
    func reset() {
        stop()
        segments = []
        partial = ""
        notice = nil
        providerName = ""
        didShow = false
    }

    /// The transcript so far, one line per segment (+ trailing partial).
    func joinedText() -> String {
        PlaudDirectService.joinedTranscript(segments, partial: partial)
    }

    // MARK: - Engine wiring (mirrors PlaudDirectService's live pipeline)

    private func makeEngine(config: AppConfig) -> (any PlaudLiveASR)? {
        let localeID = PlaudDirectService.bcp47Language(config.lastSourceLang)
        var chain: [String] = []
        // ★ 2026-10-23: honour the pinned live engine first, like the other two paths.
        if let live = config.defaults.asr.liveProvider, !live.isEmpty { chain.append(live) }
        chain.append(contentsOf: [config.defaults.asr.primary] + config.defaults.asr.fallbacks)
        chain.append("ondevice")
        for name in chain.map({ $0.lowercased() }) where !name.isEmpty {
            switch name {
            case "azure":
                if let azure = config.asrProviders.azure,
                   !azure.key.isEmpty, !azure.region.isEmpty {
                    log.info("phone captions engine=azure lang=\(localeID, privacy: .public)")
                    return PlaudAzureLiveTranscriber(key: azure.key, region: azure.region,
                                                     lang: localeID)
                }
            case "aliyun":
                // ★ 2026-10-23: the phone mic also produces 16 kHz mono PCM, so the
                // Aliyun real-time engine works here unchanged.
                if let cloud = config.asrProviders.cloud?["aliyun"],
                   !(cloud.secrets?["accessKeyId"] ?? "").isEmpty,
                   !(cloud.secrets?["accessKeySecret"] ?? "").isEmpty,
                   !(cloud.values?["appKey"] ?? "").isEmpty {
                    let region = (cloud.values?["region"].flatMap { $0.isEmpty ? nil : $0 })
                        ?? "cn-shanghai"
                    log.info("phone captions engine=aliyun region=\(region, privacy: .public)")
                    return PlaudAliyunLiveTranscriber(
                        accessKeyId: cloud.secrets?["accessKeyId"] ?? "",
                        accessKeySecret: cloud.secrets?["accessKeySecret"] ?? "",
                        appKey: cloud.values?["appKey"] ?? "",
                        region: region)
                }
            case "ondevice":
                guard config.onDeviceASREnabled != false else { continue }
                if let engine = PlaudLiveTranscriber.makeIfPermitted(localeID: config.lastSourceLang) {
                    log.info("phone captions engine=ondevice")
                    return engine
                }
            default:
                // local / remote / custom: Opus-only — the phone mic produces PCM.
                continue
            }
        }
        return nil
    }

    private func attach(_ engine: any PlaudLiveASR) {
        self.engine?.stop()
        engine.onTextChange = { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.segments = engine.segments
            self.partial = engine.partial
            if !self.didShow, !engine.segments.isEmpty {
                self.didShow = true
                Telemetry.success("record_live_caption_show",
                                  ["provider": engine.providerName])
            }
        }
        engine.onFailure = { [weak self] reason in
            Task { @MainActor in self?.fallback(reason: reason) }
        }
        engine.start()
        switch engine.unavailable {
        case .modelMissing: notice = L10n.Plaud.liveModelMissing
        case .noRecognizer, .notAuthorized, .azureMissing, .aliyunMissing:
            notice = L10n.Plaud.liveNeedsPermission
        case .azureFailed(let message): notice = L10n.Plaud.liveAzureFailed(message)
        case .aliyunFailed(let message): notice = L10n.Plaud.liveAliyunFailed(message)
        case .none: notice = nil
        }
        providerName = engine.providerName
        self.engine = engine
        TicNoteDiagLog.log("PHONE-CAPTION", "engine=\(engine.providerName) notice=\(notice ?? "none")")
    }

    /// Azure died mid-take: keep the text and continue on-device.
    private func fallback(reason: PlaudLiveASRUnavailable) {
        let dead = engine?.providerName
        guard dead == "azure" || dead == "aliyun" else { return }
        log.warning("phone captions: \(dead ?? "?", privacy: .public) failed (\(String(describing: reason), privacy: .public)) — falling back to on-device")
        guard let config = AppEnvironment.shared?.config.config,
              let onDevice = PlaudLiveTranscriber.makeIfPermitted(localeID: config.lastSourceLang) else {
            notice = L10n.Plaud.liveNeedsPermission
            Telemetry.failed("record_live_caption", reason: "fallback_unavailable")
            return
        }
        onDevice.seed(segments: segments)
        attach(onDevice)
        notice = L10n.Plaud.liveAzureFellBack
    }
}
