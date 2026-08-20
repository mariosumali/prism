// LocalAgreement.swift
// PRISM
//
// Deciding which words of a live, repeatedly-revised Whisper hypothesis are
// safe to show as settled (§5.32).
//
// A word is trustworthy once two successive decodes of overlapping audio
// agree on it. That is the entire policy: confirm the longest common prefix
// of consecutive hypotheses and leave the divergent tail provisional. It
// costs one decode of latency and nothing else — no lookahead, no second
// model, no heuristics about where sentences end.
//
// This is LocalAgreement-2, ported from ufal/whisper_streaming's
// `HypothesisBuffer` in `whisper_online.py` (MIT licence), the reference
// implementation for "Turning Whisper into Real-Time Transcription System"
// (Macháček, Dabre, Bojar, 2023). WhisperKit's WhisperAX example runs the
// same policy behind its eager mode (argmaxinc/WhisperKit, MIT). PRISM
// reimplements it rather than depending on either: WhisperKit is not a
// dependency of this target, and the algorithm is forty lines.
//
// The alternative is to draw every hypothesis as it arrives, which is what
// a naive streaming transcript does. Whisper re-decodes an overlapping
// window every couple of seconds and revises what it already said, so such
// a transcript rewrites its own last sentence several times a second —
// unreadable while somebody is talking, and impossible to quote from, since
// a line the user just copied may not survive the next decode. The other
// alternative, waiting for Whisper's own segment boundaries, buys stability
// with a full chunk of latency and still revises across chunks. Agreement
// takes its stability from the model's own repetition instead of from
// waiting, which is why it is nearly free.
//
// Two things this deliberately does not do. It never compares times: the
// same word re-decoded moves by tens of milliseconds, so a time-sensitive
// comparison would agree with nothing and settle nothing. And it never
// un-commits — a word already shown as settled stays exactly as it was
// shown, even when a later hypothesis contradicts it, because the reader
// has already read it and rewriting history behind them is worse than being
// occasionally wrong in front of them.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - The policy

public enum LocalAgreement {

    /// How many successive hypotheses must agree before a word is settled.
    /// 2 is LocalAgreement-2, and it is why `HypothesisBuffer` keeps exactly
    /// one hypothesis of history. Higher n is a real knob in the paper and a
    /// bad trade here: each increment costs another decode of latency — the
    /// transcript running two or three more seconds behind the talker — to
    /// buy robustness against two independent decodes agreeing on the same
    /// wrong word, which is not a failure mode anyone has complained about.
    public static let confirmationsNeeded = 2

    /// Stripped from both ends of a word before comparing. Punctuation only
    /// at the edges: interior marks are part of the word, and folding
    /// "don't" into "dont" would make two genuinely different decodes agree.
    private static let edgeNoise = CharacterSet.punctuationCharacters
        .union(.whitespacesAndNewlines)

    /// The form two decodes are compared in: trimmed, lower-cased, and
    /// stripped of leading and trailing punctuation.
    ///
    /// A decode that turns "prism" into "Prism," has not changed its mind
    /// about the word — it has finished the sentence around it, which is
    /// exactly what more audio buys. Treating that as disagreement would
    /// stall the confirmation on the last word of every clause, which is the
    /// word the reader is most impatient to see settle.
    public static func normalized(_ word: TranscriptWord) -> String {
        word.trimmed.lowercased().trimmingCharacters(in: edgeNoise)
    }

    /// Whether two decodes said the same word. Times are ignored on purpose
    /// (see the header).
    ///
    /// A token that normalises to nothing — a bare comma emitted on its own
    /// — agrees with nothing, including another bare comma. There is no word
    /// there to confirm, and letting punctuation settle would settle it in
    /// the wrong place, since the next decode routinely moves it. The cost
    /// is a briefly longer provisional tail rather than a stall: the decode
    /// window slides past the stray token within a chunk or two.
    public static func agree(_ a: TranscriptWord, _ b: TranscriptWord) -> Bool {
        let left = normalized(a)
        guard !left.isEmpty else { return false }
        return left == normalized(b)
    }

    /// How many words the two hypotheses agree on from the start. Exposed
    /// because both callers below want the count and one of them wants it
    /// without allocating an array to count.
    public static func commonPrefixLength(_ a: [TranscriptWord],
                                          _ b: [TranscriptWord]) -> Int {
        var length = 0
        while length < a.count, length < b.count, agree(a[length], b[length]) {
            length += 1
        }
        return length
    }

    /// The longest run of words the two hypotheses agree on, taken from `b`.
    ///
    /// The newer decode wins on text and timing. It heard more audio around
    /// the word than the older one did, so its capitalisation, its
    /// punctuation and its boundaries are the better of the two — and this
    /// is what whisper_streaming commits as well.
    public static func longestCommonPrefix(_ a: [TranscriptWord],
                                           _ b: [TranscriptWord]) -> [TranscriptWord] {
        Array(b.prefix(commonPrefixLength(a, b)))
    }

    /// What is left of `b` after the common prefix — the words the two
    /// decodes have not yet agreed on, which is what gets drawn provisional.
    public static func divergentSuffix(_ a: [TranscriptWord],
                                       _ b: [TranscriptWord]) -> [TranscriptWord] {
        Array(b.dropFirst(commonPrefixLength(a, b)))
    }

    /// The n-gram guard from whisper_streaming. When `words` begins within
    /// `windowMs` of the end of the last committed word, look for one to
    /// `maxNGram` trailing committed words repeated at the head of `words`
    /// and drop the repeat.
    ///
    /// This exists because trimming an incoming hypothesis by time is not
    /// enough. A re-decode moves word boundaries, so a word that has already
    /// been committed can come back timestamped a hair later, survive the
    /// time trim, and be committed a second time. Without the guard the
    /// transcript stutters at every chunk boundary — "and then we and then
    /// we shipped" — which reads as a model defect and is not one.
    ///
    /// The smallest matching n wins, as in the reference: with distinct
    /// words only one n can match, and when speech genuinely repeats itself
    /// the shorter deletion is the more conservative one. The cap of five is
    /// whisper_streaming's, and it is a ceiling rather than an oversight —
    /// matching further back starts catching real repetition, and deleting
    /// words somebody actually said twice is a worse failure than leaving
    /// one stutter in.
    public static func droppingRepeatedPrefix(_ words: [TranscriptWord],
                                              after committed: [TranscriptWord],
                                              windowMs: Int64 = 1_000,
                                              maxNGram: Int = 5) -> [TranscriptWord] {
        guard maxNGram > 0,
              let head = words.first,
              let tail = committed.last else { return words }
        // Far enough past the committed text that an overlap is not what is
        // happening: the model has moved on, and anything matching here is a
        // coincidence of vocabulary rather than a re-emission.
        guard abs(head.startMs - tail.endMs) <= windowMs else { return words }

        let limit = min(min(committed.count, words.count), maxNGram)
        guard limit > 0 else { return words }
        for n in 1...limit where agreeThroughout(committed.suffix(n), words.prefix(n)) {
            return Array(words.dropFirst(n))
        }
        return words
    }

    /// Pairwise agreement across two equal-length runs. Built on `agree`, so
    /// a run of tokens that all normalise to nothing cannot match a run of
    /// other tokens that also normalise to nothing.
    private static func agreeThroughout(_ a: ArraySlice<TranscriptWord>,
                                        _ b: ArraySlice<TranscriptWord>) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { agree($0.0, $0.1) }
    }
}

// MARK: - The buffer

/// Drives LocalAgreement-2 across successive decodes: hand it every new
/// hypothesis, take back the words that hypothesis just made safe.
///
/// A value type on purpose. There is one of these per channel — the
/// microphone and the far end are decoded independently (`ChannelProfile`) —
/// and a struct makes "one per channel" a dictionary rather than a
/// lifecycle. It also keeps the whole policy trivially testable: no actor,
/// no clock, no injected seams, just insert and inspect.
///
/// `committed` is the whole run rather than a window. The transcript store
/// downstream is fed from `insert`'s return value, so a buffer that forgot
/// its own history would leave the n-gram guard with nothing to compare
/// against at exactly the moment it matters.
public struct HypothesisBuffer {

    /// Everything confirmed so far, in transcript order, all `.final`.
    /// Append-only by construction: nothing in this type removes from it.
    public private(set) var committed: [TranscriptWord] = []

    /// The previous hypothesis minus whatever it already got confirmed for —
    /// whisper_streaming's `self.buffer`. Held as `.pending` so `provisional`
    /// is a read rather than a transform, and because `agree` ignores state.
    private var unconfirmed: [TranscriptWord] = []

    /// How far before the last committed word's end an incoming word may
    /// start and still be treated as new. whisper_streaming's 0.1 s: enough
    /// slack that a re-decode nudging a boundary earlier does not silently
    /// drop a real word, tight enough that the re-emitted overlap goes.
    private static let overlapSlackMs: Int64 = 100

    public init() {}

    /// The unconfirmed tail of the newest hypothesis, all `.pending`. Drawn
    /// dimmer; never persisted.
    public var provisional: [TranscriptWord] { unconfirmed }

    /// Feeds a new hypothesis and returns the words it newly confirmed,
    /// already stamped `.final` and already appended to `committed`.
    ///
    /// The first hypothesis confirms nothing, and that is the point rather
    /// than a warm-up cost: there is no second opinion to agree with yet, so
    /// everything it says is provisional until the next decode says it again.
    @discardableResult
    public mutating func insert(_ hypothesis: [TranscriptWord]) -> [TranscriptWord] {
        var incoming = droppingAlreadyCommitted(hypothesis)
        incoming = LocalAgreement.droppingRepeatedPrefix(incoming, after: committed)

        let agreed = LocalAgreement.commonPrefixLength(unconfirmed, incoming)
        var confirmed: [TranscriptWord] = []
        if agreed > 0 {
            confirmed.reserveCapacity(agreed)
            for index in 0..<agreed {
                var word = incoming[index]
                // Text and times from the newer decode, but the id the word
                // was given when it first appeared as provisional. A word
                // therefore keeps one identity from the moment it is first
                // drawn to the moment it settles, so the UI transitions a row
                // in place instead of deleting one and inserting another, and
                // a `replacedIds` correction aimed at the provisional word
                // still names the committed one.
                word.id = unconfirmed[index].id
                word.state = .final
                confirmed.append(word)
            }
            committed.append(contentsOf: confirmed)
        }
        unconfirmed = incoming.dropFirst(agreed).map { word in
            var word = word
            word.state = .pending
            return word
        }
        return confirmed
    }

    public mutating func reset() {
        committed.removeAll()
        unconfirmed.removeAll()
    }

    /// Trims the head of an incoming hypothesis back to what the committed
    /// transcript does not already cover.
    ///
    /// A leading trim, not a filter over the whole list. whisper_streaming
    /// filters, which is equivalent while timestamps rise monotonically and
    /// punches a hole in the middle of a hypothesis when one of them
    /// regresses. A hypothesis is an ordered list whose head is the only part
    /// that can be stale, so trimming the head is the same fix without the
    /// failure mode.
    private func droppingAlreadyCommitted(_ words: [TranscriptWord]) -> [TranscriptWord] {
        guard let last = committed.last else { return words }
        let floor = last.endMs - Self.overlapSlackMs
        return Array(words.drop { $0.startMs <= floor })
    }
}
