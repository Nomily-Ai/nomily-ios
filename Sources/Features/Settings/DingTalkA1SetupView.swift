import SwiftUI
import UIKit

/// Import / manage the DingTalk A1's per-card credential.
///
/// ## Where this page lives
/// ⚠️ **Not in Settings** (as of 2026-10-18). The user's words:
/// > "The A1 recorder card's key should not appear in the app's general settings — it is not a
/// >  general setting, it belongs to one specific recording product."
///
/// So this page is now reached **from one card's device-info page** (`A1CredentialSection`)
/// and carries that card's identity in `focusTail` / `focusCardName`. It is the "how do I even
/// get this secret" explainer — the import buttons themselves sit on the card's own page, one
/// tap away, because that is where the user is standing when they realise the key is missing.
///
/// ## Why the explainer still has to exist
///
/// There is exactly one step of this process that **cannot** be moved into the app — the secret
/// only exists inside an authenticated DingTalk session — so the page's job is to make the
/// remaining step as small as it can be:
///
///   before: read a README → find the log file → run a Python **module** → find the JSON it
///           printed → get that file onto the phone;
///   after:  run one command → it copies one line to the clipboard → paste that line.
///
/// Everything after that is offline. It is worth stating plainly in the UI, because "another
/// cloud account" is what people understandably assume when asked to "import a credential".
struct DingTalkA1SetupView: View {

    @EnvironmentObject private var configService: ConfigService

    /// SN tail of the card we came from (`"0655"`). `nil` when opened without a card context.
    var focusTail: String?

    /// Display name of that card, used as the page title so it never reads as a global screen.
    var focusCardName: String?

    @State private var pasted = ""
    @State private var errorMessage: String?
    @State private var imported: DingTalkA1Credential?
    @State private var cards: [DingTalkA1Credential] = DingTalkA1CredentialStore.all()
    @State private var pendingDeletion: DingTalkA1Credential?
    @State private var commandDraft: String?
    @State private var showingScanner = false
    @State private var scannedCode: String?

    /// Raised when the imported secret belongs to a **different** card than the one we came from.
    @State private var mismatch: String?

    /// Generic fallback for the extractor command. **No absolute paths here** — the script
    /// lives wherever the user put it, so the default is a bare script name and the field
    /// below is editable (persisted in `config.a1ExtractCommand`). The first version of this
    /// page hard-coded this developer's own `~/Desktop/TicNote/…` path, which read as an
    /// error on anyone else's machine.
    ///
    /// `--qr` is part of the default because it is the transfer path that doesn't depend on
    /// Handoff: the extractor draws the code, the phone's camera reads it.
    private static let defaultCommand =
        "python3 extract_secret_from_dingtalk_mac.py --copy --qr"

    /// What the copy button copies: the user's edited command, else the default.
    private var effectiveCommand: String {
        let draft = commandDraft ?? configService.config.a1ExtractCommand ?? Self.defaultCommand
        return draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultCommand
            : draft
    }

    private func commitCommand() {
        let value = commandDraft?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Empty → back to the default (stored as nil, so a future default change propagates).
        configService.config.a1ExtractCommand = value.isEmpty ? nil : value
        configService.scheduleSave()
    }

    var body: some View {
        Form {
            Section {
                // Says "this is about THAT card" before any instructions, so nobody reads the
                // page as an app-wide account setting (the exact misreading that made this
                // screen move out of Settings).
                if let focusCardName {
                    Label(L10n.A1.scopedTo(focusCardName), systemImage: "sdcard")
                        .font(.callout.weight(.medium))
                }
                Text(L10n.A1.intro)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                step(number: 1, title: L10n.A1.step1Title, body: L10n.A1.step1Body)
                step(number: 2, title: L10n.A1.step2Title, body: L10n.A1.step2Body)
                step(number: 3, title: L10n.A1.step3Title, body: L10n.A1.step3Body)
            }

            Section {
                TextField(L10n.A1.commandEditorTitle, text: Binding(
                    get: { commandDraft ?? configService.config.a1ExtractCommand ?? Self.defaultCommand },
                    set: { commandDraft = $0 }
                ))
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { commitCommand() }
                HStack {
                    Button {
                        commitCommand()
                        UIPasteboard.general.string = effectiveCommand
                    } label: {
                        Label(L10n.A1.copyCommand, systemImage: "doc.on.doc")
                    }
                    Spacer()
                    if commandDraft != nil {
                        // Discard the draft without forcing the user to retype the default.
                        Button(L10n.Common.cancel, role: .cancel) { commandDraft = nil }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text(L10n.A1.commandEditorTitle)
            } footer: {
                Text(L10n.A1.commandEditorFooter)
            }

            Section {
                TextEditor(text: $pasted)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 88)
                    .overlay(alignment: .topLeading) {
                        if pasted.isEmpty {
                            Text(L10n.A1.pastePlaceholder)
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Button {
                        if let text = UIPasteboard.general.string { pasted = text }
                    } label: {
                        Label(L10n.A1.pasteFromClipboard, systemImage: "doc.on.clipboard")
                    }
                    Spacer()
                    Button(L10n.A1.importAction) { performImport(pasted) }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // ★ QR sits **above** the paste box in intent, not in layout: the extractor
                // prints the code, the phone reads it, and the clipboard (the part that silently
                // doesn't work when Handoff is off) drops out of the loop.
                Button {
                    showingScanner = true
                } label: {
                    Label(L10n.A1.scanAction, systemImage: "qrcode.viewfinder")
                }
            } header: {
                Text(L10n.A1.pasteSection)
            } footer: {
                Text(L10n.A1.pasteFooter)
            }

            if let mismatch {
                Section {
                    Label(mismatch, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            if let imported {
                Section {
                    LabeledContent(L10n.A1.cardName, value: imported.displayName)
                    LabeledContent(L10n.A1.cardSN, value: imported.sn.isEmpty ? "—" : imported.sn)
                    LabeledContent(L10n.A1.cardSecret, value: imported.maskedSecret)
                    Label(L10n.A1.importedOK, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.appAccent)
                } header: {
                    Text(L10n.A1.importedHeader)
                }
            }

            if !visibleCards.isEmpty {
                Section {
                    ForEach(Array(visibleCards.enumerated()), id: \.offset) { _, card in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(card.displayName)
                            Text("SN \(card.sn.isEmpty ? "—" : card.sn) · \(card.maskedSecret)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDeletion = card
                            } label: {
                                Label(L10n.Common.delete, systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text(L10n.A1.cardsHeader)
                } footer: {
                    Text(L10n.A1.cardsFooter)
                }
            }
        }
        .navigationTitle(focusCardName ?? L10n.A1.title)
        .navigationBarTitleDisplayMode(.inline)
        // ★ The scan result is imported **after** the scanner sheet has closed, not from inside
        // its callback: the failure path raises an alert, and an alert presented by a view that
        // is simultaneously being dismissed is dropped — the scanner would just vanish and
        // "nothing happened", which is the exact complaint this whole change is about.
        .sheet(isPresented: $showingScanner) {
            QRScannerSheet { code in scannedCode = code }
        }
        .onChange(of: showingScanner) { isShowing in
            guard !isShowing, let code = scannedCode else { return }
            scannedCode = nil
            performImport(code)
        }
        .alert(L10n.A1.importFailed, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.Common.ok, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(L10n.A1.deleteTitle, isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button(L10n.Common.delete, role: .destructive) {
                if let card = pendingDeletion {
                    DingTalkA1CredentialStore.remove(card)
                    cards = DingTalkA1CredentialStore.all()
                }
                pendingDeletion = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(L10n.A1.deleteMessage)
        }
    }

    // MARK: Pieces

    /// When we came from a specific card, only that card's row is relevant — showing the other
    /// cards here would re-create the "this is a list of app-level credentials" impression that
    /// this screen was moved out of Settings to avoid.
    private var visibleCards: [DingTalkA1Credential] {
        guard let focusTail, !focusTail.isEmpty else { return cards }
        return cards.filter { $0.sn.hasSuffix(focusTail) }
    }

    private func step(number: Int, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number). \(title)")
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func performImport(_ raw: String) {
        do {
            let credential = try DingTalkA1Credential.parse(scanned: raw)
            DingTalkA1CredentialStore.save(credential)
            cards = DingTalkA1CredentialStore.all()
            imported = credential
            pasted = ""
            // Same warning as the card's own page: two A1s look identical in a list, so
            // "which secret did I just import" is worth one line of confirmation.
            if let focusTail, !focusTail.isEmpty, !credential.sn.hasSuffix(focusTail) {
                mismatch = L10n.A1.mismatch(credential.sn.isEmpty ? "—" : credential.sn, focusTail)
            } else {
                mismatch = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
