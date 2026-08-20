// AnthropicProvider.swift
// PRISM
//
// The Anthropic Messages API, over `LLMTransport` (§5.32, §5.33).
//
// Written against the API rather than an SDK, deliberately: PRISM has one
// third-party dependency and it is a speech model. The wire format here is
// three headers and one JSON body, and the streaming half is `SSEParser`,
// which is already tested. An SDK would be the second dependency, in the
// one part of the app where the code is short and the trust requirement is
// highest.
//
// The rules below are not stylistic. Each one is a request shape that
// returns HTTP 400 on current models, and each is written from memory
// wrongly at least as often as it is written correctly:
//
//   No assistant-turn prefill. The old trick of seeding the reply with `{`
//   to force JSON is rejected outright — `output_config.format` replaced it.
//
//   No temperature, top_p or top_k. Removed; steer with the prompt.
//
//   No thinking budget. `budget_tokens` is gone; depth is `effort`.
//
//   `system` is a top-level field, not a message with role "system".
//
//   `max_tokens` is required, and on models where thinking is on by default
//   it caps thinking *and* text together — so a value sized tightly around
//   the expected answer truncates the answer.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

final class AnthropicProvider: LLMProvider {

    let id = "anthropic"
    let displayName = "Claude"

    /// Large enough that a meeting transcript never needs chunking. Stated
    /// conservatively rather than at the documented ceiling: this number
    /// only decides whether to map-reduce, and being wrong downward costs a
    /// little quality, while being wrong upward costs a failed request at
    /// the end of an hour-long meeting.
    let contextBudget = 180_000

    private let model: String
    private let apiKey: String
    private let transport: LLMTransport

    init(model: String, apiKey: String, transport: LLMTransport = LLMTransport()) {
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    func isAvailable() async -> Bool {
        !apiKey.isEmpty && !model.isEmpty
    }

    // MARK: - Streaming

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingKey }
                    let endpoint = try makeEndpoint(request)
                    for try await line in transport.lines(for: endpoint) {
                        if let event = SSEParser.anthropic(line: line) {
                            continuation.yield(event)
                            if case .stop = event { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Request

    func makeEndpoint(_ request: LLMRequest) throws -> LLMTransport.Endpoint {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "stream": true,
            "messages": request.messages.map {
                ["role": $0.role, "content": $0.text]
            },
        ]

        // `system` as an array of blocks rather than a bare string, so the
        // cache breakpoint can sit between the frozen instructions and the
        // transcript. Caching is a prefix match: everything above the
        // breakpoint is re-read at a fraction of the price, everything below
        // is charged in full. Getting the order wrong — a timestamp or a
        // question above the transcript — costs the whole saving silently,
        // with no error and no signal other than the bill.
        var systemBlocks: [[String: Any]] = [
            ["type": "text", "text": request.systemFrozen],
        ]
        if let volatile = request.systemVolatile, !volatile.isEmpty {
            systemBlocks.append([
                "type": "text",
                "text": volatile,
                "cache_control": ["type": "ephemeral"],
            ])
        } else {
            systemBlocks[0]["cache_control"] = ["type": "ephemeral"]
        }
        body["system"] = systemBlocks

        // `output_config` carries both the effort level and the structured
        // format. Note it is `output_config.format`, not a top-level
        // `output_format` — the latter is the deprecated spelling and is the
        // single most common way to write this wrong.
        var outputConfig: [String: Any] = [:]
        if let effort = request.effort { outputConfig["effort"] = effort }
        if let schema = request.jsonSchema {
            outputConfig["format"] = [
                "type": "json_schema",
                "schema": schema.propertyList,
            ]
        }
        if !outputConfig.isEmpty { body["output_config"] = outputConfig }

        guard var components = URLComponents(
            string: "https://\(LLMTransport.anthropicHost)/v1/messages") else {
            throw LLMError.transport("Could not build the request URL.")
        }
        components.path = "/v1/messages"
        guard let url = components.url else {
            throw LLMError.transport("Could not build the request URL.")
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        return LLMTransport.Endpoint(
            url: url,
            headers: [
                "content-type": "application/json",
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ],
            body: data)
    }
}

// MARK: - Model catalogue

/// The models offered, with the numbers that decide between them.
///
/// Stored as editable text in settings rather than an enum, and listed here
/// only as suggestions: providers rename and retire models faster than an
/// application ships, and a hardcoded identifier turns a working install
/// into a 404 that only a release can fix.
public enum LLMModelCatalog {

    public struct Entry: Identifiable, Equatable {
        public var id: String
        public var displayName: String
        public var detail: String
    }

    public static let anthropic: [Entry] = [
        Entry(id: "claude-opus-5",
              displayName: "Claude Opus 5",
              detail: "The default. Best notes and the best answers."),
        Entry(id: "claude-sonnet-5",
              displayName: "Claude Sonnet 5",
              detail: "Faster and cheaper, and very close on a task that is mostly extraction."),
        Entry(id: "claude-haiku-4-5",
              displayName: "Claude Haiku 4.5",
              detail: "Cheapest and quickest. Good enough for a short call."),
    ]

    public static let defaultAnthropicModel = "claude-opus-5"
}
