// OpenAICompatibleProvider.swift
// PRISM
//
// Any endpoint that speaks the OpenAI chat-completions shape (§5.32,
// §5.33): llama.cpp's server, LM Studio, vLLM, a company's own gateway.
//
// One struct with a configurable base URL, and the reason it is worth the
// hundred lines is that it is the case PRISM cannot enumerate. Somebody is
// running a model on a machine down the hall under a policy that says the
// transcript may not leave the building, and neither of the other two
// providers helps them. Every comparable open-source project ships this
// field for the same reason.
//
// It is also the one provider that can address a host PRISM does not know
// in advance, which is why `LLMTransport` requires `isUserSupplied` to be
// set for it and why the pane shows the URL back to the user. An endpoint
// PRISM will talk to is an endpoint the user typed.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

final class OpenAICompatibleProvider: LLMProvider {

    let id = "openai-compatible"
    var displayName: String { "Endpoint at \(host)" }

    /// Unknowable in advance — it depends entirely on what the user is
    /// running — so this is the conservative floor that keeps a long
    /// transcript from being silently truncated. Chunking a transcript that
    /// would have fitted costs a little quality; not chunking one that does
    /// not fit costs half the meeting.
    let contextBudget = 28_000

    private let baseURL: String
    private let model: String
    private let apiKey: String
    private let transport: LLMTransport

    init(baseURL: String, model: String, apiKey: String = "",
         transport: LLMTransport = LLMTransport()) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    private var host: String {
        URL(string: baseURL)?.host ?? baseURL
    }

    func isAvailable() async -> Bool {
        !baseURL.isEmpty && !model.isEmpty && resolvedURL() != nil
    }

    // MARK: - Streaming

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = try makeEndpoint(request)
                    for try await line in transport.lines(for: endpoint) {
                        if let event = SSEParser.openAICompatible(line: line) {
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

    /// Accepts a base URL with or without the `/v1` and with or without the
    /// endpoint path, because every one of those is what somebody will paste
    /// out of their server's README.
    func resolvedURL() -> URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/chat/completions") { return URL(string: text) }
        if text.hasSuffix("/v1") { return URL(string: text + "/chat/completions") }
        return URL(string: text + "/v1/chat/completions")
    }

    func makeEndpoint(_ request: LLMRequest) throws -> LLMTransport.Endpoint {
        guard let url = resolvedURL() else {
            throw LLMError.transport("That endpoint address isn't a URL PRISM can use.")
        }

        var system = request.systemFrozen
        if let volatile = request.systemVolatile, !volatile.isEmpty {
            system += "\n\n" + volatile
        }
        var messages: [[String: String]] = [["role": "system", "content": system]]
        messages += request.messages.map { ["role": $0.role, "content": $0.text] }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "max_tokens": request.maxTokens,
        ]

        if let schema = request.jsonSchema {
            // llama.cpp compiles this into a GBNF grammar. Do not also send
            // a `grammar` field — servers that accept both apply one and
            // ignore the other, and which one is not consistent.
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "prism_response",
                    "schema": schema.propertyList,
                ],
            ]
        }

        var headers = ["content-type": "application/json"]
        if !apiKey.isEmpty { headers["authorization"] = "Bearer \(apiKey)" }

        let data = try JSONSerialization.data(withJSONObject: body)
        return LLMTransport.Endpoint(
            url: url,
            headers: headers,
            body: data,
            // The whole point of this provider. See LLMTransport's allowlist.
            isUserSupplied: true)
    }
}
