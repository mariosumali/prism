// TranscriptChannelState.swift
// PRISM
//
// One channel's stitcher: overlapping recogniser hypotheses in, a monotonic
// transcript out (§5.32).
//
// Ported from hyprnote/anarlog's `crates/transcript/src/channel_state.rs`
// and `crates/transcript/src/words/stitch.rs` (MIT). The rules are theirs.
// What follows is why we did not invent our own.
//
// A streaming recogniser does not hand over a transcript. It hands over the
// same three seconds four times, each time slightly better. Every batch
// overlaps the last, and the overlap is not a defect to be tolerated — it is
// how the model improves on what it already said. Something has to decide
// which half of a batch is news. Err one way and the transcript stutters;
// err the other and words vanish, which is worse, because a sentence with a
// word missing still reads like a sentence and nobody goes looking.
//
// screenpipe decides this by comparing the *text* of the overlap: a longest
// common substring search between the tail of what it has and the head of
// what arrived. That is O(n·m) per batch, and it quietly eats legitimately
// repeated phrases — say "no no no" and one "no" survives, because the
// second one looks exactly like an echo of the first. It exists only because
// screenpipe has no stable word ids and no times it trusts, so text is the
// only handle left. We have both. So the decision is a comparison against a
// watermark: everything that ended at or before the high-water mark is
// already out, everything after it is not. Four lines, exact, and "no no no"
// survives, because three words ending at three different milliseconds are
// three words no matter what they say.
//
// The last word of every final batch is held back rather than emitted,
// because it is the one word the next batch may still be in the middle of.
// Recognisers split mid-token across chunk boundaries far more often than
// the streaming APIs admit — "Hel" then "lo" — and a word emitted the
// instant it appears cannot be joined to its own second half afterwards
// without a correction the UI has to redraw. Holding one word costs one word
// of latency and removes the entire class of split-token artefacts. It is
// released when the next batch arrives, stitched onto or not, and on
// `finish()`; exactly once either way, which is the invariant this file
// exists to hold.
//
// Preview state accumulates rather than replacing itself, because a
// recogniser's preview grows one word at a time and a preview showing only
// the newest word would flicker a single token wide. Accumulation needs a
// bound, so it is capped by word count and by time window and the oldest
// goes first: a four-hour meeting must not carry four hours of guesses
// nobody ever confirmed. Previews are never revised in place — a wrong
// preview is corrected by the final that supersedes it, and diffing two
// guesses about text with a half-life of 200 ms is work spent on nothing.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// The per-channel stitching state. One instance per `ChannelProfile`; the
/// caller routes each recogniser's output to the state for its own stream,
/// which is what keeps mic and far-end from ever stitching to each other.
///
/// Deliberately not `Codable`. This is live recognition state, rebuilt from
/// the first batch of a new session; persisting a watermark would mean
/// persisting a claim about what a consumer already stored, and the two
/// would drift the first time a session ended badly.
public struct TranscriptChannelState {

    // MARK: - Bounds

    /// Most preview words kept before the oldest are dropped. 512 words is
    /// several minutes of speech — far more preview than any UI draws, and
    /// small enough that the per-batch prune stays trivial.
    public static let maxPartialWords = 512

    /// Widest span of preview kept, in milliseconds. A word still unconfirmed
    /// two minutes after it was heard is not going to be confirmed; it is a
    /// recogniser that stopped finalising, and keeping it forever turns a
    /// long meeting into a slow leak.
    public static let maxPartialWindowMs: Int64 = 120_000

    /// Largest silence a stitch will bridge. Past this the two halves are two
    /// words with a pause between them, and joining them invents a compound
    /// nobody said. 300 ms is hyprnote's number and matches the gap a speaker
    /// leaves between words without meaning anything by it.
    public static let maxStitchGapMs: Int64 = 300

    // MARK: - State

    /// Which stream this state governs. Words are not re-stamped with it —
    /// the recogniser already knows, and rewriting caller data to agree with
    /// our bookkeeping hides routing bugs instead of exposing them.
    public let channel: ChannelProfile

    /// Milliseconds. Every final word ending at or before this has already
    /// been accounted for — emitted, or held for stitching. Monotonic.
    public private(set) var watermark: Int64

    /// Milliseconds. Preview words ending at or before this are stale.
    /// Tracked apart from `watermark` because previews run ahead of finals
    /// and a single mark could not say which of the two moved.
    public private(set) var partialWatermark: Int64

    /// The word held back from the most recent final batch. Also the stitch
    /// anchor: the next batch's head is joined onto this or nothing.
    private var anchor: TranscriptWord?

    /// True once `anchor` has left in a delta — which happens on `finish()`,
    /// or when a stitch onto an already-emitted anchor forces the joined word
    /// out in the same delta that replaces it. It decides whether a stitch is
    /// a first emission or a correction, and that is the difference between
    /// `replacedIds` being right and a word appearing twice.
    private var anchorEmitted: Bool

    /// The accumulated preview, oldest first.
    private var partialWords: [TranscriptWord]

    public init(channel: ChannelProfile) {
        self.channel = channel
        watermark = 0
        partialWatermark = 0
        anchor = nil
        anchorEmitted = false
        partialWords = []
    }

    // MARK: - Finals

    /// Words the recogniser has committed to.
    ///
    /// The batch is assumed to be in time order, which is what makes the
    /// dedup a prefix drop rather than a filter: a recogniser that emits its
    /// own output out of order has a worse problem than duplication.
    public mutating func applyFinal(_ words: [TranscriptWord]) -> TranscriptDelta {
        let fresh = Self.dedup(words, mark: watermark)
        // Nothing new — so nothing moves, not even the held word. The next
        // batch may still be the one that continues it, and a batch re-sent
        // verbatim has to be a no-op or every retry doubles the transcript.
        guard !fresh.isEmpty else { return TranscriptDelta() }

        var batch = fresh
        var newWords: [TranscriptWord] = []
        var replacedIds: [String] = []
        var stitched = false
        let anchorWasEmitted = anchorEmitted

        if let anchor = anchor {
            if let merged = Self.stitch(tail: anchor, head: batch[0]) {
                batch[0] = merged
                stitched = true
                // A word the consumer never saw needs no replacement notice.
                // Listing it would ask the store to remove an id it does not
                // have, which is harmless in our store and not in every one.
                if anchorWasEmitted { replacedIds.append(anchor.id) }
            } else if !anchorWasEmitted {
                newWords.append(anchor)
            }
        }

        let tail = batch.removeLast()
        newWords.append(contentsOf: batch)

        // The tail is normally withheld. The exception: when it *is* the
        // joined word and the anchor it superseded was already out, holding
        // it back would delete a word from the consumer's store and put
        // nothing in its place. A replacement travels with its replacement.
        let tailSupersedes = stitched && batch.isEmpty && anchorWasEmitted
        if tailSupersedes { newWords.append(tail) }
        anchor = tail
        anchorEmitted = tailSupersedes

        // Monotonic by construction — dedup only passes words ending past the
        // mark — but clamped rather than assumed, because everything
        // downstream treats the watermark as a promise rather than a summary.
        // Note it covers the held word too: it marks what has been *accepted*,
        // not what has been handed on, or the next copy of this batch would
        // look like news.
        watermark = max(watermark, fresh.map(\.endMs).max() ?? watermark)
        prunePartials()
        return TranscriptDelta(newWords: newWords,
                               replacedIds: replacedIds,
                               partials: partialWords)
    }

    // MARK: - Partials

    /// The in-progress tail. Replaces the previous preview wholesale: the
    /// returned delta carries the entire current snapshot, per the apply
    /// contract in `TranscriptDelta`.
    ///
    /// Superseded preview words are never named in `replacedIds` — they were
    /// only ever ephemeral state, never stored, so there is nothing to
    /// retract.
    public mutating func applyPartial(_ words: [TranscriptWord]) -> TranscriptDelta {
        // Both marks, not just the preview one. A preview batch re-sent after
        // its region was finalised would otherwise land underneath the final
        // that superseded it, and the UI would draw the old guess below the
        // confirmed text as though it were still coming.
        let mark = max(watermark, partialWatermark)
        let fresh = Self.dedup(words, mark: mark)
        if !fresh.isEmpty {
            partialWords.append(contentsOf: fresh)
            partialWatermark = max(partialWatermark,
                                   fresh.map(\.endMs).max() ?? partialWatermark)
        }
        prunePartials()
        return TranscriptDelta(partials: partialWords)
    }

    // MARK: - End of stream

    /// End of stream: emits the held tail word, if any.
    ///
    /// The anchor is kept afterwards, marked as emitted, so a stream that
    /// resumes — a recogniser restarted mid-meeting — can still stitch its
    /// first word onto the last one. A second `finish()` emits nothing.
    public mutating func finish() -> TranscriptDelta {
        // Whatever was still being previewed never became a word.
        partialWords.removeAll()
        guard let anchor = anchor, !anchorEmitted else { return TranscriptDelta() }
        anchorEmitted = true
        return TranscriptDelta(newWords: [anchor])
    }

    public mutating func reset() {
        watermark = 0
        partialWatermark = 0
        anchor = nil
        anchorEmitted = false
        partialWords.removeAll()
    }

    // MARK: - Dedup

    /// hyprnote's dedup, verbatim in spirit: drop the leading run of words
    /// the mark already covers and keep everything after it.
    ///
    /// A prefix drop, not a filter. Once one word ends past the mark, every
    /// word behind it in a time-ordered batch is news by definition, and
    /// filtering instead would discard a legitimately short word that happens
    /// to end early after a long one.
    public static func dedup(_ words: [TranscriptWord], mark: Int64) -> [TranscriptWord] {
        Array(words.drop(while: { $0.endMs <= mark }))
    }

    // MARK: - Stitching

    /// Joins a held tail word and the next batch's head into one word, or
    /// returns nil when they are two words.
    ///
    /// From `words/stitch.rs`. Three conditions, all required. The head must
    /// not begin with whitespace, because the recogniser's own leading space
    /// is its statement that a new token started — the most reliable signal
    /// available and the only one that costs nothing. The gap must be small,
    /// because a pause is a word boundary. And it must not be a sentence
    /// boundary, because "end." followed by "Next" is the one place a
    /// recogniser routinely emits a spaceless head that is nonetheless a new
    /// word.
    ///
    /// The joined word keeps the tail's id and start: it *is* the tail, now
    /// complete, and a consumer that already stored it can replace it in
    /// place rather than reconciling two.
    public static func stitch(tail: TranscriptWord, head: TranscriptWord) -> TranscriptWord? {
        if head.text.first?.isWhitespace == true { return nil }
        guard head.startMs - tail.endMs <= maxStitchGapMs else { return nil }
        guard !isSentenceBoundary(tail: tail, head: head) else { return nil }
        let stillSettling = tail.state == .pending || head.state == .pending
        return TranscriptWord(id: tail.id,
                              text: tail.text + head.text,
                              startMs: tail.startMs,
                              endMs: head.endMs,
                              channel: tail.channel,
                              state: stillSettling ? .pending : .final)
    }

    /// Terminal punctuation followed by a capital. Both halves are required:
    /// the period alone would refuse to join "3." to "5", and abbreviations
    /// and decimals are far more common mid-utterance than sentences that
    /// end without a pause.
    public static func isSentenceBoundary(tail: TranscriptWord,
                                          head: TranscriptWord) -> Bool {
        guard let last = tail.trimmed.last, ".!?".contains(last) else { return false }
        guard let first = head.trimmed.first else { return false }
        return first.isUppercase
    }

    // MARK: - Bounding

    /// Drops preview words a final has overtaken, then anything outside the
    /// window, then the oldest above the count cap — in that order, because
    /// the window is measured against the newest word that survives the
    /// finals, not against one a final already replaced.
    private mutating func prunePartials() {
        guard !partialWords.isEmpty else { return }
        partialWords.removeAll { $0.endMs <= watermark }
        guard let newest = partialWords.map(\.endMs).max() else { return }
        let floor = newest - Self.maxPartialWindowMs
        partialWords.removeAll { $0.endMs <= floor }
        if partialWords.count > Self.maxPartialWords {
            partialWords.removeFirst(partialWords.count - Self.maxPartialWords)
        }
    }
}
