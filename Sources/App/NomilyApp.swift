import SwiftUI
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "launch")

@main
struct NomilyApp: App {
    /// Stamped the moment this app's own code first runs, and compared against
    /// the first frame below. A launch-screen hang is then attributable: a
    /// small number here with a long wait on screen means the time went to
    /// system-side work around us (dyld, bundle validation, handing the
    /// embedded watch app to the paired watch), not to our code.
    static let appInitAt = Date()

    @StateObject private var environment = AppEnvironment()

    init() {
        _ = Self.appInitAt  // `static let` is lazy; touch it so it stamps now
    }

    var body: some Scene {
        WindowGroup {
            LocalizedRoot()
                .environmentObject(environment)
                .environmentObject(environment.bluetooth)
                .environmentObject(environment.config)
                .environmentObject(environment.library)
                .environmentObject(environment.transcription)
                .environmentObject(environment.localization)
                // Injected in its own right, not reached through `environment`:
                // a nested ObservableObject's @Published changes don't
                // invalidate views observing only the parent.
                .environmentObject(environment.watch)
                .onAppear {
                    let ms = Int(Date().timeIntervalSince(Self.appInitAt) * 1000)
                    log.notice("first frame \(ms) ms after app init")
                }
        }
    }
}

/// Re-renders the whole UI when the language changes.
///
/// `L10n` reads are plain function calls, so a view that doesn't observe
/// `LocalizationService` has no reason to re-evaluate its body and would keep
/// showing the old language. The `.id` forces a fresh subtree — a wholesale
/// redraw that also lands back on the root screen.
private struct LocalizedRoot: View {
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        RootView()
            // Dates, numbers and RTL follow the chosen language too — otherwise
            // the text switches to Arabic while the layout stays left-to-right.
            .environment(\.locale, Locale(identifier: localization.effective))
            .environment(\.layoutDirection, localization.layoutDirection)
            .id(localization.selected ?? "system")
    }
}
