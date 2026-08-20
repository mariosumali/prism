// MeetingSession.swift
// PRISM
//
// The live transcript: what is running, what has been heard, and what is
// still settling (§5.32).
//
// A sub-object AppState owns and the UI observes directly, in the MicCheck
// mould — the alternative is another two hundred lines inside a four-
// thousand-line class, describing a feature that has nothing to do with the
// frame path.
//
// Every dependency arrives as a closure or a protocol: the microphone tap,
// the far-end capture, the recogniser, the clock. That is what makes the
// whole state machine testable with no hardware, no permission, no model
// and no meeting — a mute mid-sentence, a lapped ring, a stop while a
// decode is in flight are all things you want a test for and none of them
// are things you want to reproduce by hand.
//
// The shape of the loop, per channel:
//
//   drain the tap  →  resample 48k→16k  →  RMS gate  →  rolling buffer
//        →  decode  →  LocalAgreement  →  channel state  →  delta
//
// Two things about that are worth stating plainly, because they are the
// difference between a transcript and a plausible-looking fabrication.
//
// The RMS gate runs before the recogniser, not after. Whisper hallucinates
// confidently on silence — subtitle credits, "Thank you.", a phrase
// repeated until the chunk is full — and the cheapest fix by a wide margin
// is not to ask it. `TranscriptSanitizer` catches what still gets through.
//
// And a gap is a gap. When the microphone is muted the tap receives
// nothing, and this stops rather than stitching across it: two halves of a
// sentence minutes apart, joined, is a sentence nobody said.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Phase

public enum MeetingPhase: Equatable {
    case idle
    /// Downloading or loading the speech model, 0…1.
    case preparing(Double)
    case listening
    case stopping
    case failed(String)

    public var isRunning: Bool {
        switch self {
        case .listening, .preparing, .stopping: return true
        case .idle, .failed: return false
        }
    }

    public var isListening: Bool { self == .listening }
}

public enum NotesPhase: Equatable {
    case none
    case writing
    case ready
    case failed(String)
}

// MARK: - Session

@MainActor
public final class MeetingSession: ObservableObject {

    // MARK: Published

    @Published public private(set) var phase: MeetingPhase = .idle
    /// Settled lines, oldest first. What the pane and the popover draw.
    @Published public private(set) var lines: [TranscriptLine] = []
    /// The tail the recogniser is still revising. Drawn dimmer; never
    /// withheld, because withholding it is how a live transcript ends up a
    /// sentence behind the conversation.
    @Published public private(set) var hypothesis: String = ""
    @Published public private(set) var notesPhase: NotesPhase = .none
    @Published public private(set) var record: MeetingRecord?
    /// True once the far-end stream has delivered audio that is actually
    /// audible — not merely that it started. See `SystemAudioCapture`.
    @Published public private(set) var farEndHeard = false
    /// A sentence to show when something degraded but the meeting carried
    /// on — the far end could not be captured, or audio was dropped.
    @Published public private(set) var notice: String?
    /// Typed during the call. Worth more to the notes prompt than anything
    /// else in it, because it is the one part a human wrote on purpose.
    @Published public var userNotes: String = ""

    // MARK: Injected

    public typealias EngineFactory = (SpeechModel) -> SpeechRecognizing

    private let engineFactory: EngineFactory
    private let armMicTap: (Bool) -> Void
    private let micTapCursor: () -> UInt64
    private let readMicTap: (UInt64, UnsafeMutablePointer<Float>, Int) -> (cursor: UInt64, frames: Int)
    private let farEnd: (any SystemAudioCapturing)?
    private let store: TranscriptStore
    private let now: () -> Date
    /// Whether the microphone is currently off air — muted, or displaced by
    /// clip audio. The tap starves in both cases, and this is how the
    /// session tells "nobody is speaking" from "PRISM is not being given
    /// anything to hear".
    ///
    /// Settable rather than injected because the owner cannot form a
    /// closure over itself before it exists; AppState installs it
    /// immediately after construction.
    public var micIsOffAir: () -> Bool

    public init(engineFactory: @escaping EngineFactory,
                armMicTap: @escaping (Bool) -> Void,
                micTapCursor: @escaping () -> UInt64,
                readMicTap: @escaping (UInt64, UnsafeMutablePointer<Float>, Int) -> (cursor: UInt64, frames: Int),
                farEnd: (any SystemAudioCapturing)?,
                store: TranscriptStore? = nil,
                micIsOffAir: @escaping () -> Bool = { false },
                now: @escaping () -> Date = Date.init) {
        self.engineFactory = engineFactory
        self.armMicTap = armMicTap
        self.micTapCursor = micTapCursor
        self.readMicTap = readMicTap
        self.farEnd = farEnd
        // Constructed here rather than as a default argument: a default
        // argument expression is evaluated in a nonisolated context, and
        // TranscriptStore is main-actor isolated.
        self.store = store ?? TranscriptStore()
        self.micIsOffAir = micIsOffAir
        self.now = now
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrames)
        scratch.initialize(repeating: 0, count: Self.scratchFrames)
    }

    deinit {
        scratch.deallocate()
    }

    // MARK: Settings snapshot

    public private(set) var settings = MeetingSettings()

    public func apply(_ settings: MeetingSettings) {
        let modelChanged = settings.model != self.settings.model
        self.settings = settings
        // A model swap mid-meeting is not something to do quietly: the new
        // one has to be downloaded and loaded, which takes long enough to
        // lose the thread of the conversation. The picker is disabled while
        // listening; this is the belt to that braces.
        if modelChanged, phase.isRunning {
            notice = "The speech model changes the next time you start listening."
        }
    }

    // MARK: State

    private var engine: SpeechRecognizing?
    private var micChannel = ChannelPipeline(channel: .directMic)
    private var farChannel = ChannelPipeline(channel: .farEnd)
    private var words: [TranscriptWord] = []
    /// The current preview per channel — a snapshot each delta replaces.
    private var partials: [ChannelProfile: [TranscriptWord]] = [:]
    private var drainTimer: Timer?
    private var decodeTask: Task<Void, Never>?
    private var startedAt = Date()
    private var meetingID = UUID().uuidString
    /// Wall clock at which the far end is judged to have failed if nothing
    /// audible has arrived. Fifteen seconds: long enough for a quiet start,
    /// short enough that the user finds out during the call rather than
    /// from half a transcript afterwards.
    private var farEndDeadline: Date?

    private static let scratchFrames = 48_000      // 1 s at 48 kHz
    private let scratch: UnsafeMutablePointer<Float>

    // MARK: - Lifecycle

    public func start() {
        guard !phase.isRunning else { return }
        guard settings.isActive else { return }

        meetingID = UUID().uuidString
        startedAt = now()
        words = []
        lines = []
        hypothesis = ""
        notesPhase = .none
        notice = nil
        farEndHeard = false
        micChannel.reset()
        farChannel.reset()
        partials = [:]
        record = MeetingRecord(id: meetingID,
                               title: MeetingRecord.defaultTitle(for: startedAt),
                               startedAt: startedAt,
                               farEndLabel: settings.resolvedFarEndLabel)

        phase = .preparing(0)

        let model = SpeechModelCatalog.model(named: settings.model)
        let engine = engineFactory(model)
        self.engine = engine

        Task { [weak self] in
            do {
                try await engine.load { state in
                    Task { @MainActor [weak self] in
                        self?.applyModelState(state)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.phase = .failed(error.localizedDescription)
                    self?.teardownCapture()
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.beginListening()
            }
        }
    }

    private func applyModelState(_ state: SpeechModelState) {
        // Progress reports may only move the bar while the bar is still on
        // screen. They arrive on a separate hop from the completion that
        // starts listening, so a `.loading` enqueued just before `load`
        // returns can be delivered *after* the session has already reached
        // `.listening` — and without this guard it would write `.preparing`
        // back over it. `beginListening`'s own guard has passed by then, so
        // nothing would ever move it forward again: the session would sit
        // in `.preparing` forever with the tap armed and the drain running,
        // transcribing into a UI that says it is still getting ready.
        //
        // A failure is the one report that is always allowed through, since
        // an engine that dies after loading has to be able to say so.
        switch state {
        case .failed(let reason):
            phase = .failed(reason)
        case .ready:
            break                     // beginListening owns that transition
        case .absent, .downloading, .loading:
            guard case .preparing = phase else { return }
            switch state {
            case .absent: phase = .preparing(0)
            case .downloading(let fraction): phase = .preparing(fraction * 0.9)
            case .loading: phase = .preparing(0.95)
            default: break
            }
        }
    }

    private func beginListening() {
        guard case .preparing = phase else { return }

        micChannel.cursor = micTapCursor()
        armMicTap(true)

        if settings.wantsFarEnd, let farEnd {
            farEnd.onFailure = { [weak self] message in
                Task { @MainActor [weak self] in
                    // The meeting carries on with the near side. A far end
                    // that stops is a degraded transcript, not a failed one,
                    // and stopping the whole thing would throw away the half
                    // that still works.
                    self?.notice = message
                    self?.farEndDeadline = nil
                }
            }
            farEndDeadline = now().addingTimeInterval(15)
            let bundleID = settings.farEnd == .chosenApp ? settings.farEndBundleID : nil
            Task { [weak farEnd] in
                await farEnd?.start(bundleID: bundleID)
                await MainActor.run { [weak self] in
                    guard let self, let farEnd = self.farEnd else { return }
                    self.farChannel.cursor = farEnd.tapCursor
                }
            }
        }

        phase = .listening
        startDrainTimer()
    }

    public func stop() {
        guard phase.isRunning else { return }
        phase = .stopping

        teardownCapture()

        // Emit whatever each channel was holding back. The stitcher holds
        // the last word of every batch in case the next one continues it;
        // at the end of a meeting there is no next one, so it has to be
        // released or the transcript quietly loses its final word.
        apply(micChannel.state.finish(), channel: .directMic)
        apply(farChannel.state.finish(), channel: .farEnd)
        hypothesis = ""

        var finished = record ?? MeetingRecord(id: meetingID, title: MeetingRecord.defaultTitle(for: startedAt), startedAt: startedAt)
        finished.endedAt = now()
        finished.words = words
        finished.userNotes = userNotes
        finished.farEndLabel = settings.resolvedFarEndLabel
        record = finished

        if settings.savesTranscript, !words.isEmpty {
            do {
                try store.save(finished)
            } catch {
                notice = "PRISM couldn't save the transcript — \(error.localizedDescription)"
            }
        }

        Task { [engine] in await engine?.unload() }
        engine = nil
        phase = .idle
    }

    private func teardownCapture() {
        drainTimer?.invalidate()
        drainTimer = nil
        decodeTask?.cancel()
        decodeTask = nil
        armMicTap(false)
        farEndDeadline = nil
        if let farEnd {
            Task { [weak farEnd] in await farEnd?.stop() }
        }
    }

    // MARK: - Draining

    /// 10 Hz. Fast enough that the buffer never runs far behind the ring,
    /// slow enough that the main thread is doing this a tenth of the time
    /// it would at frame rate.
    private func startDrainTimer() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drain() }
        }
        // .common, not the default mode: a timer scheduled the ordinary way
        // stops firing while a menu is open or a window is being dragged,
        // and a transcript that pauses because somebody opened the popover
        // is a transcript with holes in it at exactly the wrong moments.
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
    }

    private func drain() {
        guard phase.isListening else { return }

        drainMic()
        drainFarEnd()
        checkFarEndDeadline()

        // One decode at a time, across both channels. The recogniser is an
        // actor and would serialise anyway, but queueing two decodes deep
        // means the second one starts against a buffer the first already
        // consumed.
        if decodeTask == nil {
            scheduleDecode()
        }
    }

    private func drainMic() {
        // Muted, or clip audio owns the ring: the tap is receiving nothing
        // at all, so there is no audio to interpret and nothing to wait
        // for. Break the buffer rather than letting the next real speech
        // stitch onto whatever was said before the mute.
        if micIsOffAir() {
            micChannel.breakContinuity()
            micChannel.cursor = micTapCursor()
            return
        }
        let (cursor, frames) = readMicTap(micChannel.cursor, scratch, Self.scratchFrames)
        ingest(&micChannel, requestedCursor: micChannel.cursor,
               returnedCursor: cursor, frames: frames)
    }

    private func drainFarEnd() {
        guard let farEnd, farEnd.isRunning else { return }
        let (cursor, frames) = farEnd.read(from: farChannel.cursor,
                                           into: scratch, maxFrames: Self.scratchFrames)
        ingest(&farChannel, requestedCursor: farChannel.cursor,
               returnedCursor: cursor, frames: frames)
        if farEnd.hasHeardAnything, !farEndHeard {
            farEndHeard = true
            farEndDeadline = nil
        }
    }

    /// Common tail for both channels: notice a lapped ring, resample, gate,
    /// and append.
    private func ingest(_ pipeline: inout ChannelPipeline,
                        requestedCursor: UInt64,
                        returnedCursor: UInt64,
                        frames: Int) {
        guard frames > 0 else { return }

        // The ring skips a lapped reader forward silently. Comparing what
        // came back against what was asked for is the only way to notice,
        // and the honest response is a gap rather than a splice.
        let expected = requestedCursor + UInt64(frames)
        if returnedCursor > expected {
            let dropped = Int(returnedCursor - expected)
            pipeline.breakContinuity(droppedFrames: dropped / 3)
            notice = "PRISM fell behind and lost about "
                + String(format: "%.1f", Double(dropped) / 48_000.0)
                + " seconds of audio."
        }
        pipeline.cursor = returnedCursor

        var resampled: [Float] = []
        resampled.reserveCapacity(frames / 3 + 4)
        pipeline.resampler.append(scratch, frameCount: frames, into: &resampled)
        guard !resampled.isEmpty else { return }

        // The gate. Below this the recogniser is not called at all — see
        // the file header.
        if SpeechLevel.rms(resampled) < settings.clampedSilenceRMS {
            pipeline.silentRuns += 1
            // A long silence ends the utterance rather than padding the
            // buffer with room tone the model would be charged to read.
            if pipeline.silentRuns > 20, pipeline.buffer.pendingSeconds > 0 {
                pipeline.wantsFlush = true
            }
            return
        }
        pipeline.silentRuns = 0
        pipeline.buffer.append(resampled)
    }

    private func checkFarEndDeadline() {
        guard let deadline = farEndDeadline, now() >= deadline else { return }
        farEndDeadline = nil
        guard !farEndHeard else { return }
        // Every layer of this reports success while producing silence, so
        // "the stream started" is not evidence. Saying so beats half a
        // transcript the user has to work out the shape of themselves.
        notice = "PRISM couldn't hear the other side. Only your microphone is "
            + "being transcribed — check Screen Recording permission, or that "
            + "the meeting is playing through the app you picked."
    }

    // MARK: - Decoding

    private func scheduleDecode() {
        guard let engine else { return }
        // Decode the channel with the most waiting. Both are usually idle;
        // when both have audio the longer one is closer to overflowing its
        // window. Selected by channel rather than by key path: these are
        // stored properties of a class, and a value-typed key path into one
        // cannot be written back through.
        let ready = [micChannel, farChannel].filter(\.readyToDecode)
        guard let target = ready.max(by: {
            $0.buffer.pendingSeconds < $1.buffer.pendingSeconds
        }) else { return }

        let channel = target.channel
        var pipeline = self[channel]
        let request = pipeline.makeRequest(language: settings.language)
        pipeline.buffer.markDecoded()
        pipeline.wantsFlush = false
        self[channel] = pipeline

        decodeTask = Task { [weak self] in
            let hypothesis = try? await engine.transcribe(request, channel: channel)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.decodeTask = nil
                if let hypothesis { self.applyHypothesis(hypothesis, to: channel) }
            }
        }
    }

    /// The two pipelines, addressed by the channel they carry.
    private subscript(channel: ChannelProfile) -> ChannelPipeline {
        get { channel == .directMic ? micChannel : farChannel }
        set {
            if channel == .directMic { micChannel = newValue } else { farChannel = newValue }
        }
    }

    private func applyHypothesis(_ hypothesis: SpeechHypothesis,
                                 to channel: ChannelProfile) {
        var pipeline = self[channel]

        // Whole-chunk hallucination check before anything is committed.
        if let text = TranscriptSanitizer.clean(hypothesis.text), !text.isEmpty {
            let confirmed = pipeline.agreement.insert(hypothesis.words)
            if !confirmed.isEmpty {
                let cleaned = TranscriptSanitizer.clean(confirmed)
                apply(pipeline.state.applyFinal(cleaned), channel: channel)
                // Trim to just behind what was confirmed, keeping enough
                // overlap that the next decode still agrees with this one.
                if let last = confirmed.last {
                    let sample = RollingSpeechBuffer.sample(forMilliseconds: last.endMs)
                    pipeline.buffer.trim(confirmedTo: sample)
                }
            }
            apply(pipeline.state.applyPartial(pipeline.agreement.provisional),
                  channel: channel)
        } else {
            // Nothing survived the sanitizer: drop the window rather than
            // letting the model try the same silence again next tick.
            pipeline.buffer.trim(confirmedTo: pipeline.buffer.offsetSamples
                                 + pipeline.buffer.samples.count)
        }

        self[channel] = pipeline
        rebuildHypothesis()
    }

    // MARK: - Applying deltas

    /// The three-step contract from `TranscriptDelta`, in order: remove what
    /// was replaced, persist what is new, then replace the preview.
    ///
    /// The third step is a *replacement*, not an append — `partials` is a
    /// snapshot of what is currently being previewed. Appending them
    /// instead would accumulate a transcript of every intermediate guess
    /// the recogniser ever made.
    private func apply(_ delta: TranscriptDelta, channel: ChannelProfile) {
        partials[channel] = delta.partials
        guard !delta.isEmpty else { return }
        if !delta.replacedIds.isEmpty {
            let removed = Set(delta.replacedIds)
            words.removeAll { removed.contains($0.id) }
        }
        if !delta.newWords.isEmpty {
            words.append(contentsOf: delta.newWords)
            words.sort {
                ($0.startMs, $0.channel.sortRank) < ($1.startMs, $1.channel.sortRank)
            }
            lines = TranscriptRenderer.lines(words,
                                             youLabel: TranscriptRenderer.defaultYouLabel,
                                             farEndLabel: settings.resolvedFarEndLabel)
            record?.words = words
        }
    }

    private func rebuildHypothesis() {
        let all = (partials[.directMic] ?? []) + (partials[.farEnd] ?? [])
        hypothesis = all
            .sorted { $0.startMs < $1.startMs }
            .map(\.trimmed)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Reading out

    public var labelledTranscript: String {
        TranscriptRenderer.labelled(words,
                                    youLabel: TranscriptRenderer.defaultYouLabel,
                                    farEndLabel: settings.resolvedFarEndLabel)
    }

    /// The last few lines, for the assistant's rolling context.
    public func transcriptTail(turns: Int) -> String {
        TranscriptRenderer.tail(words, turns: turns,
                               youLabel: TranscriptRenderer.defaultYouLabel,
                               farEndLabel: settings.resolvedFarEndLabel)
    }

    public var elapsed: TimeInterval {
        phase.isRunning ? now().timeIntervalSince(startedAt) : (record?.duration ?? 0)
    }

    public var wordCount: Int { words.count }

    public func dismissNotice() { notice = nil }

    // MARK: - Notes

    public func applyNotes(markdown: String, title: String?, items: [MeetingActionItem]) {
        guard var record else { return }
        record.notesMarkdown = markdown
        record.actionItems = items
        if let title, !title.isEmpty { record.title = title }
        self.record = record
        notesPhase = .ready
        try? store.save(record)
        try? store.saveNotes(markdown, for: record)
    }

    public func setNotesPhase(_ phase: NotesPhase) { notesPhase = phase }
}

// MARK: - Per-channel pipeline

/// Everything one audio stream needs on its way to becoming words. Two of
/// these exist; they never touch each other's state, which is what makes
/// "who said what" a property of the wiring rather than of a model.
struct ChannelPipeline {
    let channel: ChannelProfile
    var cursor: UInt64 = 0
    var resampler = SpeechResampler()
    var buffer = RollingSpeechBuffer()
    var agreement = HypothesisBuffer()
    var state: TranscriptChannelState
    var silentRuns = 0
    /// Set when a silence has ended an utterance, so a short final phrase
    /// gets decoded instead of waiting for the buffer to fill.
    var wantsFlush = false

    init(channel: ChannelProfile) {
        self.channel = channel
        self.state = TranscriptChannelState(channel: channel)
    }

    /// Decode when there is a couple of seconds of new speech, or when a
    /// silence has closed an utterance and something is waiting.
    var readyToDecode: Bool {
        if wantsFlush { return buffer.pendingSeconds > 0.2 }
        return buffer.pendingSeconds >= 2.0
    }

    func makeRequest(language: String) -> SpeechRequest {
        // Everything already confirmed stays in the window as context the
        // model may read but must not re-emit — which is what makes the
        // next hypothesis agree with the last one.
        let clipFrom = Float(max(0, buffer.durationSeconds - buffer.pendingSeconds - 2.0))
        return SpeechRequest(samples16k: buffer.samples,
                             sampleOffset: buffer.requestOffset,
                             clipFromSeconds: clipFrom,
                             prefixTokens: [],
                             language: language,
                             wantsWordTimestamps: true)
    }

    mutating func breakContinuity(droppedFrames: Int = 0) {
        buffer.breakContinuity(advancingBy: droppedFrames)
        resampler.reset()
        agreement.reset()
        silentRuns = 0
        wantsFlush = false
    }

    mutating func reset() {
        cursor = 0
        resampler.reset()
        buffer.reset()
        agreement.reset()
        state.reset()
        silentRuns = 0
        wantsFlush = false
    }
}
