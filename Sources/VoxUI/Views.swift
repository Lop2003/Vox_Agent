import SwiftUI
import VoxCodeCore

/// Readable line length on wide screens (iPad, landscape, big Mac windows).
public let contentMaxWidth: CGFloat = 760

public struct ConversationView: View {
    let model: AppModel
    let emptyHint: String

    public init(model: AppModel, emptyHint: String) {
        self.model = model
        self.emptyHint = emptyHint
    }

    public var body: some View {
        if model.turns.isEmpty { emptyState } else { conversation }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn, isSpeaking: model.speakingTurn == turn.id) { model.toggleSpeaking(turn) }
                            .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.turns.last?.activity.count) { scrollToBottom(proxy) }
            .onChange(of: model.turns.last?.response) { scrollToBottom(proxy) }
            .onChange(of: model.turns.count) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private static let examples: [(icon: String, text: String)] = [
        ("text.magnifyingglass", "โปรเจกต์นี้ทำอะไรได้บ้าง"),
        ("ladybug", "ช่วยหาจุดที่อาจมีปัญหา"),
        ("checkmark.circle", "เช็คว่ายังทำงานปกติไหม"),
        ("clock.arrow.circlepath", "สรุปสิ่งที่เปลี่ยนล่าสุด"),
    ]

    /// Greeting centred in the free space; suggestions sit just above the composer, within thumb reach.
    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                LogoMark(size: 88)
                Text("มีอะไรให้ช่วยไหม").font(.title2.bold())
                Text(emptyHint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 24)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.examples, id: \.text) { example in
                        Button { model.transcript = example.text } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: example.icon).font(.body).foregroundStyle(.tint)
                                    .frame(height: 22) // glyphs differ in height; keep every card identical
                                // Two reserved lines: every card is the same height and the text never touches the edge.
                                Text(example.text)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2, reservesSpace: true)
                            }
                            .frame(width: 136, alignment: .topLeading)
                            .padding(14)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.phase != .idle)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
            .padding(.bottom, 8)
        }
        .frame(maxWidth: contentMaxWidth, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}

/// The Vox Agent mark (transparent Logo.png). The tiled version is only the app icon.
public struct LogoMark: View {
    let size: CGFloat

    public init(size: CGFloat) { self.size = size }

    public var body: some View {
        logo
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: size * 0.06, y: size * 0.03) // keeps the light mark defined on white
            .accessibilityHidden(true)
    }

    // SwiftUI's Image(_:bundle:) only searches asset catalogs, so load the packaged PNG directly.
    private var logo: Image {
        guard let url = Bundle.module.url(forResource: "Logo", withExtension: "png") else { return Image(systemName: "waveform") }
        #if os(macOS)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) } ?? Image(systemName: "waveform")
        #else
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) } ?? Image(systemName: "waveform")
        #endif
    }
}

public struct MicButton: View {
    let phase: AppModel.Phase
    let size: CGFloat
    let action: () -> Void

    public init(phase: AppModel.Phase, size: CGFloat = 44, action: @escaping () -> Void) {
        self.phase = phase
        self.size = size
        self.action = action
    }

    private var listening: Bool { phase == .listening }
    private var busy: Bool { phase == .running || phase == .transcribing }

    public var body: some View {
        Button(action: action) {
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(listening ? Color.red : Color.accentColor, in: Circle())
                .background {
                    // Breathing ring while listening.
                    Circle()
                        .fill((listening ? Color.red : Color.accentColor).opacity(0.25))
                        .scaleEffect(listening ? 1.35 : 1)
                        .animation(listening ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: listening)
                }
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.4 : 1)
        .keyboardShortcut("m", modifiers: .command)
        .help(listening ? "Stop speaking (⌘M)" : "Start speaking (⌘M)")
        .accessibilityLabel(listening ? "Stop speaking" : "Start speaking")
    }
}

/// Starts or hangs up hands-free call mode.
public struct CallButton: View {
    let inCall: Bool
    let size: CGFloat
    let action: () -> Void

    public init(inCall: Bool, size: CGFloat = 40, action: @escaping () -> Void) {
        self.inCall = inCall
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: inCall ? "phone.down.fill" : "phone.fill")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(inCall ? Color.red : Color.green, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .help(inCall ? "Hang up" : "Call: talk hands-free")
        .accessibilityLabel(inCall ? "Hang up" : "Start call")
    }
}

public struct StatusBar: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 8) {
            if model.phase != .idle { ProgressView().controlSize(.small) }
            Text(model.phaseLabel)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 8)
            // Full step names when they fit, dots on narrow screens.
            ViewThatFits(in: .horizontal) {
                steps(labels: true)
                steps(labels: false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func steps(labels: Bool) -> some View {
        HStack(spacing: labels ? 6 : 5) {
            ForEach(AgentStatus.pipeline, id: \.self) { step in
                let active = step == model.currentStatus
                if labels {
                    Text(step.rawValue)
                        .font(.caption.weight(active ? .bold : .regular))
                        .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .fixedSize()
                    if step != .completed { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                } else {
                    Capsule()
                        .fill(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: active ? 18 : 7, height: 7)
                }
            }
        }
        .animation(.snappy, value: model.currentStatus)
    }
}

public struct TurnView: View {
    let turn: Turn
    let isSpeaking: Bool
    let onSpeak: (() -> Void)?

    public init(turn: Turn, isSpeaking: Bool = false, onSpeak: (() -> Void)? = nil) {
        self.turn = turn
        self.isSpeaking = isSpeaking
        self.onSpeak = onSpeak
    }

    private var isWorking: Bool { [.analyzing, .editing, .testing].contains(turn.status) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 48)
                Text(turn.user)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.tint)
                    Text(turn.agent).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    StatusBadge(status: turn.status)
                    if let onSpeak, !turn.response.isEmpty, !isWorking {
                        Button(action: onSpeak) {
                            Image(systemName: isSpeaking ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isSpeaking ? "Stop reading" : "Read aloud")
                    }
                }
                if turn.response.isEmpty, isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !turn.response.isEmpty {
                    ResponseView(markdown: turn.response)
                }
                if let error = turn.error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !turn.activity.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(turn.activity.enumerated()), id: \.offset) { Text($0.element) }
                        }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                    } label: {
                        Label("\(turn.activity.count) step\(turn.activity.count == 1 ? "" : "s")", systemImage: "list.bullet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tint(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// Renders the agent's `## Section` reply as titled blocks, hiding empty ("None") sections.
struct ResponseView: View {
    let markdown: String

    private struct Section: Identifiable {
        let id: Int
        let title: String?
        let body: String
    }

    private var sections: [Section] {
        var result: [Section] = []
        var title: String?
        var lines: [String] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let empty = ["", "none", "ไม่มี", "-", "n/a"].contains(body.lowercased())
            if !empty || (title == nil && !body.isEmpty) { result.append(Section(id: result.count, title: title, body: body)) }
            lines = []
        }
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("#") {
                flush()
                title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    if let title = section.title {
                        Text(title.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(inline(section.body))
                        .font(section.title?.caseInsensitiveCompare("Summary") == .orderedSame ? .body.weight(.medium) : .body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> AttributedString {
        let bulleted = text.replacingOccurrences(of: #"(?m)^\s*[-*]\s+"#, with: "• ", options: .regularExpression)
        return (try? AttributedString(markdown: bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(bulleted)
    }
}

struct StatusBadge: View {
    let status: AgentStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        default: .blue
        }
    }
}
