import SwiftUI

/// Version readout for the wrist.
///
/// The watch app otherwise shows nothing that distinguishes one build from the
/// next, which makes "did my new build actually reach the watch?" unanswerable
/// from the watch itself — the companion propagates updates on its own
/// schedule, minutes after the iPhone app is replaced.
struct WatchAboutView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "applewatch")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(Self.appVersion)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            // ★ 2026-11-03（用户："手表只放短提示"）：完整的免责声明在手机的首启同意页上，
            //   腕上只放这一句——手表屏幕放不下三段条款，也不该在抬腕 3 秒的地方去读法律文本。
            //   措辞与同意页第一条、第二条一一对应，不另起一套说法。
            Text(L10n.Consent.watchHint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L10n.Settings.version)
    }

    /// `1.0.2 (3)` — same shape the iPhone Settings screen uses, so the two can
    /// be compared at a glance.
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
