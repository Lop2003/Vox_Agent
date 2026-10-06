import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import VoxCodeCore

/// Sets up the iPhone without Terminal: run the bridge for a folder, then scan the QR code with the iPhone Camera.
struct PairPhoneView: View {
    /// The app's own workspace chooser: the iPhone uses the same folder.
    let chooseWorkspace: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var running = BridgeService.isRunning
    @State private var workspace = BridgeService.workspace
    @State private var code = (try? BridgeService.pairingCode()) ?? ""
    @State private var addresses = BridgeService.addresses()
    @State private var error: String?

    private var link: PairingLink {
        PairingLink(code: code, host: PairingLink.preferredHost(from: addresses))
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair your iPhone").font(.title2.bold())

            if running {
                Image(nsImage: qrImage(link.url.absoluteString))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                Text("Open the Camera on your iPhone, scan this code, then tap “Open in Vox Agent”.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 320)
            } else {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .frame(height: 140)
                Text("Choose the workspace. Agents from this Mac and from your iPhone work in that folder.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 320)
            }

            Form {
                LabeledContent("Workspace") {
                    Text(workspace?.lastPathComponent ?? "None").help(workspace?.path ?? "")
                }
                LabeledContent("Bridge") {
                    Label(running ? "Running" : "Stopped", systemImage: "circle.fill")
                        .foregroundStyle(running ? .green : .secondary)
                }
                if running {
                    LabeledContent("Code") {
                        HStack {
                            Text(code).font(.body.monospaced()).textSelection(.enabled)
                            Button("New code", action: renewCode).help("Disconnects phones paired with the old code")
                        }
                    }
                    LabeledContent("Address") {
                        Text(addresses.isEmpty ? "No network" : addresses.joined(separator: ", ")).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 420)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }

            HStack {
                if running { Button("Stop Bridge", role: .destructive, action: stop) }
                Spacer()
                Button(running ? "Change Workspace…" : "Choose Workspace…", action: start)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .frame(width: 420)
        }
        .padding(24)
    }

    private func start() {
        chooseWorkspace()
        code = (try? BridgeService.pairingCode()) ?? code
        error = nil
        refresh()
    }

    private func stop() {
        BridgeService.stop()
        refresh()
    }

    private func renewCode() {
        do {
            code = try BridgeService.pairingCode(renew: true)
            BridgeService.restart() // the bridge reads the code at start
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        // launchd needs a moment to report the new state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            running = BridgeService.isRunning
            workspace = BridgeService.workspace
            addresses = BridgeService.addresses()
        }
    }

    private func qrImage(_ text: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return NSImage() }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
