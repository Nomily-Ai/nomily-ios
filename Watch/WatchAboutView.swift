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
        }
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
