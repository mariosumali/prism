// AssistantSession.swift
// PRISM
//
// The in-meeting assistant: one question, one answer, on a panel only the
// user can see (§5.33).
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
// The second decision is the asymmetry in what gets sent. A typed question
// goes with the rolling transcript, because the question is about the
// conversation. A *detected* question goes on its own, with no transcript
// at all — cue's finding, and the highest-leverage idea in the whole
// assistant design: when you already know exactly what was asked, history
// dilutes the answer rather than improving it.
//
// And a watchdog, because a provider that stops mid-stream without closing
// the connection leaves `isStreaming` true forever and wedges every later
// question until the app is relaunched. glass has this bug and no watchdog.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

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

    // MARK: Injected

    private let now: () -> Date
    private var settings = AssistantSettings()

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    public func apply(_ settings: AssistantSettings) {
        self.settings = settings
        if !settings.isActive { cancel() }
    }

    // MARK: State

    private var streamTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    /// Rearmed on every token. If it ever fires, the provider went quiet
    /// without finishing.
    private static let stallSeconds = 25

    // MARK: - Question detection

    /// Fed the far-end transcript as it settles. Runs the detector and
    /// nothing else — see the file header.
    public func observeTranscript(_ tail: String) {
        guard settings.highlightsQuestions else {
            detectedQuestion = nil
            return
        }
        detectedQuestion = QuestionDetector.latestQuestion(in: tail)
    }

    public func clearDetectedQuestion() {
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
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = detectedQuestion

        let request: LLMRequest
        let asked: String
        if let typed, !typed.isEmpty {
            asked = typed
            request = LLMRequest(
                systemFrozen: Prompts.assistantSystem(),
                systemVolatile: nil,
                messages: [.user(Prompts.assistantAskUser(
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
                messages: [.user(Prompts.assistantAskUser(
                    transcriptTail: transcriptTail(),
                    aboutMe: settings.aboutMe,
                    question: "What should I know right now?"))],
                maxTokens: 2_000,
                effort: "low")
        }

        run(request, provider: provider, asked: asked)
    }

    private func run(_ request: LLMRequest, provider: LLMProvider, asked: String) {
        cancel()
        answer = ""
        lastError = nil
        lastAsked = asked.isEmpty ? nil : asked
        isStreaming = true
        armWatchdog()

        streamTask = Task { [weak self] in
            do {
                for try await event in provider.stream(request) {
                    if Task.isCancelled { break }
                    await MainActor.run { [weak self] in
                        self?.handle(event)
                    }
                }
                await MainActor.run { [weak self] in self?.finish() }
            } catch {
                await MainActor.run { [weak self] in
                    self?.fail(error.localizedDescription)
                }
            }
        }
    }

    private func handle(_ event: LLMEvent) {
        armWatchdog()
        switch event {
        case .textDelta(let text):
            answer += text
        case .jsonDelta:
            // The assistant asks for prose, so this should not arrive.
            // Ignored rather than treated as an error: a provider sending a
            // block type PRISM did not ask for is not a reason to throw
            // away an otherwise good answer.
            break
        case .stop:
            finish()
        case .apiError(_, let message):
            fail(message)
        }
    }

    private func finish() {
        guard isStreaming else { return }
        isStreaming = false
        watchdog?.cancel()
        watchdog = nil
        // The answer stays on screen. A panel that clears itself the moment
        // the model stops is a panel you cannot read.
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           lastError == nil {
            lastError = "The provider returned nothing."
        }
        detectedQuestion = nil
    }

    private func fail(_ message: String) {
        isStreaming = false
        watchdog?.cancel()
        watchdog = nil
        lastError = message
    }

    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
        watchdog?.cancel()
        watchdog = nil
        isStreaming = false
    }

    public func clear() {
        cancel()
        answer = ""
        lastAsked = nil
        lastError = nil
    }

    // MARK: - Watchdog

    /// Rearmed on every token; fires only if the provider goes quiet
    /// without finishing. See the file header for why this is not optional.
    private func armWatchdog() {
        watchdog?.cancel()
        let seconds = Self.stallSeconds
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isStreaming else { return }
                self.streamTask?.cancel()
                self.streamTask = nil
                self.fail(LLMError.stalled(seconds: seconds).localizedDescription
                          ?? "The provider stopped responding.")
            }
        }
    }
}
