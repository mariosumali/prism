// TranscriptChunker.swift
// PRISM
//
// Splitting a long transcript into pieces that fit a small model's context
// window, for the map-reduce notes path (§5.32).
//
// Ported from Meetily (`Zackriya-Solutions/meeting-minutes`,
// `summary/processor.rs`, MIT). The crude characters-per-token estimate, the
// fixed prompt reserve, the backwards snap to a sentence end and the
// overlapped seam are all theirs; the routing rule wrapped around them is
// not.
//
// The routing rule, stated plainly because it is the part that gets
// forgotten: a cloud model with a 200k–1M window never chunks. A two-hour
// meeting is well under 60k tokens of transcript and goes to the model
// whole. Chunking is not free. It costs quality at every seam, and a seam is
// exactly the place where a decision gets summarised twice — once from each
// side, in two different registers, and the reduce stage has to notice they
// are the same decision — or falls in the gap between two summaries and is
// not summarised at all. A model that can read the whole meeting reads the
// whole meeting.
//
// So chunking exists for one caller: the local model, where the window is
// 4k–32k and there is no version of "send it whole". The alternative there
// is not a cleverer prompt, it is silent truncation — the model reads the
// first N tokens, the last hour never reaches it, and the notes come back
// confident, well-formed and missing half the meeting, with nothing in them
// to suggest anything was dropped. Summarising overlapping pieces and
// reducing the results is worse than a single pass and enormously better
// than that.
//
// The overlap is the entire defence of the seam, and it is why the naive
// "split every N characters" version was rejected. Each chunk after the
// first restarts a hundred tokens before the previous one ended, so a
// sentence that straddles a boundary is summarised from both sides rather
// than halved. Duplicated content in the map stage is cheap: the reduce
// stage sees one decision stated twice and merges it. A halved sentence is
// not recoverable at any later stage, by any prompt.
//
// Everything here is pure arithmetic over characters, with no notion of what
// a transcript is. That is deliberate — the map-reduce driver decides what
// text to hand over (rendered lines, one channel, a time range), and a
// chunker that also knew about `TranscriptLine` would have to be re-taught
// every time that rendering changed.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public enum TranscriptChunker {

    /// Tokens held back from each chunk's budget for the prompt wrapped
    /// around it: the instruction, the meeting metadata, and the room the
    /// model needs to answer in. Meetily reserves the same flat 300 rather
    /// than measuring the real prompt, and the flat number is the right
    /// trade — measuring couples the chunker to whichever prompt template is
    /// current, and being 80 tokens conservative costs nothing while being
    /// 80 tokens optimistic costs a truncated answer.
    public static let promptReserveTokens = 300

    // MARK: - Estimating

    /// Meetily's deliberately crude estimate: `ceil(characters * 0.35)`.
    ///
    /// It is not accurate for any particular tokenizer and does not need to
    /// be — it is a routing threshold, and it errs high, which is the safe
    /// direction. English averages nearer four characters per token, so this
    /// over-counts by something like 40%, and over-counting means the worst
    /// case is one more chunk than strictly necessary. Under-counting means a
    /// request that overruns the window and comes back cut off.
    ///
    /// Explicitly *not* tiktoken: that is OpenAI's tokenizer, it undercounts
    /// Claude by 15–20%, and vendoring a vocabulary file to be wrong in a
    /// more expensive way is not an improvement. It is also not the API's own
    /// token counter, which is a network round trip, and this file is on the
    /// path that decides whether to make a network call at all.
    public static func roughTokenCount(_ text: String) -> Int {
        // Integer arithmetic, not `ceil(Double(count) * 0.35)`. The two agree
        // over every length a transcript can reach, but only after an
        // argument about how 0.35 rounds at exact multiples of twenty
        // characters. A threshold that needs a floating-point proof is one
        // somebody will re-derive incorrectly later.
        (text.count * 35 + 99) / 100
    }

    /// Whether the whole text can go to a model with `contextBudget` tokens
    /// in a single pass, prompt included.
    ///
    /// Agrees with `chunks(_:tokenBudget:)` by construction: for any
    /// `contextBudget` above `promptReserveTokens`, this returns true for
    /// exactly the texts that come back as one chunk. The one deliberate
    /// disagreement is the degenerate budget — at or below the reserve
    /// nothing fits, so this says false, while `chunks` still hands back the
    /// whole text rather than fail or spin.
    public static func fitsInOnePass(_ text: String, contextBudget: Int) -> Bool {
        roughTokenCount(text) + promptReserveTokens <= contextBudget
    }

    // MARK: - Chunking

    /// Splits `text` so no chunk exceeds `tokenBudget`, with `overlapTokens`
    /// of repeated text at each seam.
    ///
    /// Empty or whitespace-only input produces nothing: a map stage over zero
    /// chunks is the correct description of a meeting nobody spoke in, and an
    /// array holding one blank string would be a prompt sent for no reason.
    /// Text that already fits comes back as a single chunk equal to the
    /// input — byte-for-byte, not trimmed, because the caller may have built
    /// leading structure into it that the model is expected to see.
    public static func chunks(_ text: String,
                              tokenBudget: Int,
                              overlapTokens: Int = 100) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        // A budget at or below the reserve leaves nothing to put text in.
        // Returning the whole text is a lie about the window, but it is a
        // lie the model will report by truncating, whereas returning [] drops
        // the meeting silently and looping on a zero-width chunk hangs the
        // notes run. Loud and wrong beats quiet and wrong here.
        let usableTokens = tokenBudget - promptReserveTokens
        guard usableTokens > 0 else { return [text] }
        let chunkCharacters = characterBudget(forTokens: usableTokens)
        guard chunkCharacters > 0 else { return [text] }

        // Characters, not UTF-8 bytes or scalars: a cut between bytes splits
        // a multi-byte sequence and a cut between scalars splits a combining
        // pair or a flag emoji. Grapheme clusters are the only unit where an
        // arbitrary index is always a legal place to stand.
        let characters = Array(text)
        guard characters.count > chunkCharacters else { return [text] }

        // The overlap can never eat more than half a chunk. Without this
        // clamp an overlap larger than the budget makes every chunk start
        // before the previous one did, and the loop either never terminates
        // or crawls forward one character at a time producing thousands of
        // near-identical prompts. Half is the strongest clamp that still
        // leaves the requested overlap intact at every realistic budget.
        let overlapCharacters = min(characterBudget(forTokens: max(0, overlapTokens)),
                                    chunkCharacters / 2)

        var result: [String] = []
        var start = 0
        while start < characters.count {
            let limit = min(start + chunkCharacters, characters.count)
            let end = limit == characters.count
                ? limit
                : breakPoint(in: characters, start: start, limit: limit)
            result.append(String(characters[start..<end]))
            if end >= characters.count { break }
            // `breakPoint` never returns a position more than half a chunk
            // back from `limit`, and the overlap is clamped to half a chunk,
            // so this advances by at least one character on every iteration.
            // The `max` states that as code rather than as a comment nobody
            // re-checks after editing either constant.
            start = max(end - overlapCharacters, start + 1)
        }
        // The final chunk always carries at least one character the previous
        // chunk did not: it begins `overlapCharacters` before a break point
        // that was itself short of the end. So no chunk is pure repetition,
        // and the reduce stage never sees a piece with nothing new in it.
        return result
    }

    // MARK: - Boundaries

    /// The index to cut at, searching backwards from `limit`.
    ///
    /// Preference order is Meetily's: after a `". "`, else after any space,
    /// else a hard cut at the limit. Breaking inside a word is the worst of
    /// the three because both halves become garbage tokens the model will try
    /// to interpret — a transcript sliced at "the quarterly bud" / "get is
    /// approved" has invented a word in each chunk.
    ///
    /// The search stops half a chunk back rather than running to `start`.
    /// A transcript with one sentence end near the beginning of the window
    /// would otherwise hand back most of the budget on every iteration, which
    /// costs both throughput and, at small budgets, forward progress.
    private static func breakPoint(in characters: [Character],
                                   start: Int, limit: Int) -> Int {
        let earliest = start + max(1, (limit - start) / 2)
        var rightmostSpace = -1
        var index = limit
        while index > earliest {
            // `index > earliest >= start + 1` puts `index - 2` at or after
            // `start`, so both look-backs are in range.
            if characters[index - 1] == " " {
                if characters[index - 2] == "." { return index }
                if rightmostSpace < 0 { rightmostSpace = index }
            }
            index -= 1
        }
        // A sentence end anywhere in the window beats a space nearer the
        // limit: a slightly shorter chunk that ends on a complete thought
        // summarises better than a full one that stops mid-sentence.
        return rightmostSpace >= 0 ? rightmostSpace : limit
    }

    /// The most characters whose `roughTokenCount` is still at or below
    /// `tokens`.
    ///
    /// An exact inverse, not an approximation, and that is load-bearing:
    /// `chunks` decides "this fits" by comparing character counts while
    /// `fitsInOnePass` compares token counts, and any rounding difference
    /// between the two would mean a text the caller was told fits still
    /// arriving in two pieces.
    private static func characterBudget(forTokens tokens: Int) -> Int {
        // ceil(0.35c) <= t  <=>  0.35c <= t  <=>  c <= floor(20t / 7).
        // Clamped because an absurd budget from a misconfigured model entry
        // should produce an absurd chunk size, not an overflow trap.
        let clamped = max(0, min(tokens, Int.max / 20))
        return clamped * 20 / 7
    }
}
