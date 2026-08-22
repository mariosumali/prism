// AssistantPanel.swift
// PRISM
//
// The assistant's answer, floating over the user's own desktop (§5.33), and
// the second piece of text in PRISM that is never composited into the
// picture. Live insights (§5.34) put their cards on the same panel, under
// the same protection, for the same reason.
//
// Structurally the prompter's panel, for the prompter's reason: an answer
// drawn into the outgoing frame is an answer everyone on the call can read,
// which is not a feature. So it lives on the reader's screen, and
// `sharingType = .none` takes it out of the window server's capture surface.
//
// **Where this differs from the prompter, and it matters.**
//
// The prompter's header says the panel is kept out of every screen
// recording. For a script the user wrote, that is the whole story. For an
// answer the user is about to say out loud it is worth being more careful,
// because the failure is worse and the guarantee is narrower than it looks:
//
//   `sharingType = .none` is honoured by window-list capture — the mode
//   Zoom, Teams and PRISM's own screen source use — and it is what makes
//   this panel absent from an ordinary screen share.
//
//   It is not a defence against everything. Apple has said on the record
//   that there is no public API for preventing screen capture, and a
//   capture path that composites the framebuffer rather than enumerating
//   windows can see this panel. PRISM cannot fix that and will not pretend
//   to.
//
// So the Assistant pane says exactly that, in those words, and the chord is
// presented as the reliable way to put the panel away. A promise this app
// cannot keep is not one it makes.
//
// One structural note. `AssistantSession` and `InsightSession` are their
// own ObservableObjects and AppState does not forward their changes, so the
// body observes them directly — the popover's Meeting section makes the
// same arrangement for `MeetingSession`. Reading `state.assistant.answer`
// through the environment object alone redraws only when something else on
// AppState happens to change, which is most of the time and not all of it.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

// MARK: - Panel

@MainActor
final class AssistantPanelController: NSWindowController, NSWindowDelegate {
    private let state: AppState

    /// Wide enough for a two-line answer without wrapping every clause,
    /// short enough to sit in a corner rather than across the call.
    private static let defaultSize = NSSize(width: 420, height: 260)

    init(state: AppState) {
        self.state = state
        let hosting = NSHostingController(
            rootView: AssistantPanelView().environmentObject(state))
        // Without this SwiftUI derives its own minimum and overrides
        // contentMinSize, and the panel stops being resizable downward.
        hosting.sizingOptions = []

        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .resizable,
                           .fullSizeContentView, .nonactivatingPanel]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        // Floating and non-activating: clicking the answer must not pull
        // focus off the call in front of it, and it has to stay visible
        // over a full-screen meeting window on any space.
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle]

        // The load-bearing line of this file. See the header for exactly
        // what it does and does not cover.
        panel.sharingType = .none

        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.setContentSize(Self.defaultSize)
        panel.contentMinSize = NSSize(width: 320, height: 160)
        panel.setFrameOrigin(Self.origin(for: state.studio.assistant.anchor,
                                         size: Self.defaultSize))
        super.init(window: panel)
        // After super.init, so a frame the user dragged wins over the anchor.
        panel.setFrameAutosaveName("PRISM.AssistantPanel")
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        // orderFrontRegardless, never makeKeyAndOrderFront: putting an
        // answer on screen must not take the keyboard away from the call
        // the user is in the middle of.
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Closing the window and flipping the switch mean the same thing, so
    /// the switch follows the window rather than drifting out of step with
    /// it.
    func windowWillClose(_ notification: Notification) {
        state.setAssistantEnabled(false)
    }

    private static func origin(for anchor: AssistantAnchor, size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 120, y: 120) }
        let frame = screen.visibleFrame
        let inset: CGFloat = 24
        switch anchor {
        case .topLeading:
            return NSPoint(x: frame.minX + inset, y: frame.maxY - size.height - inset)
        case .topTrailing:
            return NSPoint(x: frame.maxX - size.width - inset,
                           y: frame.maxY - size.height - inset)
        case .bottomLeading:
            return NSPoint(x: frame.minX + inset, y: frame.minY + inset)
        case .bottomTrailing:
            return NSPoint(x: frame.maxX - size.width - inset, y: frame.minY + inset)
        }
    }
}

// MARK: - Contents

struct AssistantPanelView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        AssistantPanelBody(assistant: state.assistant,
                           insights: state.insights,
                           meeting: state.meeting)
    }
}

private struct AssistantPanelBody: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var assistant: AssistantSession
    @ObservedObject var insights: InsightSession
    @ObservedObject var meeting: MeetingSession

    @State private var composed = ""
    @State private var hovering = false
    @FocusState private var composerFocused: Bool

    private var settings: AssistantSettings { state.studio.assistant }
    private var showsInsights: Bool { settings.liveInsights }

    /// Newest first: full, then dimmer, then dimmer still.
    private static let ageOpacity: [Double] = [1.0, 0.8, 0.62]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color.black)
                .opacity(settings.clampedOpacity)

            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                header
                if showsInsights { liveRow }
                content
                composer
            }
            .padding(Metrics.gutter)

            if hovering { controlStrip }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering = $0 }
        .prismAnimation(value: hovering)
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let question = assistant.detectedQuestion, !assistant.isStreaming,
           assistant.answer.isEmpty {
            // A question detected is a light on a control, not a request
            // (§5.33). It is shown so the user knows the chord has
            // something to answer — it has not been sent anywhere. With
            // live insights on it may also be on its way as a card, and
            // the live row below says so.
            Label(question, systemImage: "questionmark.bubble")
                .font(.caption)
                .foregroundStyle(.yellow)
                .lineLimit(2)
                .accessibilityLabel("Detected question, not yet sent: \(question)")
        } else if let asked = assistant.lastAsked {
            Text(asked)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
        }
    }

    // MARK: Live row (§5.34)

    /// What the mode is doing right now, in one line. Standing while the
    /// mode is on, because a panel that sends on its own owes the user a
    /// visible account of when it is sending.
    private var liveRow: some View {
        HStack(spacing: Metrics.metaGap) {
            Circle()
                .fill(insights.isArmed ? Color.green : Color.white.opacity(0.35))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            if insights.isThinking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
            Text(liveStatus)
                .font(.caption)
                .foregroundStyle(insights.lastError == nil
                                 ? AnyShapeStyle(Color.white.opacity(0.6))
                                 : AnyShapeStyle(Color.orange))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !insights.cards.isEmpty {
                Button("Clear") { state.clearInsights() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .help("Remove every card")
                    .accessibilityLabel("Clear the cards")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live insights")
        .accessibilityValue(liveStatus)
    }

    private var liveStatus: String {
        if let error = insights.lastError { return error }
        if !insights.isArmed {
            return meeting.phase.isListening
                ? "Live insights is paused"
                : "Starts when you start listening"
        }
        if insights.isThinking { return "Looking at the last stretch…" }
        // Silence has to be legible: a panel that sends on its own and says
        // nothing about it reads as broken. So the count is always here.
        guard insights.requestCount > 0 else {
            return "Watching the call. A card appears when there is something worth saying."
        }
        let requests = insights.requestCount == 1 ? "1 request" : "\(insights.requestCount) requests"
        return "Watching the call · \(settings.insightPace.displayName) · \(requests)"
    }

    // MARK: Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.itemGap) {
                    ForEach(assistant.history.suffix(3)) { exchange in
                        previousExchange(exchange)
                    }
                    answerBlock
                    Color.clear.frame(height: 1).id("answerEnd")
                    if showsInsights {
                        // Older cards fade by position, so the eye lands on
                        // the newest without the panel having to move
                        // anything. Pinned cards stay at full strength.
                        ForEach(Array(insights.cards.enumerated()), id: \.element.id) { index, card in
                            InsightCardView(card: card,
                                            onAsk: { state.askAboutInsight(card.id) },
                                            onPin: { state.pinInsight(card.id) },
                                            onDismiss: { state.dismissInsight(card.id) })
                            .opacity(card.isPinned ? 1 : Self.ageOpacity[min(index, Self.ageOpacity.count - 1)])
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .prismAnimation(value: insights.cards.map(\.id))
            }
            .onChange(of: assistant.answer) { _ in
                // Follow the answer as it streams; a panel you have to
                // scroll while talking is a panel you will not read. Avoid an
                // animation per streamed batch: at display cadence those
                // animations overlap and keep the compositor busy forever.
                proxy.scrollTo("answerEnd", anchor: .bottom)
            }
            .onChange(of: assistant.history.count) { _ in
                proxy.scrollTo("answerEnd", anchor: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var answerBlock: some View {
        if let error = assistant.lastError {
            VStack(alignment: .leading, spacing: Metrics.metaGap) {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    state.askAssistant(assistant.lastAsked)
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .accessibilityLabel("Try the last assistant request again")
            }
        } else if !assistant.answer.isEmpty {
            Text(assistant.answer)
                .font(.callout)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if !showsInsights, assistant.history.isEmpty {
            // With live insights on, the live row already says what the
            // panel is for; a second explanation under it is clutter.
            Text(emptyState)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func previousExchange(_ exchange: AssistantExchange) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(exchange.question)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
            Text(exchange.answer)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.68))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Color.white.opacity(0.12))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Previous question: \(exchange.question). Answer: \(exchange.answer)")
    }

    private var emptyState: String {
        let chord = state.shortcutLabel(.ask)
        let key = chord.isEmpty ? "the ask shortcut" : chord
        return "Press \(key) to ask. Nobody on the call sees this panel."
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: Metrics.itemGap) {
            TextField("Ask something…", text: $composed)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(.white)
                .focused($composerFocused)
                .onSubmit(send)
                .accessibilityLabel("Ask the assistant")
            if assistant.isStreaming {
                Button {
                    assistant.cancel()
                } label: {
                    Image(systemName: "stop.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.7))
                .help("Stop")
                .accessibilityLabel("Stop answering")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(composed.isEmpty ? 0.3 : 0.8))
                .disabled(composed.isEmpty && assistant.detectedQuestion == nil)
                .help("Ask")
                .accessibilityLabel("Send question")
            }
        }
        .padding(.horizontal, Metrics.itemGap)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(Color.white.opacity(0.12)))
    }

    private func send() {
        let text = composed.trimmingCharacters(in: .whitespacesAndNewlines)
        state.askAssistant(text.isEmpty ? nil : text)
        composed = ""
    }

    // MARK: Controls

    private var controlStrip: some View {
        HStack(spacing: Metrics.metaGap) {
            circleButton(showsInsights ? "bolt.fill" : "bolt",
                         showsInsights ? "Turn live insights off" : "Turn live insights on") {
                state.setLiveInsights(!showsInsights)
            }
            if !assistant.answer.isEmpty {
                circleButton("doc.on.doc", "Copy answer") { copyAnswer() }
            }
            circleButton("trash", "Clear") { assistant.clear() }
            circleButton("xmark", "Put the assistant away") {
                state.setAssistantEnabled(false)
            }
        }
        .padding(Metrics.metaGap)
    }

    private func circleButton(_ symbol: String, _ label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.15)))
                .foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func copyAnswer() {
        guard !assistant.answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(assistant.answer, forType: .string)
    }
}

// MARK: - Card (§5.34)

/// One insight. The kind is the small coloured label, the title is the
/// thing itself, the body is what to say or know, and the quote at the
/// bottom is the line that prompted it — the grounding measure, kept
/// visible so the user can check the card against what was actually said
/// without leaving the panel.
private struct InsightCardView: View {
    let card: InsightCard
    let onAsk: () -> Void
    let onPin: () -> Void
    let onDismiss: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Metrics.metaGap) {
                Label(card.kind.cardLabel, systemImage: card.kind.symbolName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                if hovering || card.isPinned { actions }
            }
            Text(card.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.body)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !card.trigger.isEmpty {
                Text("“\(card.trigger)”")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
        }
        .padding(Metrics.itemGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                .fill(Color.white.opacity(card.isPinned ? 0.14 : 0.08)))
        .onHover { hovering = $0 }
        .prismAnimation(value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.kind.cardLabel): \(card.title)")
        .accessibilityValue(card.body)
    }

    /// System colours only (§8.1); the yellow is the detected question's,
    /// because an answer card is that question's other half.
    private var tint: Color {
        switch card.kind {
        case .answer: return .yellow
        case .term: return .mint
        case .fact: return .cyan
        case .followUp: return .purple
        case .commitment: return .green
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            iconButton("text.bubble", "More about this", onAsk)
            iconButton(card.isPinned ? "pin.fill" : "pin",
                       card.isPinned ? "Let this card expire" : "Keep this card", onPin)
            iconButton("xmark", "Dismiss", onDismiss)
        }
    }

    private func iconButton(_ symbol: String, _ label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.15)))
                .foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
