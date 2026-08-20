// SSEParser.swift
// PRISM
//
// The three streaming wire formats PRISM's model providers speak, decoded
// as pure functions over one line of text (§5.33).
//
// A streaming wire format breaks where you cannot reach it: mid-response,
// under load, on someone else's hardware. So the decoding does not live
// next to the transport — it lives here, as `String -> LLMStreamEvent?`,
// with no I/O of any kind. Every frame sequence in the providers' own
// documentation is therefore a test fixture, and the test bundle that
// exercises them never opens a socket. That separation is also what keeps
// the CI check for transport APIs down to a one-file allowlist elsewhere in
// the tree: this file names none of them, and cannot.
//
// The decoding is JSONSerialization and dictionary lookups rather than
// Codable, which looks like a step backwards and is not. All three formats
// are forward-compatible unions: Anthropic's docs state outright that
// clients must handle event types they do not recognise, and OpenAI-shaped
// servers add members to `delta` whenever a new feature ships. A synthesised
// decoder is the opposite of that contract — it throws on the first thing it
// has not been told about, which turns a vendor adding `thinking_delta` into
// a stream that stops producing text in production and produces nothing
// useful in the logs either. Hand-written `Decodable` conformances would fix
// the throwing but cost a family of structs per provider per frame type, to
// model data that is read once and discarded. Unknown members are ignored
// here for the same reason `tolerant` exists on the persisted side: the
// wrong answer to unknown input is to fail.
//
// One parser per provider, not one parser with a provider switch inside it.
// The formats agree on less than they appear to — Ollama has no `data:`
// framing and no terminating sentinel, Anthropic splits the stop reason and
// the token count across two different frames, and "OpenAI-compatible" is
// spoken with a drift by half a dozen local servers. A single function over
// all three would spend its life deciding which dialect it was in.
//
// The frame shapes are taken from the providers' published references: the
// Anthropic Messages API streaming documentation, Ollama's `docs/api.md`
// (MIT), and OpenAI's chat completions streaming reference. Where a rule
// below looks arbitrary it is because one of those documents says so, and
// the comment says which.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Events

/// One thing that happened in a stream.
///
/// Small on purpose. Everything a provider says that PRISM cannot act on —
/// message ids, block indices, model names, timing telemetry — is dropped at
/// this boundary rather than carried through the app in a struct nobody
/// reads.
public enum LLMStreamEvent: Equatable {
    /// Text to append to the answer.
    case textDelta(String)
    /// Chunked partial JSON for a structured-output/tool call; concatenate
    /// then parse.
    case jsonDelta(String)
    /// The model finished. A stream may legally emit more than one of these
    /// and callers must merge them, because Anthropic splits the news in
    /// two: `message_delta` carries the stop reason and the token count,
    /// `message_stop` carries neither and arrives afterwards. Merging
    /// non-nil fields handles that, and handles OpenAI's optional trailing
    /// usage chunk for free.
    case stop(reason: String?, outputTokens: Int?)
    /// An error the provider delivered INSIDE a 200 response. Anthropic
    /// does this: the HTTP status is already sent when the model is
    /// overloaded mid-stream, so a status-code-only error path misses it.
    case apiError(type: String, message: String)
}

// MARK: - Parsers

public enum SSEParser {

    // MARK: Anthropic

    /// Anthropic Messages API SSE.
    ///
    /// The discriminator is the JSON `type` field, and only that field. Each
    /// frame also arrives with an `event:` line naming the same thing, and
    /// this parser ignores it completely — two copies of one discriminator
    /// is two things that can disagree, and the one inside the payload is
    /// the one the documentation defines behaviour against.
    public static func anthropic(line: String) -> LLMStreamEvent? {
        guard let root = root(of: line),
              let type = root["type"] as? String else { return nil }

        switch type {
        case "content_block_delta":
            guard let delta = root["delta"] as? [String: Any] else { return nil }
            switch delta["type"] as? String {
            case "text_delta":
                return textEvent(delta["text"] as? String)
            case "input_json_delta":
                // Tool input and structured output arrive as JSON split at
                // arbitrary byte offsets — a chunk is very often not valid
                // JSON on its own. Concatenation is the caller's job.
                guard let partial = delta["partial_json"] as? String,
                      !partial.isEmpty else { return nil }
                return .jsonDelta(partial)
            default:
                // thinking_delta and signature_delta belong to extended
                // thinking: the first is the model's scratchpad, which is
                // not the answer, and the second is a cryptographic
                // signature over it. Neither is text to show anyone.
                return nil
            }

        case "message_delta":
            let delta = root["delta"] as? [String: Any]
            let usage = root["usage"] as? [String: Any]
            // `usage.output_tokens` here is CUMULATIVE for the whole
            // message, not an increment for this frame. Adding these up
            // across a stream — which is what a name like "delta" invites —
            // produces a number that grows quadratically with the response
            // length and bills nothing that ever happened.
            return .stop(reason: delta?["stop_reason"] as? String,
                         outputTokens: int(usage?["output_tokens"]))

        case "message_stop":
            return .stop(reason: nil, outputTokens: nil)

        case "error":
            return errorEvent(root["error"], fallbackType: "api_error")

        case "message_start", "content_block_start", "content_block_stop", "ping":
            // Known and carrying nothing PRISM acts on. `ping` in particular
            // exists to keep intermediaries from timing the connection out,
            // which is a transport concern and not one of ours.
            return nil

        default:
            // Forward compatibility is a documented requirement, not a
            // kindness: Anthropic ships new event types to existing API
            // versions. An unknown type is a no-op, never a thrown error.
            return nil
        }
    }

    // MARK: Ollama

    /// Ollama's native NDJSON: bare JSON objects, one per line, no "data:"
    /// prefix and no [DONE] sentinel; the terminal line carries done: true.
    ///
    /// Looking for a sentinel here is the mistake this comment exists to
    /// prevent. A caller that waits for `[DONE]` against Ollama waits until
    /// the body closes, which works right up until it does not.
    public static func ollama(line: String) -> LLMStreamEvent? {
        guard let root = root(of: line) else { return nil }

        // Ollama reports a bad model or a failed load as a plain string under
        // `error`, not as the object the other two send. It is also the only
        // member of the line when it appears, so it is checked first.
        if let event = errorEvent(root["error"], fallbackType: "ollama_error") {
            return event
        }

        // /api/chat nests the text under `message`; /api/generate puts it at
        // the top level under `response`. Accepting both means a caller
        // pointed at a completion endpoint by a settings mistake produces
        // text rather than a silent nothing.
        let content = ((root["message"] as? [String: Any])?["content"] as? String)
            ?? (root["response"] as? String)
        if let content, !content.isEmpty {
            return .textDelta(content)
        }

        guard flag(root["done"]) else { return nil }
        return .stop(reason: root["done_reason"] as? String,
                     outputTokens: int(root["eval_count"]))
    }

    // MARK: OpenAI-compatible

    /// OpenAI-compatible SSE, terminated by "data: [DONE]".
    public static func openAICompatible(line: String) -> LLMStreamEvent? {
        guard let payload = payload(of: line) else { return nil }
        // Checked before any JSON parse, because it is not JSON.
        if payload == "[DONE]" { return .stop(reason: nil, outputTokens: nil) }
        guard let root = object(payload) else { return nil }

        if let event = errorEvent(root["error"], fallbackType: "api_error") {
            return event
        }

        let usage = root["usage"] as? [String: Any]
        guard let choice = (root["choices"] as? [[String: Any]])?.first else {
            // With `stream_options.include_usage` the stream closes with a
            // chunk that has an empty `choices` array and nothing but the
            // token counts. It arrives after the finish_reason chunk, which
            // is why a caller merging repeated stops gets the tokens.
            if let tokens = int(usage?["completion_tokens"]) {
                return .stop(reason: nil, outputTokens: tokens)
            }
            return nil
        }

        let delta = choice["delta"] as? [String: Any]
        if let event = textEvent(delta?["content"] as? String) {
            return event
        }
        if let call = (delta?["tool_calls"] as? [[String: Any]])?.first,
           let function = call["function"] as? [String: Any],
           let arguments = function["arguments"] as? String,
           !arguments.isEmpty {
            return .jsonDelta(arguments)
        }
        // Non-null only on the final chunk of a choice. Reading it with
        // `as? String` is what makes the JSON null on every other chunk a
        // nil rather than a stop.
        if let reason = choice["finish_reason"] as? String {
            return .stop(reason: reason,
                         outputTokens: int(usage?["completion_tokens"]))
        }
        return nil
    }

    // MARK: - Line shapes

    /// The JSON text carried by one line, with an SSE `data:` prefix removed
    /// if there is one.
    ///
    /// One helper for all three formats rather than a strict one per
    /// provider. The strict version's failure mode is a support thread that
    /// says "PRISM received nothing" with no way to tell whether a proxy
    /// added framing Ollama does not use or a local OpenAI-shaped server
    /// forgot the framing it should have. Being relaxed about the envelope
    /// costs nothing: the payload still has to parse as JSON, and the `type`
    /// still has to be one this provider's parser knows.
    private static func payload(of line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank lines separate SSE frames and a line starting with a colon is
        // a comment — some gateways send one periodically as a heartbeat.
        guard !text.isEmpty, !text.hasPrefix(":") else { return nil }

        if text.hasPrefix("data:") {
            var body = text.dropFirst("data:".count)
            // SSE strips exactly one space after the colon, not all of them.
            if body.hasPrefix(" ") { body = body.dropFirst() }
            return body.isEmpty ? nil : String(body)
        }

        // A bare line is a payload only if it looks like one. This is what
        // makes `event: content_block_delta`, `id:`, and `retry:` return nil
        // without enumerating the SSE field names.
        guard text.hasPrefix("{") || text.hasPrefix("[") else { return nil }
        return text
    }

    private static func root(of line: String) -> [String: Any]? {
        guard let payload = payload(of: line) else { return nil }
        return object(payload)
    }

    /// Malformed JSON is a nil, never a throw and never a crash. Truncated
    /// frames are normal: a connection dropped mid-write leaves half an
    /// object on the wire, and losing that half is the correct outcome.
    private static func object(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return nil }
        return root
    }

    // MARK: - Member readings

    /// An empty delta is a no-op that only exists to open a content block or
    /// prime the assistant role. Forwarding it would make every consumer in
    /// the app write the same `if !text.isEmpty`.
    private static func textEvent(_ any: String?) -> LLMStreamEvent? {
        guard let any, !any.isEmpty else { return nil }
        return .textDelta(any)
    }

    /// Two shapes in the wild: Anthropic's and OpenAI's `{type, message}`
    /// object, and Ollama's bare string. Returns nil when the member is
    /// absent or JSON null, which is the ordinary case on every frame.
    private static func errorEvent(_ any: Any?,
                                   fallbackType: String) -> LLMStreamEvent? {
        if let message = any as? String {
            return .apiError(type: fallbackType, message: message)
        }
        if let object = any as? [String: Any] {
            return .apiError(
                type: object["type"] as? String ?? fallbackType,
                message: object["message"] as? String
                    ?? "The provider reported an error without describing it.")
        }
        return nil
    }

    /// JSONSerialization hands back NSNumber; some OpenAI-shaped servers
    /// stringify counts. JSON null bridges to NSNull and reads as nil here,
    /// which is what makes an absent token count absent rather than zero —
    /// a zero would be a claim, and the wrong one.
    private static func int(_ any: Any?) -> Int? {
        if let number = any as? NSNumber { return number.intValue }
        if let string = any as? String { return Int(string) }
        return nil
    }

    private static func flag(_ any: Any?) -> Bool {
        (any as? Bool) ?? false
    }
}

// MARK: - LineAccumulator

/// Accumulates bytes and yields complete lines. Handles \n and \r\n.
///
/// This lives beside the parsers, not beside whatever is reading the body,
/// because it has the same shape as they do — text in, text out, nothing
/// else — and putting it next to the reader would make it impossible to test
/// without one. A chunked response does not arrive on line boundaries, and
/// the failure it produces when nobody buffers is not a crash: it is a
/// `{"type":"content_bl` that parses as nothing and is silently dropped, one
/// word missing from an answer that otherwise looks fine.
public struct LineAccumulator {

    /// Everything since the last newline. Never contains one.
    private var pending = ""

    public init() {}

    /// Appends `text` and returns whatever lines are now complete, with the
    /// terminators removed.
    public mutating func append(_ text: String) -> [String] {
        pending += text
        // Scanned as unicode scalars rather than characters, and this is not
        // stylistic. Swift's Character is a grapheme cluster, and CR LF is a
        // single grapheme: `"a\r\nb".contains("\n")` is false, and every
        // Character-based split silently treats a CRLF-framed body — which
        // is what the SSE specification asks servers to send — as one
        // enormous line that never completes.
        guard pending.unicodeScalars.contains("\n") else { return [] }

        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in pending.unicodeScalars {
            if scalar == "\n" {
                lines.append(Self.line(from: current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        pending = String(current)
        return lines
    }

    /// Any trailing partial line, at end of stream.
    ///
    /// Not an edge case worth skipping: Ollama's NDJSON has no sentinel and
    /// servers routinely omit the final newline, so the terminal `done: true`
    /// object is exactly the thing most likely to be sitting here when the
    /// body closes.
    public mutating func flush() -> String? {
        guard !pending.isEmpty else { return nil }
        let line = Self.line(from: pending.unicodeScalars)
        pending = ""
        return line.isEmpty ? nil : line
    }

    private static func line(from scalars: String.UnicodeScalarView) -> String {
        var scalars = scalars
        if scalars.last == "\r" { scalars.removeLast() }
        return String(scalars)
    }
}
