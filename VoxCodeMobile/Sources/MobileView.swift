import SwiftUI
import VoxCodeCore
import VoxUI

struct MobileView: View {
    @State private var model = AppModel()
    @State private var bridge = BridgeClient()
    @State private var showPairing = false
    @State private var sidebarOpen = false
    @GestureState private var drag: CGFloat = 0
    @AppStorage("theme") private var theme = Theme.system
    @Environment(\.scenePhase) private var scenePhase

    enum Theme: String, CaseIterable {
        case system, light, dark

        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var icon: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = min(320, geo.size.width * 0.82)
            // How far the sidebar is out: 0 closed … width open, following the finger while dragging.
            let reveal = max(0, min(width, (sidebarOpen ? width : 0) + drag))
            ZStack(alignment: .leading) {
                NavigationStack {
                    ConversationView(model: model, emptyHint: bridge.isConnected
                        ? model.inGeneralWorkspace ? "ถามอะไรก็ได้ พิมพ์ แตะไมค์ หรือกด 〰️ เพื่อคุยแบบโทรศัพท์" : "พิมพ์ แตะไมค์ หรือกด 〰️ เพื่อคุยแบบโทรศัพท์"
                        : "Run the Vox Agent bridge on your computer, then tap the title to pair.")
                        .safeAreaInset(edge: .bottom, spacing: 0) { Composer(model: model) }
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbar }
                        .sheet(isPresented: $showPairing) { PairingView(bridge: bridge) }
                }
                .overlay {
                    // Dim the chat while the sidebar is out; tap to close.
                    Color.black.opacity(0.3 * reveal / width)
                        .ignoresSafeArea()
                        .allowsHitTesting(sidebarOpen)
                        .onTapGesture { sidebarOpen = false }
                }
                .overlay(alignment: .leading) {
                    // Swipe in from the left edge to open.
                    Color.clear.frame(width: 20).contentShape(Rectangle())
                        .gesture(sidebarDrag(width: width))
                        .allowsHitTesting(!sidebarOpen)
                }
                .offset(x: reveal)

                Sidebar(model: model) { sidebarOpen = false }
                    .frame(width: width)
                    .offset(x: reveal - width)
                    .gesture(sidebarDrag(width: width))
            }
            .animation(.snappy(duration: 0.3), value: sidebarOpen)
            .animation(.interactiveSpring, value: drag)
        }
        .onAppear {
            model.runner = bridge
            reconnect()
            if PairingStore.code == nil { showPairing = true }
        }
        // The Mac app's pairing QR code (voxagent://pair?…), scanned with the Camera, lands here.
        .onOpenURL { url in
            guard let link = PairingLink(url: url) else { return }
            PairingStore.code = link.code
            PairingStore.host = link.host ?? ""
            showPairing = false
            bridge.connect(pairingCode: link.code, host: link.host, port: link.port, preferLocalNetwork: true)
        }
        // iOS drops sockets in the background; reconnect when the app comes back.
        .onChange(of: scenePhase) { if scenePhase == .active { reconnect() } }
        // Keep the screen on during a call, like the Phone app.
        .onChange(of: model.inCall) { UIApplication.shared.isIdleTimerDisabled = model.inCall }
        .sensoryFeedback(.impact, trigger: model.phase == .listening)
        .preferredColorScheme(theme.colorScheme)
    }

    /// Drag to open or close; past half way (or a quick flick) it snaps the rest of the way.
    private func sidebarDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .updating($drag) { value, state, _ in state = value.translation.width }
            .onEnded { value in
                let moved = value.predictedEndTranslation.width
                sidebarOpen = sidebarOpen ? moved > -width / 2 : moved > width / 2
            }
    }

    private func reconnect() {
        guard let code = PairingStore.code else { return }
        switch bridge.state {
        case .disconnected, .failed, .waiting: bridge.connect(pairingCode: code, host: PairingStore.host, preferLocalNetwork: true)
        case .searching, .connecting, .connected: break
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { sidebarOpen = true } label: { Image(systemName: "line.3.horizontal") }
                .accessibilityLabel("Chats")
        }
        ToolbarItem(placement: .principal) {
            // The title is the agent picker (like a chat app's model switcher); the line below is the connection.
            Menu {
                Picker("Agent", selection: $model.agent) {
                    ForEach(model.agents, id: \.self) { Text($0).tag($0) }
                }
                .disabled(model.phase == .running)
                Divider()
                Button("Pair…", systemImage: "link") { showPairing = true }
            } label: {
                // Concrete colors, not `.primary`/`.secondary` styles: inside a toolbar Menu those inherit the
                // accent tint on iOS 18 and the title turns blue.
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text(model.agents.isEmpty ? "Vox Agent" : model.agent).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Color.secondary)
                    }
                    .font(.subheadline.weight(.semibold)) // two lines must fit the 44 pt bar with room above and below
                    .foregroundStyle(Color.primary)
                    HStack(spacing: 4) {
                        Circle().fill(connectionColor).frame(width: 6, height: 6)
                        Text(connectionText).lineLimit(1).truncationMode(.middle)
                        if model.permissionMode == .full {
                            Text("· Full access").foregroundStyle(Color.orange) // always visible while it's on
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: 240)
            }
            .tint(Color.primary)
            .accessibilityLabel("Agent: \(model.agent)")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Language", selection: $model.localeID) {
                    ForEach(SpeechToTextService.locales.sorted(by: >), id: \.key) { Text($0.value).tag($0.key) }
                }
                Picker(selection: $theme) {
                    ForEach(Theme.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
                } label: {
                    Label("Appearance", systemImage: theme.icon)
                }
                .pickerStyle(.menu)
                Picker(selection: $model.thaiVoice) {
                    Text("Automatic (Mac voice when connected)").tag("")
                    ForEach(VoiceCatalog.options(for: "th-TH")) { Text($0.label).tag($0.id) }
                } label: {
                    Label("Thai voice", systemImage: "waveform")
                }
                .pickerStyle(.menu)
                Divider()
                Toggle("Auto-send after speaking", isOn: $model.autoSend)
                Toggle("Read answers aloud", isOn: $model.autoSpeak)
                Toggle("Interrupt by voice (calls)", isOn: $model.bargeInEnabled)
                Picker(selection: $model.permissionMode) {
                    ForEach(PermissionMode.allCases, id: \.self) { mode in
                        Button {} label: { Label(mode.title, systemImage: mode.icon); Text(mode.detail) }.tag(mode)
                    }
                } label: {
                    Label("Permissions: \(model.permissionMode.title)", systemImage: model.permissionMode.icon)
                }
                .pickerStyle(.menu)
                Picker(selection: $model.effort) {
                    ForEach(Effort.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    Label("Effort: \(model.effort.title)", systemImage: "gauge.with.dots.needle.50percent")
                }
                .pickerStyle(.menu)
                Divider()
                Button("Pair…", systemImage: "link") { showPairing = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var connectionText: String {
        switch bridge.state {
        case .disconnected: "Not connected"
        case .searching: "Searching…"
        case .connecting: "Connecting…"
        // Show which workspace you're in (the project or General), not only which folder the bridge serves.
        case .connected(let folder): model.workspaces.first { $0.id == model.workspaceID }?.name ?? folder
        case .waiting: "Reconnecting…"
        case .failed: "Can't connect — tap to fix"
        }
    }

    private var connectionColor: Color {
        switch bridge.state {
        case .connected: .green
        case .failed: .red
        case .disconnected: .gray
        case .searching, .connecting, .waiting: .orange
        }
    }
}

// MARK: - Composer

/// Floating input pill: agent picker and live status above, text + mic + send/call in one row.
struct Composer: View {
    let model: AppModel
    @FocusState private var focused: Bool

    private var hasText: Bool { !model.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var busy: Bool { model.phase == .running || model.phase == .transcribing }
    private var listening: Bool { model.phase == .listening }

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Agent progress already shows on its card; the chip only covers dictation (calls show it in the bar).
            if !model.inCall, model.phase == .listening || model.phase == .transcribing {
                statusChip
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let request = model.pendingRequest {
                confirmCard(request).transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if model.inCall {
                callBar
            } else {
                inputPill
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .background {
            // Fade the conversation out under the floating composer.
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
        .animation(.snappy, value: model.phase)
        .animation(.snappy, value: model.inCall)
        .animation(.snappy, value: model.pendingRequest)
        .animation(.snappy, value: hasText)
        .animation(.snappy, value: model.errorMessage)
    }

    private var inputPill: some View {
            HStack(alignment: .bottom, spacing: 4) {
                TextField(listening ? "Listening…" : "Ask Vox Agent", text: Bindable(model).transcript, axis: .vertical)
                    .focused($focused)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit(model.send)
                    .disabled(model.phase != .idle)
                    .padding(.leading, 18)
                    .padding(.vertical, 15) // 22pt line + 30 = 52pt, same as a button plus its 8pt insets

                // Dictation: tap, speak, pause.
                Button(action: model.toggleListening) {
                    Image(systemName: listening ? "stop.fill" : "mic")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(listening ? .white : .primary)
                        .frame(width: 36, height: 36)
                        .background(listening ? AnyShapeStyle(Color.red) : AnyShapeStyle(.clear), in: Circle())
                        .symbolEffect(.pulse, isActive: listening)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .opacity(busy ? 0.35 : 1)
                .accessibilityLabel(listening ? "Stop dictation" : "Dictate")
                .padding(.vertical, 8)

                primaryButton
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
            .transition(.opacity)
    }

    // MARK: Confirmation

    /// A spoken request that would change files, shown back before the agent runs it (speech can mishear).
    private func confirmCard(_ request: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(thai ? "จะให้ \(model.agent) ทำตามนี้ใช่ไหม" : "Run this with \(model.agent)?", systemImage: "exclamationmark.bubble")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
            Text("“\(request)”")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                pillButton(thai ? "แก้ไข" : "Edit", systemImage: "pencil", action: model.editPending)
                    .disabled(model.inCall)
                pillButton(thai ? "ยกเลิก" : "Cancel", systemImage: "xmark", action: model.cancelPending)
                Spacer(minLength: 4)
                Button(action: model.confirmPending) {
                    Label(thai ? "ส่งเลย" : "Run", systemImage: "arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if model.inCall {
                Text(thai ? "หรือพูดว่า “ใช่” / “ไม่”" : "Or say “yes” / “no”").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.orange.opacity(0.35)))
    }

    // MARK: Call bar

    private var thai: Bool { model.localeID.hasPrefix("th") }

    private var callMood: CallWaveform.Mood {
        if model.micMuted, model.phase == .idle, !model.isSpeaking { return .idle }
        return switch model.phase {
        case .listening: .listening
        case .transcribing, .running: .working
        case .idle: model.isSpeaking ? .speaking : .idle
        }
    }

    private var callStatus: String {
        if model.micMuted, model.phase == .idle, !model.isSpeaking { return thai ? "ปิดไมค์อยู่" : "Muted" }
        return switch model.phase {
        case .listening: thai ? "กำลังฟัง…" : "Listening…"
        case .transcribing: thai ? "รับทราบ…" : "Got it…"
        case .running: (thai ? "กำลังทำงาน · " : "Working · ") + model.currentStatus.rawValue
        case .idle: model.isSpeaking ? (thai ? "กำลังตอบ…" : "Speaking…") : (thai ? "กำลังเชื่อมต่อ…" : "Connecting…")
        }
    }

    /// Live transcript while listening, the agent's current step while it works.
    private var callDetail: String {
        switch model.phase {
        case .listening, .transcribing: model.transcript
        case .running: model.turns.last?.activity.last ?? ""
        case .idle: ""
        }
    }

    /// In a call the input pill becomes this bar; the chat stays on screen above it.
    private var callBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.micMuted ? .orange : .green).frame(width: 8, height: 8)
                Text(callStatus).font(.footnote.weight(.semibold)).contentTransition(.opacity)
                Spacer(minLength: 8)
                Label(model.agent, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            CallWaveform(mood: callMood, level: model.inputLevel)
                .frame(height: 40)

            if !callDetail.isEmpty {
                Text(callDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                muteButton
                callAction
                Spacer(minLength: 8)
                Button(action: model.toggleCall) {
                    Label(thai ? "วางสาย" : "End", systemImage: "phone.down.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(Color.red, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End call")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: callDetail)
    }

    private var muteButton: some View {
        Button(action: model.toggleMute) {
            Image(systemName: model.micMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.micMuted ? Color.white : Color.primary)
                .frame(width: 40, height: 40)
                .background(model.micMuted ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color(.tertiarySystemFill)), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.micMuted ? "Unmute microphone" : "Mute microphone")
    }

    /// Done talking while listening; stop the agent or its voice (and listen again); otherwise talk now.
    @ViewBuilder private var callAction: some View {
        switch model.phase {
        case .listening:
            pillButton(thai ? "ส่งเลย" : "Send now", systemImage: "arrow.up", action: model.toggleListening)
        case .running:
            pillButton(thai ? "หยุด" : "Stop", systemImage: "stop.fill", action: model.interrupt)
        case .idle where model.isSpeaking:
            pillButton(thai ? "หยุดพูด" : "Stop talking", systemImage: "stop.fill", action: model.interrupt)
        case .idle where model.micMuted:
            EmptyView() // the mute button is the way back
        case .idle:
            pillButton(thai ? "พูด" : "Talk", systemImage: "waveform", action: model.toggleListening)
        case .transcribing:
            pillButton(thai ? "รอสักครู่" : "One moment", systemImage: "ellipsis", action: {}).disabled(true)
        }
    }

    private func pillButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Send when there is text, stop while working, otherwise start a hands-free call.
    @ViewBuilder private var primaryButton: some View {
        if busy {
            circle("stop.fill", color: .primary, label: "Stop", action: model.cancel)
        } else if hasText {
            circle("arrow.up", color: .accentColor, label: "Send") {
                focused = false
                model.send()
            }
        } else {
            circle("waveform", color: .primary, label: "Start voice call") {
                focused = false
                model.toggleCall()
            }
            .disabled(listening)
        }
    }

    private func circle(_ systemImage: String, color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 36, height: 36)
                .background(color, in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            if model.phase == .listening {
                Circle().fill(.red).frame(width: 7, height: 7)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(model.phaseLabel).lineLimit(1)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .contentTransition(.numericText())
    }
}

// MARK: - Sidebar

/// Slide-out sidebar: start a new conversation or reopen a saved one. Swipe a chat left to delete it.
struct Sidebar: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LogoMark(size: 30)
                Text("Vox Agent").font(.title3.bold())
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)

            if model.workspaces.count > 1 {
                // Project work vs. general questions: each has its own agents and chats.
                Picker("Workspace", selection: Binding(get: { model.workspaceID }, set: { model.workspaceID = $0 })) {
                    ForEach(model.workspaces) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .disabled(model.phase == .running)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            Button {
                model.newConversation()
                close()
            } label: {
                Label("New conversation", systemImage: "square.and.pencil")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            Text("Recent")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 22)
                .padding(.bottom, 4)

            if model.workspaceConversations.isEmpty {
                Text("Your chats will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Spacer()
            } else {
                List {
                    ForEach(model.workspaceConversations) { conversation in
                        Button {
                            model.open(conversation)
                            close()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(conversation.id == model.conversationID ? Color(.tertiarySystemFill) : .clear)
                                .padding(.horizontal, 8)
                        )
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) { model.delete(conversation) }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
    }
}

struct PairingView: View {
    let bridge: BridgeClient
    @State private var code = PairingStore.code ?? ""
    @State private var host = PairingStore.host
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XXXX", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Easiest: in the Vox Agent Mac app choose Pair iPhone, then scan its QR code with the iPhone Camera. Or type the code the bridge shows.")
                }
                Section {
                    TextField("Found automatically", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Mac address (optional)")
                } footer: {
                    Text("Only needed when your Mac isn't found automatically, e.g. over Tailscale.")
                }
                if case .failed(let message) = bridge.state {
                    Section { Text(message).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        PairingStore.code = code
                        PairingStore.host = host.trimmingCharacters(in: .whitespaces)
                        bridge.connect(pairingCode: code, host: PairingStore.host, preferLocalNetwork: true)
                        dismiss()
                    }
                    .disabled(PairingCode.normalize(code).count != 12)
                }
            }
        }
    }
}
