// MeetingSection.swift
// PRISM
//
// The popover's Meeting section (§5.32/§5.33): start or stop transcribing,
// see the last thing that was said, ask the assistant. Nothing else.
//
// This is the one surface in the app that gets opened in the middle of a
// sentence, so it carries only what is worth reading while somebody is
// waiting for you to answer. The model, the language, the far-end source,
// the note template and the whole scrollback live in the main window's
// Meeting pane. A popover that reproduced them would be a second place to
// change your mind about a download mid-call, and the transcript itself is
// unreadable at 320pt — the rejected design put a scrolling transcript here
// and it turned the popover into something you read instead of something you
// glance at.
//
// Two facts are worth the space while a meeting runs. How long it has been
// going, because the elapsed time is what tells you whether PRISM has been
// listening since the call started or since two minutes ago. And whether the
// far end is actually arriving: a system-audio stream that started but never
// delivered audible samples looks identical to a quiet room, and the failure
// only shows up afterwards, as a transcript with one voice in it. Surfacing
// `farEndHeard` mid-call is the difference between fixing it now and finding
// out when you go to write the notes.
//
// `MeetingSession` is its own ObservableObject and AppState does not forward
// its changes, so the drawing is done by a private inner view that observes
// the session directly. And `elapsed` is computed off the clock rather than
// published, so the minute count is wrapped in a slow TimelineView — without
// it the counter freezes during exactly the silence it is meant to measure.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct MeetingSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // The session publishes lines, hypothesis and phase on its own
        // schedule; AppState never republishes them. Observing it directly
        // is the only way this section stays live during a call.
        MeetingSectionBody(session: state.meeting)
    }
}

// MARK: - Body

private struct MeetingSectionBody: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var session: MeetingSession

    private var settings: MeetingSettings { state.studio.meeting }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                controlRow
                if session.phase.isRunning {
                    MinuteTicker(isRunning: true) { statusRow }
                }
                if hasTail {
                    transcriptTail
                }
                if let notice = session.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Meeting notice")
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .prismCard()
        } label: {
            MinuteTicker(isRunning: session.phase.isRunning) { labelRow }
        }
    }

    // MARK: - Label

    private var labelRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Text("Meeting")
                .font(.headline)
            if let summary = collapsedSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Meeting status")
                    .accessibilityValue(summary)
            }
        }
    }

    /// **The load-bearing requirement of this file.** A collapsed section
    /// must never hide the fact that PRISM is listening. Everything else
    /// here can be folded away; "we are recording your words" cannot, because
    /// a section that is shut is the state this popover spends most of its
    /// life in, and a microphone you forgot about is not a feature.
    ///
    /// So the summary is non-nil for every running phase and nil only when
    /// nothing is being transcribed. `preparing` and `stopping` say what they
    /// actually are rather than borrowing the word "Listening" — claiming to
    /// hear you while a model is still downloading is the same kind of lie in
    /// the other direction.
    ///
    /// "you only" rides along when the far end is off, because that is the
    /// setting people forget and only notice in the finished transcript.
    private var collapsedSummary: String? {
        switch session.phase {
        case .idle, .failed:
            return nil
        case .preparing:
            return "Starting"
        case .stopping:
            return "Stopping"
        case .listening:
            var parts = ["Listening"]
            let minutes = Int(session.elapsed / 60)
            if minutes >= 1 { parts.append("\(minutes) min") }
            if settings.farEnd == .off { parts.append("you only") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Button(session.phase.isRunning ? "Stop listening" : "Start listening") {
                state.toggleMeeting()
            }
            .controlSize(.small)
            .help("Transcribe this call on this Mac\(state.shortcutSuffix(.meeting))")
            Spacer(minLength: 0)
            Button("Ask…") { state.askAssistant() }
                .controlSize(.small)
                .disabled(!state.studio.assistant.isActive)
                .help("Open the assistant\(state.shortcutSuffix(.ask))")
                .accessibilityLabel("Ask the assistant")
        }
    }

    /// Elapsed time, plus the far end when there is one. Both are read at a
    /// glance and neither is worth a row of its own.
    private var statusRow: some View {
        HStack(spacing: Metrics.itemGap) {
            Text(phaseText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let farEnd = farEndText {
                Text(farEnd)
                    .font(.caption)
                    .foregroundStyle(farEndIsWarning
                                     ? AnyShapeStyle(Color.orange)
                                     : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meeting")
    }

    private var phaseText: String {
        switch session.phase {
        case .preparing(let progress):
            return "Loading the speech model · \(Int(progress * 100))%"
        case .stopping:
            return "Finishing up"
        default:
            let minutes = Int(session.elapsed / 60)
            return minutes < 1 ? "Under a minute" : "\(minutes) min"
        }
    }

    /// The half-transcript warning. A far-end stream that started but has
    /// never delivered an audible sample is indistinguishable from a quiet
    /// call until the transcript is finished and only has you in it, and
    /// `.chosenApp` with nothing chosen never starts a stream at all.
    private var farEndText: String? {
        guard session.phase.isListening, settings.farEnd != .off else { return nil }
        guard settings.wantsFarEnd else { return "· no app picked, so you only" }
        return session.farEndHeard
            ? "· hearing both sides"
            : "· nothing from the other side yet"
    }

    private var farEndIsWarning: Bool {
        !(settings.wantsFarEnd && session.farEndHeard)
    }

    // MARK: - Transcript tail

    private var hasTail: Bool {
        !session.lines.isEmpty || !session.hypothesis.isEmpty
    }

    /// Two rows, never more: the settled tail, then whatever the recogniser
    /// is still revising, dimmer. Head truncation because the words you want
    /// are the ones at the end — a long line elided from the front still
    /// reads as the sentence that just finished.
    private var transcriptTail: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(tailLines) { line in
                Text("\(line.label): \(line.text)")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            if !session.hypothesis.isEmpty {
                Text(session.hypothesis)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last thing heard")
    }

    /// One settled line when there is a hypothesis under it, two when there
    /// is not, so the block is the same height either way and the popover
    /// does not jump every time the recogniser settles a phrase.
    private var tailLines: [TranscriptLine] {
        Array(session.lines.suffix(session.hypothesis.isEmpty ? 2 : 1))
    }

    // MARK: - Caption

    /// §8.4 — one line, and it answers the only question anybody asks about
    /// this feature. `.none` means the whole thing is local; otherwise name
    /// the provider and say what actually reaches it, which is the notes and
    /// the questions you ask, not a running feed of the call.
    private var caption: String {
        let provider = state.studio.assistant.provider
        guard provider != .none else {
            return "Transcribing on this Mac. Nothing is sent anywhere."
        }
        let destination = "Notes and answers go to \(provider.displayName)."
        return provider.leavesThisMac
            ? "\(destination) The transcript stays on this Mac until you ask for notes."
            : "\(destination) Nothing leaves this Mac."
    }

    // MARK: - Bindings

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { state.expandedSections.contains(.meeting) },
            set: { newValue in
                if newValue != state.expandedSections.contains(.meeting) {
                    state.toggleSection(.meeting)
                }
            })
    }
}

// MARK: - Minute ticker

/// Redraws its content on a slow cadence while a meeting is running.
///
/// `MeetingSession.elapsed` is derived from the clock rather than published,
/// so it only changes value when something *else* causes a redraw — which,
/// during a call, means when somebody speaks. That is precisely backwards:
/// the minute count matters most during a long silence, and that is exactly
/// when nothing would repaint it. Twenty seconds is fine granularity for a
/// figure quoted in whole minutes, and the schedule only runs while this view
/// is actually on screen, which for a menu-bar popover is rarely.
///
/// A Timer publisher held on the view was the alternative and it is a trap:
/// a SwiftUI view struct is rebuilt on every body evaluation, so the timer
/// would be recreated dozens of times a call.
private struct MinuteTicker<Content: View>: View {
    let isRunning: Bool
    let content: () -> Content

    init(isRunning: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.isRunning = isRunning
        self.content = content
    }

    var body: some View {
        if isRunning {
            TimelineView(.periodic(from: .now, by: 20)) { _ in content() }
        } else {
            content()
        }
    }
}
