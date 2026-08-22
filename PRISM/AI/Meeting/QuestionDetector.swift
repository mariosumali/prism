// QuestionDetector.swift
// PRISM
//
// Notices that the far end has probably just asked something, so the
// assistant's composer can light up (§5.33).
//
// This drives an affordance and never a request. Nothing in this file, and
// nothing downstream of it, causes an API call: the output is a light on a
// control, and the user still presses the key. That is the whole feature,
// and it is the one decision here worth defending at length, because every
// project in this space that shipped the other version took it back out.
// cheating-daddy ran a loop that screenshotted the screen every five
// seconds and answered whatever it found; the loop is gone and the interval
// parameter is still sitting in its settings, wired to nothing. Amurex
// shipped automatic suggestions and then needed a server-side rate cap and
// a two-field guard on top of it to stop the assistant talking over the
// meeting it was supposed to be helping with. The lesson is not that their
// detectors were inaccurate. It is that a detector wired to a request turns
// every false positive into a token bill and a paragraph that arrives while
// somebody is still speaking — and nobody can un-ask it.
//
// Live insights (§5.34) is the one opt-in exception, and it is built on
// exactly that lesson rather than against it: there the detector is one of
// two triggers, behind a quiet gap, a cooldown, a ten-minute ceiling and a
// switch of its own, and a false positive costs a request that is allowed
// to — and usually does — return nothing. Everything below is still written
// for the light, because the light is the default.
//
// Wired to a light, a false positive costs a lit key that gets ignored.
// That asymmetry is what buys the rules below the right to be loose, and
// they use it: an imperative that opens with an auxiliary ("do not forget
// to file the ticket") scores as a question here, and it is left that way
// on purpose. Tightening it would cost real questions in exchange for
// suppressing a highlight nobody is obliged to look at. Precision is not
// the figure of merit when the false positive is free and the false
// negative is a user staring at a dark key during the one question they
// wanted help with.
//
// The rules are ported from cue's `isLikelyCompleteQuestion` and
// `getQuestionConfidence` (GPL-3.0, like the rest of that lineage). The
// word lists and the four-level ladder are theirs, and in a heuristic like
// this the lists *are* the work — so the attribution is owed even though
// the code is reimplemented rather than copied, which it had to be, because
// GPL-3.0 source does not belong in an Apache-2.0 file.
//
// One thing had to change in the port. cue judges text that came back from
// a cloud recogniser with punctuation restored, so it can lean on the
// question mark. PRISM's transcripts come off a local Whisper-family model
// (§5.32) that drops terminal punctuation constantly, and a detector that
// needs the "?" would sit dark through most of an interview. Every rule
// below therefore has to survive its absence, which is why the interrogative
// opener and the behavioural stems carry the weight and the punctuation is
// only ever a bonus.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Confidence

/// How much of a question a piece of transcript looks like.
///
/// Four levels rather than a Bool, because the composer needs "not yet" and
/// "no" to be different answers. A live transcript arrives a word at a time,
/// so a question passes through several shapes on its way to being one, and
/// a control that switched off at every intermediate shape would flicker its
/// way through every sentence in the meeting.
public enum QuestionConfidence: Int, Comparable, Equatable {
    /// A statement, or nothing.
    case none = 0
    /// Too little text to judge. Not a refusal — a "wait".
    case low = 1
    /// Question-shaped without the grammar of one: a behavioural stem, or a
    /// trailing phrase that hands the floor over.
    case medium = 2
    /// Reads as a question outright.
    case high = 3

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

// MARK: - Detector

public enum QuestionDetector {

    // MARK: Vocabulary

    /// Openers that make a sentence a question, given a sentence's worth of
    /// words behind them.
    ///
    /// Two kinds of thing are in here and the mix is deliberate. The first
    /// is the wh-words and the auxiliaries — "what", "did", "is", "have" —
    /// which are what makes this work with no punctuation at all: English
    /// inverts the auxiliary to ask, and that inversion survives a
    /// recogniser that drops every "?" in the meeting. The second is the
    /// imperatives that request an answer: "tell me", "walk me", "explain",
    /// "describe", "give me". Those are not interrogatives by grammar and
    /// they are the most reliable entries in the list, because an
    /// interviewer says "walk me through your approach" far more often than
    /// they say "how would you approach this".
    ///
    /// Matched only at the start, and only with a word boundary after them,
    /// so "whatever we decide" is not a question and "what's your read" is.
    public static let interrogativeOpeners: [String] = [
        "what", "why", "how", "when", "where", "who", "which",
        "can", "could", "would", "will",
        "do", "does", "did",
        "is", "are", "was", "were",
        "should", "have", "has",
        "tell me", "walk me", "give me",
        "explain", "describe",
    ]

    /// Interview stems that ask for an answer without ever inverting a verb.
    ///
    /// These earn their own rule because they defeat the opener check by
    /// construction: "so tell me about a time you shipped late" opens with
    /// "so", and "I'd love it if you'd walk me through the migration" opens
    /// with a pronoun. Matched anywhere in the sentence for exactly that
    /// reason. Every entry is a phrase of four words or a phrase of three
    /// that cannot mean anything else — the discipline is the same one the
    /// transcript sanitizer's trigger list keeps, and for the same reason:
    /// the moment a bare word gets added here the rule starts firing on
    /// sentences it was never meant to see.
    public static let behaviouralStems: [String] = [
        "tell me about a time",
        "give me an example",
        "walk me through",
        "what would you do",
        "how did you handle",
        "describe a situation",
    ]

    /// Phrases that hand the floor over when they land at the end of a
    /// sentence. "…and your thoughts" is not grammatically a question and
    /// is unmistakably a request for one.
    ///
    /// Matched against the sentence with its trailing punctuation removed,
    /// on a word boundary, so "we agreed on that" counts and "look at the
    /// moon that" cannot.
    public static let trailingImplications: [String] = [
        "about that",
        "on that",
        "your thoughts",
        "any thoughts",
    ]

    /// Tag questions, which only count when a comma precedes them.
    ///
    /// The comma is doing real work and it is a deliberate trade. "so we
    /// ship Tuesday, right" is a question; "yeah that sounds right" ends
    /// with the same word and is an agreement, and without the comma there
    /// is nothing in the text that separates them. The cost is a transcript
    /// that drops the comma as well as the "?" — that one goes undetected,
    /// and the user presses the key themselves, which is what they were
    /// going to do anyway.
    public static let questionTags: [String] = ["right", "correct"]

    /// Garbles common enough in live transcription to be worth repairing
    /// before anything is matched against them.
    ///
    /// The list stays at two entries and each one is a phrase, never a bare
    /// word: "u" alone is a variable name and half the identifiers in a
    /// technical meeting, and rewriting it everywhere would corrupt more
    /// text than it fixes. As phrases they are safe — nobody says "can u"
    /// meaning anything but "can you", and "what's you" is never the end of
    /// a well-formed clause.
    public static let garbleRepairs: [(garble: String, repair: String)] = [
        (garble: "what's you ", repair: "what's your "),
        (garble: "can u ", repair: "can you "),
    ]

    // MARK: Thresholds

    /// Below this, the sentence is still arriving.
    ///
    /// The transcript sanitizer refuses to use length as a floor, because a
    /// floor there deletes a real one-word answer and nobody ever notices.
    /// A floor here withholds a highlight for another half-second, which
    /// costs nothing at all — the same measurement, opposite consequences,
    /// so the opposite policy is the right one.
    public static let answerableWordFloor = 4
    public static let answerableCharacterFloor = 12

    /// A speaker label is short by nature: "Them", "Interviewer", "Speaker
    /// 2", "Far end". The caps exist so that a colon in the middle of a
    /// real sentence — "here's the thing: what would you do" — is not read
    /// as one and does not lose the first half of the question.
    public static let maximumLabelWords = 2
    public static let maximumLabelCharacters = 24

    // MARK: Judgements

    /// How much of a question `text` looks like.
    ///
    /// The rules are checked strongest first and the first one that fires
    /// wins, so a sentence that is both interrogative and behavioural is
    /// simply high rather than being scored twice.
    public static func confidence(_ text: String) -> QuestionConfidence {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // "?" on its own, "…", "♪": punctuation carries no question, and no
        // amount of it becomes one.
        guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { return .none }
        let folded = normalized(trimmed)
        let words = wordCount(folded)
        return confidence(trimmed: trimmed, folded: folded, words: words)
    }

    private static func confidence(trimmed: String, folded: String,
                                   words: Int) -> QuestionConfidence {

        // A question mark is the one unambiguous signal in the language, so
        // it outranks everything and it is checked without a length floor:
        // "why?" is a whole question, even if it is not yet an answerable
        // one, and saying otherwise would make the ladder disagree with
        // every reader of the transcript.
        if endsWithQuestionMark(trimmed) { return .high }

        // Grammar, once there is enough of it. The word floor is what keeps
        // "did" and "so the performance" apart: an auxiliary at the head of
        // three words is a sentence that has not finished inverting yet.
        if words >= answerableWordFloor, opensWithInterrogative(folded) { return .high }

        // Asks for an answer without asking a question.
        if behaviouralStems.contains(where: { folded.contains($0) }) { return .medium }
        if handsTheFloorOver(folded) { return .medium }

        // Still accumulating. Distinct from `.none` because the composer
        // treats it as "wait", not "no" — "so the performance" is three
        // words of a sentence that has not arrived, and in another two it
        // may well be the question of the meeting.
        if words < answerableWordFloor || trimmed.count < answerableCharacterFloor {
            return .low
        }
        return .none
    }

    /// A question complete enough to be worth answering.
    ///
    /// Confidence and completeness are separate on purpose. "Why?" scores
    /// `.high` and fails here, which is correct twice over: it is
    /// unmistakably a question, and it is unanswerable without the sentence
    /// before it. Lighting the composer for it would promise help that
    /// nothing downstream could deliver.
    public static func isLikelyCompleteQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= answerableCharacterFloor else { return false }
        let folded = normalized(trimmed)
        let words = wordCount(folded)
        guard words >= answerableWordFloor else { return false }
        return confidence(trimmed: trimmed, folded: folded, words: words) >= .medium
    }

    /// Pulls the most recent question-shaped sentence out of a run of
    /// transcript, or nil. This is what the panel highlights.
    ///
    /// Backwards from the end, and that direction is the entire point. A
    /// forward scan returns the first question in the buffer, which in a
    /// running transcript is the oldest one on screen — the panel would
    /// spend the meeting highlighting something answered five minutes ago.
    /// Scanning back also means a trailing statement cannot bury a live
    /// question: "What broke in staging? I'll check." ends on a statement,
    /// and the question is still the thing to offer help with.
    public static func latestQuestion(in text: String) -> String? {
        for sentence in sentences(in: text).reversed() {
            let candidate = strippingSpeakerLabel(sentence)
            if isLikelyCompleteQuestion(candidate) { return candidate }
        }
        return nil
    }

    // MARK: Sentences

    /// Splits a run of transcript into individually judgeable sentences.
    ///
    /// A newline ends a sentence as firmly as a full stop does. The panel
    /// renders one line per speaker turn (§5.32), so a line break is a
    /// change of speaker, and a change of speaker is a boundary whether or
    /// not anybody punctuated it.
    ///
    /// Terminators stay attached to the sentence they close, because the
    /// "?" is evidence and because what comes back out of here is what the
    /// panel displays — a highlight with its own question mark shaved off
    /// looks like a transcription error. A decimal point between two digits
    /// is not a terminator: "we shipped 2.1 last week" is one sentence, and
    /// splitting it strands "1 last week" as the most recent thing anyone
    /// said. Pieces with no letters or digits in them are dropped, which is
    /// what becomes of the leading "..." on a trailing-off utterance.
    public static func sentences(in text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        current.reserveCapacity(min(text.utf8.count, 512))
        var index = text.startIndex

        func close() {
            let piece = current.trimmingCharacters(in: .whitespaces)
            if piece.contains(where: { $0.isLetter || $0.isNumber }) {
                pieces.append(piece)
            }
            current.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            index = next
            if character.isNewline {
                close()
                continue
            }
            current.append(character)
            guard character == "." || character == "!" || character == "?" else { continue }
            if character == ".",
               let previous = current.dropLast().last, previous.isNumber,
               next < text.endIndex, text[next].isNumber {
                continue
            }
            close()
        }
        close()
        return pieces
    }

    /// Removes a leading speaker label, so "Them: what broke" is judged as
    /// the question it contains rather than as a sentence beginning with a
    /// name.
    ///
    /// Only the first colon is considered and only under the label caps,
    /// and the prefix must contain a letter — otherwise a timestamped line
    /// ("14:32 Them: what broke") would lose its hour and keep everything
    /// else. Anything that fails a guard comes back exactly as it arrived;
    /// there is no partial cleanup here.
    public static func strippingSpeakerLabel(_ sentence: String) -> String {
        guard let colon = sentence.firstIndex(of: ":") else { return sentence }
        let label = sentence[..<colon]
        guard label.contains(where: { $0.isLetter }) else { return sentence }
        guard label.count <= maximumLabelCharacters else { return sentence }
        guard label.split(whereSeparator: { $0.isWhitespace }).count <= maximumLabelWords
        else { return sentence }
        let body = sentence[sentence.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? sentence : body
    }

    // MARK: Internals

    /// Lowercased, with whitespace collapsed, curly apostrophes flattened
    /// and the known garbles repaired. Punctuation survives — the "?" is
    /// the strongest signal in the file and normalising it away would be
    /// the one edit that quietly breaks everything.
    static func normalized(_ text: String) -> String {
        var folded = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        folded = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !folded.isEmpty else { return "" }
        // Padded so a garble sitting at the very end of a partial line still
        // matches: a live transcript hands this "can u" with nothing after
        // it more often than it hands over a finished sentence.
        folded += " "
        for (garble, repair) in garbleRepairs {
            folded = folded.replacingOccurrences(of: garble, with: repair)
        }
        return folded.trimmingCharacters(in: .whitespaces)
    }

    /// True when the last punctuation run contains a "?". Scanned rather
    /// than compared, because "really?!" and a quoted `staging?"` are both
    /// questions and neither one ends in the character.
    static func endsWithQuestionMark(_ text: String) -> Bool {
        for character in text.reversed() {
            if character == "?" { return true }
            if character.isLetter || character.isNumber { return false }
        }
        return false
    }

    static func opensWithInterrogative(_ folded: String) -> Bool {
        interrogativeOpeners.contains { opener in
            guard folded.hasPrefix(opener) else { return false }
            guard let next = folded.dropFirst(opener.count).first else { return true }
            // Any non-alphanumeric is a boundary, which is how "what's" and
            // "how'd" match their bare openers without "whatever" doing the
            // same.
            return !(next.isLetter || next.isNumber)
        }
    }

    static func handsTheFloorOver(_ folded: String) -> Bool {
        let bare = withoutTrailingPunctuation(folded)
        if trailingImplications.contains(where: { ends(bare, with: $0) }) { return true }
        return questionTags.contains { bare.hasSuffix(", " + $0) }
    }

    private static func ends(_ text: String, with phrase: String) -> Bool {
        text == phrase || text.hasSuffix(" " + phrase)
    }

    private static func withoutTrailingPunctuation(_ text: String) -> String {
        var slice = text[...]
        while let last = slice.last, !(last.isLetter || last.isNumber) {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    /// Whitespace-separated tokens that carry at least one letter or digit,
    /// so a stray "-" or "..." between two words does not inflate a
    /// three-word fragment into an answerable question.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace })
            .reduce(into: 0) { count, token in
                if token.contains(where: { $0.isLetter || $0.isNumber }) { count += 1 }
            }
    }
}
