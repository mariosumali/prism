// AssistantPanel.swift
// PRISM
//
// The assistant's answer, floating over the user's own desktop (§5.33), and
// the second piece of text in PRISM that is never composited into the
// picture.
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
    @State private var composed = ""
    @State private var hovering = false
    @FocusState private var composerFocused: Bool

    private var assistant: AssistantSession { state.assistant }
    private var settings: AssistantSettings { state.studio.assistant }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color.black)
                .opacity(settings.clampedOpacity)

            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                header
                answerArea
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
            // something to answer — it has not been sent anywhere.
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

    // MARK: Answer

    @ViewBuilder
    private var answerArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.metaGap) {
                    if let error = assistant.lastError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if assistant.answer.isEmpty {
                        Text(emptyState)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(assistant.answer)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: assistant.answer) { _ in
                // Follow the answer as it streams; a panel you have to
                // scroll while talking is a panel you will not read.
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
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
}
