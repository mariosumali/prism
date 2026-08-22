// MeetingSessionTests.swift
// PRISMTests
//
// The §5.32 live-transcript state machine, driven headless through the
// closures and protocols `MeetingSession` takes in place of hardware.
//
// The bugs this file exists to catch are the ones that produce a transcript
// which reads perfectly and is wrong. A splice is the whole family: the
// user mutes mid-sentence, or the tap ring laps a stalled reader, and the
// two surviving halves get joined into a sentence nobody said. Nothing
// downstream can detect that — the words are real words, the times are
// monotonic, the line renders — so the only place it can be caught is here,
// at the moment the audio is handed over. Every gap test below asserts on
// what the recogniser was actually given, because "the session broke
// continuity" is only true if the audio from before the break never reaches
// a decode.
//
// The second family is lifecycle. A session that arms the microphone tap
// and then fails to load its model leaves PRISM reading a device for a
// feature that is not running; a session that stops without finalising
// silently loses the last word of the meeting, because the stitcher holds
// one word back in case the next batch continues it and at the end of a
// meeting there is no next batch. Both are invisible in normal use: the
// first costs power nobody attributes to this, the second removes a word
// from a sentence that still reads like a sentence.
//
// The third is demand. `transcribes == false` must mean no tap, no model,
// no capture — not "a session that starts and produces nothing" — and
// `savesTranscript == false` must mean nothing on disk. A transcript is the
// most sensitive thing this application ever holds, so the negative cases
// are tested as hard as the positive ones.
//
// And the far end is deliberately allowed to fail. A meeting whose other
// side cannot be captured is a degraded transcript, not a failed one, so a
// far-end failure has to set a notice and leave the session listening —
// tearing the whole thing down would throw away the half that still works.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

// MARK: - Fakes

/// A scripted recogniser. Records every request it was handed, hands back
/// the same hypothesis every time — which is exactly what makes
/// LocalAgreement-2 confirm on the second decode — and can be made to fail
/// its load.
private final class FakeSpeechEngine: SpeechRecognizing {

    private let lock = NSLock()
    private var _loadFailure: Error?
    private var _words: [TranscriptWord] = []
    private var _text = ""
    private var _requests: [SpeechRequest] = []
    private var _channels: [ChannelProfile] = []
    private var _loads = 0
    private var _unloads = 0

    /// Set to make `load` throw. The session must land in `.failed` with
    /// nothing armed.
    var loadFailure: Error? {
        get { lock.lock(); defer { lock.unlock() }; return _loadFailure }
        set { lock.lock(); _loadFailure = newValue; lock.unlock() }
    }

    /// The hypothesis every decode returns.
    func script(words: [TranscriptWord], text: String) {
        lock.lock(); _words = words; _text = text; lock.unlock()
    }

    var requests: [SpeechRequest] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return _requests.count
    }

    var decodedChannels: [ChannelProfile] {
        lock.lock(); defer { lock.unlock() }; return _channels
    }

    var loadCount: Int { lock.lock(); defer { lock.unlock() }; return _loads }
    var unloadCount: Int { lock.lock(); defer { lock.unlock() }; return _unloads }

    // MARK: SpeechRecognizing

    var supportsWordTimestamps: Bool { get async { true } }

    /// Handed back so a test can deliver a progress report *late* —
    /// after `load` has already returned and the session has started
    /// listening. See `testALateProgressReportCannotWedgeAStartedSession`.
    private var _progress: ((SpeechModelState) -> Void)?
    var progressHandle: ((SpeechModelState) -> Void)? {
        lock.lock(); defer { lock.unlock() }; return _progress
    }

    func load(progress: @escaping (SpeechModelState) -> Void) async throws {
        lock.lock(); _loads += 1; let failure = _loadFailure; _progress = progress; lock.unlock()
        if let failure { throw failure }
        progress(.ready)
    }

    func unload() async {
        lock.lock(); _unloads += 1; lock.unlock()
    }

    func transcribe(_ request: SpeechRequest,
                    channel: ChannelProfile) async throws -> SpeechHypothesis {
        lock.lock()
        _requests.append(request)
        _channels.append(channel)
        let words = _words
        let text = _text
        lock.unlock()
        return SpeechHypothesis(words: words, tokensByWord: [], text: text)
    }
}

/// A microphone tap under the test's control.
///
/// Samples are addressed absolutely, as the real ring's cursors are, and
/// `lapOnce` makes one read hand back a cursor that has advanced FURTHER
/// than the frames delivered — which is how `MicTapRing` signals it lapped a
/// reader that fell behind, and the only evidence the session gets.
private final class FakeTapSource {

    private var samples: [Float] = []
    private(set) var head: UInt64 = 0
    private(set) var armCalls: [Bool] = []
    private(set) var readCalls = 0
    private(set) var framesRead = 0
    private(set) var cursorCalls = 0

    /// Extra frames the next non-empty read pretends to have skipped past.
    var lapOnce: UInt64 = 0

    var armed: Bool { armCalls.last ?? false }

    func arm(_ on: Bool) { armCalls.append(on) }

    func cursor() -> UInt64 {
        cursorCalls += 1
        return head
    }

    /// Appends `frames` of a constant value. A constant is a perfectly
    /// legible marker through the anti-alias filter: it is the sign of the
    /// audio in a decode request that says which side of a gap it came from.
    func feed(_ value: Float, frames: Int) {
        samples.append(contentsOf: repeatElement(value, count: frames))
        head += UInt64(frames)
    }

    func read(from requested: UInt64, into buffer: UnsafeMutablePointer<Float>,
              maxFrames: Int) -> (cursor: UInt64, frames: Int) {
        readCalls += 1
        let available = head > requested ? Int(head - requested) : 0
        let count = min(available, maxFrames)
        guard count > 0 else { return (requested, 0) }
        let start = Int(requested)
        for i in 0..<count { buffer[i] = samples[start + i] }
        framesRead += count
        let lap = lapOnce
        lapOnce = 0
        return (requested &+ UInt64(count) &+ lap, count)
    }
}

/// The far end, with no window server and no permission behind it.
private final class FakeFarEnd: SystemAudioCapturing {

    private let lock = NSLock()
    private var _isRunning = false
    private var _hasHeard = false
    private var _onFailure: ((String) -> Void)?
    private var _samples: [Float] = []
    private var _head: UInt64 = 0
    private var _startCount = 0
    private var _stopCount = 0
    private var _startedBundleIDs: [String?] = []

    var isRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isRunning }
        set { lock.lock(); _isRunning = newValue; lock.unlock() }
    }

    var hasHeardAnything: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hasHeard }
        set { lock.lock(); _hasHeard = newValue; lock.unlock() }
    }

    var onFailure: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onFailure }
        set { lock.lock(); _onFailure = newValue; lock.unlock() }
    }

    var tapCursor: UInt64 { lock.lock(); defer { lock.unlock() }; return _head }

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
    var startedBundleIDs: [String?] {
        lock.lock(); defer { lock.unlock() }; return _startedBundleIDs
    }

    func feed(_ value: Float, frames: Int) {
        lock.lock()
        _samples.append(contentsOf: repeatElement(value, count: frames))
        _head += UInt64(frames)
        lock.unlock()
    }

    func read(from cursor: UInt64, into buffer: UnsafeMutablePointer<Float>,
              maxFrames: Int) -> (cursor: UInt64, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        let available = _head > cursor ? Int(_head - cursor) : 0
        let count = min(available, maxFrames)
        guard count > 0 else { return (cursor, 0) }
        let start = Int(cursor)
        for i in 0..<count { buffer[i] = _samples[start + i] }
        return (cursor &+ UInt64(count), count)
    }

    func start(bundleID: String?) async {
        lock.lock()
        _startCount += 1
        _startedBundleIDs.append(bundleID)
        _isRunning = true
        lock.unlock()
    }

    func stop() async {
        lock.lock(); _stopCount += 1; _isRunning = false; lock.unlock()
    }

    /// Fires the failure the session installed. The real capture calls this
    /// from ScreenCaptureKit's delegate.
    func fail(_ message: String) {
        onFailure?(message)
    }
}

/// Whether the microphone is off air, plus a count of how many drains
/// actually saw it that way — the observable that says a drain ran under
/// the mute rather than around it.
private final class OffAirSwitch {
    var isOffAir = false
    private(set) var drainsWhileOff = 0

    func read() -> Bool {
        if isOffAir { drainsWhileOff += 1 }
        return isOffAir
    }
}

/// An injectable wall clock, for the far-end deadline.
private final class TestClock {
    var date = Date()
    func now() -> Date { date }
}

// MARK: - Tests

@MainActor
final class MeetingSessionTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRISMMeetingSessionTests-\(UUID().uuidString)",
                                    isDirectory: true)
        TranscriptStore.directoryOverride = directory
    }

    override func tearDown() {
        TranscriptStore.directoryOverride = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        super.tearDown()
    }

    // MARK: - Harness

    /// One second at 48 kHz — the most a single drain can pull, so it is
    /// also the unit every "how many drains until a decode" sum below is
    /// written in.
    private static let oneSecond = 48_000

    private func makeSettings(transcribes: Bool = true,
                              farEnd: FarEndSource = .off,
                              saves: Bool = true) -> MeetingSettings {
        var settings = MeetingSettings()
        settings.transcribes = transcribes
        settings.farEnd = farEnd
        settings.savesTranscript = saves
        return settings
    }

    private func makeSession(engine: FakeSpeechEngine,
                             tap: FakeTapSource,
                             farEnd: FakeFarEnd? = nil,
                             offAir: OffAirSwitch? = nil,
                             clock: TestClock? = nil,
                             checkpointDelay: TimeInterval = 3) -> MeetingSession {
        MeetingSession(
            engineFactory: { _ in engine },
            armMicTap: { tap.arm($0) },
            micTapCursor: { tap.cursor() },
            readMicTap: { tap.read(from: $0, into: $1, maxFrames: $2) },
            farEnd: farEnd,
            store: nil,
            micIsOffAir: { offAir?.read() ?? false },
            now: { clock?.now() ?? Date() },
            checkpointDelay: checkpointDelay)
    }

    /// Turns the main run loop for a moment. The drain timer is a real
    /// 10 Hz `Timer` in `.common`, and the decode round trip is real
    /// structured concurrency, so the only honest way to advance this state
    /// machine is to let both of them run.
    private func settle(_ seconds: TimeInterval = 0.05) {
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { settle() }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func startListening(_ session: MeetingSession,
                                settings: MeetingSettings) {
        session.apply(settings)
        session.start()
        waitUntil("the session to reach .listening") { session.phase == .listening }
    }

    /// The three words every decode returns. Distinct, so the sanitizer's
    /// repetition collapse has nothing to bite on, and nothing on the
    /// attribution list.
    private func scriptedWords() -> [TranscriptWord] {
        [TranscriptWord(id: "w0", text: "Ship", startMs: 0, endMs: 400,
                        channel: .directMic),
         TranscriptWord(id: "w1", text: " the", startMs: 420, endMs: 700,
                        channel: .directMic),
         TranscriptWord(id: "w2", text: " driver", startMs: 720, endMs: 1_200,
                        channel: .directMic)]
    }

    // MARK: - Demand

    func testASessionThatDoesNotTranscribeNeverStarts() {
        let engine = FakeSpeechEngine()
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        session.apply(makeSettings(transcribes: false))
        session.start()
        settle(0.2)

        XCTAssertEqual(session.phase, .idle,
                       "the master switch is off; nothing may run")
        XCTAssertTrue(tap.armCalls.isEmpty,
                      "a feature nobody enabled must not touch the microphone")
        XCTAssertEqual(engine.loadCount, 0, "and must not load a speech model")
    }

    // MARK: - Lifecycle

    func testStartingArmsTheMicTapAndStoppingDisarmsIt() {
        let engine = FakeSpeechEngine()
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        startListening(session, settings: makeSettings())
        XCTAssertEqual(tap.armCalls, [true], "listening arms the tap exactly once")
        XCTAssertTrue(tap.armed)

        session.stop()
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(tap.armCalls, [true, false],
                       "stopping hands the microphone back")
        XCTAssertFalse(tap.armed)
    }

    /// A progress report that arrives *after* the session has started
    /// listening must not push the phase back to `.preparing`.
    ///
    /// This is a regression test for a race found by reading rather than by
    /// a failure, which is why it is worth keeping: the progress callback
    /// and the completion that starts listening reach the main actor by two
    /// different hops, so a `.loading` enqueued just before `load` returned
    /// could be delivered afterwards. Nothing would have moved the phase
    /// forward again — `beginListening`'s guard has already passed — and
    /// the session would have sat in `.preparing` forever with the tap
    /// armed and the drain running, transcribing into a UI still claiming
    /// to be getting ready.
    func testALateProgressReportCannotWedgeAStartedSession() {
        let engine = FakeSpeechEngine()
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        session.apply(makeSettings())
        session.start()
        waitUntil("the session to start listening") { session.phase == .listening }

        // The shape of the race: a report the engine emitted before it
        // returned, delivered late.
        engine.progressHandle?(.loading)
        settle()
        XCTAssertEqual(session.phase, .listening,
                       "a stale .loading must not reopen the preparing state")

        engine.progressHandle?(.downloading(0.4))
        settle()
        XCTAssertEqual(session.phase, .listening,
                       "a stale .downloading must not reopen the preparing state")

        // A failure is the one report that still gets through, because an
        // engine that dies after loading has to be able to say so.
        engine.progressHandle?(.failed("the model went away"))
        settle()
        guard case .failed(let reason) = session.phase else {
            return XCTFail("a failure after loading must still surface, got \(session.phase)")
        }
        XCTAssertEqual(reason, "the model went away")
    }

    func testAFailingModelLoadFailsTheSessionWithoutLeavingTheTapArmed() {
        let engine = FakeSpeechEngine()
        engine.loadFailure = SpeechEngineError.modelUnavailable("base.en")
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        session.apply(makeSettings())
        session.start()
        waitUntil("the session to fail") {
            if case .failed = session.phase { return true }
            return false
        }

        guard case .failed(let reason) = session.phase else {
            return XCTFail("expected .failed, got \(session.phase)")
        }
        XCTAssertFalse(reason.isEmpty, "a failure the user cannot read is not one")
        XCTAssertFalse(tap.armed,
                       "a model that never loaded must not leave PRISM reading the mic")
        XCTAssertFalse(session.phase.isRunning)
    }

    // MARK: - Gaps

    /// The mute case. Audio from before the mute must never reach a decode,
    /// because the recogniser cannot tell a pause from a cut and would join
    /// the two halves into a sentence nobody said.
    ///
    /// Asserted on what the recogniser was handed rather than on the
    /// pipeline's internals: the pre-mute audio is positive, the post-mute
    /// audio is negative, so a request that contains anything above zero is
    /// a splice.
    func testMutingProducesAGapRatherThanASplice() {
        let engine = FakeSpeechEngine()
        let tap = FakeTapSource()
        let offAir = OffAirSwitch()
        let session = makeSession(engine: engine, tap: tap, offAir: offAir)

        startListening(session, settings: makeSettings())

        // A second of speech before the mute — under the two seconds a
        // decode needs, so it is still sitting in the buffer when the mute
        // arrives.
        tap.feed(0.5, frames: Self.oneSecond)
        waitUntil("the pre-mute second to be drained") {
            tap.framesRead >= Self.oneSecond
        }
        XCTAssertEqual(engine.requestCount, 0,
                       "one second is not enough to decode; nothing has been sent yet")

        // Off air. The tap starves, and the session has to notice.
        let readsAtMute = tap.readCalls
        offAir.isOffAir = true
        waitUntil("several drains under the mute") { offAir.drainsWhileOff >= 3 }
        XCTAssertEqual(tap.readCalls, readsAtMute,
                       "an off-air tap is not read at all — there is nothing in it")

        // Back on air, and three seconds of the other polarity.
        offAir.isOffAir = false
        tap.feed(-0.5, frames: Self.oneSecond * 3)
        waitUntil("a decode of the post-mute audio") { engine.requestCount >= 1 }

        let first = engine.requests[0]
        XCTAssertFalse(first.samples16k.isEmpty)
        let loudest = first.samples16k.max() ?? 0
        XCTAssertLessThanOrEqual(loudest, 0.05,
                                 "audio from before the mute reached the recogniser")
        XCTAssertTrue(session.lines.isEmpty,
                      "nothing was confirmed across the gap")

        session.stop()
    }

    /// The lapped-ring case. The ring skips a reader that fell behind and
    /// says so only by returning a cursor further along than the frames it
    /// handed over; comparing the two is the session's one chance to notice.
    func testALappedTapCursorIsReportedAndBreaksTheBufferRatherThanStitching() {
        let engine = FakeSpeechEngine()
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        startListening(session, settings: makeSettings())

        tap.feed(0.5, frames: Self.oneSecond)
        waitUntil("the pre-lap second to be drained") {
            tap.framesRead >= Self.oneSecond
        }

        // One second of audio the ring overwrote before the reader got to
        // it, delivered as a cursor jump on the next read.
        tap.lapOnce = UInt64(Self.oneSecond)
        tap.feed(-0.5, frames: Self.oneSecond * 3)

        waitUntil("a notice about lost audio") { session.notice != nil }
        let notice = session.notice ?? ""
        XCTAssertTrue(notice.lowercased().contains("lost"),
                      "the user is told audio went missing, got: \(notice)")
        XCTAssertTrue(notice.contains("1.0"),
                      "and roughly how much of it, got: \(notice)")

        waitUntil("a decode after the lap") { engine.requestCount >= 1 }
        let loudest = engine.requests[0].samples16k.max() ?? 0
        XCTAssertLessThanOrEqual(loudest, 0.05,
                                 "audio from before the lap was stitched onto audio from after it")

        session.stop()
    }

    // MARK: - Finalising

    func testStoppingFromListeningEmitsTheHeldTailWord() {
        let engine = FakeSpeechEngine()
        engine.script(words: scriptedWords(), text: "Ship the driver")
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        startListening(session, settings: makeSettings())

        // Two decodes' worth: LocalAgreement-2 confirms nothing on the
        // first hypothesis, because there is no second opinion to agree
        // with yet.
        tap.feed(0.4, frames: Self.oneSecond * 10)
        waitUntil("words confirmed by two agreeing decodes") { session.wordCount >= 2 }

        XCTAssertGreaterThanOrEqual(engine.requestCount, 2)
        XCTAssertEqual(session.wordCount, 2,
                       "the stitcher holds the last word of the batch back")

        session.stop()

        XCTAssertEqual(session.phase, .idle)
        let words = session.record?.words ?? []
        XCTAssertEqual(words.count, 3,
                       "stopping releases the held word; a meeting must not lose its last one")
        XCTAssertEqual(words.last?.trimmed, "driver")
        XCTAssertEqual(session.hypothesis, "",
                       "nothing is left settling once the meeting has ended")
        XCTAssertNotNil(session.record?.endedAt)
    }

    // MARK: - Persistence

    func testStoppingWritesTheTranscriptWhenAskedTo() {
        let engine = FakeSpeechEngine()
        engine.script(words: scriptedWords(), text: "Ship the driver")
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        startListening(session, settings: makeSettings(saves: true))
        tap.feed(0.4, frames: Self.oneSecond * 10)
        waitUntil("words to confirm") { session.wordCount >= 2 }
        session.stop()

        guard let id = session.record?.id else { return XCTFail("no record") }
        let store = TranscriptStore()
        let reloaded = store.load(id: id)
        XCTAssertNotNil(reloaded, "the transcript was not written under the override")
        XCTAssertEqual(reloaded?.words.count, 3)
        XCTAssertTrue(store.transcriptURL(for: id).path.hasPrefix(directory.path),
                      "the suite must never write into the real Application Support")
    }

    func testAStartedMeetingCheckpointsBeforeStop() {
        let engine = FakeSpeechEngine()
        engine.script(words: scriptedWords(), text: "Ship the driver")
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap, checkpointDelay: 0)

        startListening(session, settings: makeSettings(saves: true))
        tap.feed(0.4, frames: Self.oneSecond * 10)
        waitUntil("a durable live checkpoint") { session.lastSavedAt != nil }

        guard let id = session.record?.id else { return XCTFail("no live record") }
        let checkpoint = TranscriptStore().load(id: id)
        XCTAssertNotNil(checkpoint, "a crash before Stop must not erase the meeting")
        XCTAssertGreaterThanOrEqual(checkpoint?.words.count ?? 0, 2)
        XCTAssertNil(checkpoint?.endedAt, "a checkpoint is still visibly in progress")
        session.stop()
    }

    func testTheFirstVisibleHypothesisIsIncludedInARecoveryCheckpoint() {
        let engine = FakeSpeechEngine()
        engine.script(words: scriptedWords(), text: "Ship the driver")
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap, checkpointDelay: 0)

        startListening(session, settings: makeSettings(saves: true))
        tap.feed(0.4, frames: Self.oneSecond * 3)
        waitUntil("the first provisional hypothesis") { !session.hypothesis.isEmpty }
        waitUntil("a provisional recovery checkpoint") { session.lastSavedAt != nil }

        guard let id = session.record?.id else { return XCTFail("no live record") }
        let checkpoint = TranscriptStore().load(id: id)
        XCTAssertEqual(checkpoint?.words.map(\.trimmed), ["Ship", "the", "driver"])
        XCTAssertTrue(checkpoint?.words.allSatisfy { $0.state == .pending } == true)
        session.stop()
    }

    func testTurningSavingOffRemovesALiveCheckpoint() {
        let engine = FakeSpeechEngine()
        engine.script(words: scriptedWords(), text: "Ship the driver")
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap, checkpointDelay: 0)

        startListening(session, settings: makeSettings(saves: true))
        tap.feed(0.4, frames: Self.oneSecond * 10)
        waitUntil("a live checkpoint") { session.lastSavedAt != nil }
        guard let id = session.record?.id else { return XCTFail("no live record") }

        session.apply(makeSettings(saves: false))
        XCTAssertNil(TranscriptStore().load(id: id),
                     "off must remove a checkpoint already written this meeting")
        XCTAssertNil(session.lastSavedAt)
        session.stop()
    }

    func testTheNotesSnapshotIncludesTextTypedDuringTheLiveMeeting() {
        let session = makeSession(engine: FakeSpeechEngine(), tap: FakeTapSource())
        startListening(session, settings: makeSettings(saves: false))

        session.userNotes = "Decision: ship on Friday."

        XCTAssertEqual(session.recordForNotes()?.userNotes,
                       "Decision: ship on Friday.")
        session.stop()
    }

    func testEditingNotesOnAnOpenedMeetingPersistsThem() throws {
        let stored = MeetingRecord(
            title: "Saved",
            startedAt: Date(timeIntervalSince1970: 1_000),
            endedAt: Date(timeIntervalSince1970: 1_060),
            words: [TranscriptWord(text: "Hello", startMs: 0, endMs: 500,
                                   channel: .directMic)])
        try TranscriptStore().save(stored)
        let session = makeSession(engine: FakeSpeechEngine(), tap: FakeTapSource(),
                                  checkpointDelay: 0)
        session.viewSavedMeeting(stored)

        session.userNotes = "Follow up tomorrow."
        waitUntil("the opened record update") {
            TranscriptStore().load(id: stored.id)?.userNotes == "Follow up tomorrow."
        }

        XCTAssertNotNil(session.lastSavedAt)
    }

    func testOpeningARecoveredCheckpointUsesCapturedAudioForItsDuration() {
        let started = Date(timeIntervalSince1970: 1_000)
        let recovered = MeetingRecord(
            title: "Recovered",
            startedAt: started,
            words: [TranscriptWord(text: "Hello", startMs: 2_000, endMs: 3_000,
                                   channel: .directMic)])
        let session = makeSession(engine: FakeSpeechEngine(), tap: FakeTapSource())

        session.viewSavedMeeting(recovered)

        XCTAssertEqual(session.record?.endedAt,
                       started.addingTimeInterval(3))
        XCTAssertEqual(session.elapsed, 3, accuracy: 0.001)
    }

    func testStoppingKeepsTheVisibleOnePassTail() {
        let engine = FakeSpeechEngine()
        engine.script(words: scriptedWords(), text: "Ship the driver")
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        startListening(session, settings: makeSettings(saves: false))
        tap.feed(0.4, frames: Self.oneSecond * 3)
        waitUntil("the first provisional hypothesis") { !session.hypothesis.isEmpty }
        XCTAssertEqual(session.wordCount, 0,
                       "one decode is visible but not agreement-confirmed")

        session.stop()

        XCTAssertEqual(session.record?.words.map(\.trimmed),
                       ["Ship", "the", "driver"],
                       "Stop must not cut off words that were already on screen")
    }

    func testStoppingWritesNothingWhenSavingIsOff() {
        let engine = FakeSpeechEngine()
        engine.script(words: scriptedWords(), text: "Ship the driver")
        let tap = FakeTapSource()
        let session = makeSession(engine: engine, tap: tap)

        startListening(session, settings: makeSettings(saves: false))
        tap.feed(0.4, frames: Self.oneSecond * 10)
        waitUntil("words to confirm") { session.wordCount >= 2 }
        session.stop()

        guard let id = session.record?.id else { return XCTFail("no record") }
        XCTAssertEqual(session.record?.words.count, 3,
                       "the meeting still happened; only the file is refused")
        XCTAssertNil(TranscriptStore().load(id: id))
        XCTAssertTrue(TranscriptStore().all().isEmpty,
                      "a transcript nobody asked to keep must not be on disk")
    }

    // MARK: - Far end

    func testFarEndHeardOnlyBecomesTrueWhenTheStreamActuallyDeliversAudio() {
        let engine = FakeSpeechEngine()
        let tap = FakeTapSource()
        let farEnd = FakeFarEnd()
        let session = makeSession(engine: engine, tap: tap, farEnd: farEnd)

        startListening(session, settings: makeSettings(farEnd: .everything))
        waitUntil("the far end to be started") { farEnd.startCount == 1 }

        // Running, delivering callbacks, carrying nothing. This is exactly
        // what a missing Screen Recording permission looks like from inside
        // the process, and "the stream started" must not be read as evidence.
        XCTAssertTrue(farEnd.isRunning)
        settle(0.3)
        XCTAssertFalse(session.farEndHeard,
                       "a running stream is not the same as an audible one")

        farEnd.hasHeardAnything = true
        waitUntil("the far end to be heard") { session.farEndHeard }
        XCTAssertNil(session.notice, "nothing degraded; nothing to say")

        session.stop()
    }

    func testAFarEndFailureIsANoticeAndTheMeetingKeepsListening() {
        let engine = FakeSpeechEngine()
        let tap = FakeTapSource()
        let farEnd = FakeFarEnd()
        let session = makeSession(engine: engine, tap: tap, farEnd: farEnd)

        startListening(session, settings: makeSettings(farEnd: .everything))
        waitUntil("the far end to be started") { farEnd.startCount == 1 }

        farEnd.fail("PRISM lost the other side of the call.")
        waitUntil("the failure to surface") { session.notice != nil }

        XCTAssertEqual(session.notice, "PRISM lost the other side of the call.")
        XCTAssertEqual(session.phase, .listening,
                       "half a transcript is worth more than none; the near side carries on")
        XCTAssertTrue(tap.armed, "and the microphone stays armed")

        session.dismissNotice()
        XCTAssertNil(session.notice)

        session.stop()
        XCTAssertEqual(session.phase, .idle)
    }

    /// The far end that reports success and produces silence forever. After
    /// fifteen seconds the session says so rather than handing over half a
    /// transcript and letting the user work out which half is missing.
    func testASilentFarEndIsCalledOutAfterTheDeadlineWithoutStoppingTheMeeting() {
        let engine = FakeSpeechEngine()
        let tap = FakeTapSource()
        let farEnd = FakeFarEnd()
        let clock = TestClock()
        let session = makeSession(engine: engine, tap: tap,
                                  farEnd: farEnd, clock: clock)

        startListening(session, settings: makeSettings(farEnd: .everything))
        waitUntil("the far end to be started") { farEnd.startCount == 1 }
        XCTAssertNil(session.notice)

        clock.date = clock.date.addingTimeInterval(20)
        waitUntil("the far-end deadline to expire") { session.notice != nil }

        XCTAssertTrue(session.notice?.contains("couldn't hear the other side") == true,
                      "got: \(session.notice ?? "nil")")
        XCTAssertEqual(session.phase, .listening)
        XCTAssertFalse(session.farEndHeard)

        session.stop()
    }
}
