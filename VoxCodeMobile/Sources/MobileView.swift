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
                        ? "พิมพ์ แตะไมค์ หรือกด 〰️ เพื่อคุยแบบโทรศัพท์"
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
        .fullScreenCover(isPresented: Binding(get: { model.inCall }, set: { if !$0, model.inCall { model.toggleCall() } })) {
            CallView(model: model)
        }
        .onAppear {
            model.runner = bridge
            reconnect()
            if PairingStore.code == nil { showPairing = true }
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
        case .disconnected, .failed, .waiting: bridge.connect(pairingCode: code, host: PairingStore.host)
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
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text(model.agents.isEmpty ? "Vox Agent" : model.agent).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .font(.headline)
                    .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Circle().fill(connectionColor).frame(width: 6, height: 6)
                        Text(connectionText).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 240)
            }
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
        case .connected(let workspace): workspace
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

            // Agent progress already shows on its card; the chip only covers dictation.
            if model.phase == .listening || model.phase == .transcribing {
                statusChip
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

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
        .animation(.snappy, value: hasText)
        .animation(.snappy, value: model.errorMessage)
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

// MARK: - Call

/// Full-screen hands-free call: listens, sends when you pause, narrates, reads the answer, listens again.
struct CallView: View {
    let model: AppModel

    private var thai: Bool { model.localeID.hasPrefix("th") }
    private var active: Bool { model.phase == .listening || model.isSpeaking }

    private var status: String {
        switch model.phase {
        case .listening: thai ? "กำลังฟัง…" : "Listening…"
        case .transcribing: thai ? "รับทราบ…" : "Got it…"
        case .running: (thai ? "กำลังทำงาน · " : "Working · ") + model.currentStatus.rawValue
        case .idle: model.isSpeaking ? (thai ? "กำลังตอบ…" : "Speaking…") : (thai ? "เชื่อมต่อ…" : "Connecting…")
        }
    }

    /// Live transcript while listening, otherwise what the agent is doing or saying.
    private var detail: String {
        if model.phase == .listening || model.phase == .transcribing { return model.transcript }
        guard let turn = model.turns.last else { return "" }
        if model.phase == .running { return turn.activity.last ?? "" }
        return SpeechText.speakable(from: turn.response)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Label(model.agent, systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 12)

                Spacer()

                Orb(active: active, working: model.phase == .running, listening: model.phase == .listening)
                    .frame(width: 200, height: 200)

                Text(status)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)

                Text(detail.isEmpty ? " " : detail)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 32)
                    .frame(minHeight: 80, alignment: .top)

                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                }

                Spacer()

                HStack(spacing: 56) {
                    // Cut in while it talks, or finish your sentence early.
                    callButton(model.phase == .listening ? "arrow.up" : "mic.fill",
                               label: model.phase == .listening ? "Done speaking" : "Talk now",
                               background: .white.opacity(0.15), action: model.toggleListening)
                        .disabled(model.phase == .running || model.phase == .transcribing)
                        .opacity(model.phase == .running || model.phase == .transcribing ? 0.4 : 1)
                    callButton("phone.down.fill", label: "End call", background: .red, action: model.toggleCall)
                }
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func callButton(_ systemImage: String, label: String, background: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(background, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// Breathing gradient orb: calm when idle, pulsing while listening or speaking, spinning while the agent works.
struct Orb: View {
    let active: Bool
    let working: Bool
    let listening: Bool

    var body: some View {
        let colors: [Color] = listening ? [.cyan, .blue, .purple] : [.purple, .pink, .orange]
        ZStack {
            Circle()
                .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
                .blur(radius: 30)
                .opacity(0.7)
                .phaseAnimator([false, true]) { view, phase in
                    view.scaleEffect(active && phase ? 1.15 : 0.95)
                } animation: { _ in .easeInOut(duration: 1.1) }
            Circle()
                .fill(AngularGradient(colors: colors + [colors[0]], center: .center))
                .padding(28)
                .phaseAnimator([0.0, 360.0]) { view, angle in
                    view.rotationEffect(.degrees(working ? angle : 0))
                } animation: { _ in working ? .linear(duration: 2.5) : .default }
            Circle()
                .fill(.white.opacity(0.12))
                .padding(28)
        }
        .animation(.easeInOut, value: listening)
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

            if model.conversations.isEmpty {
                Text("Your chats will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Spacer()
            } else {
                List {
                    ForEach(model.conversations) { conversation in
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
                    Text("On your Mac run `voxcode-bridge --workspace <project>` and enter the code it prints. Your iPhone and Mac must be on the same network.")
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
                        bridge.connect(pairingCode: code, host: PairingStore.host)
                        dismiss()
                    }
                    .disabled(PairingCode.normalize(code).count != 12)
                }
            }
        }
    }
}
