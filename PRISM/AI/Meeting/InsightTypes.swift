// InsightTypes.swift
// PRISM
//
// The value types of live insights (§5.34): what a card is, the kinds there
// are, how eager the mode is allowed to be, and the pure decision of whether
// now is a moment worth asking a model about.
//
// The decision lives here as a function over a snapshot rather than inside
// the session that uses it, for the reason the question detector does: the
// whole difficulty of an automatic assistant is *when* it speaks, and a rule
// that can only be exercised by running a meeting is a rule nobody tests.
// `InsightTrigger.decide` takes numbers in and gives a reason out, and the
// session's job is reduced to measuring the numbers honestly.
//
// The numbers themselves are in `InsightPolicy`, in one struct, per pace.
// Every project that shipped an automatic mode and kept it ended up with
// the same three controls — a floor on how much new material is worth a
// request, a quiet gap so the request goes out between sentences rather
// than during one, and a cooldown so that a lively stretch of conversation
// does not turn into a request a second. Those three are what stand between
// this feature and the version every open-source attempt took back out, so
// they are named, grouped, and tested rather than scattered as literals.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Kinds

/// What a card is for. The model picks one per card and the user picks
/// which ones they want to see at all.
public enum InsightKind: String, Codable, CaseIterable, Equatable, Hashable {
    /// Somebody asked the user something and they will have to reply out
    /// loud. The answer, or a position they could say.
    case answer
    /// A term, acronym, product, company or person went past that the user
    /// may not know.
    case term
    /// A number or a fact that bears on what is being discussed right now.
    case fact
    /// A question the user could ask next.
    case followUp
    /// Something somebody just promised or agreed to, so it is not lost.
    case commitment

    public var displayName: String {
        switch self {
        case .answer: return "Answers to what I'm asked"
        case .term: return "Terms and names that go past"
        case .fact: return "Facts and numbers"
        case .followUp: return "Questions worth asking next"
        case .commitment: return "Commitments people make"
        }
    }

    /// The one-word label a card wears.
    public var cardLabel: String {
        switch self {
        case .answer: return "Answer"
        case .term: return "Term"
        case .fact: return "Fact"
        case .followUp: return "Ask next"
        case .commitment: return "Commitment"
        }
    }

    /// SF Symbol for the card. A string here rather than an `Image`, so this
    /// file stays out of SwiftUI and inside the test target.
    public var symbolName: String {
        switch self {
        case .answer: return "text.bubble"
        case .term: return "character.book.closed"
        case .fact: return "number"
        case .followUp: return "arrow.turn.down.right"
        case .commitment: return "checkmark.seal"
        }
    }

    /// The sentence the model is given for this kind, and the sentence the
    /// pane shows under its switch. One string, so the user reads exactly
    /// the rule the model was given.
    public var rule: String {
        switch self {
        case .answer:
            return "somebody on the call asked the user something and they will have to reply out loud — the answer, or a position they could say"
        case .term:
            return "a term, acronym, product, company or person went past that the user may not know — one sentence on what it is and why it came up"
        case .fact:
            return "a number, date or fact that bears on what is being discussed right now — only when you are sure of it"
        case .followUp:
            return "a question the user could ask next that would move the conversation forward — only at a natural point for one"
        case .commitment:
            return "somebody just promised or agreed to something specific — who, what and when — so it is not lost"
        }
    }

    /// Every kind but `fact`. A fact card is the one kind no project in
    /// the open-source record has shipped and measured, and it is the one
    /// most likely to be a confident invention about the user's own
    /// company — the failure the accuracy block exists to prevent. It is a
    /// switch away, not gone.
    public static let defaultSet: Set<InsightKind> = [.answer, .term, .followUp, .commitment]

    /// Accepts the spellings a model actually produces for a kind —
    /// "follow-up", "follow_up", "FollowUp" — rather than only the raw
    /// value. A card of a kind PRISM cannot place is dropped, and dropping a
    /// good card over a hyphen is the kind of failure nobody ever sees.
    public static func lenient(_ raw: String) -> InsightKind? {
        let folded = raw.lowercased().filter { $0.isLetter }
        return allCases.first { $0.rawValue.lowercased() == folded }
    }
}

// MARK: - Pace

/// How eager the mode is. Three presets rather than six sliders, because
/// the sliders interact and the only thing anybody actually decides is how
/// much they want to be interrupted.
public enum InsightPace: String, Codable, CaseIterable, Equatable {
    /// Only when somebody asks the user something.
    case quiet
    /// Questions, plus a look at the conversation every so often.
    case balanced
    /// Looks more often and sooner.
    case eager

    public var displayName: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .eager: return "Eager"
        }
    }

    public var detail: String {
        switch self {
        case .quiet:
            return "Only when the other side asks you something. Nothing else prompts a request."
        case .balanced:
            return "When you are asked something, and otherwise a look at the last stretch of conversation every half a minute or so — when there is enough new material and a pause to send it in."
        case .eager:
            return "The same, sooner and more often. Expect more cards and more requests."
        }
    }
}

// MARK: - Card

/// One thing the model thought was worth interrupting for.
public struct InsightCard: Identifiable, Equatable {
    public var id: String
    public var kind: InsightKind
    /// At most a few words — the term, the answer's headline, the commitment.
    public var title: String
    /// One or two sentences. Plain text; the panel does not render markdown.
    public var body: String
    /// The transcript line that prompted the card, quoted. The grounding
    /// measure of §5.32's action items again: a card the model cannot quote
    /// a line for is a card it invented, and the quote is what lets the
    /// user check that in a glance.
    public var trigger: String
    public var arrivedAt: Date
    /// Pinned cards do not expire and are not pushed out by newer ones.
    public var isPinned: Bool

    public init(id: String = UUID().uuidString,
                kind: InsightKind, title: String, body: String, trigger: String,
                arrivedAt: Date, isPinned: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.trigger = trigger
        self.arrivedAt = arrivedAt
        self.isPinned = isPinned
    }
}

// MARK: - Policy

/// The numbers. One struct per pace, built by `forPace`.
///
/// Units are seconds and words. The word floor is measured over *settled*
/// transcript only, because a request that goes out over a hypothesis the
/// recogniser then revises is a request about a sentence nobody said.
public struct InsightPolicy: Equatable {

    /// Whether a stretch of new conversation, with no question in it, is
    /// ever reason enough for a request. `quiet` says no.
    public var answersMaterial: Bool

    /// New settled words since the last request before a material request
    /// is considered. Roughly ten seconds of speech at the default.
    public var minNewWords: Int

    /// How long the transcript has to have been still before a material
    /// request goes out. This is what puts the request between sentences
    /// rather than in the middle of one: a model asked about half a sentence
    /// answers about half a sentence.
    public var materialGapSeconds: TimeInterval

    /// The same, after a detected question. Shorter, because the question
    /// has arrived complete and the clock is running on the user's reply.
    public var questionGapSeconds: TimeInterval

    /// Between material requests.
    public var cooldownSeconds: TimeInterval

    /// Between question requests. A second question eight seconds after the
    /// first is a real second question and deserves its own card; a second
    /// request two seconds later is the same question settling.
    public var questionCooldownSeconds: TimeInterval

    /// A detected question older than this when a request could finally go
    /// out — held up by a cooldown or a request in flight — is dropped
    /// rather than asked about. The moment to answer it has passed, and an
    /// answer card that lands a quarter of a minute late is a card about
    /// the wrong minute.
    public var questionStaleSeconds: TimeInterval

    /// The hard ceiling: this many requests in any rolling window of
    /// `windowSeconds`, after which the mode waits regardless of what is
    /// said. Amurex needed this server-side after shipping without it.
    public var requestsPerWindow: Int
    public var windowSeconds: TimeInterval

    /// At most this many cards accepted from one reply.
    public var maxCardsPerReply: Int
    /// At most this many unpinned cards on the panel.
    public var visibleLimit: Int
    /// An unpinned card leaves after this long. Long enough to read after
    /// the moment has passed, short enough that the panel is about the
    /// current minute rather than the whole call.
    public var expirySeconds: TimeInterval
    /// A reply that has not finished by then is abandoned. The assistant's
    /// watchdog, for the assistant's reason.
    public var requestTimeoutSeconds: TimeInterval
    /// How many recent titles ride along in the prompt so the model does not
    /// repeat itself.
    public var shownMemory: Int

    public init(answersMaterial: Bool, minNewWords: Int,
                materialGapSeconds: TimeInterval, questionGapSeconds: TimeInterval,
                cooldownSeconds: TimeInterval, questionCooldownSeconds: TimeInterval,
                questionStaleSeconds: TimeInterval = 12,
                requestsPerWindow: Int, windowSeconds: TimeInterval = 600,
                maxCardsPerReply: Int = 2, visibleLimit: Int = 6,
                expirySeconds: TimeInterval = 120, requestTimeoutSeconds: TimeInterval = 20,
                shownMemory: Int = 12) {
        self.answersMaterial = answersMaterial
        self.minNewWords = minNewWords
        self.materialGapSeconds = materialGapSeconds
        self.questionGapSeconds = questionGapSeconds
        self.cooldownSeconds = cooldownSeconds
        self.questionCooldownSeconds = questionCooldownSeconds
        self.questionStaleSeconds = questionStaleSeconds
        self.requestsPerWindow = requestsPerWindow
        self.windowSeconds = windowSeconds
        self.maxCardsPerReply = maxCardsPerReply
        self.visibleLimit = visibleLimit
        self.expirySeconds = expirySeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.shownMemory = shownMemory
    }

    public static func forPace(_ pace: InsightPace) -> InsightPolicy {
        switch pace {
        case .quiet:
            return InsightPolicy(answersMaterial: false, minNewWords: .max,
                                 materialGapSeconds: 3, questionGapSeconds: 1.5,
                                 cooldownSeconds: 30, questionCooldownSeconds: 8,
                                 requestsPerWindow: 8)
        case .balanced:
            return InsightPolicy(answersMaterial: true, minNewWords: 35,
                                 materialGapSeconds: 3, questionGapSeconds: 1.5,
                                 cooldownSeconds: 25, questionCooldownSeconds: 8,
                                 requestsPerWindow: 14)
        case .eager:
            return InsightPolicy(answersMaterial: true, minNewWords: 20,
                                 materialGapSeconds: 2, questionGapSeconds: 1,
                                 cooldownSeconds: 12, questionCooldownSeconds: 5,
                                 requestsPerWindow: 24)
        }
    }
}

// MARK: - Trigger

/// Whether now is a moment to ask. Pure; the session measures, this judges.
public enum InsightTrigger {

    public enum Reason: Equatable {
        /// The other side asked this, and it has not been answered yet.
        case question(String)
        /// Enough new conversation has settled, and there is a pause.
        case material
    }

    /// Everything the decision depends on, measured by the caller.
    public struct Snapshot: Equatable {
        /// Settled words since the last request started.
        public var newWords: Int
        /// A complete question in the newest settled far-end line that no
        /// request has been made about, or nil.
        public var detectedQuestion: String?
        /// Since the last request started; nil when there has been none.
        public var secondsSinceLastRequest: TimeInterval?
        /// Since the transcript last changed at all — settled or not. This
        /// is the "is anybody still talking" signal.
        public var secondsSinceLastChange: TimeInterval
        public var inFlight: Bool
        /// Requests started inside the current window.
        public var requestsInWindow: Int
        /// Until the oldest request in the window falls out of it; nil when
        /// the window is not full.
        public var secondsUntilWindowFrees: TimeInterval?

        public init(newWords: Int, detectedQuestion: String?,
                    secondsSinceLastRequest: TimeInterval?,
                    secondsSinceLastChange: TimeInterval,
                    inFlight: Bool, requestsInWindow: Int,
                    secondsUntilWindowFrees: TimeInterval? = nil) {
            self.newWords = newWords
            self.detectedQuestion = detectedQuestion
            self.secondsSinceLastRequest = secondsSinceLastRequest
            self.secondsSinceLastChange = secondsSinceLastChange
            self.inFlight = inFlight
            self.requestsInWindow = requestsInWindow
            self.secondsUntilWindowFrees = secondsUntilWindowFrees
        }
    }

    /// The reason to send a request now, or nil.
    ///
    /// A question outranks material: when both apply, the request is about
    /// the question, and the material goes along as context anyway.
    public static func decide(_ s: Snapshot, policy: InsightPolicy) -> Reason? {
        guard !s.inFlight else { return nil }
        guard s.requestsInWindow < policy.requestsPerWindow else { return nil }
        let sinceLast = s.secondsSinceLastRequest ?? .infinity

        if let question = s.detectedQuestion,
           s.secondsSinceLastChange >= policy.questionGapSeconds,
           sinceLast >= policy.questionCooldownSeconds {
            return .question(question)
        }
        if policy.answersMaterial,
           s.newWords >= policy.minNewWords,
           s.secondsSinceLastChange >= policy.materialGapSeconds,
           sinceLast >= policy.cooldownSeconds {
            return .material
        }
        return nil
    }

    /// When `decide` could next say yes if nothing further is said, or nil
    /// when no amount of waiting will do it — there is nothing pending, or a
    /// request is in flight and its completion is the next event.
    ///
    /// This is what lets the session sleep rather than poll: it wakes
    /// exactly when a gap or a cooldown elapses, and not before.
    public static func delayUntilPossible(_ s: Snapshot, policy: InsightPolicy) -> TimeInterval? {
        guard !s.inFlight else { return nil }
        if s.requestsInWindow >= policy.requestsPerWindow {
            return s.secondsUntilWindowFrees.map { max($0, minimumDelay) }
        }
        let sinceLast = s.secondsSinceLastRequest ?? .infinity
        var candidates: [TimeInterval] = []
        if s.detectedQuestion != nil {
            candidates.append(max(policy.questionGapSeconds - s.secondsSinceLastChange,
                                  policy.questionCooldownSeconds - sinceLast))
        }
        if policy.answersMaterial, s.newWords >= policy.minNewWords {
            candidates.append(max(policy.materialGapSeconds - s.secondsSinceLastChange,
                                  policy.cooldownSeconds - sinceLast))
        }
        guard let soonest = candidates.min() else { return nil }
        // Never zero: a zero here means `decide` should already have fired,
        // and a zero-delay reschedule is a spin.
        return max(soonest, minimumDelay)
    }

    static let minimumDelay: TimeInterval = 0.05
}

// MARK: - Dedup

/// Whether two titles are the same card in different words.
///
/// Word-set overlap rather than string equality, because the model rarely
/// repeats itself verbatim: "Series B dilution" and "Dilution at Series B"
/// are one card. Stop words are dropped first so that "the" and "of" cannot
/// make two unrelated titles look alike.
public enum InsightDeduper {

    static let stopWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "and", "or",
        "is", "are", "was", "were", "be", "it", "its", "this", "that", "with",
        "your", "you", "their", "they", "we", "our", "about", "what", "how",
    ]

    /// Lowercased alphanumeric tokens minus stop words.
    public static func tokens(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let pieces = lowered.split { !($0.isLetter || $0.isNumber) }
        return Set(pieces.map(String.init).filter { !stopWords.contains($0) && !$0.isEmpty })
    }

    /// True when the two titles share most of their words, or one is
    /// contained in the other.
    public static func similar(_ a: String, _ b: String) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        if ta.isSubset(of: tb) || tb.isSubset(of: ta) { return true }
        let overlap = Double(ta.intersection(tb).count)
        let union = Double(ta.union(tb).count)
        return overlap / union >= 0.6
    }

    public static func isDuplicate(_ title: String, of shown: [String]) -> Bool {
        shown.contains { similar($0, title) }
    }

    /// Whether a card's quoted trigger actually occurs in the transcript it
    /// was given. The prompt says every card must quote its line; this is
    /// the check that makes the rule hold when the model does not. Token
    /// presence rather than a substring match, because the model shortens
    /// and the recogniser misspells, and a quote with most of its words in
    /// the window is a quote of the window.
    ///
    /// Stop words count here, unlike in `similar`: "what do you think" is
    /// almost entirely stop words and is a real line.
    public static func isGrounded(_ trigger: String, in window: String) -> Bool {
        let wanted = rawTokens(trigger)
        guard !wanted.isEmpty else { return false }
        let present = Set(rawTokens(window))
        let found = wanted.filter { present.contains($0) }.count
        return Double(found) / Double(wanted.count) >= 0.6
    }

    static func rawTokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }
}
