// QuestionDetectorTests.swift
// PRISMTests
//
// The line between "somebody just asked something" and "somebody is still
// talking" (§5.33).
//
// One edit is the reason most of this file exists. Every rule in the
// detector reduces, under a casual reading, to `text.hasSuffix("?")` — and
// against a punctuated corpus that reduction looks like a tidy-up and
// passes review. It would also turn the composer's light off for most of
// every real meeting, because PRISM's transcripts come off a local
// Whisper-family model that drops terminal punctuation constantly (§5.32).
// So the missing-"?" cases below are not edge cases padding out a suite:
// they are the main case, and they are here to fail that tidy-up loudly.
//
// The second class of bug is the flicker. `.low` and `.none` are different
// answers — a three-word fragment is a sentence that has not arrived, not a
// statement — and a detector that collapses them makes a control blink its
// way through every sentence somebody speaks. The ordering assertions are
// what hold those two apart.
//
// The third is direction. `latestQuestion` scans backwards, and a forward
// scan passes any test written over a transcript with one question in it
// while highlighting the oldest question on screen in every real one. The
// backwards test therefore has a statement after the question on purpose.
//
// Some of what follows asserts behaviour that is wrong on its face and
// deliberate: an imperative opening with an auxiliary scores as a question,
// and a tag question without its comma does not. Those are recorded here so
// that a later reader can see the trade was made rather than missed. Both
// are affordable for the same reason: this detector lights a key and never
// sends anything, so a false positive costs a highlight nobody has to look
// at. There is nothing to mock in this file because there is nothing to
// call — the whole feature is a pure function over a string, and that is
// the design and not a convenience.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class QuestionDetectorTests: XCTestCase {

    // MARK: - The ladder

    func testConfidenceIsOrdered() {
        XCTAssertLessThan(QuestionConfidence.none, .low)
        XCTAssertLessThan(QuestionConfidence.low, .medium)
        XCTAssertLessThan(QuestionConfidence.medium, .high)
    }

    // MARK: - Scoring

    func testAQuestionMarkOutranksEverything() {
        XCTAssertEqual(QuestionDetector.confidence("What's your take on the pricing model?"),
                       .high)
        XCTAssertTrue(QuestionDetector.isLikelyCompleteQuestion("What's your take on the pricing model?"))
    }

    func testAQuestionMarkIsFoundInsideATrailingPunctuationRun() {
        // Neither of these ends in the character, and both are questions.
        XCTAssertEqual(QuestionDetector.confidence("What broke in staging?!"), .high)
        XCTAssertEqual(QuestionDetector.confidence("So what broke in staging?\""), .high)
    }

    func testABehaviouralStemIsAnAnswerableQuestion() {
        let asked = "Tell me about a time you shipped something late."
        XCTAssertGreaterThanOrEqual(QuestionDetector.confidence(asked), .medium)
        XCTAssertTrue(QuestionDetector.isLikelyCompleteQuestion(asked))
    }

    func testAnInterrogativeOpenerCarriesAQuestionWithNoQuestionMark() {
        // The load-bearing case. A recogniser that never emits "?" must not
        // leave the composer dark through an entire interview.
        let asked = "How did you handle that"
        XCTAssertGreaterThanOrEqual(QuestionDetector.confidence(asked), .medium)
        XCTAssertTrue(QuestionDetector.isLikelyCompleteQuestion(asked))
    }

    func testATrailingHandoverPhraseIsAQuestion() {
        // Not a question by grammar; unmistakably a request for an answer.
        XCTAssertGreaterThanOrEqual(QuestionDetector.confidence("...and your thoughts"),
                                    .medium)
        XCTAssertGreaterThanOrEqual(QuestionDetector.confidence("So we should hear you on that"),
                                    .medium)
    }

    func testATagQuestionNeedsItsComma() {
        // "right" is the last word of both. The comma is the only thing in
        // the text that separates a question from an agreement, so it is
        // required — and the cost is that a transcript which drops the
        // comma as well as the "?" goes undetected.
        XCTAssertGreaterThanOrEqual(QuestionDetector.confidence("So we ship Tuesday, right"),
                                    .medium)
        XCTAssertEqual(QuestionDetector.confidence("Yeah that sounds right"), .none)
        XCTAssertFalse(QuestionDetector.isLikelyCompleteQuestion("Yeah that sounds right"))
    }

    func testAnImperativeOpeningWithAnAuxiliaryIsAllowedToScoreAsAQuestion() {
        // Deliberate, not an oversight. Tightening this to exclude
        // imperatives costs real questions in a transcript with no
        // punctuation, and the only thing it buys back is the suppression
        // of a highlight nobody is obliged to look at.
        XCTAssertEqual(QuestionDetector.confidence("Do not forget to file the ticket"), .high)
    }

    // MARK: - Fragments

    func testAnAccumulatingFragmentIsLowAndNotNone() {
        // Three words of a sentence that has not arrived. It must outrank a
        // finished statement, or the composer's light blinks off and on
        // while somebody speaks a single question.
        XCTAssertEqual(QuestionDetector.confidence("so the performance"), .low)
        XCTAssertFalse(QuestionDetector.isLikelyCompleteQuestion("so the performance"))
        XCTAssertGreaterThan(QuestionDetector.confidence("so the performance"),
                             QuestionDetector.confidence("we shipped the release on Tuesday afternoon"))
    }

    func testAOneWordUtteranceIsNeverAnswerable() {
        XCTAssertLessThanOrEqual(QuestionDetector.confidence("yeah"), .low)
        XCTAssertFalse(QuestionDetector.isLikelyCompleteQuestion("yeah"))
    }

    func testATenCharacterLineIsNeverAnswerable() {
        let short = "understood"
        XCTAssertEqual(short.count, 10)
        XCTAssertLessThanOrEqual(QuestionDetector.confidence(short), .low)
        XCTAssertFalse(QuestionDetector.isLikelyCompleteQuestion(short))
    }

    func testAWholeQuestionCanStillBeUnanswerable() {
        // High confidence and not worth offering help with: "Why?" is
        // unmistakably a question and cannot be answered without the
        // sentence before it. Confidence and completeness are separate
        // judgements and this is the case that proves it.
        XCTAssertEqual(QuestionDetector.confidence("Why?"), .high)
        XCTAssertFalse(QuestionDetector.isLikelyCompleteQuestion("Why?"))
    }

    func testPunctuationAloneIsNotAQuestion() {
        for noise in ["", "   ", "?", "...", "♪♪♪"] {
            XCTAssertEqual(QuestionDetector.confidence(noise), .none,
                           "\(noise) carries no question")
            XCTAssertFalse(QuestionDetector.isLikelyCompleteQuestion(noise))
        }
    }

    // MARK: - Transcription garbles

    func testGarblesAreRepairedBeforeAnythingIsMatched() {
        let asked = "can u walk me through the architecture"
        XCTAssertGreaterThanOrEqual(QuestionDetector.confidence(asked), .medium)
        XCTAssertTrue(QuestionDetector.isLikelyCompleteQuestion(asked))
    }

    func testTheYourGarbleIsRepairedWhereItChangesTheAnswer() {
        // "what's you thoughts" only reaches the handover phrase after the
        // repair; without it the sentence ends in "you thoughts" and scores
        // as a statement. The second assertion is the control: the repair
        // list is closed, and a garble that is not in it is not guessed at.
        XCTAssertGreaterThanOrEqual(QuestionDetector.confidence("so what's you thoughts"),
                                    .medium)
        XCTAssertEqual(QuestionDetector.confidence("so what's yer thoughts"), .none)
    }

    // MARK: - Sentence splitting

    func testSentencesKeepTheirTerminators() {
        // The "?" is evidence, and what comes out of here is what the panel
        // displays — a highlight with its question mark shaved off looks
        // like a transcription error.
        XCTAssertEqual(
            QuestionDetector.sentences(in: "We shipped Tuesday. What broke in staging? I'll check."),
            ["We shipped Tuesday.", "What broke in staging?", "I'll check."])
    }

    func testADecimalPointIsNotASentenceBoundary() {
        XCTAssertEqual(QuestionDetector.sentences(in: "the number is 3.5 percent"),
                       ["the number is 3.5 percent"])
    }

    func testAColonInsideASentenceIsNotASpeakerLabel() {
        let sentence = "Here's the thing: what would you do?"
        XCTAssertEqual(QuestionDetector.strippingSpeakerLabel(sentence), sentence)
        // And the question comes back whole rather than beheaded.
        XCTAssertEqual(QuestionDetector.latestQuestion(in: sentence), sentence)
    }

    func testATimestampIsNotASpeakerLabel() {
        let sentence = "14:32 what broke in staging"
        XCTAssertEqual(QuestionDetector.strippingSpeakerLabel(sentence), sentence)
    }

    // MARK: - latestQuestion

    func testLatestQuestionScansBackwardsPastATrailingStatement() {
        // A forward scan returns the oldest question in the buffer, which
        // in a running transcript is one that was answered minutes ago. And
        // the statement after the question must not bury it.
        XCTAssertEqual(
            QuestionDetector.latestQuestion(in: "We shipped Tuesday. What broke in staging? I'll check."),
            "What broke in staging?")
    }

    func testLatestQuestionPrefersTheMostRecentOfTwoQuestions() {
        XCTAssertEqual(
            QuestionDetector.latestQuestion(in: "What did the rollout cost us? How did you handle the rollback?"),
            "How did you handle the rollback?")
    }

    func testLatestQuestionStripsASpeakerLabel() {
        XCTAssertEqual(QuestionDetector.latestQuestion(in: "Them: What broke in staging?"),
                       "What broke in staging?")
    }

    func testLatestQuestionSplitsOnNewlinesAsWellAsTerminators() {
        // One line per speaker turn, and the last turn is a statement — the
        // question above it is still the thing to offer help with.
        let run = "Them: What broke in staging?\nMe: I'll check the logs after lunch."
        XCTAssertEqual(QuestionDetector.latestQuestion(in: run), "What broke in staging?")
    }

    func testLatestQuestionFindsAQuestionWithNoPunctuationAtAll() {
        XCTAssertEqual(
            QuestionDetector.latestQuestion(in: "we shipped tuesday\nwalk me through the rollback"),
            "walk me through the rollback")
    }

    func testLatestQuestionIsNilWhenNobodyAsked() {
        XCTAssertNil(QuestionDetector.latestQuestion(in: "We shipped Tuesday. I'll check the logs after lunch."))
        XCTAssertNil(QuestionDetector.latestQuestion(in: ""))
        XCTAssertNil(QuestionDetector.latestQuestion(in: "so the performance"))
    }
}
