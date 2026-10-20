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
        // ★ The unread ledger must be built **at launch**, not when the Library is opened.
        //
        // `origin` ("the moment this feature shipped") is taken lazily — if it waited until the user
        // first opened the Library to be built, then on the most common path — "the app is already running, a card just finished transferring one, and only then you tap into
        // the Library" — the arrival time would precede `origin`, and that new recording
        // would **never get a red dot**. Touching it at launch places origin before any transfer.
        _ = ClipReadStore.shared
        // ★ The trash's "auto-delete after 30 days" gets its first run from here.
        //
        // There's no `BGTaskScheduler` to hang it on (that needs an extra background-mode declaration, and when the system
        // actually schedules it is entirely beyond our control), so expiry cleanup can only hang off two points the user
        // is bound to pass through: **launch** (here) and **opening the trash** (`TrashView`).
        // Running it at launch has an extra benefit — cleanup happens before any screen reads the disk, so expired entries
        // aren't first counted into that count badge on the settings page and then "lose one by themselves".
        _ = ClipTrash.shared.purgeExpired()
        // Disk‑based diagnostic **session separator line**. Two purposes:
        //   1. Ensure `Documents/ticnote-ble.log` always exists — otherwise "user never connected a card"
        //      and "diagnostic not effective" looks identical (both lack this file), cannot be distinguished;
        //   2. Logs from multiple launches are appended to the same file, and this line splits sections,
        //      so we can answer "which launch this record belongs to".
        TicNoteDiagLog.log("DIAG", "App launch — ticnote diagnostic start")
    }

    var body: some Scene {
        WindowGroup {
            LocalizedRoot()
                .environmentObject(environment)
                .environmentObject(environment.bluetooth)
                .environmentObject(environment.config)
                .environmentObject(environment.library)
                .environmentObject(environment.transcription)
                // ★ 2026-10-16 twelfth revision: the background job queue (summary / translation / format conversion).
                // Same reason as `watch` — changes to a nested ObservableObject's `@Published`
                // don't invalidate a view that observes only the parent object, so without injecting it separately the detail page and
                // the background-jobs page would stay stuck on the old state ("the job finished but the UI doesn't update").
                .environmentObject(environment.jobs)
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

    @State private var linkNotice: String?
    @State private var linkNoticeTitle: String?
    /// ★ (2026-10-19) Branded splash: the system launch screen is a bare red page; the logo
    /// now stays on it for a beat before the app is revealed. Purely presentational — the
    /// root is laid out underneath from the first frame, so nothing is blocked.
    @State private var splashVisible = true

    var body: some View {
        RootView()
            // Dates, numbers and RTL follow the chosen language too — otherwise
            // the text switches to Arabic while the layout stays left-to-right.
            .environment(\.locale, Locale(identifier: localization.effective))
            .environment(\.layoutDirection, localization.layoutDirection)
            .id(localization.selected ?? "system")
            .overlay {
                if splashVisible {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .task {
                // Hold the logo for a second, then fade. `task` starts with the first frame,
                // so the beat is measured from what the user actually sees.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                withAnimation(.easeOut(duration: 0.3)) {
                    splashVisible = false
                }
            }
            // ★ `nomily-a1://import/…` — how a QR code scanned with the system Camera app (or
            // a tapped link in a chat) becomes a stored credential. The in-app scanner calls
            // the same parser; this is only the "already outside the app" entry point.
            //
            // Registering the scheme is worth it even with the scanner available: a code read
            // by the Camera app needs *some* handler, and without one iOS shows a dead URL.
            .onOpenURL { url in handleIncoming(url) }
            .alert(linkNoticeTitle ?? "", isPresented: Binding(
                get: { linkNotice != nil },
                set: { if !$0 { linkNotice = nil; linkNoticeTitle = nil } }
            )) {
                Button(L10n.Common.ok, role: .cancel) { linkNotice = nil; linkNoticeTitle = nil }
            } message: {
                Text(linkNotice ?? "")
            }
    }

    private func handleIncoming(_ url: URL) {
        linkNoticeTitle = L10n.A1.importedFromLink
        do {
            let credential = try DingTalkA1Credential.parse(link: url)
            DingTalkA1CredentialStore.save(credential)
            linkNotice = L10n.A1.importedFromLinkBody(credential.displayName)
        } catch {
            linkNoticeTitle = L10n.A1.importFailed
            linkNotice = L10n.A1.scanFailed
        }
    }
}

/// The one-second branded splash: same red as the launch screen, the app mark floating
/// in the middle. No interaction, no progress — a beat of brand before the app appears.
private struct SplashView: View {
    var body: some View {
        Color.accentColor
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 22) {
                    Image("NomiLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 116, height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 6)

                    // App name in SF Pro (the system font) — the closest thing
                    // to an "Apple-style" wordmark without shipping a custom face.
                    Text("Nomily AI")
                        .font(.system(size: 30, weight: .semibold, design: .default))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.96))
                }
            }
            .ignoresSafeArea()
    }
}
