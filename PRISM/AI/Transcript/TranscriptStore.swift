// TranscriptStore.swift
// PRISM
//
// Where a meeting's words are kept (§5.32).
//
// One folder per meeting under Application Support, holding a transcript
// and — once written — the notes. Never the audio. That is not an omission
// to be filled in later: PRISM reads the microphone into a ten-second ring
// and lets it go, and there is no code path from that ring to a file. A
// recording of a conversation is a different object with a different
// consent story, and this feature does not need one to work.
//
// Words in one JSON array in one document, rather than a row per word.
// hyprnote's shape, and the arithmetic is the argument: an hour of speech
// is on the order of ten thousand words, which is a trivial JSON document
// and a miserable ten-thousand-row table to open, migrate or hand to
// someone.
//
// Decoding is tolerant field by field, like every other persisted type
// here: a transcript written by a later build that added a field must not
// become unreadable by an earlier one, and a single unrecognised key must
// not cost a user the record of their meeting.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Record

public struct MeetingRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// The label the far end was given while this meeting ran. Stored with
    /// the meeting rather than read from settings at render time, so
    /// renaming "Them" to a client's name next week does not silently
    /// relabel last week's transcript.
    public var farEndLabel: String
    public var words: [TranscriptWord]
    /// What the user typed while the meeting ran. Fed to the notes prompt,
    /// where it is worth more than anything else in it.
    public var userNotes: String
    /// Rendered notes, once written. Nil until the user asks.
    public var notesMarkdown: String?
    public var actionItems: [MeetingActionItem]

    public init(id: String = UUID().uuidString,
                title: String,
                startedAt: Date,
                endedAt: Date? = nil,
                farEndLabel: String = "Them",
                words: [TranscriptWord] = [],
                userNotes: String = "",
                notesMarkdown: String? = nil,
                actionItems: [MeetingActionItem] = []) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.farEndLabel = farEndLabel
        self.words = words
        self.userNotes = userNotes
        self.notesMarkdown = notesMarkdown
        self.actionItems = actionItems
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tolerant(.id, UUID().uuidString)
        title = c.tolerant(.title, "Meeting")
        startedAt = c.tolerant(.startedAt, Date())
        endedAt = c.tolerant(.endedAt, nil)
        farEndLabel = c.tolerant(.farEndLabel, "Them")
        words = c.tolerant(.words, [])
        userNotes = c.tolerant(.userNotes, "")
        notesMarkdown = c.tolerant(.notesMarkdown, nil)
        actionItems = c.tolerant(.actionItems, [])
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// A title PRISM can produce without knowing anything about the call.
    /// Deliberately a date and time rather than a guess at the subject: the
    /// model can retitle it when notes are written, and until then an
    /// invented subject line is a claim about a conversation nobody has
    /// read yet.
    public static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        return "Meeting \(formatter.string(from: date))"
    }
}

// MARK: - Action items

public struct MeetingActionItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var task: String
    public var owner: String
    public var due: String
    /// The transcript line this was drawn from, and when it was said.
    ///
    /// Meetily's trick, and the cheapest grounding measure found anywhere
    /// in the research: a model that has to cite the line cannot invent the
    /// owner, because the quote would have to be invented too. It is also
    /// the thing that makes an action item checkable by the person it was
    /// assigned to.
    public var quote: String
    public var timeSeconds: Double

    public init(id: String = UUID().uuidString, task: String, owner: String,
                due: String, quote: String, timeSeconds: Double) {
        self.id = id
        self.task = task
        self.owner = owner
        self.due = due
        self.quote = quote
        self.timeSeconds = timeSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tolerant(.id, UUID().uuidString)
        task = c.tolerant(.task, "")
        owner = c.tolerant(.owner, "")
        due = c.tolerant(.due, "")
        quote = c.tolerant(.quote, "")
        timeSeconds = c.tolerant(.timeSeconds, 0)
    }

    public var timestamp: String {
        let total = max(0, Int(timeSeconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Store

@MainActor
public final class TranscriptStore {

    /// Every transcript operation is ordered through one queue. Live
    /// checkpoints use it asynchronously so JSON encoding and disk I/O never
    /// interrupt the transcript UI; the final save uses the same queue
    /// synchronously, which guarantees an older checkpoint can never land
    /// after the finished record and overwrite it.
    private static let ioQueue = DispatchQueue(
        label: "horse.prism.transcripts", qos: .utility)

    /// Injectable so the suite never writes into a developer's real
    /// Application Support folder. Same idiom as LUTStore's directory
    /// override.
    public static var directoryOverride: URL?

    public static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PRISM", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    public init() {}

    public func folder(for id: String) -> URL {
        Self.directory.appendingPathComponent(id, isDirectory: true)
    }

    public func transcriptURL(for id: String) -> URL {
        folder(for: id).appendingPathComponent("transcript.json")
    }

    public func notesURL(for id: String) -> URL {
        folder(for: id).appendingPathComponent("notes.md")
    }

    // MARK: Writing

    @discardableResult
    public func save(_ record: MeetingRecord) throws -> URL {
        let folder = folder(for: record.id)
        let url = transcriptURL(for: record.id)
        return try Self.ioQueue.sync {
            try Self.write(record, folder: folder, url: url)
        }
    }

    /// Coalesced live checkpoints take this path. The completion always
    /// returns on the main actor, where MeetingSession owns its status.
    public func saveInBackground(
        _ record: MeetingRecord,
        additionalWords: [TranscriptWord] = [],
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let folder = folder(for: record.id)
        let url = transcriptURL(for: record.id)
        Self.ioQueue.async {
            var snapshot = record
            if !additionalWords.isEmpty {
                snapshot.words = TranscriptRenderer.mergingChronological(
                    snapshot.words, with: additionalWords)
            }
            let result = Result { try Self.write(snapshot, folder: folder, url: url) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Writes the notes as markdown beside the transcript, so the useful
    /// half of a meeting is a file somebody can open, mail, or drop into
    /// whatever they already keep notes in — rather than something only
    /// PRISM can read.
    @discardableResult
    public func saveNotes(_ markdown: String, for record: MeetingRecord) throws -> URL {
        let folder = folder(for: record.id)
        let url = notesURL(for: record.id)
        return try Self.ioQueue.sync {
            try FileManager.default.createDirectory(at: folder,
                                                    withIntermediateDirectories: true)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    // MARK: Reading

    public func load(id: String) -> MeetingRecord? {
        let url = transcriptURL(for: id)
        return Self.ioQueue.sync { Self.decode(url) }
    }

    /// Every meeting on disk, newest first.
    public func all() -> [MeetingRecord] {
        let directory = Self.directory
        return Self.ioQueue.sync { Self.scan(directory) }
    }

    /// Loads the library without parsing every meeting on the main thread.
    /// Old installs do not have a separate metadata index, so discovery still
    /// has to decode each record once; doing it here keeps opening the Meeting
    /// pane responsive even after years of saved calls.
    public func allInBackground(completion: @escaping ([MeetingRecord]) -> Void) {
        let directory = Self.directory
        Self.ioQueue.async {
            let records = Self.scan(directory)
            DispatchQueue.main.async { completion(records) }
        }
    }

    public func delete(id: String) throws {
        let folder = folder(for: id)
        try Self.ioQueue.sync {
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Everything, when the user asks for everything gone. A transcript is
    /// the most sensitive thing this application will ever hold, so getting
    /// rid of all of it has to be one obvious action rather than a folder
    /// the user is told to go and find.
    public func deleteAll() throws {
        let root = Self.directory
        try Self.ioQueue.sync {
            guard FileManager.default.fileExists(atPath: root.path) else { return }
            try FileManager.default.removeItem(at: root)
        }
    }

    public func bytesOnDisk() -> Int64 {
        let directory = Self.directory
        return Self.ioQueue.sync {
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]) else { return 0 }
            var total: Int64 = 0
            for case let url as URL in enumerator {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return total
        }
    }

    // MARK: Queue-only helpers

    private nonisolated static func write(_ record: MeetingRecord,
                                           folder: URL, url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Compact JSON is materially faster to encode and write for a long
        // meeting. The user-facing copy/export paths render readable text;
        // this file is the durable source of truth.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
    }

    private nonisolated static func decode(_ url: URL) -> MeetingRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingRecord.self, from: data)
    }

    private nonisolated static func scan(_ directory: URL) -> [MeetingRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        return entries
            .compactMap { decode($0.appendingPathComponent("transcript.json")) }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
