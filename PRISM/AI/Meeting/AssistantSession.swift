// AssistantSession.swift
// PRISM
//
// The in-meeting assistant: an intentionally short, in-memory conversation
// on a panel only the user can see (§5.33).
//
// The design decision that matters here is what this class does *not* do.
// It has a question detector wired to it, and the detector never causes a
// request. It sets a flag; the flag lights up a control; the user presses a
// key. That is the convergent finding across every open-source project in
// this space — cheating-daddy deleted its five-second automatic capture
// loop and left the dead parameter behind, and Amurex, the only fully
// automatic one, needed a server-side rate cap and a two-field guard to
// make the noise bearable. An assistant that answers unprompted is an
// assistant that talks over the meeting.
//
// The opt-in exception is `InsightSession` (§5.34), which is a separate
// object with a separate switch precisely so that this one never grows an
// automatic branch. It sends on its own, behind the controls those projects
// had to add afterwards, and it puts cards on the same panel; it does not
// go through `ask`.
//
// The second decision is the asymmetry in what gets sent. A typed question
// goes with the rolling transcript and a small follow-up history, because the
// question is about the conversation. A *detected* question goes on its own,
// with no transcript or assistant history at all — cue's finding, and the
// highest-leverage idea in the whole assistant design: when you already know
// exactly what was asked, history dilutes the answer rather than improving it.
//
// And a watchdog, because a provider that stops mid-stream without closing
// the connection leaves `isStreaming` true forever and wedges every later
// question until the app is relaunched. glass has this bug and no watchdog.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// One completed manual exchange kept in memory for follow-ups and for the
/// panel's short scrollback. Never persisted with the meeting.
public struct AssistantExchange: Identifiable, Equatable, Sendable {
    public var id: String
    public var question: String
    public var answer: String

    public init(id: String = UUID().uuidString, question: String, answer: String) {
        self.id = id
        self.question = question
        self.answer = answer
    }
}

@MainActor
public final class AssistantSession: ObservableObject {

    // MARK: Published

    /// The answer so far, streaming in. Rendered as it arrives — a live
    /// answer that appears all at once is an answer that arrives after the
    /// moment to say it has passed.
    @Published public private(set) var answer: String = ""
    @Published public private(set) var isStreaming = false
    /// The question the far end appears to have just asked, if any. Drives
    /// the composer's ready state. Never sent by itself.
    @Published public private(set) var detectedQuestion: String?
    @Published public private(set) var lastError: String?
    /// What the user last asked, so the panel can show the question above
    /// the answer.
    @Published public private(set) var lastAsked: String?
    /// Oldest first, capped. The current streaming answer remains in
    /// `answer`; completed answers move here when the next question starts.
    @Published public private(set) var history: [AssistantExchange] = []

    // MARK: Injected

    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    private let uptime: () -> TimeInterval
    private let sleep: Sleep
    private let stallSeconds: TimeInterval
    private let answerPublishSeconds: TimeInterval
    private var settings = AssistantSettings()

    public init(
        uptime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        sleep: @escaping Sleep = { seconds in
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        stallSeconds: TimeInterval = 25,
        answerPublishSeconds: TimeInterval = 0.033
    ) {
        self.uptime = uptime
        self.sleep = sleep
        self.stallSeconds = stallSeconds
        self.answerPublishSeconds = answerPublishSeconds
    }

    public func apply(_ settings: AssistantSettings) {
        self.settings = settings
        if !settings.isActive || !settings.highlightsQuestions {
            lastObservedTranscript = nil
            suppressedQuestion = nil
            if detectedQuestion != nil { detectedQuestion = nil }
        }
        if !settings.isActive { cancel() }
    }

    // MARK: State

    private var streamTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Provider deltas can be smaller than a word. Buffering them for one
    /// display interval keeps a fast stream from invalidating the SwiftUI
    /// panel hundreds of times per second while still looking instantaneous.
    private var pendingAnswer = ""
    private var answerPublishTask: Task<Void, Never>?
    private var lastStreamActivityUptime: TimeInterval = 0
    /// Invalidates callbacks from a provider whose request was cancelled.
    /// Some AsyncSequence implementations can still resume once after
    /// cancellation; that late event must never finish a newer answer.
    private var streamGeneration: UInt64 = 0
    private var lastObservedTranscript: String?
    /// A successfully handled question stays suppressed until it leaves the
    /// newest transcript line. Otherwise the next transcript publication
    /// lights the composer for the question that was just answered.
    private var suppressedQuestion: String?
    private var questionToSuppressOnSuccess: String?
    /// Only a provider-completed answer becomes follow-up context. A stopped
    /// or failed partial remains readable but must not be presented to the
    /// next request as though it were a completed assistant turn.
    private var currentAnswerCanArchive = false
    private static let historyLimit = 6
    private static let promptHistoryLimit = 3

    // MARK: - Question detection

    /// Fed the far-end transcript as it settles. Runs the detector and
    /// nothing else — see the file header.
    public func observeTranscript(_ tail: String) {
        guard settings.highlightsQuestions else {
            if detectedQuestion != nil { detectedQuestion = nil }
            return
        }
        guard tail != lastObservedTranscript else { return }
        lastObservedTranscript = tail
        let next = QuestionDetector.latestQuestion(in: tail)
        if next == nil { suppressedQuestion = nil }
        let visible = next == suppressedQuestion ? nil : next
        if visible != detectedQuestion { detectedQuestion = visible }
    }

    public func clearDetectedQuestion() {
        suppressedQuestion = detectedQuestion
        detectedQuestion = nil
    }

    // MARK: - Asking

    /// Asks a question.
    ///
    /// `text` nil means "answer the question that was detected". The two
    /// paths build very different prompts on purpose; see the header.
    public func ask(_ text: String?,
                    provider: LLMProvider,
                    transcriptTail: @autoclosure () -> String) {
        // A follow-up should retain the exchange it refers to. Do not archive
        // a superseded stream: a partial answer is not conversation history.
        if !isStreaming { archiveCurrentExchange() }
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = detectedQuestion

        let request: LLMRequest
        let asked: String
        if let typed, !typed.isEmpty {
            asked = typed
            request = LLMRequest(
                systemFrozen: Prompts.assistantSystem(),
                systemVolatile: nil,
                messages: recentConversationMessages + [.user(Prompts.assistantAskUser(
                    transcriptTail: transcriptTail(),
                    aboutMe: settings.aboutMe,
                    question: typed))],
                maxTokens: 2_000,
                effort: "medium")
        } else if let detected, !detected.isEmpty {
            asked = detected
            request = LLMRequest(
                systemFrozen: Prompts.assistantSystem(),
                systemVolatile: nil,
                messages: [.user(Prompts.assistantAnswerDetectedUser(
                    question: detected,
                    aboutMe: settings.aboutMe))],
                maxTokens: 2_000,
                effort: "medium")
        } else {
            // Nothing typed and nothing detected: send the tail and let the
            // model decide whether there is anything to answer. Its system
            // prompt has an explicit branch for "nothing to do", so this
            // produces a short summary rather than an invented task.
            asked = ""
            request = LLMRequest(
                systemFrozen: Prompts.assistantSystem(),
                systemVolatile: nil,
                messages: recentConversationMessages + [.user(Prompts.assistantAskUser(
                    transcriptTail: transcriptTail(),
                    aboutMe: settings.aboutMe,
                    question: "What should I know right now?"))],
                maxTokens: 2_000,
                effort: "low")
        }

        run(request, provider: provider, asked: asked,
            questionToSuppress: detected)
    }

    private func run(_ request: LLMRequest, provider: LLMProvider, asked: String,
                     questionToSuppress: String?) {
        // Keep the spinner continuously active when one Ask supersedes
        // another; publishing false and immediately true adds two redraws
        // and creates a visible one-frame flicker.
        stopCurrentStream(preservePendingAnswer: false, publishIdle: false)
        if !answer.isEmpty { answer = "" }
        if lastError != nil { lastError = nil }
        let nextAsked = asked.isEmpty ? nil : asked
        if lastAsked != nextAsked { lastAsked = nextAsked }
        questionToSuppressOnSuccess = questionToSuppress
        if !isStreaming { isStreaming = true }
        lastStreamActivityUptime = uptime()
        let generation = streamGeneration
        armWatchdog()

        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in provider.stream(request) {
                    guard !Task.isCancelled,
                          generation == self.streamGeneration else { return }
                    if !self.handle(event, generation: generation) { return }
                }
                self.finish(generation: generation)
            } catch {
                self.fail(error.localizedDescription, generation: generation)
            }
        }
    }

    /// Returns whether the provider stream should keep being consumed.
    private func handle(_ event: LLMEvent, generation: UInt64) -> Bool {
        guard generation == streamGeneration, isStreaming else { return false }
        lastStreamActivityUptime = uptime()
        switch event {
        case .textDelta(let text):
            pendingAnswer += text
            scheduleAnswerPublish()
            return true
        case .jsonDelta:
            // The assistant asks for prose, so this should not arrive.
            // Ignored rather than treated as an error: a provider sending a
            // block type PRISM did not ask for is not a reason to throw
            // away an otherwise good answer.
            return true
        case .stop:
            finish(generation: generation)
            return false
        case .apiError(_, let message):
            fail(message, generation: generation)
            return false
        }
    }

    private func finish(generation: UInt64) {
        guard generation == streamGeneration, isStreaming else { return }
        flushPendingAnswer()
        isStreaming = false
        streamTask = nil
        watchdog?.cancel()
        watchdog = nil
        // The answer stays on screen. A panel that clears itself the moment
        // the model stops is a panel you cannot read.
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           lastError == nil {
            lastError = "The provider returned nothing."
        }
        if let questionToSuppressOnSuccess {
            suppressedQuestion = questionToSuppressOnSuccess
        }
        currentAnswerCanArchive = lastError == nil
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        questionToSuppressOnSuccess = nil
        detectedQuestion = nil
    }

    private func fail(_ message: String, generation: UInt64) {
        guard generation == streamGeneration, isStreaming else { return }
        flushPendingAnswer()
        isStreaming = false
        streamTask?.cancel()
        streamTask = nil
        watchdog?.cancel()
        watchdog = nil
        lastError = message
        currentAnswerCanArchive = false
    }

    public func cancel() {
        stopCurrentStream(preservePendingAnswer: true)
    }

    /// Ends the current generation. Starting a new answer discards buffered
    /// text instead of publishing an obsolete answer for a single frame;
    /// an explicit Stop keeps everything received so far on screen.
    private func stopCurrentStream(preservePendingAnswer: Bool,
                                   publishIdle: Bool = true) {
        streamGeneration &+= 1
        if preservePendingAnswer {
            flushPendingAnswer()
        } else {
            answerPublishTask?.cancel()
            answerPublishTask = nil
            pendingAnswer.removeAll(keepingCapacity: true)
        }
        streamTask?.cancel()
        streamTask = nil
        watchdog?.cancel()
        watchdog = nil
        questionToSuppressOnSuccess = nil
        currentAnswerCanArchive = false
        if publishIdle, isStreaming { isStreaming = false }
    }

    public func clear() {
        cancel()
        answer = ""
        lastAsked = nil
        lastError = nil
        history = []
        currentAnswerCanArchive = false
    }

    // MARK: - Conversation memory

    private func archiveCurrentExchange() {
        guard currentAnswerCanArchive else { return }
        guard let question = lastAsked?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else { return }
        let completed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !completed.isEmpty else { return }
        history.append(AssistantExchange(question: question, answer: completed))
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        currentAnswerCanArchive = false
    }

    private var recentConversationMessages: [LLMMessage] {
        history.suffix(Self.promptHistoryLimit).flatMap { exchange in
            [.user(exchange.question), .assistant(exchange.answer)]
        }
    }

    // MARK: - Watchdog

    // MARK: - Answer publishing

    private func scheduleAnswerPublish() {
        guard answerPublishTask == nil else { return }
        let delay = answerPublishSeconds
        let sleep = self.sleep
        answerPublishTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.answerPublishTask = nil
            self.flushPendingAnswer()
        }
    }

    private func flushPendingAnswer() {
        answerPublishTask?.cancel()
        answerPublishTask = nil
        guard !pendingAnswer.isEmpty else { return }
        answer += pendingAnswer
        pendingAnswer.removeAll(keepingCapacity: true)
    }

    // MARK: - Watchdog

    /// One task per answer, not one task per token. It sleeps until the last
    /// observed activity would be stale and rechecks; a busy provider thus
    /// updates one scalar rather than repeatedly allocating and cancelling
    /// delayed tasks.
    private func armWatchdog() {
        watchdog?.cancel()
        let seconds = stallSeconds
        let generation = streamGeneration
        let sleep = self.sleep
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled, let self, self.isStreaming,
                  generation == self.streamGeneration {
                let elapsed = self.uptime() - self.lastStreamActivityUptime
                let remaining = max(0.05, seconds - elapsed)
                await sleep(remaining)
                guard !Task.isCancelled, self.isStreaming,
                      generation == self.streamGeneration else { return }
                let quietFor = self.uptime() - self.lastStreamActivityUptime
                if quietFor >= seconds {
                    self.streamTask?.cancel()
                    self.streamTask = nil
                    let reportedSeconds = max(1, Int(seconds.rounded()))
                    self.fail(LLMError.stalled(seconds: reportedSeconds).localizedDescription,
                              generation: generation)
                    return
                }
            }
        }
    }
}
