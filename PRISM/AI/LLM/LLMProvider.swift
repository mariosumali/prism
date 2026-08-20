// LLMProvider.swift
// PRISM
//
// The seam between PRISM and whichever model writes the notes and answers
// the questions (§5.32, §5.33). Types and a protocol; no networking.
//
// Three providers sit behind this: Anthropic's API, Ollama on this Mac, and
// any OpenAI-compatible endpoint. They exist as three because the honest
// answer to "where should this run" is different for different people, and
// PRISM should not be the one deciding. Someone on a plane wants Ollama.
// Someone who wants the best notes wants Claude. Someone running their
// company's own endpoint wants to point at it. All three are one protocol
// and about four hundred lines, which is cheaper than picking a side.
//
// The default is none of them. Transcription (§5.32) is entirely on-device
// and needs no provider at all, so a PRISM that never has one configured is
// a PRISM that never opens a socket — which is what the stock build is.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Messages

public struct LLMMessage: Equatable {
    public var role: String        // "user" | "assistant"
    public var text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> LLMMessage { LLMMessage(role: "user", text: text) }
    public static func assistant(_ text: String) -> LLMMessage { LLMMessage(role: "assistant", text: text) }
}

// MARK: - Request

public struct LLMRequest {
    /// Instructions that never change between calls. Kept separate from the
    /// volatile half so a provider that supports prompt caching can put a
    /// breakpoint between them: caching is a prefix match, and a timestamp
    /// or a session id anywhere above the breakpoint silently invalidates
    /// everything after it.
    public var systemFrozen: String

    /// The part of the system prompt that grows — the transcript so far.
    /// Appended after `systemFrozen`, and the cache breakpoint goes at its
    /// end, so each new question re-reads the prior prefix cheaply and only
    /// pays full price for what was added.
    public var systemVolatile: String?

    public var messages: [LLMMessage]

    /// Hard ceiling on the response. On models where thinking is on by
    /// default this caps thinking *and* text together, so a value sized
    /// tightly around the expected answer truncates mid-sentence.
    public var maxTokens: Int

    /// JSON Schema for a structured reply, or nil for prose. Every object in
    /// it must carry `additionalProperties: false` and list every required
    /// field — that is a constraint of the schema support, not a style
    /// preference.
    public var jsonSchema: JSONValue?

    /// How hard to work: "low", "medium", "high", "xhigh", "max". Notes are
    /// extraction rather than reasoning and run at "low"; a live answer runs
    /// higher because it is the thing the user is about to say out loud.
    public var effort: String?

    public init(systemFrozen: String,
                systemVolatile: String? = nil,
                messages: [LLMMessage],
                maxTokens: Int = 8_000,
                jsonSchema: JSONValue? = nil,
                effort: String? = nil) {
        self.systemFrozen = systemFrozen
        self.systemVolatile = systemVolatile
        self.messages = messages
        self.maxTokens = maxTokens
        self.jsonSchema = jsonSchema
        self.effort = effort
    }
}

// MARK: - Events

/// One thing that happened while a response streamed.
///
/// Defined by `SSEParser`, which is where the three wire formats are
/// decoded and where the case list is justified. Aliased here because this
/// is the file a reader lands in first, and a protocol whose event type is
/// named somewhere else reads as an accident rather than a decision.
public typealias LLMEvent = LLMStreamEvent

// MARK: - Errors

public enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case missingKey
    case transport(String)
    case http(status: Int, body: String)
    case stalled(seconds: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No AI provider is set up yet. Choose one in the Assistant pane."
        case .missingKey:
            return "PRISM needs an API key for that provider. Add one in the Assistant pane."
        case .transport(let reason):
            return "PRISM couldn't reach the provider — \(reason)"
        case .http(let status, let body):
            return Self.sentence(status: status, body: body)
        case .stalled(let seconds):
            return "The provider stopped responding after \(seconds) seconds."
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Providers put a usable sentence in the body; a bare status code does
    /// not tell anyone whether to fix their key or wait a minute. Prefer
    /// theirs, fall back to ours.
    private static func sentence(status: Int, body: String) -> String {
        if let extracted = extractMessage(from: body), !extracted.isEmpty {
            return extracted
        }
        switch status {
        case 401, 403: return "That API key was rejected. Check it in the Assistant pane."
        case 404: return "That model doesn't exist for this provider. Check the model name."
        case 429: return "The provider is rate limiting PRISM. Try again in a moment."
        case 500...599: return "The provider is having trouble (\(status)). Try again in a moment."
        default: return "The provider refused the request (\(status))."
        }
    }

    static func extractMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let error = object["error"] as? [String: Any],
           let message = error["message"] as? String { return message }
        if let message = object["error"] as? String { return message }
        if let message = object["message"] as? String { return message }
        return nil
    }
}

// MARK: - Provider

public protocol LLMProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }

    /// Roughly how much text this provider can take in one pass, in tokens.
    /// Drives the map-reduce decision in `TranscriptChunker`: a cloud model
    /// with a very large window never chunks, a small local one always does.
    var contextBudget: Int { get }

    /// Whether the provider is reachable and configured. Cheap; called when
    /// a pane opens, not per request.
    func isAvailable() async -> Bool

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

// MARK: - JSON

/// A minimal JSON tree, so a schema can be built in Swift and handed to
/// `JSONSerialization` without a dictionary of `Any` escaping into the rest
/// of the app.
public enum JSONValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public var propertyList: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .array(let values): return values.map(\.propertyList)
        case .object(let values): return values.mapValues(\.propertyList)
        case .null: return NSNull()
        }
    }

    /// Convenience for building schemas readably.
    public static func schema(type: String, properties: [String: JSONValue] = [:],
                              required: [String] = [],
                              items: JSONValue? = nil,
                              description: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["type": .string(type)]
        if let description { object["description"] = .string(description) }
        if !properties.isEmpty {
            object["properties"] = .object(properties)
            // Required on every object, and every field listed: the schema
            // support rejects a partially-specified object rather than
            // guessing, and a schema that 400s at generation time is a
            // feature that fails only in production.
            object["required"] = .array(required.map(JSONValue.string))
            object["additionalProperties"] = .bool(false)
        }
        if let items { object["items"] = items }
        return .object(object)
    }
}
