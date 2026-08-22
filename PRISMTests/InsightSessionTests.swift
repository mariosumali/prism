// InsightSessionTests.swift
// PRISMTests
//
// The §5.34 live-insights engine, driven headless against a fake provider
// and a clock the test winds by hand.
//
// Everything that makes this mode bearable is a rule about time — a gap, a
// cooldown, a ceiling, a timeout, an expiry — and a rule about time that
// can only be exercised by holding a meeting is a rule nobody tests. So the
// session takes its clock and its sleep as closures, and `VirtualClock`
// below parks every sleeper until the test says the moment has come. The
// whole suite runs in well under a second and asserts on seconds.
//
// The bugs this file exists to catch are the ones every automatic
// assistant shipped: a request that goes out mid-sentence, a second
// request two seconds after the first, a lively call that becomes a request
// a second, a provider that hangs and takes the mode with it, the same
// definition shown three times. Each is a test below, and each asserts on
// what the provider was actually sent — because "the session decided not
// to" is only true if the request never left.
//
// The negative cases are tested as hard as the positive ones, for §5.32's
// reason: this is the one mode that sends on its own, so "off means
// nothing is sent" has to hold under every combination of the three
// switches that arm it.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

// MARK: - Fakes

/// A clock the test advances by hand. `sleep` parks the caller until the
/// clock passes its wake time and honours cancellation, so the session's
/// debounces, cooldowns and timeouts all run against this and never the
/// wall.
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var sleepers: [(wake: Date, id: UUID, resume: () -> Void)] = []

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        _now = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    func sleep(_ seconds: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                let wake = _now.addingTimeInterval(seconds)
                if Task.isCancelled || seconds <= 0 || wake <= _now {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append((wake, id, { continuation.resume() }))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = sleepers.firstIndex { $0.id == id }
            let sleeper = index.map { sleepers.remove(at: $0) }
            lock.unlock()
            sleeper?.resume()
        }
    }

    /// Moves time forward, waking sleepers in order as their moments pass
    /// and letting each one run before the next — a woken task may register
    /// a new sleeper inside the same advance, and it must be honoured.
    @MainActor
    func advance(by seconds: TimeInterval) async {
        // A task created just before this call — the session's check task,
        // say — has not run yet, so it has not registered its sleeper. Let
        // it, so its wake time is computed from the clock as it stands now
        // rather than from wherever this advance ends.
        await Self.settle()
        let target = now.addingTimeInterval(seconds)
        while let resume = popSleeper(dueBy: target) {
            resume()
            await Self.settle()
        }
        await Self.settle()
    }

    /// Wakes the earliest sleeper due by `target` and moves the clock to its
    /// moment, or moves the clock to `target` and returns nil when none is.
    /// Synchronous, so the lock is never held across a suspension.
    private func popSleeper(dueBy target: Date) -> (() -> Void)? {
        lock.lock(); defer { lock.unlock() }
        sleepers.sort { $0.wake < $1.wake }
        guard let next = sleepers.first, next.wake <= target else {
            _now = target
            return nil
        }
        sleepers.removeFirst()
        _now = max(_now, next.wake)
        return next.resume
    }

    /// Lets the main actor drain what a woken task scheduled, including the
    /// hop off to the provider and back.
    @MainActor
    static func settle() async {
        for _ in 0..<3 {
            for _ in 0..<8 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        for _ in 0..<8 { await Task.yield() }
    }

    var pendingSleepers: Int {
        lock.lock(); defer { lock.unlock() }
        return sleepers.count
    }
}

/// A scripted provider. Records every request, answers each with the next
/// reply in the script (the last one repeats), and can be made to hang.
final class FakeInsightProvider: LLMProvider, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake"
    let contextBudget = 100_000

    private let lock = NSLock()
    private var _requests: [LLMRequest] = []
    private var _replies: [String]
    private var _hang = false
    private var _holdAfterStop = false
    private var heldContinuations: [AsyncThrowingStream<LLMEvent, Error>.Continuation] = []

    init(replies: [String] = [#"{"cards":[]}"#]) {
        _replies = replies
    }

    var requests: [LLMRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var requestCount: Int { requests.count }

    var hang: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _hang }
        set { lock.lock(); _hang = newValue; lock.unlock() }
    }

    var holdAfterStop: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _holdAfterStop }
        set { lock.lock(); _holdAfterStop = newValue; lock.unlock() }
    }

    func script(_ replies: [String]) {
        lock.lock(); _replies = replies; lock.unlock()
    }

    func isAvailable() async -> Bool { true }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        lock.lock()
        _requests.append(request)
        let reply = _replies.count > 1 ? _replies.removeFirst() : (_replies.first ?? #"{"cards":[]}"#)
        let hang = _hang
        let holdAfterStop = _holdAfterStop
        lock.unlock()
        return AsyncThrowingStream { continuation in
            guard !hang else { return }
            continuation.yield(.jsonDelta(reply))
            continuation.yield(.stop(reason: "end_turn", outputTokens: nil))
            if holdAfterStop {
                lock.lock(); heldContinuations.append(continuation); lock.unlock()
            } else {
                continuation.finish()
            }
        }
    }
}

private final class InsightSleepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - Tests

@MainActor
final class InsightSessionTests: XCTestCase {

    private var clock: VirtualClock!
    private var provider: FakeInsightProvider!
    private var session: InsightSession!
    private var lines: [TranscriptLine] = []
    private var nextMs: Int64 = 0

    override func setUp() async throws {
        clock = VirtualClock()
        provider = FakeInsightProvider()
        lines = []
        nextMs = 0
        let clock = self.clock!
        let provider = self.provider!
        session = InsightSession(now: { clock.now }, sleep: { await clock.sleep($0) })
        session.providerFactory = { provider }
        session.apply(Self.settings())
        session.setListening(true)
    }

    override func tearDown() async throws {
        session.setListening(false)
        session = nil
    }

    // MARK: Helpers

    /// Live insights on, balanced, every kind (including `fact`, which the
    /// shipped default leaves off), Ollama so no key is needed.
    private static func settings(pace: InsightPace = .balanced,
                                 kinds: Set<InsightKind> = Set(InsightKind.allCases),
                                 panelUp: Bool = true,
                                 on: Bool = true) -> AssistantSettings {
        var settings = AssistantSettings()
        settings.isEnabled = panelUp
        settings.provider = .ollama
        settings.ollamaModel = "llama3"
        settings.liveInsights = on
        settings.insightPace = pace
        settings.insightKinds = kinds
        return settings
    }

    private func words(_ count: Int) -> String {
        (0..<count).map { "word\($0)" }.joined(separator: " ")
    }

    /// Appends a line and feeds the whole transcript back, the way
    /// `MeetingSession.lines` republishes on every change.
    private func say(_ text: String, from channel: ChannelProfile = .farEnd,
                     settled: Bool = true) {
        let line = TranscriptLine(id: UUID().uuidString,
                                  label: channel == .directMic ? "You" : "Them",
                                  text: text, startMs: nextMs, endMs: nextMs + 1_000,
                                  channel: channel, isSettled: settled)
        nextMs += 1_000
        lines.append(line)
        session.observe(lines: lines)
    }

    private func reviseLast(_ text: String, settled: Bool = true) {
        guard !lines.isEmpty else { return }
        lines[lines.count - 1].text = text
        lines[lines.count - 1].isSettled = settled
        session.observe(lines: lines)
    }

    private func advance(_ seconds: TimeInterval) async {
        await clock.advance(by: seconds)
    }

    /// The default trigger quotes two words every `words(_:)` line
    /// contains, so a scripted card passes the grounding check unless a
    /// test says otherwise.
    private func card(_ kind: String, _ title: String,
                      body: String = "Because.", trigger: String = "word1 word2") -> String {
        #"{"kind":"\#(kind)","title":"\#(title)","body":"\#(body)","trigger":"\#(trigger)"}"#
    }

    private func reply(_ cards: String...) -> String {
        #"{"cards":[\#(cards.joined(separator: ","))]}"#
    }

    private func userPrompt(_ index: Int = 0) -> String {
        let requests = provider.requests
        guard requests.indices.contains(index) else { return "" }
        return requests[index].messages.first?.text ?? ""
    }

    // MARK: - A. The three switches

    func testNothingIsSentWhileTheModeIsOff() async {
        session.apply(Self.settings(on: false))
        say(words(80))
        await advance(120)
        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertFalse(session.isArmed)
    }

    func testNothingIsSentWhileThePanelIsDown() async {
        session.apply(Self.settings(panelUp: false))
        say(words(80))
        await advance(120)
        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertFalse(session.isArmed)
    }

    func testNothingIsSentUntilTheMeetingListens() async {
        session.setListening(false)
        say(words(80))
        await advance(120)
        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertFalse(session.isArmed)
    }

    func testNothingIsSentWhenEveryKindIsOff() async {
        session.apply(Self.settings(kinds: []))
        say(words(80))
        await advance(120)
        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertFalse(session.isArmed, "no kinds is the same intent as the switch being off")
    }

    func testClosingThePanelMidMeetingDisarmsAndClearsTheCards() async {
        provider.script([reply(card("term", "Series B"))])
        say(words(40))
        await advance(3)
        XCTAssertEqual(session.cards.count, 1)

        session.apply(Self.settings(panelUp: false))
        XCTAssertFalse(session.isArmed)
        XCTAssertTrue(session.cards.isEmpty, "a panel that reopens onto stale cards is a panel about the wrong minute")

        say(words(40))
        await advance(60)
        XCTAssertEqual(provider.requestCount, 1)
    }

    // MARK: - B. When a request goes out

    func testAStretchOfConversationAndAPauseSendsOneRequest() async {
        say(words(40))
        XCTAssertEqual(provider.requestCount, 0, "nothing goes out the instant text lands")
        await advance(3)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertTrue(userPrompt().contains("<transcript>"))
        XCTAssertTrue(userPrompt().contains("word39"))
    }

    func testNothingIsSentMidSentence() async {
        say(words(40))
        await advance(1)
        say(words(5))               // still talking
        await advance(2)            // three seconds since the first line, two since the last
        XCTAssertEqual(provider.requestCount, 0, "the gap is measured from the last change, not the first")
        await advance(1)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testSameLengthTranscriptCorrectionRestartsTheQuietGap() async {
        say(words(40))
        await advance(2)
        reviseLast((0..<40).map { "edit\($0)" }.joined(separator: " "))

        await advance(1)
        XCTAssertEqual(provider.requestCount, 0,
                       "a one-for-one correction is still active transcription")
        await advance(2)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testRevisingTheChangedSuffixUpdatesTheMaterialWordCount() async {
        say(words(40))
        await advance(2)
        reviseLast(words(10))
        await advance(30)
        XCTAssertEqual(provider.requestCount, 0,
                       "words removed by a recogniser correction are not still material")

        reviseLast(words(40))
        await advance(3)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testTranscriptBurstKeepsOneScheduledWake() async {
        session.setListening(false)
        let counter = InsightSleepCounter()
        let clock = self.clock!
        let provider = self.provider!
        session = InsightSession(now: { clock.now }, sleep: { seconds in
            counter.increment()
            await clock.sleep(seconds)
        })
        session.providerFactory = { provider }
        session.apply(Self.settings())
        session.setListening(true)

        say(words(40))
        await VirtualClock.settle()
        XCTAssertEqual(counter.value, 1)
        for index in 0..<20 {
            reviseLast(words(40) + " extra\(index)")
            await advance(0.01)
        }

        XCTAssertEqual(counter.value, 1,
                       "continued speech should update state, not replace the timer task")
        XCTAssertEqual(clock.pendingSleepers, 1)
        await advance(2.8)
        XCTAssertEqual(provider.requestCount, 0,
                       "the early wake must recheck the quiet gap")
        await advance(0.2)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testTooFewNewWordsIsNotWorthARequest() async {
        say(words(10))
        await advance(120)
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testUnsettledTextIsNotMaterial() async {
        say(words(80), settled: false)
        await advance(120)
        XCTAssertEqual(provider.requestCount, 0, "a request over a hypothesis is a request about a sentence nobody said")
    }

    func testTheCooldownHoldsASecondRequest() async {
        say(words(40))
        await advance(3)
        XCTAssertEqual(provider.requestCount, 1)

        say(words(40))
        await advance(3)
        XCTAssertEqual(provider.requestCount, 1, "the gap elapsed but the cooldown did not")
        await advance(22)
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testAQuestionFromTheOtherSideBypassesTheWordFloor() async {
        say("What do you think about the pricing model?")
        await advance(1.5)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertTrue(userPrompt().contains("# Just asked"))
        XCTAssertTrue(userPrompt().contains("pricing model"))
    }

    func testTheSameQuestionIsNeverAskedAboutTwice() async {
        say("What do you think about the pricing model?")
        await advance(1.5)
        XCTAssertEqual(provider.requestCount, 1)
        // The recogniser republishes the same lines; the line may even grow.
        session.observe(lines: lines)
        await advance(60)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testASecondQuestionWaitsForTheQuestionCooldown() async {
        say("What do you think about the pricing model?")
        await advance(1.5)
        XCTAssertEqual(provider.requestCount, 1)
        say("And how would you roll it out to the enterprise tier?")
        await advance(1.5)
        XCTAssertEqual(provider.requestCount, 1, "a second question moments after the first is the first still settling")
        await advance(5)
        XCTAssertEqual(provider.requestCount, 1, "six and a half seconds in, the eight-second question cooldown still holds")
        await advance(1.5)
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testAQuestionFromTheUserIsNotATrigger() async {
        say("What do you think about the pricing model?", from: .directMic)
        await advance(60)
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testAQuestionTheUserHasStartedAnsweringIsNotAskedAbout() async {
        say("What do you think about the pricing model?")
        say("I think the pricing model is about right for the mid market honestly", from: .directMic)
        await advance(60)
        XCTAssertEqual(provider.requestCount, 0,
                       "a settled reply of eight words or more means the user is answering")
    }

    func testAQuestionThatWaitedTooLongIsDroppedNotAnsweredLate() async {
        provider.hang = true
        say(words(40))
        await advance(3)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertTrue(session.isThinking)

        // Asked while a request is in flight; it can only go after the
        // twenty-second timeout, by which time it is stale.
        say("What do you think about the pricing model?")
        await advance(25)
        XCTAssertEqual(provider.requestCount, 1, "the moment to answer passed during the hung request")
        XCTAssertFalse(session.isThinking)
    }

    func testACardWhoseQuoteIsNotInTheTranscriptIsRejected() async {
        provider.script([reply(card("term", "Invented", trigger: "something nobody ever said here"),
                               card("fact", "Grounded", trigger: "word7 word8 word9"))])
        say(words(40))
        await advance(3)
        XCTAssertEqual(session.cards.map(\.title), ["Grounded"])
    }

    func testADetectedQuestionCountsAsPartOfTheWindowForGrounding() async {
        provider.script([reply(card("answer", "Say it is competitive",
                                    trigger: "think about the pricing model"))])
        say("What do you think about the pricing model?")
        await advance(1.5)
        XCTAssertEqual(session.cards.map(\.title), ["Say it is competitive"])
    }

    func testTheMeetingSummaryIsCountsOnly() async {
        XCTAssertNil(session.meetingSummary, "nothing to say until something was sent")
        provider.script([reply(card("term", "Series B dilution"), card("fact", "Runway"))])
        say(words(40))
        await advance(3)
        guard let first = session.cards.first else { return XCTFail("no card") }
        session.dismiss(first.id)
        XCTAssertEqual(session.meetingSummary, "Live insights: 1 request, 2 cards shown, 1 dismissed")
        XCTAssertFalse(session.meetingSummary?.contains("Series B") == true)
    }

    func testQuietPaceOnlyAnswersQuestions() async {
        session.apply(Self.settings(pace: .quiet))
        say(words(200))
        await advance(120)
        XCTAssertEqual(provider.requestCount, 0)
        say("Could you walk me through how the migration went?")
        await advance(1.5)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testOnlyOneRequestIsInFlightAndMaterialCatchesUpAfterwards() async {
        provider.hang = true
        say(words(40))
        await advance(3)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertTrue(session.isThinking)

        say(words(40))
        await advance(5)
        XCTAssertEqual(provider.requestCount, 1, "nothing overlaps a request in flight")

        // The hung request times out at twenty seconds; the cooldown from
        // its start has elapsed by then, and the waiting material goes.
        await advance(20)
        XCTAssertEqual(provider.requestCount, 2)
    }

    // MARK: - C. What a request looks like

    func testARequestAsksForJSONQuicklyAndCarriesTheShownTitles() async {
        provider.script([reply(card("term", "Series B dilution")), reply()])
        say(words(40))
        await advance(3)
        let first = provider.requests[0]
        XCTAssertNotNil(first.jsonSchema, "cards are structured output, not prose")
        XCTAssertEqual(first.effort, "low", "latency is the figure of merit here")
        XCTAssertLessThanOrEqual(first.maxTokens, 1_000)
        XCTAssertTrue(first.systemFrozen.contains("<transcript>"))
        XCTAssertTrue(first.systemFrozen.contains("<shown>"))
        XCTAssertTrue(userPrompt(0).contains("No cards have been shown yet"))

        say(words(40))
        await advance(25)
        XCTAssertEqual(provider.requestCount, 2)
        XCTAssertTrue(userPrompt(1).contains("<shown>"))
        XCTAssertTrue(userPrompt(1).contains("Series B dilution"))
    }

    func testTheTranscriptSentIsTheLastContextTurns() async {
        var settings = Self.settings()
        settings.contextTurns = 4
        session.apply(settings)
        for index in 0..<6 { say("line \(index) \(words(8))") }
        await advance(3)
        let prompt = userPrompt()
        XCTAssertFalse(prompt.contains("line 0 "))
        XCTAssertFalse(prompt.contains("line 1 "))
        XCTAssertTrue(prompt.contains("line 2 "))
        XCTAssertTrue(prompt.contains("line 5 "))
    }

    func testNoProviderIsAnErrorAndNotARetryLoop() async {
        session.providerFactory = { nil }
        say(words(40))
        await advance(3)
        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertEqual(session.lastError, LLMError.notConfigured.errorDescription)
        XCTAssertFalse(session.isThinking)
        await advance(600)
        XCTAssertEqual(session.requestCount, 0)
    }

    // MARK: - D. What comes back

    func testCardsArriveNewestFirstAndInTheModelsOrderWithinAReply() async {
        provider.script([reply(card("term", "First"), card("fact", "Second")),
                         reply(card("followUp", "Third"))])
        say(words(40))
        await advance(3)
        XCTAssertEqual(session.cards.map(\.title), ["First", "Second"])

        say(words(40))
        await advance(25)
        XCTAssertEqual(session.cards.map(\.title), ["Third", "First", "Second"])
        XCTAssertEqual(session.requestCount, 2)
    }

    func testCardsOfAKindTheUserTurnedOffAreDropped() async {
        session.apply(Self.settings(kinds: [.term]))
        provider.script([reply(card("term", "Kept"), card("followUp", "Dropped"))])
        say(words(40))
        await advance(3)
        XCTAssertEqual(session.cards.map(\.title), ["Kept"])
        XCTAssertFalse(userPrompt().contains("- followUp:"), "and the model was not asked for it either")
    }

    func testARepeatedCardInDifferentWordsIsDropped() async {
        provider.script([reply(card("term", "Series B dilution")),
                         reply(card("term", "Dilution at Series B"))])
        say(words(40))
        await advance(3)
        say(words(40))
        await advance(25)
        XCTAssertEqual(session.requestCount, 2)
        XCTAssertEqual(session.cards.map(\.title), ["Series B dilution"])
    }

    func testADismissedCardDoesNotComeBack() async {
        provider.script([reply(card("term", "Series B dilution")),
                         reply(card("term", "Series B dilution"))])
        say(words(40))
        await advance(3)
        guard let id = session.cards.first?.id else { return XCTFail("no card") }
        session.dismiss(id)
        XCTAssertTrue(session.cards.isEmpty)

        say(words(40))
        await advance(25)
        XCTAssertEqual(session.requestCount, 2)
        XCTAssertTrue(session.cards.isEmpty, "a term the user waved away is not one they want defined again")
    }

    func testAtMostTwoCardsAreTakenFromOneReply() async {
        provider.script([reply(card("term", "One"), card("fact", "Two"),
                               card("followUp", "Three"), card("commitment", "Four"))])
        say(words(40))
        await advance(3)
        XCTAssertEqual(session.cards.map(\.title), ["One", "Two"])
    }

    func testCardsExpireUnlessPinned() async {
        provider.script([reply(card("term", "Expires"), card("fact", "Stays"))])
        say(words(40))
        await advance(3)
        XCTAssertEqual(session.cards.count, 2)
        guard let stays = session.cards.first(where: { $0.title == "Stays" }) else {
            return XCTFail("no card")
        }
        session.togglePin(stays.id)

        await advance(119)
        XCTAssertEqual(session.cards.count, 2)
        await advance(1)
        XCTAssertEqual(session.cards.map(\.title), ["Stays"])
        await advance(600)
        XCTAssertEqual(session.cards.map(\.title), ["Stays"], "pinned means pinned")
    }

    func testTheOldestUnpinnedCardsArePushedOutOverTheLimit() async {
        let replies = (0..<4).map { index in
            reply(card("term", "Card \(index * 2)"), card("fact", "Card \(index * 2 + 1)"))
        }
        provider.script(replies + [reply()])
        say(words(40))
        await advance(3)
        for _ in 0..<3 {
            say(words(40))
            await advance(25)
        }
        XCTAssertEqual(session.requestCount, 4)
        XCTAssertEqual(session.cards.count, 6)
        XCTAssertEqual(session.cards.first?.title, "Card 6")
        XCTAssertEqual(session.cards.map(\.title),
                       ["Card 6", "Card 7", "Card 4", "Card 5", "Card 2", "Card 3"],
                       "cards 0 and 1 were the oldest; within a reply the model's order is kept")
    }

    // MARK: - E. Failure and stopping

    func testAStalledProviderIsAFailureNotAState() async {
        provider.hang = true
        say(words(40))
        await advance(3)
        XCTAssertTrue(session.isThinking)
        await advance(20)
        XCTAssertFalse(session.isThinking)
        XCTAssertEqual(session.lastError, LLMError.stalled(seconds: 20).errorDescription)
    }

    func testStopEventEndsAProviderThatLeavesItsStreamOpen() async {
        provider.holdAfterStop = true
        provider.script([reply(card("term", "Series B"))])
        say(words(40))
        await advance(3)

        XCTAssertFalse(session.isThinking)
        XCTAssertEqual(session.cards.map(\.title), ["Series B"])
        XCTAssertNil(session.lastError)
    }

    func testStoppingTheMeetingClearsEverythingAndIgnoresALateReply() async {
        provider.script([reply(card("term", "Series B"))])
        say(words(40))
        await advance(3)
        XCTAssertEqual(session.cards.count, 1)

        provider.hang = true
        say(words(40))
        await advance(25)
        XCTAssertTrue(session.isThinking)

        session.setListening(false)
        XCTAssertFalse(session.isThinking)
        XCTAssertTrue(session.cards.isEmpty)
        XCTAssertEqual(session.requestCount, 0)
        XCTAssertFalse(session.isArmed)

        await advance(60)
        XCTAssertNil(session.lastError, "the cancelled request's timeout must not land on the next meeting")
        XCTAssertEqual(provider.requestCount, 2)
    }

    func testAReplyThatIsNotJSONIsNoCardsNotAnError() async {
        provider.script(["Sure! Here are some thoughts about the conversation so far."])
        say(words(40))
        await advance(3)
        XCTAssertTrue(session.cards.isEmpty)
        XCTAssertNil(session.lastError)
    }

    // MARK: - F. The decoder

    func testAFencedReplyStillDecodes() {
        let raw = "```json\n" + reply(card("term", "Series B")) + "\n```"
        XCTAssertEqual(InsightReplyDecoder.decode(raw).map(\.title), ["Series B"])
    }

    func testTheSpellingsAModelUsesForAKindAreAccepted() {
        let raw = reply(card("follow-up", "A"), card("Follow_Up", "B"), card("COMMITMENT", "C"),
                        card("hologram", "D"))
        XCTAssertEqual(InsightReplyDecoder.decode(raw).map(\.kind), [.followUp, .followUp, .commitment])
    }

    func testACardWithoutATitleOrBodyIsDropped() {
        let raw = #"{"cards":[{"kind":"term","title":"","body":"x","trigger":""},{"kind":"term","title":"T","body":"","trigger":""},{"kind":"term","title":"Kept","body":"b","trigger":""}]}"#
        XCTAssertEqual(InsightReplyDecoder.decode(raw).map(\.title), ["Kept"])
    }

    func testABareArrayAndProseBothDecodeSafely() {
        XCTAssertEqual(InsightReplyDecoder.decode("[" + card("fact", "Bare") + "]").map(\.title), ["Bare"])
        XCTAssertTrue(InsightReplyDecoder.decode("nothing worth a card").isEmpty)
        XCTAssertTrue(InsightReplyDecoder.decode("").isEmpty)
    }

    // MARK: - G. The trigger, as a pure function

    private func snapshot(newWords: Int = 0, question: String? = nil,
                          sinceLast: TimeInterval? = nil, sinceChange: TimeInterval = .infinity,
                          inFlight: Bool = false, inWindow: Int = 0,
                          frees: TimeInterval? = nil) -> InsightTrigger.Snapshot {
        InsightTrigger.Snapshot(newWords: newWords, detectedQuestion: question,
                                secondsSinceLastRequest: sinceLast,
                                secondsSinceLastChange: sinceChange,
                                inFlight: inFlight, requestsInWindow: inWindow,
                                secondsUntilWindowFrees: frees)
    }

    func testAQuestionOutranksMaterial() {
        let policy = InsightPolicy.forPace(.balanced)
        XCTAssertEqual(InsightTrigger.decide(snapshot(newWords: 100, question: "Why?", sinceChange: 10),
                                             policy: policy),
                       .question("Why?"))
    }

    func testTheCeilingBlocksWhateverIsSaidAndSaysWhenItFrees() {
        let policy = InsightPolicy.forPace(.balanced)
        let full = snapshot(newWords: 500, question: "Why?", sinceLast: 100, sinceChange: 100,
                            inWindow: policy.requestsPerWindow, frees: 42)
        XCTAssertNil(InsightTrigger.decide(full, policy: policy))
        XCTAssertEqual(InsightTrigger.delayUntilPossible(full, policy: policy), 42)
    }

    func testNothingFiresWhileARequestIsInFlightAndNothingIsScheduledEither() {
        let policy = InsightPolicy.forPace(.eager)
        let busy = snapshot(newWords: 500, question: "Why?", sinceLast: 100, sinceChange: 100,
                            inFlight: true)
        XCTAssertNil(InsightTrigger.decide(busy, policy: policy))
        XCTAssertNil(InsightTrigger.delayUntilPossible(busy, policy: policy),
                     "completion is the next event, not the clock")
    }

    func testTheWakeUpIsExactlyWhenTheLaterOfGapAndCooldownElapses() {
        let policy = InsightPolicy.forPace(.balanced)
        // Gap satisfied, cooldown not: wake when the cooldown does.
        XCTAssertEqual(InsightTrigger.delayUntilPossible(
            snapshot(newWords: 40, sinceLast: 10, sinceChange: 10), policy: policy), 15)
        // Cooldown satisfied, gap not: wake when the gap does.
        XCTAssertEqual(InsightTrigger.delayUntilPossible(
            snapshot(newWords: 40, sinceLast: 100, sinceChange: 1), policy: policy), 2)
        // Nothing pending: nothing to wake for.
        XCTAssertNil(InsightTrigger.delayUntilPossible(
            snapshot(newWords: 3, sinceLast: 100, sinceChange: 1), policy: policy))
    }

    func testEveryPaceRespectsTheShapeOfTheControls() {
        for pace in InsightPace.allCases {
            let policy = InsightPolicy.forPace(pace)
            XCTAssertGreaterThan(policy.materialGapSeconds, 0, "\(pace)")
            XCTAssertGreaterThanOrEqual(policy.materialGapSeconds, policy.questionGapSeconds, "\(pace)")
            XCTAssertGreaterThanOrEqual(policy.cooldownSeconds, policy.questionCooldownSeconds, "\(pace)")
            XCTAssertGreaterThan(policy.requestsPerWindow, 0, "\(pace)")
            XCTAssertLessThanOrEqual(policy.maxCardsPerReply, 2, "\(pace)")
        }
        XCTAssertFalse(InsightPolicy.forPace(.quiet).answersMaterial)
        XCTAssertLessThan(InsightPolicy.forPace(.balanced).requestsPerWindow,
                          InsightPolicy.forPace(.eager).requestsPerWindow)
    }

    // MARK: - H. Dedup

    func testSimilarTitlesAreOneCard() {
        XCTAssertTrue(InsightDeduper.similar("Series B dilution", "Dilution at Series B"))
        XCTAssertTrue(InsightDeduper.similar("SOC 2", "SOC 2 compliance"))
        XCTAssertFalse(InsightDeduper.similar("Series B dilution", "Runway in months"))
        XCTAssertFalse(InsightDeduper.similar("the of and", "a to in"), "stop words alone match nothing")
    }

    func testGroundingTakesTheQuoteAsMostlyPresentNotVerbatim() {
        let window = "Them: what do you think about the pricing model\nYou: it is competitive"
        XCTAssertTrue(InsightDeduper.isGrounded("what do you think about the pricing model", in: window))
        XCTAssertTrue(InsightDeduper.isGrounded("the pricing modle", in: window),
                      "one misspelt word in three does not unground a quote")
        XCTAssertFalse(InsightDeduper.isGrounded("our Series B closes Friday", in: window))
        XCTAssertFalse(InsightDeduper.isGrounded("", in: window), "no quote, no card")
    }
}
