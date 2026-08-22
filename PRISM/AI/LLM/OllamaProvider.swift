// OllamaProvider.swift
// PRISM
//
// Ollama, running on this Mac (§5.32, §5.33).
//
// The reason this exists alongside the cloud provider is one sentence in
// the privacy pane: with Ollama selected, the transcript does not leave the
// machine, and PRISM can say so without qualification. For a lot of
// conversations that is the difference between using the feature and not.
//
// Two details are load-bearing and both were learned the expensive way.
//
// `num_ctx` must be sent explicitly. Ollama's default context is 4096
// tokens, and it does not error when a prompt exceeds it — it silently
// truncates from the front. The symptom is meeting notes that describe the
// last five minutes of an hour-long call, with no error anywhere. That is a
// far worse failure than a refused request.
//
// And the native `/api/chat` endpoint rather than the OpenAI-compatible
// shim, because the shim drops exactly the options that matter here:
// `num_ctx`, `format`, and `keep_alive`.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

final class OllamaProvider: LLMProvider {

    let id = "ollama"
    let displayName = "Ollama"

    /// What a local model can realistically hold. Conservative on purpose:
    /// this decides when `TranscriptChunker` starts map-reducing, and the
    /// cost of chunking a meeting that would have fitted is some quality,
    /// while the cost of not chunking one that does not fit is a silently
    /// truncated transcript.
    let contextBudget = 28_000

    /// 127.0.0.1 rather than "localhost": the name costs a DNS resolution
    /// on every call, and on a machine with an unusual resolver that is a
    /// startup delay for a service that is definitionally on this host.
    static let host = "127.0.0.1"
    static let port = 11_434

    private let model: String
    private let transport: LLMTransport

    init(model: String, transport: LLMTransport = LLMTransport()) {
        self.model = model
        self.transport = transport
    }

    // MARK: - Availability

    func isAvailable() async -> Bool {
        guard !model.isEmpty else { return false }
        let installed = try? await Self.installedModels(transport: transport)
        return installed != nil
    }

    /// The models Ollama has pulled, for the pane's picker. A short timeout:
    /// this runs when a settings pane opens, and a Mac without Ollama should
    /// not make the pane hang while it finds that out.
    static func installedModels(transport: LLMTransport = LLMTransport()) async throws -> [String] {
        guard let url = URL(string: "http://\(host):\(port)/api/tags") else { return [] }
        let endpoint = LLMTransport.Endpoint(url: url, headers: [:], body: Data())
        let data = try await transport.data(for: endpoint, method: "GET", timeout: 0.3)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    // MARK: - Streaming

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = try makeEndpoint(request)
                    for try await line in transport.lines(for: endpoint) {
                        if let event = SSEParser.ollama(line: line) {
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

    func makeEndpoint(_ request: LLMRequest) throws -> LLMTransport.Endpoint {
        guard let url = URL(string: "http://\(Self.host):\(Self.port)/api/chat") else {
            throw LLMError.transport("Could not build the request URL.")
        }

        // Ollama has no separate system field, so the two halves of the
        // system prompt are one message. There is no prompt caching to
        // preserve a breakpoint for — which is the honest argument for the
        // cloud provider being the better default for the assistant
        // specifically, where the same transcript is re-sent per question.
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
            "options": [
                // See the header. Without this the model truncates silently.
                "num_ctx": contextBudget,
                // LLMRequest's ceiling applies locally too. Ollama's
                // default is unlimited generation, which can turn a brief
                // insight request into minutes of unnecessary inference if
                // a model fails to emit its own stop sequence.
                "num_predict": request.maxTokens,
            ],
            // Keep the weights resident between the notes call and the
            // questions that follow it. Reloading several gigabytes per
            // request is most of the latency otherwise.
            "keep_alive": "30m",
        ]

        if let schema = request.jsonSchema {
            body["format"] = schema.propertyList
        }

        let data = try JSONSerialization.data(withJSONObject: body)
        return LLMTransport.Endpoint(
            url: url,
            headers: ["content-type": "application/json"],
            body: data)
    }
}
