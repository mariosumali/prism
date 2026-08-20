// TranscriptSanitizer.swift
// PRISM
//
// Drops what the speech model made up, before it reaches a transcript
// anybody will read (§5.32).
//
// Whisper-family models are trained on subtitle corpora, and handed silence
// or a fan or a keyboard they emit what subtitle files are full of: "Thank
// you for watching!", "Subtitles by the Amara.org community", "Please
// subscribe", and one phrase repeated until the chunk is used up. None of
// it was said. A transcript that contains it is worse than one with a gap
// in it, because the gap is honest — a reader can see that nothing was
// captured, and cannot see that a line sitting under a colleague's name was
// invented by a decoder walking in circles.
//
// Ordering matters, and most of the defence is not in this file. The RMS
// gate in the session runs BEFORE the recogniser is called and is the
// cheapest thing here by a wide margin: a chunk that never reaches the
// model costs nothing to skip and cannot make the model invent anything.
// What follows runs after, on what came back anyway, because that gate is
// deliberately set low enough to pass a whispered "no" — and anything loose
// enough to pass a whispered "no" is loose enough to pass a laptop fan.
//
// The obvious alternative was a confidence threshold, and it does not work.
// Hallucinated subtitle boilerplate scores *high*: it is exactly the text
// the model was trained to be fluent in, so the score agrees with it. A
// confident lie is the failure mode, which is precisely why the score
// cannot be the detector. Token suppression at decode time —
// openai/whisper's `whisper/tokenizer.py`, `non_speech_tokens` (MIT) — is
// real, is worth having, and catches "♪" and bracketed stage directions;
// it cannot suppress an ordinary English sentence made of ordinary English
// tokens, which is what all of these are.
//
// The repetition rule is a cheaper cousin of openai/whisper's
// `whisper/transcribe.py` compression-ratio check (MIT), which gzips the
// decoded text and rejects a segment whose ratio crosses a threshold. Good
// signal, wrong tool here: it wants the finished segment, its threshold is
// a number tuned on a corpus that is not this one, and it can only say that
// the whole thing is bad. It cannot say which run of words to drop, which
// is the entire job of the word-level pass below.
//
// And the tempting alternative — drop anything shorter than N characters,
// which kills most of this in one line — is refused outright. It also kills
// "yes", "no", "okay" and "right", and losing the answer to a question is a
// worse transcript than keeping a stray "Please subscribe": a wrong line is
// visible, a missing one is not. Length is used here only as a ceiling,
// never as a floor.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public enum TranscriptSanitizer {

    // MARK: - Policy

    /// Substrings that mark a chunk as subtitle furniture rather than
    /// speech. Matched case-insensitively, anywhere in the text, and only
    /// under `attributionCeiling` characters.
    ///
    /// Every entry is a *phrase*, not a word, and that is the whole
    /// discipline of this list. "subscribe" is a word people say about
    /// newsletters and calendars; "please subscribe" is a thing nobody has
    /// ever said in a meeting. The moment a bare word gets added here, the
    /// filter starts eating sentences it was never meant to see.
    ///
    /// Deliberately NOT here, and it must stay that way: "yes", "no", "ok",
    /// "okay", "right", "sure", "mm-hm", "thanks", "thank you". Those are
    /// real one-word answers. A short-greeting filter that eats "yes"
    /// removes the answer to a question and leaves a transcript that still
    /// reads as a transcript, so nobody ever reports it. "Thank you." on
    /// its own stays; only the "…for watching" form is subtitle residue.
    public static let attributionTriggers: [String] = [
        "thanks for watching",
        "thank you for watching",
        "subtitles by",
        "subtitles are provided",
        "amara.org",
        "transcribed by",
        "subscribe to",
        "please subscribe",
        "like and subscribe",
        "www.",
        "translated by",
        "closed captions",
        "captioning by",
    ]

    /// A trigger only condemns a *short* chunk. Subtitle credits are short
    /// by nature; a three-hundred-character utterance that happens to
    /// mention subscribing to a mailing list is somebody talking, and
    /// dropping it would lose a real paragraph to a substring match. The
    /// ceiling is the single line that keeps this filter honest.
    public static let attributionCeiling = 120

    /// Longest phrase the collapse detector will look for. Past seven
    /// tokens a "repeat" is more likely to be a speaker restating a clause
    /// than a decoder stuck in a loop.
    public static let longestRepeatedPhrase = 7

    /// Four consecutive repeats is a loop regardless of how long the chunk
    /// is. Someone hammering "no no no no" loses that line; that is the
    /// accepted cost, and it is a far smaller one than shipping forty
    /// copies of a phrase the model never heard.
    public static let alwaysCollapseRepeats = 4

    /// Three repeats only condemn the chunk when they are most of it.
    public static let coveredCollapseRepeats = 3
    public static let collapseCoverage = 0.6

    // MARK: - Whole-chunk judgements

    /// True when the chunk should be thrown away entirely.
    public static func isLikelyHallucination(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        // "♪♪♪", "...", "- -": the recogniser's way of writing down a noise
        // it could not turn into words. There is no reading of this that is
        // speech, and no length at which it becomes speech.
        if trimmed.rangeOfCharacter(from: .alphanumerics) == nil { return true }
        guard trimmed.count <= attributionCeiling else { return false }
        let folded = trimmed.lowercased()
        return attributionTriggers.contains { folded.contains($0) }
    }

    /// True when the chunk is one phrase repeated until it filled up.
    ///
    /// Tokens are compared with case and edge punctuation removed, because
    /// the loop the decoder falls into emits "Okay. Okay. Okay. Okay." at
    /// least as often as it emits "okay okay okay okay", and a comparison
    /// that cannot see through a full stop misses half of them.
    public static func isRepetitionCollapse(_ text: String) -> Bool {
        let tokens = comparableTokens(text)
        guard tokens.count >= coveredCollapseRepeats else { return false }
        for length in 1...longestRepeatedPhrase {
            // Below three repeats nothing can be condemned, so a phrase
            // length that cannot fit three of them cannot fit any longer
            // one either.
            guard tokens.count >= length * coveredCollapseRepeats else { break }
            var start = 0
            // Linear scan per phrase length. Chunks are seconds of speech —
            // tens of tokens — so the quadratic worst case is smaller than
            // the cost of being clever about it.
            while start + length * coveredCollapseRepeats <= tokens.count {
                let phrase = tokens[start..<(start + length)]
                var repeats = 1
                var next = start + length
                while next + length <= tokens.count,
                      tokens[next..<(next + length)].elementsEqual(phrase) {
                    repeats += 1
                    next += length
                }
                if repeats >= alwaysCollapseRepeats { return true }
                if repeats >= coveredCollapseRepeats,
                   Double(repeats * length) >= collapseCoverage * Double(tokens.count) {
                    return true
                }
                start += 1
            }
        }
        return false
    }

    /// Removes a trailing attribution, cutting back to the sentence
    /// boundary before it.
    ///
    /// Back to the boundary, not back to the trigger word: the residue is a
    /// whole phrase — "Thanks for watching, and don't forget to like the
    /// video" — and truncating at the trigger leaves the rest of it sitting
    /// in the transcript looking like something a person said. If no
    /// boundary precedes the trigger there is no sentence to keep and the
    /// whole string goes. A chunk with no trigger in it comes back exactly
    /// as it arrived.
    public static func strippingAttributionTail(_ text: String) -> String {
        guard let trigger = lastTriggerStart(in: text) else { return text }
        guard let boundary = text[..<trigger].lastIndex(where: isSentenceBoundary) else {
            return ""
        }
        // The slice ends on the boundary character itself, so there is no
        // trailing whitespace left over to trim.
        return String(text[...boundary])
    }

    /// The three judgements above in order, cheapest and most decisive
    /// first. Returns nil when nothing worth keeping is left.
    ///
    /// The tail strip runs last and its result is re-judged, because a
    /// chunk that was only over the length ceiling on the strength of its
    /// own attribution is under it once the attribution is gone.
    ///
    /// That re-judgement condemns the whole chunk rather than stripping
    /// again, and that is the deliberate half. Credits stack — "Thanks for
    /// watching. Please subscribe." — and the strip cuts back from the last
    /// one, which leaves the earlier one exposed. Looping until the text
    /// stops shrinking would rescue whatever real sentence sat in front of
    /// the pile, but two credits in one chunk means the decoder was talking
    /// to itself for the length of it, and the sentence in front is far
    /// more likely to be a third invention than a rescue. The chunk goes.
    ///
    /// Surviving text comes back trimmed: the recogniser pads chunks with
    /// leading spaces and no consumer wants them.
    public static func clean(_ text: String) -> String? {
        if isLikelyHallucination(text) { return nil }
        if isRepetitionCollapse(text) { return nil }
        let kept = strippingAttributionTail(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kept.isEmpty, !isLikelyHallucination(kept) else { return nil }
        return kept
    }

    // MARK: - Word level

    /// Filters words without rewriting them.
    ///
    /// Judgement happens per run of contiguous channel, never per word: a
    /// single word carries nothing to judge, and the whole point of the
    /// channel split is that the microphone and the far end hallucinate
    /// independently. A credit invented during the far end's silence must
    /// not take the user's answer down with it, and the runs are already
    /// the boundary that separates them.
    ///
    /// This is a filter and only a filter. It never reorders, never merges,
    /// never retimes, and never touches an id — corrections arrive later
    /// naming words by id (`TranscriptDelta.replacedIds`), and a sanitizer
    /// that reissued ids would break them silently.
    public static func clean(_ words: [TranscriptWord]) -> [TranscriptWord] {
        guard !words.isEmpty else { return [] }
        var kept: [TranscriptWord] = []
        kept.reserveCapacity(words.count)
        var index = words.startIndex
        while index < words.endIndex {
            let channel = words[index].channel
            var end = index + 1
            while end < words.endIndex, words[end].channel == channel {
                end += 1
            }
            let run = words[index..<end]
            if clean(renderedText(of: run)) != nil {
                kept.append(contentsOf: run)
            }
            index = end
        }
        return kept
    }

    // MARK: - Internals

    /// Joins a run into the sentence the filters judge. Trimmed tokens
    /// joined by single spaces rather than raw concatenation: the
    /// recogniser usually emits words with a leading space, but "usually"
    /// is not a contract, and a producer that omits them would otherwise
    /// hand the filters "Thanksforwatching" — one token, no triggers, no
    /// repeats, invisible to everything here.
    private static func renderedText(of run: ArraySlice<TranscriptWord>) -> String {
        run.map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Start of the last trigger occurrence anywhere in the text, or nil.
    private static func lastTriggerStart(in text: String) -> String.Index? {
        var latest: String.Index?
        for trigger in attributionTriggers {
            guard let found = text.range(of: trigger,
                                         options: [.caseInsensitive, .backwards])
            else { continue }
            if let current = latest, found.lowerBound <= current { continue }
            latest = found.lowerBound
        }
        return latest
    }

    private static func isSentenceBoundary(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    /// Whitespace-separated tokens, lowercased, with punctuation stripped
    /// from both ends. Interior punctuation survives, so "that's" stays one
    /// word and does not collide with "thats" from somewhere else.
    private static func comparableTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        for raw in text.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            let token = String(raw)
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if !token.isEmpty { tokens.append(token) }
        }
        return tokens
    }
}
