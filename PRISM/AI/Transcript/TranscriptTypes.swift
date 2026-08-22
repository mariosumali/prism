// TranscriptTypes.swift
// PRISM
//
// The value types a live transcript is made of (§5.32).
//
// Ported from hyprnote/anarlog's `crates/transcript` (MIT), because the
// shape of this data is the whole difficulty of live transcription and it
// is not obvious from first principles. Three ideas are load-bearing:
//
//   A word, not a segment, is the unit. Segments are derived on demand.
//   Storing segments instead means a correction that arrives later — from a
//   second recogniser pass, or from a model cleaning up "PRISM" into
//   "prism" — has nowhere to land without rewriting timings, and speaker
//   attribution can never be applied after the fact. Meetily stores
//   segments and consequently ships no speaker attribution at all.
//
//   Words carry stable ids, so a correction names what it replaces rather
//   than describing where it goes. This is what makes `replacedIds` a
//   four-word contract instead of a diff algorithm.
//
//   A word is `final` or `pending`. `pending` means the recogniser has
//   committed to it but something slower may still revise it. The UI can
//   draw it, the notes prompt can use it, and nothing has to block.
//
// The channel is the other half of the design, and it is why PRISM gets
// "who said what" without a diarization model: the microphone and the far
// end arrive as two physically separate streams, and a stream is a better
// speaker signal than any clustering over a mixed one. Mixing them first,
// as most recorders do, throws that away and then tries to recover it with
// machine learning.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Channel

/// Which stream a word came off. Not "who spoke" — that is a label applied
/// on top (§5.32) — but the physical origin, which is the evidence.
///
/// Deliberately only two cases. hyprnote carries a third, `mixedCapture`,
/// for recorders that only have one stream; PRISM always has two or one,
/// never a mixed one, because the mic tap and the far-end tap are separate
/// rings by construction.
public enum ChannelProfile: Int, Codable, CaseIterable, Equatable, Sendable {
    /// This Mac's microphone: the user.
    case directMic = 0
    /// Everyone else, captured from the meeting app's own output.
    case farEnd = 1

    /// Ties in `startMs` break toward the microphone. The user speaks
    /// before they hear a reply, so mic-first is the physically correct
    /// order, and a stable tie-break keeps a transcript from reshuffling
    /// itself between renders.
    public var sortRank: Int { self == .directMic ? 0 : 1 }
}

// MARK: - Word state

/// Whether anything may still revise this word.
public enum WordState: String, Codable, Equatable, Sendable {
    /// Nothing else is coming. Safe to persist and to quote.
    case final
    /// Confirmed by the recogniser, but a slower correction source is still
    /// working on it. Drawn normally; replaced in place if a correction
    /// lands.
    case pending
}

// MARK: - Word

/// One word, with the time it occupied in the meeting.
///
/// Times are milliseconds from the start of the meeting, not from the start
/// of the audio chunk that produced them — a chunk-relative time is a bug
/// waiting for the first buffer trim, and every consumer would have to know
/// the offset to do anything useful.
public struct TranscriptWord: Codable, Equatable, Identifiable, Sendable {
    /// Stable for the life of the word, across corrections. Not derived
    /// from the text or the index: both change.
    public var id: String
    public var text: String
    public var startMs: Int64
    public var endMs: Int64
    public var channel: ChannelProfile
    public var state: WordState

    public init(id: String = UUID().uuidString,
                text: String,
                startMs: Int64,
                endMs: Int64,
                channel: ChannelProfile,
                state: WordState = .final) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.channel = channel
        self.state = state
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tolerant(.id, UUID().uuidString)
        text = c.tolerant(.text, "")
        startMs = c.tolerant(.startMs, 0)
        endMs = c.tolerant(.endMs, 0)
        channel = c.tolerant(.channel, ChannelProfile.directMic)
        state = c.tolerant(.state, WordState.final)
    }

    /// Whitespace-trimmed text. The recogniser emits words with a leading
    /// space more often than not, and every comparison in the stitcher and
    /// the sanitizer wants the bare token.
    public var trimmed: String {
        text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Delta

/// What changed, and the only thing that crosses from the recognition side
/// to the UI and the store.
///
/// The apply contract is three steps, in this order, quoted from hyprnote's
/// `types/delta.rs` because getting the order wrong is silent:
///
///   1. Remove the words listed in `replacedIds`.
///   2. Persist `newWords`, honouring each word's `state`.
///   3. Store `partials` in ephemeral state for rendering.
///
/// `partials` is a *global snapshot*, not an increment: whatever was
/// previously being previewed is replaced wholesale. A consumer that
/// appends partials instead of replacing them grows a transcript of every
/// intermediate guess the recogniser ever made.
public struct TranscriptDelta: Codable, Equatable {
    public var newWords: [TranscriptWord]
    /// Ids of words superseded by `newWords`. Empty for ordinary
    /// finalization; non-empty only when a correction lands.
    public var replacedIds: [String]
    /// The current in-progress words. A snapshot, replaced each time.
    public var partials: [TranscriptWord]

    public init(newWords: [TranscriptWord] = [],
                replacedIds: [String] = [],
                partials: [TranscriptWord] = []) {
        self.newWords = newWords
        self.replacedIds = replacedIds
        self.partials = partials
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        newWords = c.tolerant(.newWords, [])
        replacedIds = c.tolerant(.replacedIds, [])
        partials = c.tolerant(.partials, [])
    }

    public var isEmpty: Bool {
        newWords.isEmpty && replacedIds.isEmpty && partials.isEmpty
    }
}

// MARK: - Rendered line

/// A run of words from one channel, already labelled — what the UI draws
/// and what the notes prompt is built from.
///
/// Derived, never stored. The words are the record.
public struct TranscriptLine: Identifiable, Equatable {
    public var id: String
    public var label: String
    public var text: String
    public var startMs: Int64
    public var endMs: Int64
    public var channel: ChannelProfile
    /// True when every word in the run is `.final`. A line that is still
    /// settling is drawn dimmer rather than withheld — withholding it is
    /// how a live transcript ends up lagging the conversation by a sentence.
    public var isSettled: Bool

    public init(id: String, label: String, text: String,
                startMs: Int64, endMs: Int64,
                channel: ChannelProfile, isSettled: Bool) {
        self.id = id
        self.label = label
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.channel = channel
        self.isSettled = isSettled
    }

    /// `mm:ss` from the start of the meeting, for the action-item citations
    /// the notes prompt asks the model to quote.
    public var timestamp: String {
        let total = max(0, Int(startMs / 1000))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
