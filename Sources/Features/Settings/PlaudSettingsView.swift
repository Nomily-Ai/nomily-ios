import SwiftUI

/// PLAUD cloud sync settings — the "cloud mode" half of the dual-mode PLAUD
/// support (2026-10-21). Sign in with the **consumer PLAUD account** (email +
/// OTP code); Nomily then pulls the original Opus audio the official app
/// uploaded and re-transcribes it with the user's own ASR/LLM keys. The
/// official app is never touched.
struct PlaudSettingsView: View {
    @ObservedObject private var plaud = PlaudCloudService.shared
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var message: String?
    @State private var syncSummary: String?

    var body: some View {
        Form {
            if plaud.isSignedIn {
                connectedSection
                syncSection
                guideSection
                signOutSection
            } else {
                signInSection
                guideSection
            }
        }
        .navigationTitle(L10n.Plaud.navTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sign in

    private var signInSection: some View {
        Section {
            TextField(L10n.Plaud.emailPlaceholder, text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if codeSent {
                TextField(L10n.Plaud.codePlaceholder, text: $code)
                    .keyboardType(.numberPad)
                Button(L10n.Plaud.signIn) { Task { await signIn() } }
                    .disabled(busy || code.isEmpty || email.isEmpty)
            } else {
                Button(L10n.Plaud.sendCode) { Task { await sendCode() } }
                    .disabled(busy || email.isEmpty)
            }
            if busy { ProgressView() }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Plaud.signInHeader)
        }
    }

    private func sendCode() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await plaud.sendCode(to: email)
            codeSent = true
            message = L10n.Plaud.codeSent
        } catch {
            message = error.localizedDescription
        }
    }

    private func signIn() async {
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await plaud.verify(code, email: email)
            code = ""
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Connected

    private var connectedSection: some View {
        Section {
            LabeledContent(L10n.Plaud.accountLabel, value: plaud.email ?? "")
        } header: {
            Text(L10n.Plaud.connectedHeader)
        }
    }

    private var syncSection: some View {
        Section {
            Button(L10n.Plaud.syncNow) { Task { await sync() } }
                .disabled(busy)
            if busy { ProgressView() }
            if let syncSummary {
                Text(syncSummary).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Plaud.syncHeader)
        } footer: {
            Text(L10n.Plaud.syncFooter)
        }
    }

    private func sync() async {
        busy = true
        syncSummary = nil
        defer { busy = false }
        do {
            let (done, skipped) = try await PlaudCloudService.shared.syncAll { _, _, _ in }
            syncSummary = L10n.Plaud.syncResult(done, skipped)
        } catch {
            syncSummary = error.localizedDescription
        }
    }

    private var signOutSection: some View {
        Section {
            Button(L10n.Plaud.signOut, role: .destructive) {
                plaud.signOut()
                codeSent = false
            }
        }
    }

    // MARK: - Guide

    /// Explains the model honestly: where the audio comes from, who
    /// transcribes it, and what the official app is (and isn't) doing.
    private var guideSection: some View {
        Section {
            Label(L10n.Plaud.guideAudio, systemImage: "waveform")
            Label(L10n.Plaud.guideKeys, systemImage: "key")
            Label(L10n.Plaud.guideOfficialApp, systemImage: "checkmark.shield")
        } header: {
            Text(L10n.Plaud.guideHeader)
        }
    }
}
