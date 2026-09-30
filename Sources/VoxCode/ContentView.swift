import AppKit
import SwiftUI
import VoxCodeCore
import VoxUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var workspace = WorkspaceManager.load()

    var body: some View {
        VStack(spacing: 0) {
            ConversationView(model: model, emptyHint: workspace == nil
                ? "Choose a workspace, then press the microphone and speak."
                : "Press the microphone and speak — e.g. “ช่วยตรวจสอบ login rate limit ให้หน่อย”")
            Divider()
            StatusBar(model: model)
            Divider()
            composer
        }
        .frame(minWidth: 680, minHeight: 600)
        .toolbar { toolbar }
        .navigationTitle("Vox Agent")
        .onAppear {
            model.runnerMissingMessage = "Choose a workspace folder first."
            model.runner = workspace.map { AgentSession(workspace: $0) }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.newConversation()
        workspace = url
        WorkspaceManager.save(url)
        model.runner = AgentSession(workspace: url)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: chooseWorkspace) {
                Label(workspace?.lastPathComponent ?? "Choose Workspace…", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .help(workspace?.path ?? "Folder the agent works in")
            .disabled(model.phase == .running)
        }
        ToolbarItem(placement: .principal) {
            Picker("Agent", selection: $model.agent) {
                ForEach(model.agents, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(model.phase == .running)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: model.newConversation) { Label("New Conversation", systemImage: "square.and.pencil") }
                .help("Start a new conversation")
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 10) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack(alignment: .bottom, spacing: 12) {
                MicButton(phase: model.phase, action: model.toggleListening)
                CallButton(inCall: model.inCall, action: model.toggleCall)
                    .keyboardShortcut("k", modifiers: .command)

                TextField(model.phase == .listening ? "Listening…" : "Speak or type a request", text: $model.transcript, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(model.send)
                    .disabled(model.phase != .idle)

                if model.phase == .idle {
                    Button(action: model.send) { Label("Send", systemImage: "arrow.up.circle.fill") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button(role: .cancel, action: model.cancel) { Label("Stop", systemImage: "stop.circle.fill") }
                        .keyboardShortcut(.escape, modifiers: [])
                        .tint(.red)
                }
                Button(action: model.toggleSpeaking) {
                    Label(model.isSpeaking ? "Stop Voice" : "Play Response", systemImage: model.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .disabled(model.lastResponse == nil)
            }
            .controlSize(.large)

            HStack(spacing: 16) {
                Picker("Language", selection: $model.localeID) {
                    ForEach(SpeechToTextService.locales.sorted(by: >), id: \.key) { Text($0.value).tag($0.key) }
                }
                .fixedSize()
                .disabled(model.phase != .idle)
                Picker("Voice", selection: $model.thaiVoice) {
                    Text("Automatic").tag("")
                    ForEach(VoiceCatalog.options(for: "th-TH")) { Text($0.label).tag($0.id) }
                }
                .fixedSize()
                Toggle("Auto-send after speaking", isOn: $model.autoSend)
                Toggle("Speak responses", isOn: $model.autoSpeak)
                Spacer()
                TextField("Active file (optional)", text: $model.activeFile)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            .font(.callout)
            .toggleStyle(.checkbox)
        }
        .padding(14)
    }
}

/// Remembers the workspace the agent runs in. Never hardcoded: the user picks it.
enum WorkspaceManager {
    private static let key = "workspacePath"

    static func load() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? URL(fileURLWithPath: path) : nil
    }

    static func save(_ url: URL?) { UserDefaults.standard.set(url?.path, forKey: key) }
}
