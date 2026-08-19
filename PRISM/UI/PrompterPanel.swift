// PrompterPanel.swift
// PRISM
//
// The teleprompter (§5.27): a floating panel over the user's own desktop
// that scrolls their script, and the one piece of text in PRISM that is
// never composited into the picture.
//
// That is the whole design decision, and it is worth stating plainly. A
// prompter drawn into the outgoing frame would be a prompter everyone on the
// call can read — which is not a feature, it is a leak. So the script lives
// on the reader's screen, positioned by them wherever their lens is, which
// is also what makes it compose with eye contact (§5.6): you read from just
// under the camera and the correction closes the last few degrees.
//
// Three things keep the script off other people's screens, and they are
// independent on purpose:
//
//   Nothing on the frame path knows the prompter exists. PrompterSettings
//   lives in StudioSettings, not PipelineConfiguration, and no stage reads
//   it — there is no code path from a script to a texture.
//
//   `sharingType = .none` takes the panel out of the window server's capture
//   surface entirely. Zoom, Teams, QuickTime, ScreenCaptureKit and PRISM's
//   own screen source all get the desktop with a prompter-shaped hole in it,
//   because the refusal is made below all of them. Screen-sharing while
//   prompting is the case this exists for, and it is not one PRISM can ask
//   the other app to handle.
//
//   PRISM's display capture (§5.24) already excludes every window PRISM
//   owns, so the panel is doubly excluded from the one screen source this
//   app does control.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

// MARK: - Panel

@MainActor
final class PrompterPanelController: NSWindowController, NSWindowDelegate {
    private let state: AppState

    /// Roomy enough for two or three lines at the default size, and narrow
    /// enough to sit beside a lens rather than across the whole display.
    private static let defaultSize = NSSize(width: 560, height: 230)

    init(state: AppState) {
        self.state = state
        let hosting = NSHostingController(
            rootView: PrompterPanelView().environmentObject(state))
        hosting.sizingOptions = []

        let panel = NSPanel(contentViewController: hosting)
        panel.styleMask = [.titled, .closable, .resizable,
                           .fullSizeContentView, .nonactivatingPanel]
        // The panel is chrome-free: a title bar over a script is a title bar
        // in your eyeline. Dragging the body moves it, and the close button
        // lives in the hover strip inside the content.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false

        // Floating and non-activating: clicking the prompter must not pull
        // focus off the call in front of it, and it has to stay visible over
        // a full-screen meeting window on any space.
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle]

        // The load-bearing line of this file. See the header: the window
        // server itself refuses to hand these pixels to any screen recorder,
        // which is the only place the promise can be made once and hold for
        // every app that might be capturing.
        panel.sharingType = .none

        panel.isReleasedWhenClosed = false
        panel.tabbingMode = .disallowed
        panel.setContentSize(Self.defaultSize)
        panel.contentMinSize = NSSize(width: 320, height: 120)
        panel.setFrameOrigin(Self.origin(for: state.studio.prompter.anchor,
                                         size: Self.defaultSize))
        super.init(window: panel)
        // After the anchor default, so a frame the user has dragged wins.
        panel.setFrameAutosaveName("PRISM.PrompterPanel")
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PrompterPanelController is code-only")
    }

    /// `orderFrontRegardless` rather than `makeKeyAndOrderFront`: putting the
    /// script up must not take the keyboard away from whatever the user is
    /// about to talk over.
    func show() {
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// Closing the panel is how the prompter is put away, so it has to mean
    /// the same thing as the switch — otherwise the panel would be gone and
    /// the chord would still think it was running.
    func windowWillClose(_ notification: Notification) {
        state.setPrompterEnabled(false)
    }

    /// Where a prompter nobody has dragged yet opens: horizontally centred,
    /// and vertically wherever the user says their camera is.
    private static func origin(for anchor: PrompterAnchor, size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 120, y: 120) }
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let y: CGFloat
        switch anchor {
        case .top: y = frame.maxY - size.height - 12
        case .center: y = frame.midY - size.height / 2
        case .bottom: y = frame.minY + 12
        }
        return NSPoint(x: x.rounded(), y: y.rounded())
    }
}

// MARK: - Panel contents

struct PrompterPanelView: View {
    @EnvironmentObject var state: AppState

    /// Scroll position in points, split into the part already banked and the
    /// part being animated. Keeping the two separate is what makes pause
    /// exact: the clock is only ever consulted while the script is moving.
    @State private var bankedOffset: CGFloat = 0
    @State private var runningSince: Date?
    @State private var scriptHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    @State private var showsControls = false

    private var settings: PrompterSettings { state.studio.prompter }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(.black)
                script
                controls
            }
            .opacity(settings.clampedOpacity)
            .onAppear { visibleHeight = proxy.size.height }
            .onChange(of: proxy.size.height) { visibleHeight = $0 }
        }
        .onPreferenceChange(ScriptHeightKey.self) { scriptHeight = $0 }
        .onHover { showsControls = $0 }
        .onChange(of: state.prompterRunning) { running in
            if running {
                runningSince = Date()
            } else {
                // Bank exactly what was on screen, so resuming picks up the
                // line the reader stopped on rather than one the clock kept
                // counting toward while they were not reading.
                bankedOffset = offset(at: Date())
                runningSince = nil
            }
        }
        .onChange(of: state.prompterResetToken) { _ in
            bankedOffset = 0
            runningSince = state.prompterRunning ? Date() : nil
        }
    }

    // MARK: Script

    @ViewBuilder
    private var script: some View {
        if settings.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Write your script in PRISM's Prompter pane. Nobody on the call can see this panel.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(Metrics.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !state.prompterRunning)) { context in
                Text(settings.script)
                    .font(.system(size: settings.clampedFontSize, weight: .medium))
                    // The system's own 1.2 leading plus this is the 1.35 line
                    // height PrompterSettings derives the scroll rate from,
                    // so "lines per minute" measures real lines.
                    .lineSpacing(settings.clampedFontSize * 0.15)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
                    .background(heightReader)
                    .offset(y: -offset(at: context.date))
                    // The flip belongs to the words, not the panel: on a
                    // beam-splitter rig the glass reverses what it reflects,
                    // and the buttons are pressed on this side of it.
                    .scaleEffect(x: settings.isMirrored ? -1 : 1, y: 1, anchor: .center)
            }
            .padding(.vertical, Metrics.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius,
                                        style: .continuous))
        }
    }

    private var heightReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: ScriptHeightKey.self, value: proxy.size.height)
        }
    }

    /// Banked travel plus whatever the clock has added since the last start,
    /// clamped so the script comes to rest on its last line rather than
    /// scrolling off into an empty panel nobody can read their way back from.
    private func offset(at date: Date) -> CGFloat {
        var total = bankedOffset
        if let runningSince {
            total += CGFloat(max(0, date.timeIntervalSince(runningSince))
                * settings.scrollRate)
        }
        // The last line comes to rest a third of the way up, which is where a
        // reader's eye already is.
        return min(max(0, total), max(0, scriptHeight - visibleHeight * 0.34))
    }

    // MARK: Controls

    /// Hidden until the pointer is over the panel: this thing sits in the
    /// user's eyeline while they are on camera, and a permanent row of
    /// buttons there is a row of buttons everyone watches them look at.
    private var controls: some View {
        HStack(spacing: Metrics.itemGap) {
            Spacer(minLength: 0)
            button(state.prompterRunning ? "pause.fill" : "play.fill",
                   label: state.prompterRunning ? "Pause the script" : "Start the script") {
                state.togglePrompter()
            }
            button("arrow.uturn.backward", label: "Back to the first line") {
                state.resetPrompter()
            }
            button("xmark", label: "Close the prompter") {
                state.setPrompterEnabled(false)
            }
        }
        .padding(Metrics.itemGap)
        .opacity(showsControls ? 1 : 0)
        .prismAnimation(value: showsControls)
    }

    private func button(_ symbol: String, label: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ScriptHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
