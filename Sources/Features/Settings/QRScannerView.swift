import AVFoundation
import SwiftUI

// MARK: - QR scanner for the DingTalk A1 credential
//
// ## Why a camera scanner, and not "just paste it"
//
// The credential lives on a **computer** (that is where the DingTalk desktop log is) and has
// to end up on the **phone**. Pasting depends on Universal Clipboard / Handoff actually being
// on and in range — when it silently isn't, the button looks broken. A QR code on the Mac's
// screen and a camera here is the one transfer path that needs no account, no pairing and no
// network, which is what "scan the card in" should mean.
//
// Implementation notes that matter:
//
// * **`AVCaptureMetadataOutput` is added after the session's inputs**, not before. Adding it
//   to a session with no input throws at runtime, and the crash reads as "camera unusable".
// * **The delegate fires on a background queue** — the callback is hopped to the main actor,
//   and a `hasFired` flag stops the same code from being delivered several times while the
//   sheet is dismissing (which would import twice and show two alerts).
// * **Simulator has no capture device** — that is a normal, explainable state, so it renders
//   an explanation instead of a black rectangle.

/// The bare camera preview + detection. Wrapped by `QRScannerSheet`, which supplies the
/// viewfinder chrome and the cancel affordance.
struct QRScannerView: UIViewControllerRepresentable {

    /// Called once, on the main actor, with the first QR payload that decodes.
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) {
        controller.stop()
    }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

        var onCode: ((String) -> Void)?

        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var hasFired = false
        private let queue = DispatchQueue(label: "com.nomily.app.ios.a1.qr")

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard !session.isRunning else { return }
            // `startRunning` blocks until the session is live (hundreds of ms); never on main.
            queue.async { [session] in session.startRunning() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            stop()
        }

        func stop() {
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                showUnavailable(L10n.A1.scanNoCamera)
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                showUnavailable(L10n.A1.scanNoCamera)
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            // Must be set *after* the output is attached, otherwise `availableMetadataObjectTypes`
            // is still empty and this assignment traps.
            output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            // ⛔ `CALayer.autoresizingMask` is unavailable on iOS — the layer is sized from
            // `viewDidLayoutSubviews` instead, which is also what keeps it correct through
            // rotation and the sheet's presentation animation.
            view.layer.addSublayer(preview)
            previewLayer = preview
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // No implicit animation: the preview would visibly "grow" into place on the first
            // layout pass otherwise.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer?.frame = view.bounds
            CATransaction.commit()
        }

        private func showUnavailable(_ message: String) {
            let label = UILabel()
            label.text = message
            label.textColor = .white
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = .preferredFont(forTextStyle: .callout)
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            ])
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !hasFired else { return }
            guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  object.type == .qr,
                  let value = object.stringValue, !value.isEmpty
            else { return }
            hasFired = true
            onCode?(value)
        }
    }
}

// MARK: - Sheet

/// Camera + viewfinder + cancel. Reports the raw scanned string; the caller decides whether it
/// parses, so a QR code that belongs to something else produces a readable error instead of a
/// silently dead scanner.
struct QRScannerSheet: View {

    let onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var denied = false
    /// The camera is only built **after** the permission question is settled. Building it first
    /// and asking afterwards leaves `AVCaptureSession` with no deliverable frames and a black
    /// preview that never recovers, even once access is granted.
    @State private var ready = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if ready {
                QRScannerView { code in
                    onCode(code)
                    dismiss()
                }
                .ignoresSafeArea()
            }

            if denied {
                Text(L10n.A1.scanDenied)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(32)
            }

            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .frame(width: 220, height: 220)
                Text(L10n.A1.scanHint)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(L10n.Common.cancel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.16), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
        }
        .task {
            guard !ready else { return }
            let blocked = await QRScannerView.cameraDenied()
            denied = blocked
            ready = !blocked
        }
    }
}

extension QRScannerView {

    /// `true` when the user has explicitly refused camera access — the sheet then explains why
    /// nothing is happening instead of showing a black screen with a viewfinder over it.
    static func cameraDenied() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            return true
        case .notDetermined:
            return !(await AVCaptureDevice.requestAccess(for: .video))
        default:
            return false
        }
    }
}
