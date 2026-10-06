import AVFoundation
import SwiftUI
import VoxCodeCore

/// Full-screen camera that reads the Mac app's pairing QR code and hands back the link.
struct PairingScanner: View {
    let onScan: (PairingLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var message = "Point the camera at the QR code in the Vox Agent Mac app (Pair iPhone)."
    @State private var denied = false

    var body: some View {
        ZStack {
            if denied {
                Color.black.ignoresSafeArea()
            } else {
                QRCameraView { text in
                    guard let url = URL(string: text), let link = PairingLink(url: url) else {
                        message = "That isn't a Vox Agent pairing code."
                        return false
                    }
                    onScan(link)
                    dismiss()
                    return true
                } onDenied: {
                    denied = true
                    message = "Camera access is off. Allow it in Settings › Privacy & Security › Camera, or type the code instead."
                }
                .ignoresSafeArea()
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .opacity(denied ? 0 : 1)
                Spacer()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(20)
        }
        .background(Color.black)
    }
}

/// AVFoundation QR reader. `onCode` returns true once a code is accepted (scanning then stops).
private struct QRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Bool
    let onDenied: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onDenied = onDenied
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Bool)?
        var onDenied: (() -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.start() : self.onDenied?() }
            }
        }

        private func start() {
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return onDenied?() ?? () }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            self.preview = preview
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() } }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            if onCode?(text) == true {
                done = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}
