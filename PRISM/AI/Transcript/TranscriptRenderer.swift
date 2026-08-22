// TranscriptRenderer.swift
// PRISM
//
// Merging the microphone and the far end into one time-ordered, labelled
// transcript (§5.32) — the whole of "who said what" in PRISM.
//
// The argument for getting attribution this way rather than from a model is
// in TranscriptTypes.swift: two physically separate streams are better
// speaker evidence than any clustering over a mixed one. What is left here
// is bookkeeping, and the bookkeeping is where it quietly goes wrong. Every
// rule below exists because a slightly-off version of it hides somebody's
// words inside somebody else's paragraph — the one failure a transcript
// cannot survive, because the result still reads as a plausible paragraph
// and the reader has no way to notice.
//
// The label is therefore unconditional. A renderer that prints a speaker
// prefix only when it has a non-empty name to print will, the first time a
// far-end name is missing, glue the remote speech onto the end of the local
// speaker's line and attribute it to them. humla shipped exactly that, and
// nothing in its UI showed it happening. So an empty `farEndLabel` falls
// back to the literal "Them", never to nothing, and the fallback is tested
// by name.
//
// The two repairs — bridging a short interjection, rejoining a run-on
// sentence — run as post-passes over the grouped runs rather than as extra
// conditions inside the grouping loop. Grouping is a decision made per word
// with only that word in hand; both repairs need to see a run's neighbours
// on *both* sides. Folding them inline would mean a lookahead buffer inside
// the loop that is already the most delicate part of the file. The order is
// fixed and matters: bridging rewrites labels, and rejoining only ever
// merges across matching labels, so bridging has to go first or the repair
// it makes possible never happens.
//
// Nothing here is stored. Words are the record and lines are recomputed on
// every render, which is why the sort has to be stable rather than merely
// correct: an arbitrary tie-break makes a line reshuffle itself between two
// renders of the same data, and a transcript that twitches is one the user
// stops reading.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public enum TranscriptRenderer {

    // MARK: - Tuning

    /// Used when the caller has no name for the local speaker. "You" and not
    /// the account's real name: the local speaker is reading their own
    /// transcript, and second person is what every meeting tool prints.
    public static let defaultYouLabel = "You"

    /// Used when the caller has no name for the far end — which is the
    /// common case, since the meeting app does not tell PRISM who is on the
    /// call. Anonymous is fine; unlabelled is not.
    public static let defaultFarEndLabel = "Them"

    /// Silence long enough to be a new turn rather than a breath. Two
    /// seconds is where a pause stops reading as hesitation; shorter and a
    /// speaker who thinks mid-sentence gets chopped into three lines.
    public static let defaultMaxGapMs: Int64 = 2_000

    /// A run this short, between two runs of the other speaker, is treated
    /// as bleed rather than as a turn. Both bounds have to hold: six words
    /// of genuine interruption inside three and a half seconds is still an
    /// interruption if it is slow, and a fast nine-word sentence is still a
    /// sentence.
    public static let bridgeMaxWords = 6
    public static let bridgeMaxSpanMs: Int64 = 3_500

    /// What counts as a finished sentence for the run-on repair. The colon
    /// and semicolon are in here because a speaker who has just said "so
    /// here's the thing:" has closed a clause, and gluing the next run onto
    /// it produces a line no punctuation can rescue.
    static let sentenceTerminators: Set<Character> = [".", "!", "?", ":", ";"]

    // MARK: - Public rendering

    /// Grouped runs, for the UI.
    ///
    /// A new line starts where the channel changes or where the silence
    /// since the run's furthest point exceeds `maxGapMs`; the two repairs
    /// then run over the result.
    public static func lines(_ words: [TranscriptWord],
                             youLabel: String,
                             farEndLabel: String,
                             maxGapMs: Int64 = TranscriptRenderer.defaultMaxGapMs) -> [TranscriptLine] {
        // Words that are nothing but whitespace are dropped before anything
        // else looks at them. A recogniser emits them at chunk boundaries,
        // and keeping one would either open a run that renders as a bare
        // label or stretch a gap that should not exist.
        // Recognisers almost never emit a whitespace-only word. Preserve the
        // original array storage on that common path; `filter` otherwise
        // allocated a second full transcript before the sort even began.
        let visible = words.contains { !hasVisibleContent($0.text) }
            ? words.filter { hasVisibleContent($0.text) }
            : words
        let ordered = chronological(visible)
        guard !ordered.isEmpty else { return [] }

        var rendered: [TranscriptLine] = []
        rendered.reserveCapacity(min(ordered.count, 32))
        var runStart = ordered.startIndex
        /// The furthest point in time the current run has reached. The gap
        /// is measured against this rather than literally against the last
        /// word's end, so one word that overlaps its predecessor — which
        /// happens whenever a correction lands with wider bounds — cannot
        /// manufacture a gap and split a sentence in half.
        var reach: Int64 = 0

        var index = ordered.startIndex
        while index < ordered.endIndex {
            let word = ordered[index]
            if index > runStart {
                let last = ordered[index - 1]
                if word.channel != last.channel || word.startMs - reach > maxGapMs {
                    rendered.append(line(from: ordered[runStart..<index],
                                         youLabel: youLabel,
                                         farEndLabel: farEndLabel))
                    runStart = index
                    reach = word.endMs
                    index += 1
                    continue
                }
            }
            reach = index == runStart ? word.endMs : max(reach, word.endMs)
            index += 1
        }
        rendered.append(line(from: ordered[runStart..<ordered.endIndex],
                             youLabel: youLabel,
                             farEndLabel: farEndLabel))

        return mergeRunOnSentences(bridgeShortInterjections(rendered))
    }

    private static func line<Run: Collection>(from run: Run,
                                               youLabel: String,
                                               farEndLabel: String) -> TranscriptLine
        where Run.Element == TranscriptWord {
        // The id is the first word's, not a fresh UUID: SwiftUI diffs this
        // list on every delta. Ranges let the renderer avoid allocating one
        // temporary word array per spoken turn.
        let first = run.first!
        return TranscriptLine(id: first.id,
                              label: label(for: first.channel,
                                           youLabel: youLabel,
                                           farEndLabel: farEndLabel),
                              text: joinedText(run),
                              startMs: first.startMs,
                              endMs: run.reduce(first.endMs) { max($0, $1.endMs) },
                              channel: first.channel,
                              isSettled: run.allSatisfy { $0.state == .final })
    }

    /// One labelled string, for a prompt or the clipboard. Each line is
    /// "Label: text", optionally prefixed with `[mm:ss] ` so the model can
    /// cite a moment rather than paraphrase one.
    public static func labelled(_ words: [TranscriptWord],
                                youLabel: String,
                                farEndLabel: String,
                                includeTimestamps: Bool = false) -> String {
        render(lines(words, youLabel: youLabel, farEndLabel: farEndLabel),
               includeTimestamps: includeTimestamps)
    }

    /// The last `turns` lines, for the assistant's rolling context.
    ///
    /// Chronological, not reversed: a model handed a conversation backwards
    /// answers the oldest question in it. Timestamps are left off because
    /// this is context rather than a citation source, and every `[mm:ss]`
    /// is tokens spent on something the model is not being asked about.
    public static func tail(_ words: [TranscriptWord], turns: Int,
                            youLabel: String, farEndLabel: String) -> String {
        guard turns > 0 else { return "" }
        let all = lines(words, youLabel: youLabel, farEndLabel: farEndLabel)
        return render(all.suffix(turns), includeTimestamps: false)
    }

    // MARK: - Ordering

    /// Sorted by `(startMs, channel.sortRank)`, stably.
    ///
    /// `Array.sorted` is not documented as stable, and the input arrives
    /// pre-ordered per channel from two recognisers, so equal keys have a
    /// meaning worth keeping: the arrival order within one channel is the
    /// order the words were spoken in. Decorating with the original index
    /// costs one allocation per render and buys an output that does not
    /// move when nothing changed.
    static func chronological(_ words: [TranscriptWord]) -> [TranscriptWord] {
        // MeetingSession maintains this order as words arrive. Most renders
        // can therefore return the same CoW storage after a linear check,
        // instead of decorating, sorting, mapping and allocating the entire
        // meeting again on every transcript update.
        if words.count < 2 { return words }
        var alreadyOrdered = true
        for index in 1..<words.count {
            let previous = words[index - 1]
            let current = words[index]
            if current.startMs < previous.startMs
                || (current.startMs == previous.startMs
                    && current.channel.sortRank < previous.channel.sortRank) {
                alreadyOrdered = false
                break
            }
        }
        if alreadyOrdered { return words }

        return words.enumerated()
            .sorted { left, right in
                if left.element.startMs != right.element.startMs {
                    return left.element.startMs < right.element.startMs
                }
                let leftRank = left.element.channel.sortRank
                let rightRank = right.element.channel.sortRank
                if leftRank != rightRank { return leftRank < rightRank }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// Stable linear merge for the live session. Existing words win an exact
    /// timestamp/channel tie because they arrived first; new words are first
    /// stably ordered among themselves by `chronological`.
    static func mergingChronological(_ existing: [TranscriptWord],
                                     with newWords: [TranscriptWord]) -> [TranscriptWord] {
        guard !newWords.isEmpty else { return existing }
        guard !existing.isEmpty else { return chronological(newWords) }
        let incoming = chronological(newWords)
        var merged: [TranscriptWord] = []
        merged.reserveCapacity(existing.count + incoming.count)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < existing.count && newIndex < incoming.count {
            let old = existing[oldIndex]
            let new = incoming[newIndex]
            let newComesFirst = new.startMs < old.startMs
                || (new.startMs == old.startMs
                    && new.channel.sortRank < old.channel.sortRank)
            if newComesFirst {
                merged.append(new)
                newIndex += 1
            } else {
                merged.append(old)
                oldIndex += 1
            }
        }
        if oldIndex < existing.count {
            merged.append(contentsOf: existing[oldIndex...])
        }
        if newIndex < incoming.count {
            merged.append(contentsOf: incoming[newIndex...])
        }
        return merged
    }

    // MARK: - Labels

    /// The name a channel is printed under. Both sides fall back rather
    /// than render empty, because the caller's labels come from settings
    /// the user can clear and a cleared field must not be able to change
    /// who a sentence is attributed to.
    static func label(for channel: ChannelProfile,
                      youLabel: String, farEndLabel: String) -> String {
        switch channel {
        case .directMic:
            let trimmed = youLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? defaultYouLabel : trimmed
        case .farEnd:
            let trimmed = farEndLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? defaultFarEndLabel : trimmed
        }
    }

    // MARK: - Text

    /// Words joined into the text of one line.
    ///
    /// Recognisers are inconsistent about where the space belongs — some
    /// emit " word", some emit "word", and punctuation arrives as its own
    /// token often enough that a naive space-join produces "Hello , world".
    /// So the tokens are stripped of their own whitespace on the way in and
    /// the join owns every space in the result.
    static func joinedText<Run: Collection>(_ run: Run) -> String
        where Run.Element == TranscriptWord {
        var text = ""
        var previousBindsRight = false
        for word in run {
            let token = collapsed(word.text)
            guard !token.isEmpty else { continue }
            let binding = binding(of: token)
            if text.isEmpty {
                text = token
            } else if previousBindsRight || binding == .left {
                text.append(contentsOf: token)
            } else {
                text.append(" ")
                text.append(contentsOf: token)
            }
            previousBindsRight = binding == .right
        }
        return text
    }

    private static func hasVisibleContent(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    /// Whitespace runs of any kind squeezed to one space, with none left at
    /// either end. Splitting on `isWhitespace` rather than trimming a
    /// character set also catches the newline a recogniser puts between
    /// utterances, which `trimmingCharacters(in: .whitespaces)` does not.
    static func collapsed(_ text: String) -> String {
        // The overwhelmingly common token has no whitespace and can keep its
        // original String storage. Build a replacement only for recogniser
        // chunks that actually need trimming or whitespace compression.
        guard text.contains(where: { $0.isWhitespace }) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                result.append(character)
                pendingSpace = false
            }
        }
        return result
    }

    /// Which side of itself a token owns the space on.
    ///
    /// A token that is nothing but punctuation belongs against the word
    /// before it: "Hello" + "," is "Hello,". Opening brackets and quotes are
    /// the mirror image and have to be handled as their own case rather than
    /// merely excluded from the first one — suppressing the space on the
    /// wrong side of `(` gives `he said ( quietly)`, which is the same bug
    /// as `he said( quietly)` seen from the other end.
    enum TokenBinding {
        /// Ordinary word: a space on each side.
        case word
        /// Trailing punctuation: joins the token before it.
        case left
        /// An opener: joins the token after it.
        case right
    }

    static func binding(of token: String) -> TokenBinding {
        guard let first = token.unicodeScalars.first else { return .word }
        let punctuation = CharacterSet.punctuationCharacters
        for scalar in token.unicodeScalars where !punctuation.contains(scalar) {
            return .word
        }
        return openingMarks.contains(first) ? .right : .left
    }

    private static let openingMarks =
        CharacterSet(charactersIn: "([{\u{201C}\u{2018}\u{00AB}\u{00BF}\u{00A1}")

    static func render<Lines: Collection>(_ lines: Lines,
                                          includeTimestamps: Bool) -> String
        where Lines.Element == TranscriptLine {
        var result = ""
        for line in lines {
            if !result.isEmpty { result.append("\n") }
            if includeTimestamps {
                result.append("[")
                result.append(contentsOf: line.timestamp)
                result.append(contentsOf: "] ")
            }
            result.append(contentsOf: line.label)
            result.append(contentsOf: ": ")
            result.append(contentsOf: line.text)
        }
        return result
    }

    private static func wordCount(_ text: String) -> Int {
        var count = 0
        var insideWord = false
        for character in text {
            if character.isWhitespace {
                insideWord = false
            } else if !insideWord {
                count += 1
                insideWord = true
            }
        }
        return count
    }

    // MARK: - Repairs

    /// A run of one speaker sandwiched between two runs of the other is
    /// relabelled to match its neighbours when it is short in both words
    /// and time.
    ///
    /// This exists because the far end's "mm-hm" leaks acoustically into
    /// the microphone — through the speakers, past whatever echo
    /// cancellation the meeting app is doing — and lands as a directMic run
    /// in the middle of a far-end sentence. Untouched, one sentence becomes
    /// three lines with the wrong speaker owning the middle of it. Two
    /// bounds instead of one because either alone is wrong: a slow six
    /// words is still bleed, and a fast nine-word sentence is a real
    /// interruption that must keep its own name.
    ///
    /// Only the label moves. The channel stays what the hardware reported,
    /// because the channel is the evidence and this pass is a guess about
    /// what the evidence means; rewriting it would leave nothing for a
    /// later pass — or a human reading the log — to disagree with.
    ///
    /// Internal rather than private so the tests can drive it on synthetic
    /// runs instead of reverse-engineering word timings that produce them.
    static func bridgeShortInterjections(_ input: [TranscriptLine]) -> [TranscriptLine] {
        guard input.count >= 3 else { return input }
        var result = input
        for index in 1..<(input.count - 1) {
            // Neighbours are read from the input, never from the partly
            // rewritten output. A pass that reads its own edits chains one
            // repair into the next and can relabel an entire alternating
            // stretch off the back of a single "mm-hm".
            let previous = input[index - 1]
            let line = input[index]
            let next = input[index + 1]
            guard previous.label == next.label, line.label != previous.label else { continue }
            guard wordCount(line.text) <= bridgeMaxWords,
                  line.endMs - line.startMs <= bridgeMaxSpanMs else { continue }
            result[index].label = previous.label
        }
        return result
    }

    /// Two adjacent runs with the same label are merged when the earlier one
    /// does not end a sentence and the later one starts lowercase.
    ///
    /// The split those two runs came from was a silence longer than
    /// `maxGapMs`, and this deliberately overrides it: a speaker who pauses
    /// four seconds in the middle of a clause has paused, not finished, and
    /// printing the second half as a new turn implies a handover that never
    /// happened. The text is the better evidence than the clock here, and
    /// only where both halves of the evidence agree.
    ///
    /// Different labels never merge, whatever the punctuation says. That is
    /// the rule that makes the empty-label bug survivable: even if a label
    /// went missing, two speakers still cannot be joined into one line.
    ///
    /// Internal rather than private for the same reason as the pass above.
    static func mergeRunOnSentences(_ input: [TranscriptLine]) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        result.reserveCapacity(input.count)
        for line in input {
            guard var previous = result.last, shouldMerge(previous, into: line) else {
                result.append(line)
                continue
            }
            previous.text = collapsed(previous.text + " " + line.text)
            previous.endMs = max(previous.endMs, line.endMs)
            previous.isSettled = previous.isSettled && line.isSettled
            result[result.count - 1] = previous
        }
        return result
    }

    private static func shouldMerge(_ earlier: TranscriptLine,
                                    into later: TranscriptLine) -> Bool {
        guard earlier.label == later.label else { return false }
        guard let tail = earlier.text.last,
              !sentenceTerminators.contains(tail) else { return false }
        // `isLowercase` is false for scripts without case, so a Japanese or
        // Chinese transcript never merges here. That is the right default
        // for a heuristic built on a Latin capitalisation convention: it
        // declines to act rather than guessing where a sentence ended.
        guard let head = later.text.first, head.isLowercase else { return false }
        return true
    }
}
