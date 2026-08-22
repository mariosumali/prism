// MeetingPane.swift
// PRISM
//
// The main window's Meeting pane (§5.32): the live transcript, and everything
// about how it is captured and kept.
//
// The controls here are ordinary — a button, three pickers, two text fields.
// The copy is the feature. Transcription is the one thing PRISM does that
// makes a permanent record of a conversation, and the only honest way to ship
// it is to say, on the surface where it is switched on, exactly what happens
// to the audio and exactly where the words end up. So the privacy block at
// the bottom is standing rather than conditional, the same way the prompter's
// is: a sentence people only see after they have gone looking is a sentence
// written for the lawyers, not for the user.
//
// The transcript is drawn here rather than in a document window of its own.
// The pane keeps the current meeting at hand while also exposing a compact
// library of saved meetings, search, speaker filters, and export controls.
// The underlying JSON files remain ordinary Application Support files that
// can be revealed in Finder whenever direct access is useful.
//
// Notes are the network boundary and they are drawn as one. Everything above
// the Notes section happens on this Mac with no connection at all; pressing
// Write notes sends the transcript to whichever provider the Assistant pane
// is pointed at. Splitting that across two panes was the rejected
// alternative — the button that sends a conversation somewhere belongs next
// to the conversation, where the person pressing it can see what they are
// sending.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MeetingPane: View {
    @EnvironmentObject var state: AppState

    // MeetingSession and Permissions are ObservableObjects in their own
    // right, and AppState does not republish for either — the MicCheck
    // arrangement in VoicePane, for the same reason. Handing them to a body
    // that observes them directly is what keeps a live transcript live
    // without routing every settled word through the frame path's state.
    var body: some View {
        MeetingPaneBody(session: state.meeting, permissions: state.permissions)
    }
}

// MARK: - Body

private struct MeetingPaneBody: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var session: MeetingSession
    @ObservedObject var permissions: Permissions

    /// Seconds since the meeting started, refreshed once a second while the
    /// pane is open. `session.elapsed` is computed from a start date and
    /// publishes nothing of its own, so without this the counter would only
    /// move when somebody happened to speak.
    @State private var elapsed: TimeInterval = 0
    @State private var modelBytes: Int64 = 0
    @State private var removalError: String?
    @State private var transcriptSearch = ""
    @State private var transcriptScope = TranscriptScope.everyone
    @State private var followsTranscript = true
    @State private var copiedTranscript = false
    @State private var transcriptActionError: String?
    @State private var savedMeetings: [MeetingRecord] = []
    @State private var isLoadingMeetings = false

    private enum TranscriptScope: String, CaseIterable {
        case everyone = "All"
        case you = "You"
        case others = "Others"
    }

    /// `@State` rather than a stored `let`: this view is rebuilt every time
    /// AppState publishes, and a publisher rebuilt with it would tear the
    /// subscription down and start a fresh timer on every unrelated change.
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var settings: MeetingSettings { state.studio.meeting }
    private var selectedModel: SpeechModel {
        SpeechModelCatalog.model(named: settings.model)
    }

    var body: some View {
        Form {
            listeningSection
            savedMeetingsSection
            modelSection
            farEndSection
            transcriptSection
            notesSection
            keepingSection
            privacySection
        }
        .formStyle(.grouped)
        .onAppear {
            modelBytes = SpeechModelCatalog.bytesOnDisk()
            elapsed = session.phase.isRunning ? session.elapsed : 0
            refreshSavedMeetings()
        }
        .onChange(of: session.phase) { _ in
            modelBytes = SpeechModelCatalog.bytesOnDisk()
            elapsed = session.phase.isRunning ? session.elapsed : 0
            if !session.phase.isRunning { refreshSavedMeetings() }
        }
        .onChange(of: session.notesPhase) { phase in
            if phase == .ready, !session.phase.isRunning { refreshSavedMeetings() }
        }
        .onReceive(ticker) { _ in
            let current = session.phase.isRunning ? session.elapsed : 0
            if Int(current) != Int(elapsed) { elapsed = current }
        }
    }

    // MARK: - Saved meetings

    private var savedMeetingsSection: some View {
        Section("Saved meetings") {
            HStack(spacing: Metrics.itemGap) {
                if isLoadingMeetings {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if savedMeetings.isEmpty {
                    Text("No saved meetings yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Menu {
                        ForEach(savedMeetings) { meeting in
                            Button {
                                session.viewSavedMeeting(meeting)
                            } label: {
                                Text(savedMeetingLabel(meeting))
                            }
                        }
                    } label: {
                        Label("Open a transcript", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(session.phase.isRunning)
                }
                Spacer(minLength: 0)
                Button {
                    refreshSavedMeetings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isLoadingMeetings)
                .help("Refresh saved meetings")
                .accessibilityLabel("Refresh saved meetings")
                Button("Show folder") { revealMeetingsFolder() }
                    .controlSize(.small)
                    .help("Open PRISM's Meetings folder in Finder")
            }

            if let record = session.record {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.itemGap) {
                    Text(record.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(MeetingNoteWriter.durationText(record.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Viewing \(record.title)")
            }
        }
    }

    private func savedMeetingLabel(_ record: MeetingRecord) -> String {
        let recovery = record.endedAt == nil ? "Recovered · " : ""
        return "\(recovery)\(record.title) — \(record.startedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func refreshSavedMeetings() {
        guard !isLoadingMeetings else { return }
        isLoadingMeetings = true
        TranscriptStore().allInBackground { records in
            savedMeetings = records
            isLoadingMeetings = false
        }
    }

    // MARK: - 1. Listening

    private var listeningSection: some View {
        Section("Listening") {
            HStack(spacing: Metrics.itemGap) {
                Button(session.phase.isRunning ? "Stop listening" : "Start listening") {
                    state.toggleMeeting()
                }
                .buttonStyle(.borderedProminent)
                .disabled(permissions.microphone != .granted)
                .help(session.phase.isRunning
                      ? "Stop transcribing and file the transcript\(state.shortcutSuffix(.meeting))"
                      : "Transcribe this call on this Mac\(state.shortcutSuffix(.meeting))")
                .accessibilityLabel(session.phase.isRunning ? "Stop listening" : "Start listening")
                Spacer(minLength: 0)
                Text(state.shortcutLabel(.meeting))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            phaseRow
            if let notice = session.notice {
                noticeRow(notice)
            }
            if permissions.microphone != .granted {
                Text("PRISM cannot hear anything: microphone access has not been granted. Allow it in System Settings › Privacy & Security › Microphone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Starting here turns transcription on if it was off — the button and the switch ask the same question, so there is only the button.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Where the meeting is, in one row. `.preparing` gets a bar because the
    /// first run of this feature downloads a few hundred megabytes and a
    /// spinner would not say how much longer.
    @ViewBuilder
    private var phaseRow: some View {
        switch session.phase {
        case .idle:
            Text("Not listening.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .preparing(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text(fraction > 0
                     ? "Preparing the speech model… \(Int((fraction * 100).rounded()))%"
                     : "Preparing the speech model…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: min(max(fraction, 0), 1))
                    .accessibilityLabel("Speech model progress")
            }
        case .listening:
            Text("Listening · \(elapsedText)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .stopping:
            Text("Finishing the last few words…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Minutes once there are minutes. "0 min" for the first stretch of a
    /// call is a counter that looks broken.
    private var elapsedText: String {
        let total = Int(max(0, elapsed))
        return total < 60 ? "\(total) s" : "\(total / 60) min"
    }

    private func noticeRow(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.itemGap) {
            Text(notice)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Dismiss") { session.dismissNotice() }
                .controlSize(.small)
                .accessibilityLabel("Dismiss this notice")
        }
    }

    // MARK: - 2. The speech model

    private var modelSection: some View {
        Section("The speech model") {
            Picker("Model", selection: modelBinding) {
                ForEach(SpeechModelCatalog.all) { model in
                    Text("\(model.displayName) · \(model.megabytes) MB")
                        .tag(model.shortName)
                }
            }
            .disabled(session.phase.isRunning)
            .help("Bigger models hear names and technical words better and take longer to download")
            Text(selectedModel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(SpeechModelCatalog.isDownloaded(selectedModel)
                 ? "Already downloaded. Starting is immediate."
                 : "Not downloaded yet. The first start fetches \(selectedModel.megabytes) MB, once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The multilingual model is the only one that can be wrong about
            // this, so it is the only one that asks. An `.en` model ignores
            // the hint entirely, and a field that does nothing is worse than
            // no field.
            if selectedModel.shortName == "large-v3" {
                TextField("Language code, e.g. en, de, ja", text: languageBinding)
                    .disabled(session.phase.isRunning)
                    .accessibilityLabel("Spoken language")
                Text("Tell it which language is being spoken. Guessing from a three-word chunk is a coin flip, and a wrong guess turns a quiet English sentence into Welsh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("The model is downloaded once, kept in your Application Support folder, and used entirely offline from then on. It is the only download PRISM ever makes.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)

            if modelBytes > 0 {
                HStack(spacing: Metrics.itemGap) {
                    Text("\(SpeechModelCatalog.sizeText(modelBytes)) on disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Remove downloaded models") { removeModels() }
                        .controlSize(.small)
                        .disabled(session.phase.isRunning)
                        .help("Delete every downloaded speech model. The next start downloads again.")
                }
            }
            if let removalError {
                Text(removalError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrismSliderRow(label: "Silence",
                           value: silenceBinding,
                           range: 0.001...0.02,
                           defaultValue: 0.005,
                           fractionDigits: 3,
                           snap: 0.001)
                .help("Audio quieter than this is never sent to the model")
            Text("Below this level PRISM does not ask the model at all. That is what stops it inventing words during silence — asked to transcribe room tone, a speech model will confidently produce a sentence nobody said. Raise it if a quiet room is being written down; lower it if someone sitting back from the Mac is being dropped.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 3. The other side

    private var farEndSection: some View {
        Section("The other side") {
            Picker("Transcribe", selection: farEndBinding) {
                ForEach(FarEndSource.allCases, id: \.self) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .accessibilityLabel("What else to transcribe besides your microphone")
            .help("PRISM always has your microphone. This is where everyone else comes from.")
            Text(settings.farEnd.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.farEnd == .chosenApp {
                TextField("Application, e.g. us.zoom.xos", text: farEndAppBinding)
                    .accessibilityLabel("Meeting application bundle identifier")
                    .help("The meeting app's bundle identifier")
                Text("Until an app is named, nothing but your microphone is transcribed. PRISM will not quietly widen this to everything the Mac plays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("What to call them in the transcript", text: farEndLabelBinding)
                .accessibilityLabel("Label for the other side")
                .help("Appears in front of every line PRISM did not hear from your microphone")
            Text("PRISM has no way of knowing who is on the call, and a wrong name in a set of meeting notes is worse than a plain one. Whatever you type is stored with this meeting, so renaming it next week does not relabel last week's transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.farEnd != .off, permissions.screenRecording != .granted {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.itemGap) {
                    Text("macOS calls this permission Screen Recording. It is the permission that covers another application's sound, and it is the only way any app on this Mac is allowed to hear another one. PRISM captures no pixels for it — nothing is looked at, only listened to. The grant takes effect the next time PRISM opens.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Allow…") { state.requestScreenRecordingAccess() }
                        .controlSize(.small)
                        .accessibilityLabel("Allow screen recording permission")
                }
            }
        }
    }

    // MARK: - 4. The transcript

    private var transcriptSection: some View {
        Section("The transcript") {
            transcriptTools
            transcriptScroller
            HStack(spacing: Metrics.itemGap) {
                Text(transcriptCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let saved = saveStatusText {
                    Label(saved, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Transcript \(saved)")
                } else if session.phase.isRunning, settings.savesTranscript,
                          session.wordCount > 0 {
                    Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Metrics.itemGap) {
                Button(copiedTranscript ? "Copied" : "Copy transcript") {
                    copyTranscript()
                }
                .disabled(session.lines.isEmpty)
                Button("Export…") { exportMeeting() }
                    .disabled(session.lines.isEmpty || session.record == nil)
                if let id = session.record?.id,
                   FileManager.default.fileExists(
                    atPath: TranscriptStore().transcriptURL(for: id).path) {
                    Button("Show file") { revealTranscript(id: id) }
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            if let transcriptActionError {
                Text(transcriptActionError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $session.userNotes)
                .font(.body)
                .frame(minHeight: 80)
                .accessibilityLabel("Your own notes")
            Text("Your own notes. These are sent along when notes are written, and they are worth more than anything else in the prompt because a human wrote them on purpose — a name spelled right, a decision that was nodded at rather than said, the thing you want to remember.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcriptTools: some View {
        HStack(spacing: Metrics.itemGap) {
            TextField("Search transcript", text: $transcriptSearch)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search transcript")
            Picker("Speaker", selection: $transcriptScope) {
                ForEach(TranscriptScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .labelsHidden()
            .frame(width: 92)
            Toggle(isOn: $followsTranscript) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Keep the newest words in view")
            .accessibilityLabel("Follow the latest transcript")
        }
    }

    private var visibleTranscriptLines: [TranscriptLine] {
        let query = transcriptSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return session.lines.filter { line in
            let speakerMatches: Bool
            switch transcriptScope {
            case .everyone: speakerMatches = true
            case .you: speakerMatches = line.channel == .directMic
            case .others: speakerMatches = line.channel == .farEnd
            }
            guard speakerMatches else { return false }
            guard !query.isEmpty else { return true }
            return line.text.localizedCaseInsensitiveContains(query)
                || line.label.localizedCaseInsensitiveContains(query)
                || line.timestamp.localizedCaseInsensitiveContains(query)
        }
    }

    private var transcriptCountText: String {
        let shown = visibleTranscriptLines.count
        if transcriptSearch.isEmpty, transcriptScope == .everyone {
            return "\(session.wordCount) words · \(session.lines.count) turns"
        }
        return "\(shown) of \(session.lines.count) turns"
    }

    private var saveStatusText: String? {
        guard settings.savesTranscript, let savedAt = session.lastSavedAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(savedAt)))
        if !session.phase.isRunning { return "saved" }
        if seconds < 5 { return "saved just now" }
        if seconds < 60 { return "saved \(seconds)s ago" }
        return "saved \(seconds / 60)m ago"
    }

    /// Oldest at the top, newest at the bottom, and it follows the
    /// conversation. A live transcript you have to scroll while talking is a
    /// transcript nobody reads.
    private var transcriptScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Metrics.metaGap) {
                    if session.lines.isEmpty, session.hypothesis.isEmpty {
                        Text(emptyTranscriptState)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !session.lines.isEmpty, visibleTranscriptLines.isEmpty {
                        Text("No transcript lines match this search and speaker filter.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(visibleTranscriptLines) { line in
                        transcriptRow(line)
                    }
                    if !session.hypothesis.isEmpty,
                       transcriptSearch.isEmpty, transcriptScope == .everyone {
                        // Never withheld: holding the unsettled tail back is
                        // how a live transcript ends up a sentence behind the
                        // conversation it is transcribing.
                        Text(session.hypothesis)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Still settling: \(session.hypothesis)")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(minHeight: 140, maxHeight: 280)
            .onChange(of: session.lines.count) { _ in
                scrollToTranscriptEnd(proxy)
            }
            .onChange(of: session.hypothesis) { _ in
                scrollToTranscriptEnd(proxy)
            }
        }
    }

    private func transcriptRow(_ line: TranscriptLine) -> some View {
        HStack(alignment: .top, spacing: Metrics.itemGap) {
            Text(line.timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(line.channel == .directMic ? Color.accentColor : Color.orange)
                // A line still settling is drawn dimmer, never withheld.
                Text(line.text)
                    .font(.callout)
                    .foregroundStyle(line.isSettled
                                     ? AnyShapeStyle(.primary)
                                     : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.label) at \(line.timestamp): \(line.text)")
    }

    private var emptyTranscriptState: String {
        if session.phase.isRunning { return "Listening. Words appear as they settle." }
        return "Nothing has been transcribed. Start listening and this fills in as people talk."
    }

    private func scrollToTranscriptEnd(_ proxy: ScrollViewProxy) {
        guard followsTranscript, transcriptSearch.isEmpty,
              transcriptScope == .everyone else { return }
        // No animation: streamed revisions already move frequently, and an
        // animated scroll per revision keeps the main thread continuously
        // compositing during a long answer.
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    // MARK: - 5. Notes

    private var notesSection: some View {
        Section("Notes") {
            Picker("Template", selection: templateBinding) {
                ForEach(NoteTemplate.builtIns) { template in
                    Text(template.name).tag(template.name)
                }
            }
            .help("Which headings the notes are written under")

            HStack(spacing: Metrics.itemGap) {
                Button("Write notes") { state.writeMeetingNotes() }
                    .disabled(!canWriteNotes)
                    .help(writeNotesHelp)
                if session.notesPhase == .writing {
                    ProgressView()
                        .controlSize(.small)
                    Text(session.notesProgress ?? "Writing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { state.cancelMeetingNotes() }
                        .controlSize(.small)
                        .accessibilityLabel("Cancel writing notes")
                }
                Spacer(minLength: 0)
            }

            if case .failed(let message) = session.notesPhase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.studio.assistant.provider == LLMProviderKind.none {
                Text("No AI provider is chosen, so there is nothing to write with. Pick one in the Assistant pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if session.notesPhase == .ready, let record = session.record {
                if let markdown = record.notesMarkdown, !markdown.isEmpty {
                    ScrollView(.vertical) {
                        Text(rendered(markdown))
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 280)
                    .accessibilityLabel("Written notes")
                }
                if !record.actionItems.isEmpty {
                    ForEach(record.actionItems) { item in
                        actionItemRow(item)
                    }
                    Text("Every action item cites the line it came from. A model that has to quote the transcript cannot invent the owner, because the quote would have to be invented too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Writing notes is the one moment this pane uses the network, and only because you pressed the button. The transcript and your own notes go to whichever provider the Assistant pane is set to; nothing goes anywhere before that, and nothing goes on its own afterwards.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionItemRow(_ item: MeetingActionItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Metrics.itemGap) {
                Text(item.owner.isEmpty ? "Unassigned" : item.owner)
                    .font(.callout.weight(.medium))
                Text(item.task)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !item.due.isEmpty {
                    Text(item.due)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(item.timestamp) — \u{201C}\(item.quote)\u{201D}")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.owner.isEmpty ? "Unassigned" : item.owner): \(item.task)"
                            + (item.due.isEmpty ? "" : ", due \(item.due)")
                            + ", from \(item.timestamp)")
    }

    private var canWriteNotes: Bool {
        state.studio.assistant.provider != LLMProviderKind.none
            && session.wordCount > 0
            && session.notesPhase != .writing
    }

    private var writeNotesHelp: String {
        if state.studio.assistant.provider == LLMProviderKind.none {
            return "Choose an AI provider in the Assistant pane first"
        }
        if session.wordCount == 0 {
            return "There is no transcript to write notes from yet"
        }
        return "Send this transcript to your chosen provider and get notes back"
    }

    /// Inline markdown only, whitespace preserved: the notes arrive as
    /// headings and bullets, and collapsing the line breaks to render bold
    /// text would turn a structured document into a paragraph.
    private func rendered(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    // MARK: - 6. Keeping it

    private var keepingSection: some View {
        Section("Keeping it") {
            Toggle("Keep a crash-safe transcript", isOn: savesBinding)
                .help("Checkpoint the words to a file in Application Support while listening")
            Text("PRISM never writes the audio, under any setting. While this is on, it checkpoints the transcript in your Application Support folder so an app or system crash cannot erase the meeting. It is not sent anywhere unless you ask for notes. Turning this off during a meeting removes its checkpoint; the words are gone when the meeting stops.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 7. Privacy

    /// Standing, not conditional (§8.4). This is the section people are
    /// looking for when they open this pane for the first time, and it is
    /// not something to make them earn.
    private var privacySection: some View {
        Section {
            Text("PRISM transcribes on this Mac. The audio never leaves it, is never written to disk, and is gone the moment it has been read — the speech model runs here, and the buffer it reads from is overwritten seconds later.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing is transcribed while you are muted. When you mute, PRISM stops receiving the microphone entirely, so there is nothing to hear and no buffer holding what was said before. A gap in the transcript is a gap: PRISM will not stitch two halves of a sentence across it, because a sentence joined across a mute is a sentence nobody said.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text("The transcript is a file in your Application Support folder, and is not sent anywhere unless you ask for notes.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func copyTranscript() {
        let text = TranscriptRenderer.render(
            visibleTranscriptLines, includeTimestamps: true)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedTranscript = true
        transcriptActionError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedTranscript = false
        }
    }

    private func exportMeeting() {
        guard let record = session.recordForNotes() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = safeFilename(record.title) + ".md"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let markdown = MeetingExport.markdown(
                record: record,
                transcript: TranscriptRenderer.render(
                    session.lines, includeTimestamps: true))
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                transcriptActionError = nil
            } catch {
                transcriptActionError = "PRISM couldn't export this meeting — \(error.localizedDescription)"
            }
        }
    }

    private func safeFilename(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        let parts = title.components(separatedBy: forbidden)
        let cleaned = parts.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Meeting" : cleaned
    }

    private func revealTranscript(id: String) {
        let url = TranscriptStore().transcriptURL(for: id)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func revealMeetingsFolder() {
        let directory = TranscriptStore.directory
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
            transcriptActionError = nil
        } catch {
            transcriptActionError = "PRISM couldn't open the Meetings folder — \(error.localizedDescription)"
        }
    }

    private func removeModels() {
        do {
            try SpeechModelCatalog.removeAll()
            removalError = nil
        } catch {
            removalError = "Could not remove the models: \(error.localizedDescription)"
        }
        modelBytes = SpeechModelCatalog.bytesOnDisk()
    }

    // MARK: - Bindings

    private var modelBinding: Binding<String> {
        Binding(
            get: { state.studio.meeting.model },
            set: { state.setMeetingModel($0) })
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { state.studio.meeting.language },
            set: { state.setMeetingLanguage($0) })
    }

    private var silenceBinding: Binding<Double> {
        Binding(
            get: { state.studio.meeting.clampedSilenceRMS },
            set: { state.setMeetingSilenceRMS($0) })
    }

    private var farEndBinding: Binding<FarEndSource> {
        Binding(
            get: { state.studio.meeting.farEnd },
            set: { state.setMeetingFarEnd($0) })
    }

    /// An emptied field means "not picked yet", which the settings model
    /// spells `nil` — and which is a different state from an app that was
    /// picked and has since quit.
    private var farEndAppBinding: Binding<String> {
        Binding(
            get: { state.studio.meeting.farEndBundleID ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                state.setMeetingFarEndApp(trimmed.isEmpty ? nil : trimmed)
            })
    }

    private var farEndLabelBinding: Binding<String> {
        Binding(
            get: { state.studio.meeting.farEndLabel },
            set: { state.setMeetingFarEndLabel($0) })
    }

    private var templateBinding: Binding<String> {
        Binding(
            get: { state.studio.meeting.templateName },
            set: { state.setMeetingTemplate($0) })
    }

    private var savesBinding: Binding<Bool> {
        Binding(
            get: { state.studio.meeting.savesTranscript },
            set: { state.setMeetingSavesTranscript($0) })
    }
}
