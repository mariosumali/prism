// TranscriptSanitizerTests.swift
// PRISMTests
//
// The line between "the model made that up" and "somebody actually said
// that" (§5.32).
//
// Two opposite bugs live here, and the second one is the one that ships.
// The first is obvious: a subtitle sign-off left in a meeting transcript,
// filed by channel under whoever happened to be on the far end. The second
// is a filter that gets enthusiastic and eats "yes" — and a missing "yes"
// is invisible, because a transcript with an answer removed still reads
// like a transcript. Nobody files a bug for a word that is not there. So
// most of what follows is a list of things that must survive, and the
// assertions that they do are the load-bearing half of this file.
//
// The other invariant under test is that the word-level pass is a filter
// and nothing more: it drops whole runs, it never reorders, and it never
// touches an id or a timestamp on a word it keeps. Corrections arrive later
// naming words by id, so a sanitizer that reissued them would break
// `replacedIds` a release after anyone would think to look here.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class TranscriptSanitizerTests: XCTestCase {

    // MARK: - Helpers

    private func word(_ text: String, _ startMs: Int64, _ endMs: Int64,
                      _ channel: ChannelProfile, id: String) -> TranscriptWord {
        TranscriptWord(id: id, text: text, startMs: startMs, endMs: endMs,
                       channel: channel)
    }

    /// Well over the attribution ceiling, and it does contain a trigger
    /// phrase — that is the point of it.
    private let longRealUtterance = """
        Right, so the way the billing migration lands is that we keep the old \
        endpoints alive for a full quarter, and every customer who has not \
        moved by then gets a personal email from support rather than a \
        banner. Anyone who wants the weekly rollout digest can subscribe to \
        the internal list and it turns up on Friday mornings.
        """

    // MARK: - Things that must be dropped

    func testSubtitleSignOffIsDropped() {
        XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination("Thanks for watching!"))
        XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination("Thank you for watching."))
        XCTAssertNil(TranscriptSanitizer.clean("Thanks for watching!"))
        XCTAssertNil(TranscriptSanitizer.clean("Thank you for watching."))
    }

    func testAmaraCreditIsDropped() {
        let credit = "Subtitles by the Amara.org community"
        XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination(credit))
        XCTAssertNil(TranscriptSanitizer.clean(credit))
    }

    func testTriggersAreMatchedWithoutRegardToCase() {
        XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination("SUBTITLES BY THE AMARA.ORG COMMUNITY"))
        XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination("please subscribe"))
        XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination("Please Subscribe"))
    }

    func testAStrayCreditDomainIsDropped() {
        // The canonical Whisper-on-silence output, and a URL is not a thing
        // anybody pronounces into a meeting.
        XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination("www.zeoranger.co.kr"))
        XCTAssertNil(TranscriptSanitizer.clean("www.zeoranger.co.kr"))
    }

    func testTextWithNoLettersOrDigitsIsDropped() {
        for noise in ["...", "♪♪♪", "♪", "- -", "   ", ""] {
            XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination(noise),
                          "\(noise) carries no word")
            XCTAssertNil(TranscriptSanitizer.clean(noise))
        }
    }

    // MARK: - Things that must survive

    func testOneWordAnswersSurvive() {
        // These are the whole reason there is no minimum-length rule. Each
        // one is a complete answer to a question somebody asked, and losing
        // it silently inverts the meaning of the exchange above it.
        for answer in ["yes", "no", "ok", "okay", "right", "sure", "mm-hm",
                       "Yes.", "No.", "Right."] {
            XCTAssertFalse(TranscriptSanitizer.isLikelyHallucination(answer),
                           "\(answer) is a real answer")
            XCTAssertEqual(TranscriptSanitizer.clean(answer), answer)
        }
    }

    func testBarePolitenessSurvivesBecauseOnlyTheForWatchingFormIsAnArtifact() {
        // Deliberate and slightly uncomfortable: "Thank you." is the single
        // most common thing a Whisper model emits over silence, and it is
        // also something people say roughly once a minute in a meeting.
        // Dropping it would clear up a lot of noise and would also delete
        // the closing line of most calls, so the trigger is the *phrase*
        // "thank you for watching" and never the greeting on its own. A
        // stray "Thank you." in a transcript costs a reader nothing; a
        // missing one is a person who sounds like they hung up mid-sentence.
        for polite in ["Thank you.", "Thanks.", "Thanks!", "Thank you so much."] {
            XCTAssertFalse(TranscriptSanitizer.isLikelyHallucination(polite),
                           "\(polite) is a real thing to say")
            XCTAssertEqual(TranscriptSanitizer.clean(polite), polite)
        }
        XCTAssertNil(TranscriptSanitizer.clean("Thank you for watching."))
    }

    func testALongUtteranceIsNotCondemnedByOneTriggerPhrase() {
        // The length ceiling doing the only job it has. The same trigger in
        // a short chunk is condemned; in three hundred characters of
        // somebody explaining a migration it is a word in a sentence.
        XCTAssertGreaterThan(longRealUtterance.count,
                             TranscriptSanitizer.attributionCeiling)
        XCTAssertTrue(longRealUtterance.lowercased().contains("subscribe to"))
        XCTAssertTrue(TranscriptSanitizer.isLikelyHallucination("Please subscribe to the channel."))
        XCTAssertFalse(TranscriptSanitizer.isLikelyHallucination(longRealUtterance))

        // It survives `clean` too. The tail rule still trims the final
        // sentence back to the boundary before the trigger — that is the
        // price of a substring match, and it is bounded to one sentence
        // rather than the whole utterance.
        guard let kept = TranscriptSanitizer.clean(longRealUtterance) else {
            return XCTFail("a real utterance was thrown away")
        }
        XCTAssertTrue(kept.hasPrefix("Right, so the way the billing migration lands"))
        XCTAssertTrue(kept.hasSuffix("rather than a banner."))
    }

    func testSurvivingTextComesBackTrimmed() {
        // The recogniser pads chunks with leading spaces; nothing
        // downstream wants them, and a run joined out of padded words
        // otherwise inherits them.
        XCTAssertEqual(TranscriptSanitizer.clean("  We shipped it Tuesday.  "),
                       "We shipped it Tuesday.")
    }

    // MARK: - Repetition collapse

    func testAPhraseRepeatedUntilItFillsTheChunkIsDropped() {
        XCTAssertTrue(TranscriptSanitizer.isRepetitionCollapse("okay okay okay okay"))
        XCTAssertNil(TranscriptSanitizer.clean("okay okay okay okay"))
        // The same loop written out as sentences, which is how it usually
        // arrives.
        XCTAssertTrue(TranscriptSanitizer.isRepetitionCollapse("Okay. Okay. Okay. Okay."))
        XCTAssertNil(TranscriptSanitizer.clean("Okay. Okay. Okay. Okay."))
        // Multi-token phrase, four times round.
        XCTAssertTrue(TranscriptSanitizer.isRepetitionCollapse(
            "I don't know. I don't know. I don't know. I don't know."))
    }

    func testAnIncidentalRepeatIsNotACollapse() {
        // Ordinary English repeats itself constantly. Two of anything is
        // emphasis, not a decoder in a loop.
        for line in ["no no, that's fine",
                     "I said that that was fine",
                     "yes yes",
                     "we we should probably start"] {
            XCTAssertFalse(TranscriptSanitizer.isRepetitionCollapse(line),
                           "\(line) is ordinary speech")
            XCTAssertNotNil(TranscriptSanitizer.clean(line))
        }
    }

    func testThreeRepeatsOnlyCondemnAChunkWhenTheyAreMostOfIt() {
        // Three of a thing, and nothing else: a loop.
        XCTAssertTrue(TranscriptSanitizer.isRepetitionCollapse(
            "thank you thank you thank you"))
        // Three of a thing inside a real sentence: emphasis.
        let emphatic = "I went round the block and thought about it and then "
            + "I said no no no and we moved on to the pricing question which "
            + "took the rest of the afternoon anyway."
        XCTAssertFalse(TranscriptSanitizer.isRepetitionCollapse(emphatic))
        XCTAssertNotNil(TranscriptSanitizer.clean(emphatic))
    }

    // MARK: - Attribution tails

    func testStrippingAnAttributionCutsBackToTheSentenceBefore() {
        // Back to the boundary, not back to the trigger: "for watching!"
        // left dangling reads like something a person said.
        XCTAssertEqual(
            TranscriptSanitizer.strippingAttributionTail(
                "We shipped it Tuesday. Thanks for watching!"),
            "We shipped it Tuesday.")
        XCTAssertEqual(
            TranscriptSanitizer.strippingAttributionTail(
                "One. Two. Subtitles by the Amara.org community"),
            "One. Two.")
    }

    func testAChunkThatIsNothingButAttributionLeavesNothing() {
        XCTAssertEqual(TranscriptSanitizer.strippingAttributionTail("Thanks for watching!"), "")
        XCTAssertEqual(TranscriptSanitizer.strippingAttributionTail("Please subscribe"), "")
    }

    func testACleanSentenceComesBackUntouched() {
        for line in ["We shipped it Tuesday.",
                     "The build is green and every test passes.",
                     "yes",
                     "Can you hear me now?"] {
            XCTAssertEqual(TranscriptSanitizer.strippingAttributionTail(line), line)
        }
    }

    func testTheCutIsTakenAtTheLastAttributionAndStackedCreditsCondemnTheChunk() {
        // Credits stack once a decoder has lost the audio entirely. The
        // strip is one pass and cuts back from the *last* trigger, so the
        // earlier credit is still standing afterwards.
        let stacked = "We shipped it Tuesday. Thanks for watching. Please subscribe."
        XCTAssertEqual(TranscriptSanitizer.strippingAttributionTail(stacked),
                       "We shipped it Tuesday. Thanks for watching.")
        // And that is why `clean` re-judges rather than re-strips: what
        // comes back still reads as an attribution, so the whole chunk
        // goes. Looping would rescue "We shipped it Tuesday.", but a
        // sentence sitting in front of two invented credits is far more
        // likely to be a third invention than a rescue.
        XCTAssertNil(TranscriptSanitizer.clean(stacked))
    }

    // MARK: - Word level

    func testAHallucinatedFarEndRunIsDroppedAndTheRunsAroundItKeepTheirIds() {
        let words = [
            word("Did", 0, 200, .directMic, id: "m1"),
            word("that", 200, 400, .directMic, id: "m2"),
            word("land?", 400, 700, .directMic, id: "m3"),
            word("Subtitles", 900, 1100, .farEnd, id: "f1"),
            word("by", 1100, 1200, .farEnd, id: "f2"),
            word("the", 1200, 1300, .farEnd, id: "f3"),
            word("Amara.org", 1300, 1600, .farEnd, id: "f4"),
            word("community", 1600, 1900, .farEnd, id: "f5"),
            word("Yes,", 2000, 2200, .directMic, id: "m4"),
            word("Tuesday.", 2200, 2500, .directMic, id: "m5"),
        ]
        let kept = TranscriptSanitizer.clean(words)
        XCTAssertEqual(kept.map(\.id), ["m1", "m2", "m3", "m4", "m5"])
        // Ids and times survive untouched, in the order they arrived.
        XCTAssertEqual(kept.map(\.startMs), [0, 200, 400, 2000, 2200])
        XCTAssertEqual(kept.map(\.endMs), [200, 400, 700, 2200, 2500])
        XCTAssertEqual(kept.map(\.text), ["Did", "that", "land?", "Yes,", "Tuesday."])
        XCTAssertTrue(kept.allSatisfy { $0.channel == .directMic })
    }

    func testARepeatingFarEndRunGoesWhileASingleThankYouStays() {
        // The same words, judged by the run they sit in. One "Thank you."
        // is a person; four in a row is a decoder that ran out of audio.
        var words = [
            word("Thank", 0, 200, .directMic, id: "m1"),
            word("you.", 200, 500, .directMic, id: "m2"),
        ]
        for index in 0..<4 {
            let base = Int64(1000 + index * 400)
            words.append(word("Thank", base, base + 200, .farEnd, id: "f\(index)a"))
            words.append(word("you.", base + 200, base + 400, .farEnd, id: "f\(index)b"))
        }
        let kept = TranscriptSanitizer.clean(words)
        XCTAssertEqual(kept.map(\.id), ["m1", "m2"])
    }

    func testAWordLevelFilterJudgesEachChannelRunSeparately() {
        // The user answering over a far-end credit must not be taken down
        // with it, which is the whole reason runs are the unit.
        let words = [
            word("Subtitles", 0, 200, .farEnd, id: "f1"),
            word("by", 200, 400, .farEnd, id: "f2"),
            word("Amara.org", 400, 700, .farEnd, id: "f3"),
            word("no", 100, 300, .directMic, id: "m1"),
            word("Transcribed", 800, 1100, .farEnd, id: "f4"),
            word("by", 1100, 1200, .farEnd, id: "f5"),
            word("someone", 1200, 1500, .farEnd, id: "f6"),
        ]
        XCTAssertEqual(TranscriptSanitizer.clean(words).map(\.id), ["m1"])
    }

    func testNoWordsInNoWordsOut() {
        XCTAssertTrue(TranscriptSanitizer.clean([TranscriptWord]()).isEmpty)
    }

    func testAWholeTranscriptOfRealSpeechIsLeftAlone() {
        // The regression that matters most: run a normal exchange through
        // the filter and get every word back.
        let words = [
            word("Are", 0, 150, .directMic, id: "m1"),
            word("we", 150, 300, .directMic, id: "m2"),
            word("shipping", 300, 600, .directMic, id: "m3"),
            word("Tuesday?", 600, 900, .directMic, id: "m4"),
            word("Yes,", 1000, 1200, .farEnd, id: "f1"),
            word("assuming", 1200, 1600, .farEnd, id: "f2"),
            word("the", 1600, 1700, .farEnd, id: "f3"),
            word("audit", 1700, 2000, .farEnd, id: "f4"),
            word("signs", 2000, 2300, .farEnd, id: "f5"),
            word("off.", 2300, 2500, .farEnd, id: "f6"),
            word("Right.", 2600, 2900, .directMic, id: "m5"),
        ]
        XCTAssertEqual(TranscriptSanitizer.clean(words), words)
    }
}
