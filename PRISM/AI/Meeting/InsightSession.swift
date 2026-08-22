// InsightSession.swift
// PRISM
//
// Live insights (§5.34): cards that appear on the assistant's panel while the
// call goes on, without a key being pressed.
//
// This is the one place in PRISM where a model is asked something the user
// did not just ask for, and it exists as a separate mode with its own switch
// rather than as a behaviour of the assistant, because §5.33's whole argument
// is that an assistant which answers unprompted talks over the meeting. That
// argument is right, and it was made by reading the projects that shipped the
// automatic version: cheating-daddy took its capture loop out, Amurex needed
// a server-side rate cap, glass's listen view got an off switch within weeks.
// None of them failed because their detectors were wrong. They failed because
// a detector wired straight to a request turns every false positive into a
// paragraph that arrives while somebody is still speaking.
//
// So this mode is built out of the controls those projects added afterwards,
// and it is off until the user turns it on:
//
//   It never sends mid-sentence. A request waits for the transcript to have
//   been still for a moment — `materialGapSeconds` — which puts it between
//   turns rather than inside one.
//
//   It needs a reason. Either the other side asked a question (the detector
//   that §5.33 keeps as a light becomes, in this mode and only this mode, a
//   trigger), or enough new conversation has settled since the last request
//   to be worth a look. "Enough" is a word floor, over settled text only.
//
//   It has a cooldown and a ceiling. Two requests cannot be closer together
//   than the cooldown, and no rolling ten minutes can hold more than the
//   window allows, whatever is said. A lively call cannot become a request a
//   second, and a runaway cannot become a bill.
//
//   It is allowed to say nothing, and it is told that nothing is the usual
//   answer. The schema permits an empty list; the prompt says to prefer it;
//   everything the model does return is filtered again here against what
//   has already been shown and what the user has dismissed.
//
//   It only runs while the panel is up and a meeting is being transcribed.
//   Close the panel, stop listening, or pick no provider, and nothing is
//   sent — the mode is armed by three switches and disarmed by any one.
//
// The clock and the sleep are injected so that every one of those rules can
// be tested in milliseconds against a fake provider. A rule about timing
// that can only be exercised by holding a meeting is a rule nobody tests.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Decoding

/// One card as the model wrote it, before PRISM has decided whether to
/// show it.
struct InsightReplyCard: Equatable {
    var kind: InsightKind
    var title: String
    var body: String
    var trigger: String
}

/// Parses a reply. Tolerant, for the note writer's reason: providers differ
/// on whether a schema-constrained reply comes back bare or fenced, and a
/// card should not be lost to three backticks. Prose that is not JSON at all
/// is no cards, not an error — a model that answered in a paragraph when
/// asked for a list has nothing worth putting on a panel.
enum InsightReplyDecoder {

    static func decode(_ raw: String) -> [InsightReplyCard] {
        let trimmed = unwrapFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        let entries: [[String: Any]]
        if let dictionary = object as? [String: Any] {
            entries = dictionary["cards"] as? [[String: Any]] ?? []
        } else if let array = object as? [[String: Any]] {
            entries = array
        } else {
            return []
        }

        return entries.compactMap { entry in
            guard let kindRaw = entry["kind"] as? String,
                  let kind = InsightKind(rawValue: kindRaw) ?? InsightKind.lenient(kindRaw)
            else { return nil }
            let title = (entry["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (entry["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let trigger = (entry["trigger"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty else { return nil }
            return InsightReplyCard(kind: kind, title: title, body: body, trigger: trigger)
        }
    }

    static func unwrapFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: .newlines)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Session

@MainActor
public final class InsightSession: ObservableObject {

    // MARK: Published

    /// Newest first. Within one reply the model's order is kept, so the card
    /// it ranked first stays on top.
    @Published public private(set) var cards: [InsightCard] = []
    /// A request is in flight.
    @Published public private(set) var isThinking = false
    @Published public private(set) var lastError: String?
    /// Requests made this meeting. Shown in the pane, because "how often
    /// does this actually send" is the question the feature has to answer.
    @Published public private(set) var requestCount = 0
    /// Cards accepted and dismissed this meeting. Not shown anywhere live;
    /// they become one content-free row in the session log when the meeting
    /// ends, which is the only way the defaults will ever get tuned against
    /// real use.
    public private(set) var cardsShown = 0
    public private(set) var cardsDismissed = 0
    /// All three switches are on: the mode, the panel with a provider, and a
    /// meeting that is listening.
    @Published public private(set) var isArmed = false

    // MARK: Injected

    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    /// Builds the provider the settings describe, or nil when none is
    /// usable. Installed by AppState, which owns the key.
    public var providerFactory: () -> LLMProvider? = { nil }

    private let now: () -> Date
    private let sleep: Sleep

    public init(now: @escaping () -> Date = Date.init,
                sleep: @escaping Sleep = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                }) {
        self.now = now
        self.sleep = sleep
    }

    // MARK: Settings

    public private(set) var settings = AssistantSettings()
    public private(set) var policy = InsightPolicy.forPace(.balanced)
    private var listening = false

    public func apply(_ settings: AssistantSettings) {
        let wasOn = self.settings.wantsLiveInsights
        self.settings = settings
        policy = InsightPolicy.forPace(settings.insightPace)
        // Turning the mode off, closing the panel, or dropping the provider
        // all land here. The cards were about a conversation the user has
        // stopped wanting cards about, and a panel that reopens onto stale
        // ones is a panel about the wrong minute.
        if wasOn, !settings.wantsLiveInsights { clearAll() }
        rearm()
    }

    /// Mirrors `MeetingSession.phase.isListening`. A meeting that stops for
    /// any reason takes everything here with it.
    public func setListening(_ on: Bool) {
        guard on != listening else { return }
        listening = on
        if !on { reset() }
        rearm()
    }

    // MARK: State

    private var latestLines: [TranscriptLine] = []
    /// Parallel to `latestLines`. Only the changed suffix is counted when a
    /// live transcript appends or revises its last line, so a long meeting
    /// does not make every new word progressively more expensive.
    private var lineWordCounts: [Int] = []
    /// Words across every line, settled or not: the "is anyone still
    /// talking" signal.
    private var activityWordCount = 0
    /// Words across settled lines only: what a request may be about.
    private var settledWordCount = 0
    /// `settledWordCount` when the last request started.
    private var seenWordCount = 0
    private var lastChangeAt: Date?
    private var lastRequestAt: Date?
    private var requestTimes: [Date] = []
    private var pendingQuestion: String?
    private var pendingQuestionAt: Date?
    private var lastAnsweredQuestion: String?
    /// Every title shown this meeting, for dedup: a term defined once stays
    /// defined. The prompt gets only the most recent `shownMemory` of them.
    private var shownTitles: [String] = []
    private var dismissedTitles: [String] = []
    /// The transcript window the in-flight request was built from, so the
    /// reply's quotes can be checked against what the model actually saw.
    private var windowSent = ""

    private var checkTask: Task<Void, Never>?
    private var checkDeadline: Date?
    private var checkGeneration: UInt64 = 0
    private var requestTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?

    private func rearm() {
        let armed = listening && settings.wantsLiveInsights
        if armed != isArmed { isArmed = armed }
        if armed {
            scheduleCheck()
        } else {
            cancelWork()
        }
    }

    private func cancelWork() {
        cancelScheduledCheck()
        requestTask?.cancel()
        requestTask = nil
        isThinking = false
    }

    private func reset() {
        cancelWork()
        clearAll()
        latestLines = []
        lineWordCounts = []
        activityWordCount = 0
        settledWordCount = 0
        seenWordCount = 0
        lastChangeAt = nil
        lastRequestAt = nil
        requestTimes = []
        pendingQuestion = nil
        pendingQuestionAt = nil
        lastAnsweredQuestion = nil
        shownTitles = []
        dismissedTitles = []
        windowSent = ""
        lastError = nil
        requestCount = 0
        cardsShown = 0
        cardsDismissed = 0
    }

    /// One content-free row for the session log, or nil when the mode never
    /// sent anything this meeting. Counts only — §5.21's rule does not bend
    /// for the feature that produces the most sensitive text in the app.
    public var meetingSummary: String? {
        guard requestCount > 0 else { return nil }
        return "Live insights: \(requestCount) request\(requestCount == 1 ? "" : "s"), "
            + "\(cardsShown) card\(cardsShown == 1 ? "" : "s") shown, "
            + "\(cardsDismissed) dismissed"
    }

    // MARK: - Observing

    /// Fed every change to the meeting's lines. Measures; never sends
    /// directly — `scheduleCheck` decides.
    public func observe(lines: [TranscriptLine]) {
        guard lines != latestLines else { return }
        // A transcript normally keeps its prefix and changes only its last
        // line. Reuse the prefix's counts; still handle replacement and
        // deletion exactly for recogniser corrections and meeting resets.
        var common = 0
        let commonLimit = min(latestLines.count, lines.count)
        while common < commonLimit, latestLines[common] == lines[common] {
            common += 1
        }

        var activity = activityWordCount
        var settled = settledWordCount
        if common < latestLines.count {
            for index in common..<latestLines.count {
                let count = lineWordCounts[index]
                activity -= count
                if latestLines[index].isSettled { settled -= count }
            }
            lineWordCounts.removeSubrange(common...)
        }
        if common < lines.count {
            lineWordCounts.reserveCapacity(lines.count)
            for index in common..<lines.count {
                let line = lines[index]
                let count = Self.wordCount(line.text)
                lineWordCounts.append(count)
                activity += count
                if line.isSettled { settled += count }
            }
        }
        latestLines = lines
        activityWordCount = activity
        // A same-length recogniser correction is activity too. Counting
        // only words would let a request leave while the actual sentence is
        // still being revised, simply because one word replaced one word.
        lastChangeAt = now()
        settledWordCount = settled

        // The detector over the newest settled far-end line, and only that
        // line: a question from three turns ago has been answered or moved
        // past, and a request about it now is a request about the wrong
        // moment. Kept pending across the user's reply on purpose — an
        // answer card that arrives while they are still forming the answer
        // is exactly on time.
        if let newest = lines.last(where: \.isSettled) {
            if newest.channel == .farEnd,
               let question = QuestionDetector.latestQuestion(in: newest.text),
               question != lastAnsweredQuestion {
                if question != pendingQuestion {
                    pendingQuestion = question
                    pendingQuestionAt = now()
                }
            } else if newest.channel == .directMic,
                      Self.wordCount(newest.text) >= Self.answeredWordFloor {
                // The user has settled a sentence of their own since the
                // question: they are answering it. A card now would arrive
                // after the answer it was meant to help with. Amurex wrote
                // this rule into its prompt; here it costs no request at all.
                pendingQuestion = nil
                pendingQuestionAt = nil
            }
        }

        guard isArmed else { return }
        scheduleCheck()
    }

    /// A settled reply of this many words means the user is answering.
    static let answeredWordFloor = 8

    // MARK: - Scheduling

    private func snapshot() -> InsightTrigger.Snapshot {
        let t = now()
        requestTimes.removeAll { t.timeIntervalSince($0) >= policy.windowSeconds }
        // A question that has waited out a cooldown or a request in flight
        // for this long has been answered or moved past. Drop it rather
        // than answer it late; the material path still sees the context.
        if let askedAt = pendingQuestionAt,
           t.timeIntervalSince(askedAt) > policy.questionStaleSeconds {
            pendingQuestion = nil
            pendingQuestionAt = nil
        }
        return InsightTrigger.Snapshot(
            newWords: max(0, settledWordCount - seenWordCount),
            detectedQuestion: pendingQuestion,
            secondsSinceLastRequest: lastRequestAt.map { t.timeIntervalSince($0) },
            secondsSinceLastChange: lastChangeAt.map { t.timeIntervalSince($0) } ?? .infinity,
            inFlight: requestTask != nil,
            requestsInWindow: requestTimes.count,
            secondsUntilWindowFrees: requestTimes.first.map {
                policy.windowSeconds - t.timeIntervalSince($0)
            })
    }

    /// Sends now if the policy says so; otherwise sleeps until the policy
    /// could next say so, and asks again. Never polls.
    private func scheduleCheck() {
        guard isArmed else { return }
        let snapshot = snapshot()
        if let reason = InsightTrigger.decide(snapshot, policy: policy) {
            cancelScheduledCheck()
            run(reason)
            return
        }
        guard let delay = InsightTrigger.delayUntilPossible(snapshot, policy: policy) else {
            cancelScheduledCheck()
            return
        }
        let deadline = now().addingTimeInterval(delay)
        // Keep an existing earlier wake. If continued speech moves the real
        // quiet-gap deadline later, that wake will cheaply re-evaluate once;
        // replacing a task for every transcript delta is much more costly.
        if checkTask != nil, let checkDeadline, checkDeadline <= deadline {
            return
        }
        cancelScheduledCheck()
        let sleep = self.sleep
        checkGeneration &+= 1
        let generation = checkGeneration
        checkDeadline = deadline
        checkTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self,
                  generation == self.checkGeneration else { return }
            self.checkTask = nil
            self.checkDeadline = nil
            self.scheduleCheck()
        }
    }

    private func cancelScheduledCheck() {
        checkGeneration &+= 1
        checkTask?.cancel()
        checkTask = nil
        checkDeadline = nil
    }

    // MARK: - Requests

    private func run(_ reason: InsightTrigger.Reason) {
        guard let provider = providerFactory() else {
            // No reschedule. A provider that is not set up is a settings
            // problem, and settings changes re-arm.
            lastError = LLMError.notConfigured.errorDescription
            return
        }
        let t = now()
        lastRequestAt = t
        requestTimes.append(t)
        seenWordCount = settledWordCount

        var question: String?
        if case .question(let asked) = reason {
            question = asked
        } else if let pending = pendingQuestion {
            // A material request with a question still pending carries it
            // along rather than leaving it to fire separately a moment later.
            question = pending
        }
        if let question { lastAnsweredQuestion = question }
        pendingQuestion = nil
        pendingQuestionAt = nil

        let kinds = InsightKind.allCases.filter { settings.effectiveInsightKinds.contains($0) }
        let transcriptTail = Self.render(latestLines.suffix(settings.clampedContextTurns))
        windowSent = transcriptTail
        if let question { windowSent += "\n" + question }
        let request = LLMRequest(
            systemFrozen: Prompts.insightsSystem(),
            systemVolatile: nil,
            messages: [.user(Prompts.insightsUser(
                transcriptTail: transcriptTail,
                aboutMe: settings.aboutMe,
                shownTitles: Array(shownTitles.suffix(policy.shownMemory)),
                detectedQuestion: question,
                kinds: kinds))],
            maxTokens: 700,
            jsonSchema: Self.schema,
            effort: "low")

        isThinking = true
        lastError = nil
        requestCount += 1
        let timeout = policy.requestTimeoutSeconds
        let sleep = self.sleep
        requestTask = Task { [weak self] in
            let result = await Self.collect(request, provider: provider,
                                            timeout: timeout, sleep: sleep)
            guard !Task.isCancelled else { return }
            self?.finish(result)
        }
    }

    /// Drains the reply, racing it against the timeout. Structured replies
    /// arrive as `jsonDelta` and prose as `textDelta`; both are kept,
    /// because which one a provider uses for a schema-constrained reply is
    /// not consistent between them.
    nonisolated private static func collect(_ request: LLMRequest, provider: LLMProvider,
                                            timeout: TimeInterval,
                                            sleep: @escaping Sleep) async -> Result<String, Error> {
        await withTaskGroup(of: Result<String, Error>?.self) { group in
            group.addTask {
                do {
                    var output = ""
                    for try await event in provider.stream(request) {
                        if Task.isCancelled { return .failure(LLMError.cancelled) }
                        switch event {
                        case .textDelta(let text): output += text
                        case .jsonDelta(let json): output += json
                        case .apiError(_, let message): return .failure(LLMError.transport(message))
                        case .stop: return .success(output)
                        }
                    }
                    return .success(output)
                } catch {
                    return .failure(error)
                }
            }
            group.addTask {
                await sleep(timeout)
                return Task.isCancelled ? nil : .failure(LLMError.stalled(seconds: Int(timeout)))
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(LLMError.cancelled)
        }
    }

    private func finish(_ result: Result<String, Error>) {
        requestTask = nil
        isThinking = false
        switch result {
        case .failure(let error):
            if let llm = error as? LLMError, llm == .cancelled { break }
            lastError = error.localizedDescription
        case .success(let raw):
            lastError = nil
            accept(InsightReplyDecoder.decode(raw))
        }
        // Conversation that arrived mid-flight is material for the next one.
        scheduleCheck()
    }

    // MARK: - Accepting cards

    /// The filters, cheapest first and all in code: the kinds the user
    /// wants, the quote that has to be real, and the titles already shown
    /// or waved away. The prompt asks for all three; this is where they
    /// hold when the model does not.
    private func accept(_ decoded: [InsightReplyCard]) {
        let t = now()
        var known = shownTitles + dismissedTitles + cards.map(\.title)
        var accepted: [InsightCard] = []
        for card in decoded {
            guard settings.effectiveInsightKinds.contains(card.kind) else { continue }
            // A card that cannot quote a line it was given is a card the
            // model invented, and the quote is checked against the window
            // that was actually sent — not the transcript as it is now.
            guard InsightDeduper.isGrounded(card.trigger, in: windowSent) else { continue }
            guard !InsightDeduper.isDuplicate(card.title, of: known) else { continue }
            known.append(card.title)
            accepted.append(InsightCard(kind: card.kind, title: card.title,
                                        body: card.body, trigger: card.trigger,
                                        arrivedAt: t))
            if accepted.count >= policy.maxCardsPerReply { break }
        }
        guard !accepted.isEmpty else { return }
        shownTitles.append(contentsOf: accepted.map(\.title))
        cardsShown += accepted.count
        cards.insert(contentsOf: accepted, at: 0)
        prune(at: t)
        scheduleSweep()
    }

    /// Drops expired cards, then the oldest unpinned ones over the limit.
    private func prune(at t: Date) {
        cards.removeAll { !$0.isPinned && t.timeIntervalSince($0.arrivedAt) >= policy.expirySeconds }
        var excess = cards.filter { !$0.isPinned }.count - policy.visibleLimit
        guard excess > 0 else { return }
        var kept: [InsightCard] = []
        for card in cards.reversed() {          // oldest first
            if !card.isPinned, excess > 0 {
                excess -= 1
                continue
            }
            kept.append(card)
        }
        cards = kept.reversed()
    }

    private func scheduleSweep() {
        sweepTask?.cancel()
        sweepTask = nil
        let t = now()
        let remaining = cards.filter { !$0.isPinned }
            .map { policy.expirySeconds - t.timeIntervalSince($0.arrivedAt) }
            .min()
        guard let remaining else { return }
        let sleep = self.sleep
        sweepTask = Task { [weak self] in
            await sleep(max(remaining, InsightTrigger.minimumDelay))
            guard !Task.isCancelled, let self else { return }
            self.sweepTask = nil
            self.prune(at: self.now())
            self.scheduleSweep()
        }
    }

    // MARK: - Card actions

    public func card(id: String) -> InsightCard? {
        cards.first { $0.id == id }
    }

    /// Dismissed cards are remembered for the meeting: a term the user
    /// waved away once is not one they want defined again.
    public func dismiss(_ id: String) {
        guard let card = card(id: id) else { return }
        dismissedTitles.append(card.title)
        cardsDismissed += 1
        cards.removeAll { $0.id == id }
        scheduleSweep()
    }

    public func togglePin(_ id: String) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index].isPinned.toggle()
        scheduleSweep()
    }

    /// Removes every card. Remembers nothing — this is "tidy up", not "never
    /// again".
    public func clearAll() {
        sweepTask?.cancel()
        sweepTask = nil
        cards = []
    }

    // MARK: - Schema

    /// Every object carries `additionalProperties: false` and lists every
    /// required field — a constraint of the schema support, not a style.
    static var schema: JSONValue {
        .schema(type: "object",
                properties: [
                    "cards": .schema(
                        type: "array",
                        items: .schema(type: "object",
                                       properties: [
                                        "kind": .object([
                                            "type": .string("string"),
                                            "enum": .array(InsightKind.allCases.map { .string($0.rawValue) }),
                                        ]),
                                        "title": .schema(type: "string",
                                                         description: "At most eight words."),
                                        "body": .schema(type: "string",
                                                        description: "One or two sentences, plain text."),
                                        "trigger": .schema(type: "string",
                                                           description: "The transcript line that prompted this card, quoted as short as possible."),
                                       ],
                                       required: ["kind", "title", "body", "trigger"]),
                        description: "Zero, one or two cards. Empty when nothing is worth one."),
                ],
                required: ["cards"])
    }

    // MARK: - Helpers

    static func render(_ lines: ArraySlice<TranscriptLine>) -> String {
        lines.map { "\($0.label): \($0.text)" }.joined(separator: "\n")
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        var insideWord = false
        for character in text {
            if character.isWhitespace {
                insideWord = false
            } else if !insideWord {
                count += 1
                insideWord = true
            }
        }
        return count
    }
}
