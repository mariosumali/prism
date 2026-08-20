// MeetingNoteWriter.swift
// PRISM
//
// Turning a transcript into notes (§5.32).
//
// One call where the transcript fits, map-reduce where it does not. The
// routing is not a hedge — it is the difference between the two providers
// PRISM offers. A cloud model with a very large window reads an hour of
// conversation in one pass, which is strictly better: every seam in a
// map-reduce is a place where a decision gets summarised twice or missed
// entirely. A local model with a 28k window has to chunk, and chunking
// badly is worse than chunking, so the seams are overlapped and the
// boundaries snapped to sentence ends.
//
// One request produces the title, the notes body and machine-readable
// action items together. Asking separately would cost a second pass over
// the same transcript to produce a title — hyprnote does exactly that, and
// there is no reason to.
//
// A failed chunk is skipped, not fatal. A model that refuses or times out
// on minute forty of a ninety-minute meeting should cost the user minute
// forty, not the notes.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

@MainActor
public final class MeetingNoteWriter {

    public struct Result {
        public var title: String
        public var markdown: String
        public var actionItems: [MeetingActionItem]
    }

    public init() {}

    private var task: Task<Void, Never>?

    /// The schema the model fills in.
    ///
    /// Every object carries `additionalProperties: false` and lists every
    /// required field, because a partially-specified object is rejected
    /// rather than tolerated. No length or range constraints: those are not
    /// supported and including them fails the request rather than being
    /// ignored.
    static var notesSchema: JSONValue {
        .schema(type: "object",
                properties: [
                    "title": .schema(type: "string",
                                     description: "A short, specific title for this meeting."),
                    "markdown": .schema(type: "string",
                                        description: "The notes, as markdown."),
                    "actionItems": .schema(
                        type: "array",
                        items: .schema(type: "object",
                                       properties: [
                                        "task": .schema(type: "string"),
                                        "owner": .schema(type: "string"),
                                        "due": .schema(type: "string"),
                                        "quote": .schema(type: "string",
                                                         description: "The transcript line that assigns this."),
                                        "timeSeconds": .schema(type: "number",
                                                               description: "When that line was said, in seconds from the start."),
                                       ],
                                       required: ["task", "owner", "due", "quote", "timeSeconds"])),
                ],
                required: ["title", "markdown", "actionItems"])
    }

    // MARK: - Writing

    public func write(record: MeetingRecord,
                      transcript: String,
                      template: NoteTemplate,
                      provider: LLMProvider,
                      language: String,
                      onProgress: @escaping (String) -> Void,
                      completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let body: String
                if TranscriptChunker.fitsInOnePass(transcript,
                                                   contextBudget: provider.contextBudget) {
                    body = transcript
                } else {
                    onProgress("Summarising a long meeting in sections…")
                    body = try await self.mapReduce(transcript, provider: provider)
                }
                onProgress("Writing the notes…")
                let result = try await self.singlePass(record: record,
                                                       transcript: body,
                                                       template: template,
                                                       provider: provider,
                                                       language: language)
                await MainActor.run { completion(.success(result)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - One pass

    private func singlePass(record: MeetingRecord,
                            transcript: String,
                            template: NoteTemplate,
                            provider: LLMProvider,
                            language: String) async throws -> Result {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "HH:mm"
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEEE d MMMM yyyy"

        let request = LLMRequest(
            systemFrozen: Prompts.notesSystem(
                date: day.string(from: record.startedAt),
                language: language,
                farEndLabel: record.farEndLabel,
                formatRequirements: Prompts.defaultFormatRequirements,
                sectionInstructions: template.sectionInstructions()),
            systemVolatile: nil,
            messages: [.user(Prompts.notesUser(
                title: record.title,
                start: stamp.string(from: record.startedAt),
                end: stamp.string(from: record.endedAt ?? Date()),
                duration: Self.durationText(record.duration),
                farEndLabel: record.farEndLabel,
                userNotes: record.userNotes,
                transcript: transcript,
                markdownStructure: template.markdownStructure()))],
            maxTokens: 16_000,
            jsonSchema: Self.notesSchema,
            // Notes are extraction, not reasoning. Low effort is both
            // cheaper and, on a task where the answer is already in the
            // input, no worse.
            effort: "low")

        let raw = try await collect(request, provider: provider)
        return try Self.decode(raw)
    }

    // MARK: - Map / reduce

    private func mapReduce(_ transcript: String, provider: LLMProvider) async throws -> String {
        let chunks = TranscriptChunker.chunks(transcript,
                                              tokenBudget: provider.contextBudget)
        guard !chunks.isEmpty else { return transcript }

        var summaries: [String] = []
        for chunk in chunks {
            if Task.isCancelled { throw LLMError.cancelled }
            let request = LLMRequest(
                systemFrozen: Prompts.mapSystem,
                messages: [.user(Prompts.mapUser(chunk: chunk))],
                maxTokens: 4_000,
                effort: "low")
            // A chunk that fails is skipped. See the file header.
            if let summary = try? await collect(request, provider: provider),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                summaries.append(summary)
            }
        }
        guard !summaries.isEmpty else {
            throw LLMError.transport("None of the transcript could be summarised.")
        }

        let joined = summaries.joined(separator: "\n---\n")
        let request = LLMRequest(
            systemFrozen: Prompts.reduceSystem,
            messages: [.user(Prompts.reduceUser(summaries: joined))],
            maxTokens: 8_000,
            effort: "low")
        return try await collect(request, provider: provider)
    }

    // MARK: - Stream collection

    /// Drains a stream into one string. Structured replies arrive as
    /// `jsonDelta` and prose as `textDelta`; both are concatenated, because
    /// which one a given provider uses for a schema-constrained reply is
    /// not consistent between them.
    private func collect(_ request: LLMRequest, provider: LLMProvider) async throws -> String {
        var output = ""
        for try await event in provider.stream(request) {
            if Task.isCancelled { throw LLMError.cancelled }
            switch event {
            case .textDelta(let text): output += text
            case .jsonDelta(let json): output += json
            case .apiError(_, let message): throw LLMError.transport(message)
            case .stop: break
            }
        }
        return output
    }

    // MARK: - Decoding

    /// Parses the model's reply.
    ///
    /// Tolerant of the reply being wrapped in a markdown fence, because
    /// providers differ on whether a schema-constrained response comes back
    /// bare, and a set of meeting notes should not be lost to three
    /// backticks.
    static func decode(_ raw: String) throws -> Result {
        let trimmed = unwrapFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not JSON at all — the model answered in prose. Better to show
            // the prose as the notes than to fail: the user asked for
            // notes, and these are notes.
            guard !trimmed.isEmpty else {
                throw LLMError.transport("The provider returned nothing.")
            }
            return Result(title: "", markdown: trimmed, actionItems: [])
        }

        let items = (object["actionItems"] as? [[String: Any]] ?? []).map { entry in
            MeetingActionItem(
                task: entry["task"] as? String ?? "",
                owner: entry["owner"] as? String ?? "",
                due: entry["due"] as? String ?? "",
                quote: entry["quote"] as? String ?? "",
                timeSeconds: (entry["timeSeconds"] as? NSNumber)?.doubleValue ?? 0)
        }
        return Result(title: object["title"] as? String ?? "",
                      markdown: object["markdown"] as? String ?? "",
                      actionItems: items.filter { !$0.task.isEmpty })
    }

    static func unwrapFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: .newlines)
        lines.removeFirst()
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Pure arithmetic over a number, so it is reachable from the export
    /// path without hopping to the main actor for a division.
    nonisolated static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) s"
    }
}

// MARK: - Export

public enum MeetingExport {

    /// The whole meeting as one markdown document — notes on top, then the
    /// action items, then the transcript. One file that can be mailed,
    /// pasted, or dropped into whatever the user already keeps notes in.
    public static func markdown(record: MeetingRecord, transcript: String) -> String {
        var out = "# \(record.title)\n\n"
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "EEEE d MMMM yyyy 'at' HH:mm"
        out += "\(stamp.string(from: record.startedAt)) · "
        out += MeetingNoteWriter.durationText(record.duration) + "\n\n"

        if let notes = record.notesMarkdown, !notes.isEmpty {
            out += notes + "\n\n"
        }
        if !record.actionItems.isEmpty {
            out += "# Action items\n\n"
            out += "| Owner | Task | Due | Quoted line | Time |\n"
            out += "|---|---|---|---|---|\n"
            for item in record.actionItems {
                out += "| \(cell(item.owner)) | \(cell(item.task)) | \(cell(item.due)) "
                out += "| \(cell(item.quote)) | \(item.timestamp) |\n"
            }
            out += "\n"
        }
        if !record.userNotes.isEmpty {
            out += "# Your notes\n\n\(record.userNotes)\n\n"
        }
        out += "# Transcript\n\n\(transcript)\n"
        return out
    }

    /// A pipe inside a cell would end the column early.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
