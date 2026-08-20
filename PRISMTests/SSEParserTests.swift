// SSEParserTests.swift
// PRISMTests
//
// The provider streaming wire formats (§5.33), pinned to the frame
// sequences the providers publish.
//
// The bug this file exists to catch is the one you cannot reproduce. A
// stream decoder is wrong in production, on a response that already came
// back 200, against a model that shipped a new frame type last Tuesday —
// and its symptom is not an exception but an answer that is quietly missing
// a word, or a spinner that never stops because the stop event was spelled
// differently than expected. None of that survives a reproduction attempt
// after the fact, so the frames are captured here as literal strings and
// asserted against forever.
//
// Every fixture below is a documented frame, copied verbatim rather than
// paraphrased. The point of copying is that a paraphrase is a belief about
// the format, and a belief is exactly what is being tested. Nothing here
// opens a connection, and nothing here can: the parser is a function from a
// String, which is the whole reason it was written that way.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class SSEParserTests: XCTestCase {

    // MARK: - Helpers

    /// Runs a body through the real line splitter and then the parser, which
    /// is the path the app takes. Doing it any other way would test a
    /// splitting rule that ships nowhere.
    private func events(in body: String,
                        _ parser: (String) -> LLMStreamEvent?) -> [LLMStreamEvent] {
        var accumulator = LineAccumulator()
        var lines = accumulator.append(body)
        if let tail = accumulator.flush() { lines.append(tail) }
        return lines.compactMap(parser)
    }

    // MARK: - Anthropic

    /// The full sequence from Anthropic's streaming documentation, including
    /// the `event:` lines and the blank separators a real body carries.
    private let anthropicBody = #"""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1nZdL29xx5MUA1yADyHTEsnR8uuvGzszyY","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5","stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":25,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: ping
        data: {"type": "ping"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"!"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":15}}

        event: message_stop
        data: {"type":"message_stop"}
        """#

    func testDocumentedAnthropicStreamYieldsOnlyItsTextAndThenStops() {
        // message_start, content_block_start, ping and content_block_stop all
        // carry state PRISM does not keep; if any of them ever produced an
        // event, an answer would grow punctuation nobody generated.
        XCTAssertEqual(events(in: anthropicBody, SSEParser.anthropic(line:)),
                       [.textDelta("Hello"),
                        .textDelta("!"),
                        .stop(reason: "end_turn", outputTokens: 15),
                        .stop(reason: nil, outputTokens: nil)])
    }

    func testAnthropicReadsTheJSONTypeAndNotTheEventLine() {
        // The two discriminators are deliberately made to disagree here. The
        // payload wins, because that is the one the documentation defines
        // behaviour against — and an `event:` line on its own is nothing.
        XCTAssertNil(SSEParser.anthropic(line: "event: message_stop"))
        XCTAssertEqual(
            SSEParser.anthropic(line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#),
            .textDelta("Hello"))
    }

    func testAnthropicIgnoresBlanksAndComments() {
        XCTAssertNil(SSEParser.anthropic(line: ""))
        XCTAssertNil(SSEParser.anthropic(line: "   "))
        XCTAssertNil(SSEParser.anthropic(line: ": heartbeat"))
        XCTAssertNil(SSEParser.anthropic(line: "data:"))
    }

    func testAnthropicUnknownEventTypeIsIgnoredRatherThanFatal() {
        // Forward compatibility is a documented requirement: new event types
        // ship to existing API versions. This must be a no-op, and reaching
        // this assertion at all is half the test — a throwing decoder would
        // never get here.
        XCTAssertNil(SSEParser.anthropic(
            line: #"data: {"type":"web_search_tool_result_delta","index":0,"delta":{"type":"citations_delta"}}"#))
    }

    func testAnthropicUnknownDeltaTypeInsideAKnownFrameIsIgnored() {
        XCTAssertNil(SSEParser.anthropic(
            line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"citations_delta","citation":{"type":"char_location"}}}"#))
    }

    func testAnthropicIgnoresThinkingDeltas() {
        // The model's scratchpad is not the answer. Appending it to the
        // visible text is how a summary starts with "Let me think about".
        XCTAssertNil(SSEParser.anthropic(
            line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me count the action items."}}"#))
        XCTAssertNil(SSEParser.anthropic(
            line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIM1gbcDa9GJwZA2b3hHRgCIJwLjurpS9Y"}}"#))
    }

    func testAnthropicInputJSONDeltaIsSurfacedAsChunkedJSON() {
        // A chunk is split at an arbitrary byte offset and is very often not
        // valid JSON by itself; it must arrive intact for concatenation, not
        // be parsed and re-serialised on the way through.
        XCTAssertEqual(
            SSEParser.anthropic(
                line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"location\": \"San Fra"}}"#),
            .jsonDelta(#"{"location": "San Fra"#))
    }

    func testAnthropicMessageDeltaCarriesStopReasonAndCumulativeOutputTokens() {
        // `output_tokens` on this frame is the total for the message, not an
        // increment. A caller that sums these across a stream reports a
        // number that never happened.
        XCTAssertEqual(
            SSEParser.anthropic(
                line: #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens","stop_sequence":null},"usage":{"output_tokens":1024}}"#),
            .stop(reason: "max_tokens", outputTokens: 1024))
    }

    func testAnthropicMessageStopCarriesNothing() {
        XCTAssertEqual(SSEParser.anthropic(line: #"data: {"type":"message_stop"}"#),
                       .stop(reason: nil, outputTokens: nil))
    }

    func testAnthropicSurfacesAnErrorDeliveredInsideASuccessfulResponse() {
        // The status line was sent long before the model fell over, so a
        // status-code-only error path treats this stream as a success that
        // returned half an answer.
        XCTAssertEqual(
            SSEParser.anthropic(
                line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            .apiError(type: "overloaded_error", message: "Overloaded"))
    }

    func testMalformedJSONReturnsNilRatherThanFailing() {
        // A connection dropped mid-write leaves half an object on the wire.
        // Losing that half is correct; taking the process with it is not.
        XCTAssertNil(SSEParser.anthropic(
            line: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_de"#))
        XCTAssertNil(SSEParser.openAICompatible(line: "data: {oops"))
        XCTAssertNil(SSEParser.ollama(line: "not json at all"))
        XCTAssertNil(SSEParser.anthropic(line: #"data: ["not","an","object"]"#))
    }

    // MARK: - Ollama

    func testOllamaChatContentLineYieldsText() {
        XCTAssertEqual(
            SSEParser.ollama(
                line: #"{"model":"llama3.2","created_at":"2023-08-04T08:52:19.385406455-07:00","message":{"role":"assistant","content":"The"},"done":false}"#),
            .textDelta("The"))
    }

    func testOllamaGenerateResponseKeyAlsoYieldsText() {
        // /api/generate has no `message` object. A caller pointed at the
        // completion endpoint by a settings mistake should produce text, not
        // a silent nothing that looks like a hung model.
        XCTAssertEqual(
            SSEParser.ollama(
                line: #"{"model":"llama3.2","created_at":"2023-08-04T08:52:19.385406455-07:00","response":"The","done":false}"#),
            .textDelta("The"))
    }

    func testOllamaDoneLineCarriesTheReasonAndTheEvalCount() {
        // The terminal line's `message.content` is empty, which is what makes
        // "text first, otherwise done" unambiguous in practice.
        XCTAssertEqual(
            SSEParser.ollama(
                line: #"{"model":"llama3.2","created_at":"2023-08-04T19:22:45.499127Z","message":{"role":"assistant","content":""},"done_reason":"stop","done":true,"total_duration":4883583458,"load_duration":1334875,"prompt_eval_count":26,"prompt_eval_duration":342546000,"eval_count":282,"eval_duration":4535599000}"#),
            .stop(reason: "stop", outputTokens: 282))
    }

    func testOllamaErrorIsAPlainStringNotAnObject() {
        XCTAssertEqual(
            SSEParser.ollama(
                line: #"{"error":"model 'llama3.2' not found, try pulling it first"}"#),
            .apiError(type: "ollama_error",
                      message: "model 'llama3.2' not found, try pulling it first"))
    }

    func testOllamaHasNoDoneSentinelToWaitFor() {
        // Waiting for `[DONE]` against Ollama means waiting for the body to
        // close, which is a different thing and fails differently.
        XCTAssertNil(SSEParser.ollama(line: "data: [DONE]"))
        XCTAssertNil(SSEParser.ollama(line: "[DONE]"))
    }

    func testOllamaStreamYieldsTextThenOneStop() {
        let body = #"""
            {"model":"llama3.2","created_at":"2023-08-04T08:52:19.385406455-07:00","message":{"role":"assistant","content":"The"},"done":false}
            {"model":"llama3.2","created_at":"2023-08-04T08:52:19.385406455-07:00","message":{"role":"assistant","content":" sky"},"done":false}
            {"model":"llama3.2","created_at":"2023-08-04T19:22:45.499127Z","message":{"role":"assistant","content":""},"done_reason":"stop","done":true,"eval_count":282}
            """#
        XCTAssertEqual(events(in: body, SSEParser.ollama(line:)),
                       [.textDelta("The"),
                        .textDelta(" sky"),
                        .stop(reason: "stop", outputTokens: 282)])
    }

    // MARK: - OpenAI-compatible

    func testOpenAIDeltaYieldsTextAndDoneTerminates() {
        let body = #"""
            data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4o-mini","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"role":"assistant","content":""},"logprobs":null,"finish_reason":null}]}

            data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4o-mini","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{"content":"Hello"},"logprobs":null,"finish_reason":null}]}

            data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1694268190,"model":"gpt-4o-mini","system_fingerprint":"fp_44709d6fcb","choices":[{"index":0,"delta":{},"logprobs":null,"finish_reason":"stop"}]}

            data: [DONE]
            """#
        // The first chunk exists only to announce the assistant role; its
        // empty content must not become an event.
        XCTAssertEqual(events(in: body, SSEParser.openAICompatible(line:)),
                       [.textDelta("Hello"),
                        .stop(reason: "stop", outputTokens: nil),
                        .stop(reason: nil, outputTokens: nil)])
    }

    func testOpenAIDoneSentinelStopsOnItsOwn() {
        XCTAssertEqual(SSEParser.openAICompatible(line: "data: [DONE]"),
                       .stop(reason: nil, outputTokens: nil))
    }

    func testOpenAIUsageOnlyChunkCarriesTheTokenCount() {
        // stream_options.include_usage closes with a choice-less chunk after
        // the finish_reason chunk. Two stops, and the caller merges them.
        XCTAssertEqual(
            SSEParser.openAICompatible(
                line: #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":17,"total_tokens":26}}"#),
            .stop(reason: nil, outputTokens: 17))
    }

    func testOpenAIToolCallArgumentsAreChunkedJSON() {
        XCTAssertEqual(
            SSEParser.openAICompatible(
                line: #"data: {"id":"chatcmpl-123","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"loc"}}]},"finish_reason":null}]}"#),
            .jsonDelta(#"{"loc"#))
    }

    func testOpenAIErrorObjectIsSurfaced() {
        XCTAssertEqual(
            SSEParser.openAICompatible(
                line: #"data: {"error":{"message":"The model is currently overloaded.","type":"server_error","param":null,"code":null}}"#),
            .apiError(type: "server_error",
                      message: "The model is currently overloaded."))
    }

    // MARK: - LineAccumulator

    func testLineSplitAcrossTwoAppendsIsYieldedOnceAndOnlyOnce() {
        var accumulator = LineAccumulator()
        // A chunked body splits wherever the transport felt like it, which is
        // routinely in the middle of a JSON key.
        XCTAssertEqual(accumulator.append(#"data: {"type":"cont"#), [])
        XCTAssertEqual(accumulator.append("ent_block_stop\",\"index\":0}\n"),
                       [#"data: {"type":"content_block_stop","index":0}"#])
        // The second call must not re-emit what the first completed.
        XCTAssertEqual(accumulator.append(""), [])
        XCTAssertNil(accumulator.flush())
    }

    func testCarriageReturnLineFeedIsHandled() {
        // Swift's Character is a grapheme cluster and CR LF is one of them,
        // so a Character-based split never finds the newline at all and the
        // whole body looks like a single line that never completes.
        var accumulator = LineAccumulator()
        XCTAssertEqual(accumulator.append("event: ping\r\ndata: {}\r\n"),
                       ["event: ping", "data: {}"])
        XCTAssertNil(accumulator.flush())
    }

    func testCRLFFramedAnthropicBodyParsesIdentically() {
        // What the SSE specification actually asks servers to send.
        let crlf = anthropicBody.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(events(in: crlf, SSEParser.anthropic(line:)),
                       [.textDelta("Hello"),
                        .textDelta("!"),
                        .stop(reason: "end_turn", outputTokens: 15),
                        .stop(reason: nil, outputTokens: nil)])
    }

    func testFlushReturnsTheTrailingPartialLine() {
        // Ollama has no sentinel and servers routinely omit the final
        // newline, so the terminal `done: true` object is the single most
        // likely thing to be sitting in the buffer when the body closes.
        var accumulator = LineAccumulator()
        XCTAssertEqual(accumulator.append(#"{"done":false}"# + "\n" + #"{"done":true,"eval_count":7}"#),
                       [#"{"done":false}"#])
        XCTAssertEqual(accumulator.flush(), #"{"done":true,"eval_count":7}"#)
        // Flushing twice must not hand the same line over again.
        XCTAssertNil(accumulator.flush())
    }

    func testFlushIsNilWhenTheBodyEndedOnALineBreak() {
        var accumulator = LineAccumulator()
        XCTAssertEqual(accumulator.append("data: [DONE]\n"), ["data: [DONE]"])
        XCTAssertNil(accumulator.flush())
    }

    func testEmptyLinesSurviveSplittingSoFramesStaySeparated() {
        // The blank line between SSE frames is part of the format, not noise
        // to be swallowed by the splitter; the parsers are what discard it.
        var accumulator = LineAccumulator()
        XCTAssertEqual(accumulator.append("a\n\nb\n"), ["a", "", "b"])
    }
}
