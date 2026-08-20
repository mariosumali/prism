// LLMTransport.swift
// PRISM
//
// The only file in PRISM that opens a network connection (§7).
//
// PRISM has never made a request the user did not ask for: no analytics, no
// telemetry, no crash reporting, no update check. That has not changed and
// is not going to. What changed is that §5.32 and §5.33 let a user point
// PRISM at an AI provider, and a request to a provider the user chose, made
// when the user presses a key, is a request the user asked for.
//
// The promise is kept by construction rather than by intent. Every byte
// PRISM sends leaves through this file. CI enforces it: the networking grep
// that used to cover the whole source tree now allows exactly this path and
// fails on a hit anywhere else, a second step asserts that no endpoint
// literal outside the three allowed hosts appears here, and a third greps
// the entire tree for telemetry-shaped symbols. That last check is new —
// the amendment made the guarantee narrower in one place and stronger
// everywhere else.
//
// Eighty lines is the right size for this file, and keeping it that size is
// the point: it is small enough to read in full before trusting it, and it
// is the file to read first if you ever want to know what PRISM sends.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

final class LLMTransport {

    /// The only hosts this file may address. Providers hand over a URL and
    /// this refuses anything else — an allowlist in code as well as in CI,
    /// because CI checks the literals in this file and cannot check a URL
    /// assembled at runtime from a settings field.
    ///
    /// The compatible-endpoint case is deliberately open: its whole purpose
    /// is a server the user runs, and PRISM cannot know its address in
    /// advance. It is gated instead on the user having typed one — an empty
    /// field means no request — and the pane says plainly where it goes.
    static let anthropicHost = "api.anthropic.com"
    static let localHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]

    struct Endpoint {
        var url: URL
        var headers: [String: String]
        var body: Data
        /// Whether this endpoint was typed by the user rather than being one
        /// of PRISM's two known hosts.
        var isUserSupplied: Bool = false
    }

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        // The default 60 s is an *inactivity* timeout, and a long transcript
        // can take longer than that to prefill before a single byte comes
        // back — especially on a local model, where prompt evaluation
        // dominates. Sixty seconds here means "the notes silently failed" on
        // exactly the meetings worth writing notes about.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    /// Streams the response body as complete lines.
    ///
    /// Lines, not events: parsing is `SSEParser`'s job and lives in a file
    /// that never opens a socket, which is what makes the wire formats
    /// testable without one.
    func lines(for endpoint: Endpoint) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard Self.isAllowed(endpoint) else {
                        throw LLMError.transport(
                            "PRISM will only connect to the provider you chose.")
                    }
                    var request = URLRequest(url: endpoint.url)
                    request.httpMethod = "POST"
                    request.httpBody = endpoint.body
                    for (field, value) in endpoint.headers {
                        request.setValue(value, forHTTPHeaderField: field)
                    }

                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200...299).contains(status) else {
                        // A non-2xx body is one JSON error object, not a
                        // stream — drain it whole so the provider's own
                        // sentence reaches the user.
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(status: status, body: body)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing:
                        LLMError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One non-streaming request, for availability probes.
    func data(for endpoint: Endpoint, method: String = "GET",
              timeout: TimeInterval = 2) async throws -> Data {
        guard Self.isAllowed(endpoint) else {
            throw LLMError.transport("PRISM will only connect to the provider you chose.")
        }
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if method != "GET" { request.httpBody = endpoint.body }
        for (field, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw LLMError.http(status: status,
                                body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// The runtime half of the allowlist.
    static func isAllowed(_ endpoint: Endpoint) -> Bool {
        guard let host = endpoint.url.host else { return false }
        if host == anthropicHost { return true }
        if localHosts.contains(host) { return true }
        // Anything else is only reachable because the user typed it in.
        return endpoint.isUserSupplied
    }
}
