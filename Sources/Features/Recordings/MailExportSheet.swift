import MessageUI
import SwiftUI
import UIKit

/// Email export with attachment picker (★ 2026-10-22, 任务二).
///
/// Plaud ships this as the workflow action
/// `Workflow_send_email_attachments_{summary|transcription|mindmap}` —
/// "send email with the summary / the transcript / the mind map" is a proven
/// high-frequency path, so the composer offers exactly those three (greyed
/// out when the artefact doesn't exist). Only the design intent is copied;
/// wording and layout are Nomily's own.
struct MailExportSheet: View {
    let clipName: String
    @Environment(\.dismiss) private var dismiss
    @State private var attachSummary = false
    @State private var attachTranscript = true
    @State private var attachMindMap = false
    @State private var showComposer = false
    @State private var errorText: String?

    private var hasSummary: Bool { DocumentExporter.hasSummary(clipName) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $attachSummary) {
                        Text(L10n.ClipDetail.emailAttachSummary)
                    }
                    .disabled(!hasSummary)
                    Toggle(isOn: $attachTranscript) {
                        Text(L10n.ClipDetail.emailAttachTranscript)
                    }
                    Toggle(isOn: $attachMindMap) {
                        Text(L10n.ClipDetail.emailAttachMindMap)
                    }
                    .disabled(!hasSummary)
                } footer: {
                    Text(L10n.ClipDetail.emailAttachFooter)
                }
                Section {
                    Button {
                        send()
                    } label: {
                        Label(L10n.ClipDetail.emailCompose, systemImage: "envelope")
                    }
                }
                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.ClipDetail.emailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
            .onAppear {
                // Pre-tick only what actually exists.
                attachSummary = hasSummary
                attachMindMap = false
            }
            .sheet(isPresented: $showComposer) {
                MailComposerView(clipName: clipName,
                                 includeSummary: attachSummary,
                                 includeTranscript: attachTranscript,
                                 includeMindMap: attachMindMap)
            }
        }
    }

    private func send() {
        guard MFMailComposeViewController.canSendMail() else {
            errorText = L10n.ClipDetail.emailUnavailable
            return
        }
        var chosen: [String] = []
        if attachSummary { chosen.append("summary") }
        if attachTranscript { chosen.append("transcript") }
        if attachMindMap { chosen.append("mindmap") }
        Telemetry.event("export_email_attach_select", ["attachments": chosen.joined(separator: ",")])
        showComposer = true
    }
}

// MARK: - Composer

/// `MFMailComposeViewController` wrapper that assembles the chosen attachments
/// and fires `export_email_success/_failed` when the compose sheet closes.
struct MailComposerView: UIViewControllerRepresentable {
    let clipName: String
    let includeSummary: Bool
    let includeTranscript: Bool
    let includeMindMap: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let stem = (clipName as NSString).deletingPathExtension
        let vc = MFMailComposeViewController()
        vc.setSubject(String(format: L10n.ClipDetail.emailSubjectFormat, stem))
        vc.setMessageBody(L10n.ClipDetail.emailBody, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        context.coordinator.clipName = clipName

        var failures: [String] = []
        do {
            if includeTranscript {
                let text = try DocumentExporter.transcriptText(for: clipName)
                if let data = text.data(using: .utf8) {
                    vc.addAttachmentData(data, mimeType: "text/plain", fileName: "\(stem).txt")
                }
            }
            if includeSummary {
                let text = try DocumentExporter.summaryText(for: clipName)
                if let data = text.data(using: .utf8) {
                    vc.addAttachmentData(data, mimeType: "text/markdown", fileName: "\(stem).md")
                }
            }
            if includeMindMap {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = try DocumentExporter.export("png", clipName: clipName, into: dir)
                if let data = try? Data(contentsOf: url) {
                    vc.addAttachmentData(data, mimeType: "image/png",
                                         fileName: url.lastPathComponent)
                }
            }
        } catch {
            failures.append(error.localizedDescription)
        }
        context.coordinator.failures = failures
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var clipName: String = ""
        var failures: [String] = []

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            switch result {
            case .sent:
                Telemetry.success("export_email", ["clip": clipName])
            case .failed:
                Telemetry.failed("export_email", reason: error?.localizedDescription ?? "unknown")
            default:
                break // cancelled / saved: neither a conversion nor a failure
            }
            controller.dismiss(animated: true)
        }
    }
}
