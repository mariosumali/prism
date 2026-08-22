// AssistantSessionTests.swift
// PRISMTests
//
// The manual Ask lifecycle: prompt routing, streaming, cancellation,
// supersession and the watchdog. No test opens a socket.

import Combine
import XCTest

private final class FakeAssistantProvider: LLMProvider, @unchecked Sendable {
    enum Ending {
        case finish
        case hold
        case fail(String)
    }

    struct Script {
        var events: [LLMEvent]
        var ending: Ending

        static func events(_ events: [LLMEvent], ending: Ending = .finish) -> Script {
            Script(events: events, ending: ending)
        }

        static var hold: Script { Script(events: [], ending: .hold) }
    }

    let id = "assistant-fake"
    let displayName = "Assistant fake"
    let contextBudget = 100_000

    private let lock = NSLock()
    private var scripts: [Script]
    private var recordedRequests: [LLMRequest] = []
    private var continuations: [AsyncThrowingStream<LLMEvent, Error>.Continuation] = []
    private var terminations = 0

    init(_ scripts: [Script]) { self.scripts = scripts }

    var requests: [LLMRequest] {
        lock.withLock { recordedRequests }
    }

    var terminationCount: Int {
        lock.withLock { terminations }
    }

    func isAvailable() async -> Bool { true }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        let script: Script = lock.withLock {
            recordedRequests.append(request)
            return scripts.isEmpty ? .hold : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            lock.withLock { continuations.append(continuation) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.terminations += 1 }
            }
            for event in script.events { continuation.yield(event) }
            switch script.ending {
            case .finish:
                continuation.finish()
            case .hold:
                break
            case .fail(let reason):
                continuation.finish(throwing: LLMError.transport(reason))
            }
        }
    }

    func emit(_ event: LLMEvent, stream index: Int = 0) {
        let continuation = lock.withLock { continuations[index] }
        continuation.yield(event)
    }
}

@MainActor
final class AssistantSessionTests: XCTestCase {

    private static func activeSettings(highlights: Bool = true) -> AssistantSettings {
        var settings = AssistantSettings()
        settings.isEnabled = true
        settings.provider = .ollama
        settings.ollamaModel = "test"
        settings.highlightsQuestions = highlights
        settings.aboutMe = "I lead the rollout."
        return settings
    }

    private func settle() async {
        await VirtualClock.settle()
    }

    func testTypedAskCarriesContextAndStreamsACompleteAnswer() async {
        let provider = FakeAssistantProvider([.events([
            .textDelta("Use the "), .textDelta("staged rollout."),
            .stop(reason: "end_turn", outputTokens: 5),
        ], ending: .hold)])
        let session = AssistantSession()
        session.apply(Self.activeSettings())

        session.ask("What should I recommend?", provider: provider,
                    transcriptTail: "Them: the migration starts Friday.")
        await settle()

        XCTAssertEqual(session.answer, "Use the staged rollout.")
        XCTAssertEqual(session.lastAsked, "What should I recommend?")
        XCTAssertFalse(session.isStreaming)
        XCTAssertNil(session.lastError)
        let request = try? XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request?.effort, "medium")
        XCTAssertTrue(request?.messages.first?.text.contains("migration starts Friday") == true)
        XCTAssertTrue(request?.messages.first?.text.contains("What should I recommend?") == true)
        XCTAssertEqual(provider.terminationCount, 1,
                       "a stop event must release a provider that leaves its stream open")
    }

    func testTypedFollowUpKeepsShortConversationHistory() async {
        let provider = FakeAssistantProvider([
            .events([.textDelta("Use a staged rollout."),
                     .stop(reason: nil, outputTokens: nil)]),
            .hold,
        ])
        let session = AssistantSession()
        session.apply(Self.activeSettings())

        session.ask("What should I recommend?", provider: provider,
                    transcriptTail: "Them: Migration starts Friday.")
        await settle()
        session.ask("Why?", provider: provider,
                    transcriptTail: "Them: Migration starts Friday.")
        await settle()

        XCTAssertEqual(session.history.map(\.question), ["What should I recommend?"])
        XCTAssertEqual(session.history.first?.answer, "Use a staged rollout.")
        let followUp = provider.requests[1]
        XCTAssertEqual(followUp.messages.map(\.role),
                       ["user", "assistant", "user"])
        XCTAssertEqual(followUp.messages[0].text, "What should I recommend?")
        XCTAssertEqual(followUp.messages[1].text, "Use a staged rollout.")
        XCTAssertTrue(followUp.messages[2].text.contains("Why?"))

        session.clear()
        XCTAssertTrue(session.history.isEmpty)
    }

    func testAFailedPartialAnswerIsNotUsedAsFollowUpHistory() async {
        let provider = FakeAssistantProvider([
            .events([.textDelta("Incomplete"),
                     .apiError(type: "overloaded", message: "Try later")],
                    ending: .hold),
            .hold,
        ])
        let session = AssistantSession()
        session.apply(Self.activeSettings())

        session.ask("First", provider: provider, transcriptTail: "Context")
        await settle()
        session.ask("Retry", provider: provider, transcriptTail: "Context")
        await settle()

        XCTAssertTrue(session.history.isEmpty)
        XCTAssertEqual(provider.requests[1].messages.count, 1)
        XCTAssertFalse(provider.requests[1].messages[0].text.contains("Incomplete"))
    }

    func testDetectedAskSendsOnlyTheQuestionAndDoesNotRelightIt() async {
        let question = "How would you handle the enterprise rollout?"
        let provider = FakeAssistantProvider([.events([
            .textDelta("Start with one design partner."),
            .stop(reason: nil, outputTokens: nil),
        ])])
        let session = AssistantSession()
        session.apply(Self.activeSettings())
        session.observeTranscript(question)
        XCTAssertEqual(session.detectedQuestion, question)

        session.ask(nil, provider: provider,
                    transcriptTail: "SECRET HISTORY THAT MUST NOT BE SENT")
        await settle()

        let prompt = provider.requests.first?.messages.first?.text ?? ""
        XCTAssertTrue(prompt.contains(question))
        XCTAssertFalse(prompt.contains("SECRET HISTORY"))
        XCTAssertNil(session.detectedQuestion)

        session.observeTranscript(question)
        XCTAssertNil(session.detectedQuestion, "the question just answered must stay handled")
        session.observeTranscript("We can move on to the next topic.")
        session.observeTranscript(question)
        XCTAssertEqual(session.detectedQuestion, question,
                       "the same wording can be a new question after it left the live turn")
    }

    func testEmptyAskUsesTheLowEffortRightNowPath() async {
        let provider = FakeAssistantProvider([.events([
            .textDelta("The date changed to Friday."),
            .stop(reason: nil, outputTokens: nil),
        ])])
        let session = AssistantSession()
        session.apply(Self.activeSettings())

        session.ask(nil, provider: provider,
                    transcriptTail: "Them: the date changed to Friday.")
        await settle()

        XCTAssertNil(session.lastAsked)
        XCTAssertEqual(provider.requests.first?.effort, "low")
        XCTAssertTrue(provider.requests.first?.messages.first?.text
            .contains("What should I know right now?") == true)
    }

    func testAPIErrorsKeepPartialTextAndEndTheStream() async {
        let provider = FakeAssistantProvider([.events([
            .textDelta("Partial answer"),
            .apiError(type: "overloaded", message: "Try again shortly."),
        ], ending: .hold)])
        let session = AssistantSession(answerPublishSeconds: 60)
        session.apply(Self.activeSettings())

        session.ask("Help", provider: provider, transcriptTail: "")
        await settle()

        XCTAssertEqual(session.answer, "Partial answer")
        XCTAssertEqual(session.lastError, "Try again shortly.")
        XCTAssertFalse(session.isStreaming)
    }

    func testAnEmptyProviderReplyIsVisibleAsAnError() async {
        let provider = FakeAssistantProvider([.events([
            .stop(reason: "end_turn", outputTokens: 0),
        ])])
        let session = AssistantSession()
        session.apply(Self.activeSettings())

        session.ask("Help", provider: provider, transcriptTail: "")
        await settle()

        XCTAssertEqual(session.lastError, "The provider returned nothing.")
        XCTAssertFalse(session.isStreaming)
    }

    func testExplicitStopKeepsBufferedText() async {
        let provider = FakeAssistantProvider([.hold])
        let session = AssistantSession(answerPublishSeconds: 60)
        session.apply(Self.activeSettings())
        session.ask("Help", provider: provider, transcriptTail: "")
        await settle()

        provider.emit(.textDelta("Keep this much"))
        await settle()
        XCTAssertTrue(session.answer.isEmpty, "the display interval has not elapsed")
        session.cancel()

        XCTAssertEqual(session.answer, "Keep this much")
        XCTAssertFalse(session.isStreaming)
    }

    func testSupersededRequestCannotFinishTheNewAnswer() async {
        let provider = FakeAssistantProvider([.hold, .hold])
        let session = AssistantSession(answerPublishSeconds: 60)
        session.apply(Self.activeSettings())
        session.ask("Old", provider: provider, transcriptTail: "")
        await settle()

        provider.emit(.textDelta("obsolete"), stream: 0)
        await settle()
        session.ask("New", provider: provider, transcriptTail: "")
        await settle()

        XCTAssertTrue(session.isStreaming,
                      "the cancelled request's completion must not finish its replacement")
        provider.emit(.textDelta("current"), stream: 1)
        provider.emit(.stop(reason: nil, outputTokens: nil), stream: 1)
        await settle()
        XCTAssertEqual(session.answer, "current")
        XCTAssertEqual(session.lastAsked, "New")
        XCTAssertFalse(session.isStreaming)
    }

    func testFastTokenStreamPublishesAtMostOncePerDisplayInterval() async {
        let clock = VirtualClock()
        let session = AssistantSession(
            uptime: { clock.now.timeIntervalSince1970 },
            sleep: { await clock.sleep($0) })
        session.apply(Self.activeSettings())
        let provider = FakeAssistantProvider([.hold])
        var publications = 0
        let token = session.$answer.dropFirst().sink { _ in publications += 1 }
        _ = token

        session.ask("Help", provider: provider, transcriptTail: "")
        await settle()
        for _ in 0..<100 { provider.emit(.textDelta("x")) }
        await settle()
        XCTAssertTrue(session.answer.isEmpty)

        await clock.advance(by: 0.033)
        XCTAssertEqual(session.answer.count, 100)
        XCTAssertEqual(publications, 1)
        provider.emit(.stop(reason: nil, outputTokens: nil))
        await settle()
    }

    func testWatchdogTurnsAHungProviderIntoARecoverableError() async {
        let clock = VirtualClock()
        let session = AssistantSession(
            uptime: { clock.now.timeIntervalSince1970 },
            sleep: { await clock.sleep($0) },
            stallSeconds: 1)
        session.apply(Self.activeSettings())
        let provider = FakeAssistantProvider([.hold])

        session.ask("Help", provider: provider, transcriptTail: "")
        await settle()
        XCTAssertTrue(session.isStreaming)
        await clock.advance(by: 1)

        XCTAssertFalse(session.isStreaming)
        XCTAssertEqual(session.lastError,
                       LLMError.stalled(seconds: 1).errorDescription)
    }

    func testSettingsDisarmDetectionAndCancelWork() async {
        let provider = FakeAssistantProvider([.hold])
        let session = AssistantSession()
        session.apply(Self.activeSettings())
        session.observeTranscript("What should we do about the rollout?")
        session.ask("Help", provider: provider, transcriptTail: "")
        await settle()
        XCTAssertTrue(session.isStreaming)
        XCTAssertNotNil(session.detectedQuestion)

        session.apply(Self.activeSettings(highlights: false))
        XCTAssertNil(session.detectedQuestion)
        var inactive = Self.activeSettings(highlights: false)
        inactive.isEnabled = false
        session.apply(inactive)
        XCTAssertFalse(session.isStreaming)

        session.apply(Self.activeSettings())
        session.observeTranscript("What should we do about the rollout?")
        XCTAssertNotNil(session.detectedQuestion)
        inactive = Self.activeSettings()
        inactive.isEnabled = false
        session.apply(inactive)
        XCTAssertNil(session.detectedQuestion,
                     "a panel reopened later must not offer an old question")
    }
}

final class AssistantProviderRequestTests: XCTestCase {

    private var request: LLMRequest {
        LLMRequest(systemFrozen: "frozen", systemVolatile: "volatile",
                   messages: [.user("question")], maxTokens: 700,
                   jsonSchema: .schema(type: "object", properties: [
                    "answer": .schema(type: "string"),
                   ], required: ["answer"]), effort: "low")
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testOllamaCarriesContextAndOutputLimits() throws {
        let endpoint = try OllamaProvider(model: "local-model").makeEndpoint(request)
        let body = try object(endpoint.body)
        let options = try XCTUnwrap(body["options"] as? [String: Any])

        XCTAssertEqual(options["num_ctx"] as? Int, 28_000)
        XCTAssertEqual(options["num_predict"] as? Int, 700)
        XCTAssertEqual(body["keep_alive"] as? String, "30m")
        XCTAssertNotNil(body["format"])
        XCTAssertEqual(endpoint.url.absoluteString,
                       "http://127.0.0.1:11434/api/chat")
    }

    func testAnthropicPreservesCacheBoundaryEffortAndSchema() throws {
        let endpoint = try AnthropicProvider(model: "model", apiKey: "key")
            .makeEndpoint(request)
        let body = try object(endpoint.body)
        let system = try XCTUnwrap(body["system"] as? [[String: Any]])
        let output = try XCTUnwrap(body["output_config"] as? [String: Any])

        XCTAssertEqual(system.count, 2)
        XCTAssertNil(system[0]["cache_control"])
        XCTAssertNotNil(system[1]["cache_control"])
        XCTAssertEqual(output["effort"] as? String, "low")
        XCTAssertNotNil(output["format"])
        XCTAssertEqual(body["max_tokens"] as? Int, 700)
        XCTAssertEqual(endpoint.headers["x-api-key"], "key")
    }

    func testCompatibleEndpointKeepsLimitsSchemaAndUserSuppliedGate() throws {
        let provider = OpenAICompatibleProvider(
            baseURL: "http://meeting-box.local:8080/v1/", model: "model")
        let endpoint = try provider.makeEndpoint(request)
        let body = try object(endpoint.body)

        XCTAssertEqual(endpoint.url.absoluteString,
                       "http://meeting-box.local:8080/v1/chat/completions")
        XCTAssertTrue(endpoint.isUserSupplied)
        XCTAssertEqual(body["max_tokens"] as? Int, 700)
        XCTAssertNotNil(body["response_format"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages.first?["content"]?.contains("volatile") == true)
    }
}
