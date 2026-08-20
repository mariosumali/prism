// TranscriptRendererTests.swift
// PRISMTests
//
// Who said what (§5.32), and the several ways a two-channel merge can lie
// about it without anybody noticing.
//
// Every failure this file defends against produces a transcript that still
// reads correctly. A far-end sentence absorbed into the local speaker's
// line is a grammatical paragraph attributed to the wrong person; a run-on
// left unmerged is two plausible turns; an unstable tie-break is a line
// that renders one way now and the other way after the next word arrives.
// None of them throw, none of them look wrong on screen, and all of them
// end up quoted back at the user in a summary. So the assertions here are
// on exact strings and exact label sequences rather than on counts —
// "there are two lines" is true of both the correct and the broken output
// in most of these cases.
//
// The load-bearing test is testFarEndRunNeverMergesIntoAYouLine. Its input
// is chosen so that a renderer which lets an empty far-end label through
// would merge the two turns: same (empty) label, no terminal punctuation on
// the first, lowercase start on the second. That is the humla bug, exactly.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class TranscriptRendererTests: XCTestCase {

    // MARK: - Builders

    private func word(_ text: String, _ startMs: Int64, _ endMs: Int64,
                      _ channel: ChannelProfile,
                      state: WordState = .final) -> TranscriptWord {
        TranscriptWord(text: text, startMs: startMs, endMs: endMs,
                       channel: channel, state: state)
    }

    /// A spoken run, one word per token, evenly spaced. The 20 ms shaved off
    /// each word's end is the silence between words — without it a word
    /// would end exactly where the next begins, which never happens.
    private func say(_ sentence: String, from startMs: Int64,
                     on channel: ChannelProfile,
                     msPerWord: Int64 = 300,
                     state: WordState = .final) -> [TranscriptWord] {
        sentence.split(separator: " ").enumerated().map { index, token in
            let start = startMs + Int64(index) * msPerWord
            return TranscriptWord(text: String(token), startMs: start,
                                  endMs: start + msPerWord - 20,
                                  channel: channel, state: state)
        }
    }

    private func line(_ id: String, _ label: String, _ text: String,
                      _ startMs: Int64, _ endMs: Int64,
                      _ channel: ChannelProfile,
                      settled: Bool = true) -> TranscriptLine {
        TranscriptLine(id: id, label: label, text: text, startMs: startMs,
                       endMs: endMs, channel: channel, isSettled: settled)
    }

    /// Four alternating turns, each deliberately spanning more than
    /// `bridgeMaxSpanMs` and starting with a capital, so neither repair pass
    /// touches them and the tests below can assert on the raw grouping.
    private func fourTurns() -> [TranscriptWord] {
        var words = say("First thing first", from: 0, on: .directMic, msPerWord: 1_500)
        words += say("Second point here", from: 6_000, on: .farEnd, msPerWord: 1_500)
        words += say("Third one now", from: 12_000, on: .directMic, msPerWord: 1_500)
        words += say("Fourth and last", from: 18_000, on: .farEnd, msPerWord: 1_500)
        return words
    }

    private func render(_ words: [TranscriptWord],
                        you: String = "You", them: String = "Them",
                        maxGapMs: Int64 = TranscriptRenderer.defaultMaxGapMs) -> [TranscriptLine] {
        TranscriptRenderer.lines(words, youLabel: you, farEndLabel: them,
                                 maxGapMs: maxGapMs)
    }

    // MARK: - Order

    func testMicWinsAStartTimeTie() {
        // Both recognisers stamped the same millisecond, and the far end is
        // listed first in the input. The user speaks and then hears a reply,
        // so the mic is the physically earlier of the two.
        let words = [
            word("hi", 1_000, 1_200, .farEnd),
            word("hello", 1_000, 1_200, .directMic),
        ]
        let lines = render(words)
        XCTAssertEqual(lines.map(\.channel), [.directMic, .farEnd])
        XCTAssertEqual(lines.map(\.text), ["hello", "hi"])
    }

    func testWordsOnOneChannelKeepTheirArrivalOrderWhenTimesTie() {
        // Equal keys must not reorder: the sort is re-run on every render,
        // and a transcript that reshuffles itself between renders is one the
        // user stops trusting.
        let words = [
            word("one", 500, 600, .directMic),
            word("two", 500, 600, .directMic),
            word("three", 500, 600, .directMic),
        ]
        XCTAssertEqual(render(words).first?.text, "one two three")
        XCTAssertEqual(TranscriptRenderer.chronological(words).map(\.text),
                       ["one", "two", "three"])
    }

    // MARK: - Labels

    func testFarEndRunNeverMergesIntoAYouLine() {
        // The whole point of the file. These two runs are a run-on across a
        // channel change: "ship it" has no terminal punctuation and "no"
        // starts lowercase, so a renderer that let an empty far-end label
        // through would see one label on both runs and merge them into a
        // single "You:" line — attributing the far end's objection to the
        // user, in a paragraph that reads perfectly.
        var words = say("I think we should ship it", from: 0, on: .directMic)
        words += say("no we should not", from: 2_000, on: .farEnd)

        let lines = render(words, them: "")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.label), ["You", "Them"])
        XCTAssertEqual(lines[0].text, "I think we should ship it")
        XCTAssertEqual(lines[1].text, "no we should not")
        XCTAssertFalse(lines[0].text.contains("no we should not"))
        XCTAssertEqual(TranscriptRenderer.labelled(words, youLabel: "You", farEndLabel: ""),
                       "You: I think we should ship it\nThem: no we should not")

        // A label of nothing but spaces is the same bug wearing a hat.
        XCTAssertEqual(render(words, them: "   ").map(\.label), ["You", "Them"])
    }

    func testAnEmptyYouLabelFallsBackRatherThanEmittingABareColon() {
        var words = say("Are you there", from: 0, on: .directMic)
        words += say("I am", from: 2_000, on: .farEnd)
        let text = TranscriptRenderer.labelled(words, youLabel: "", farEndLabel: "")
        XCTAssertEqual(text, "You: Are you there\nThem: I am")
        XCTAssertFalse(text.hasPrefix(":"))
    }

    func testLabelIsEmittedOnlyWhenItChanges() {
        // Four mic words then five far-end words is two labelled lines, not
        // nine. The label marks a change of speaker; repeating it per word
        // would be a different document.
        var words = say("Can you hear me", from: 0, on: .directMic)
        words += say("Yes I can hear you", from: 1_500, on: .farEnd)

        let lines = render(words, them: "Nadia")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.label), ["You", "Nadia"])
        XCTAssertEqual(TranscriptRenderer.labelled(words, youLabel: "You", farEndLabel: "Nadia"),
                       "You: Can you hear me\nNadia: Yes I can hear you")
    }

    // MARK: - Grouping

    func testGapLongerThanMaxStartsANewLine() {
        // Same speaker, same channel, 2.7 s of silence. "Where" is
        // capitalised so the run-on repair has no reason to undo the split.
        var words = say("Right", from: 0, on: .directMic)
        words += say("Where were we", from: 3_000, on: .directMic)

        let lines = render(words)
        XCTAssertEqual(lines.map(\.text), ["Right", "Where were we"])
        XCTAssertEqual(lines.map(\.channel), [.directMic, .directMic])
    }

    func testAGapExactlyAtTheLimitStaysOnOneLine() {
        // The bound is "exceeds", not "reaches". A pause that lands on the
        // limit is a pause.
        let words = [
            word("Right", 0, 280, .directMic),
            word("okay", 2_280, 2_500, .directMic),
        ]
        let lines = render(words)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Right okay")
    }

    func testAChannelChangeSplitsEvenWithNoGapAtAll() {
        // Overlapping speech: the far end starts before the mic word ends.
        // A negative gap must never be read as "same run".
        let words = [
            word("wait", 1_000, 2_000, .directMic),
            word("sorry", 1_500, 2_200, .farEnd),
        ]
        let lines = render(words)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.channel), [.directMic, .farEnd])
    }

    // MARK: - Text assembly

    func testPunctuationAttachesWithoutASpace() {
        let words = [
            word("Hello", 0, 300, .directMic),
            word(",", 300, 320, .directMic),
            word(" world", 320, 700, .directMic),   // recognisers emit the space
            word("!", 700, 720, .directMic),
        ]
        let text = render(words)[0].text
        XCTAssertEqual(text, "Hello, world!")
        XCTAssertEqual(text, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testAnOpeningBracketBindsToTheWordAfterIt() {
        let words = [
            word("he", 0, 200, .directMic),
            word("said", 200, 400, .directMic),
            word("(", 400, 420, .directMic),
            word("quietly", 420, 700, .directMic),
            word(")", 700, 720, .directMic),
        ]
        XCTAssertEqual(render(words)[0].text, "he said (quietly)")
    }

    func testWhitespaceCollapsesAndLinesNeverStartOrEndWithASpace() {
        let words = [
            word("  ragged", 0, 300, .directMic),
            word("spacing\there", 300, 600, .directMic),
            word("\n", 600, 620, .directMic),        // a chunk boundary
            word("indeed ", 620, 900, .directMic),
        ]
        let text = render(words)[0].text
        XCTAssertEqual(text, "ragged spacing here indeed")
        XCTAssertFalse(text.contains("  "))
    }

    // MARK: - Settling

    func testALineIsSettledOnlyWhenEveryWordIsFinal() {
        var words = say("Almost there", from: 0, on: .directMic)
        XCTAssertEqual(render(words).map(\.isSettled), [true])

        words.append(word("now", 600, 900, .directMic, state: .pending))
        let lines = render(words)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].isSettled)
    }

    func testAMergedLineIsSettledOnlyIfBothHalvesAre() {
        let merged = TranscriptRenderer.mergeRunOnSentences([
            line("a", "You", "I was going to say", 0, 1_500, .directMic, settled: true),
            line("b", "You", "that we should wait", 5_000, 6_500, .directMic, settled: false),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertFalse(merged[0].isSettled)
    }

    // MARK: - Bridging short interjections

    func testShortInterjectionIsBridged() {
        let input = [
            line("a", "Them", "so what I was getting at", 0, 2_000, .farEnd),
            line("b", "You", "mm-hm", 2_050, 2_400, .directMic),
            line("c", "Them", "is that the deadline moved", 2_450, 4_500, .farEnd),
        ]
        let bridged = TranscriptRenderer.bridgeShortInterjections(input)
        XCTAssertEqual(bridged.map(\.label), ["Them", "Them", "Them"])
        // The label is a claim about who spoke; the channel is the evidence
        // that the claim overrode, and it stays put.
        XCTAssertEqual(bridged[1].channel, .directMic)

        // Both bounds are inclusive: six words spanning exactly 3500 ms is
        // still bleed.
        let onTheLimit = [
            input[0],
            line("b", "You", "one two three four five six", 2_050, 5_550, .directMic),
            input[2],
        ]
        XCTAssertEqual(TranscriptRenderer.bridgeShortInterjections(onTheLimit).map(\.label),
                       ["Them", "Them", "Them"])
    }

    func testLongInterjectionIsNotBridged() {
        let tooManyWords = [
            line("a", "Them", "so what I was getting at", 0, 2_000, .farEnd),
            line("b", "You", "hold on that is not what the contract says",
                 2_050, 2_400, .directMic),          // nine words
            line("c", "Them", "is that the deadline moved", 2_450, 4_500, .farEnd),
        ]
        XCTAssertEqual(TranscriptRenderer.bridgeShortInterjections(tooManyWords).map(\.label),
                       ["Them", "You", "Them"])

        let tooLong = [
            line("a", "Them", "so what I was getting at", 0, 2_000, .farEnd),
            line("b", "You", "hold on", 2_050, 7_050, .directMic),   // five seconds
            line("c", "Them", "is that the deadline moved", 7_100, 9_000, .farEnd),
        ]
        XCTAssertEqual(TranscriptRenderer.bridgeShortInterjections(tooLong).map(\.label),
                       ["Them", "You", "Them"])
    }

    func testAnInterjectionBetweenDifferentSpeakersIsLeftAlone() {
        // Nothing to bridge to: the neighbours disagree with each other, so
        // the middle run is just the middle of a three-way exchange.
        let input = [
            line("a", "You", "so anyway", 0, 800, .directMic),
            line("b", "Them", "right", 900, 1_200, .farEnd),
            line("c", "Them", "carry on", 1_300, 2_000, .farEnd),
        ]
        XCTAssertEqual(TranscriptRenderer.bridgeShortInterjections(input).map(\.label),
                       ["You", "Them", "Them"])
    }

    func testBridgingLetsTheChoppedSentenceRejoin() {
        // End to end: the far end's "mm-hm" bleeds into the mic and cuts one
        // sentence into three lines. Bridging relabels it and the run-on
        // repair puts the sentence back together.
        var words = say("so what I was getting at", from: 0, on: .farEnd)
        words += say("mm-hm", from: 1_900, on: .directMic)
        words += say("is that the deadline moved", from: 2_300, on: .farEnd)

        let lines = render(words)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].label, "Them")
        XCTAssertEqual(lines[0].text,
                       "so what I was getting at mm-hm is that the deadline moved")
    }

    // MARK: - Run-on sentences

    func testRunOnSentencesMergeAcrossTheSameLabel() {
        // A 3.5 s pause mid-clause split this into two runs. The speaker was
        // thinking, not finishing: "say" ends no sentence and "that" starts
        // no new one.
        var words = say("I was going to say", from: 0, on: .directMic)
        words += say("that we should wait", from: 5_000, on: .directMic)

        let lines = render(words)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "I was going to say that we should wait")
        XCTAssertEqual(lines[0].startMs, 0)
        XCTAssertEqual(lines[0].endMs, words.map(\.endMs).max())
    }

    func testRunOnSentencesDoNotMergeAcrossLabels() {
        let input = [
            line("a", "You", "I was going to say", 0, 1_500, .directMic),
            line("b", "Them", "that we should wait", 5_000, 6_500, .farEnd),
        ]
        let merged = TranscriptRenderer.mergeRunOnSentences(input)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.label), ["You", "Them"])
    }

    func testAFinishedSentenceDoesNotAbsorbTheNextRun() {
        let terminated = TranscriptRenderer.mergeRunOnSentences([
            line("a", "You", "I was going to say something.", 0, 1_500, .directMic),
            line("b", "You", "that we should wait", 5_000, 6_500, .directMic),
        ])
        XCTAssertEqual(terminated.count, 2)

        // A colon closes a clause too — "here's the thing:" plus a lowercase
        // continuation is exactly the case a naive check gets wrong.
        let colon = TranscriptRenderer.mergeRunOnSentences([
            line("a", "You", "here's the thing:", 0, 1_500, .directMic),
            line("b", "You", "we are late", 5_000, 6_500, .directMic),
        ])
        XCTAssertEqual(colon.count, 2)
    }

    func testACapitalisedContinuationDoesNotMerge() {
        let merged = TranscriptRenderer.mergeRunOnSentences([
            line("a", "You", "I was going to say something", 0, 1_500, .directMic),
            line("b", "You", "Then I forgot", 5_000, 6_500, .directMic),
        ])
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - Empty input

    func testEmptyInputRendersNothing() {
        XCTAssertTrue(TranscriptRenderer.lines([], youLabel: "You", farEndLabel: "Them").isEmpty)
        XCTAssertEqual(TranscriptRenderer.labelled([], youLabel: "You", farEndLabel: "Them"), "")
        XCTAssertEqual(TranscriptRenderer.labelled([], youLabel: "", farEndLabel: "",
                                                   includeTimestamps: true), "")
        XCTAssertEqual(TranscriptRenderer.tail([], turns: 5, youLabel: "You",
                                               farEndLabel: "Them"), "")
    }

    func testWhitespaceOnlyWordsRenderNothingRatherThanABareLabel() {
        let blanks = [
            word("   ", 0, 100, .directMic),
            word("\n", 100, 200, .farEnd),
        ]
        XCTAssertTrue(render(blanks).isEmpty)
        XCTAssertEqual(TranscriptRenderer.labelled(blanks, youLabel: "You",
                                                   farEndLabel: "Them"), "")
    }

    // MARK: - Timestamps

    func testTimestampsPrefixEveryLineWhenAsked() {
        let words = fourTurns()
        XCTAssertEqual(
            TranscriptRenderer.labelled(words, youLabel: "You", farEndLabel: "Ivan",
                                        includeTimestamps: true),
            """
            [00:00] You: First thing first
            [00:06] Ivan: Second point here
            [00:12] You: Third one now
            [00:18] Ivan: Fourth and last
            """)
    }

    func testTimestampsAreOffByDefault() {
        XCTAssertEqual(
            TranscriptRenderer.labelled(fourTurns(), youLabel: "You", farEndLabel: "Ivan"),
            """
            You: First thing first
            Ivan: Second point here
            You: Third one now
            Ivan: Fourth and last
            """)
    }

    // MARK: - Tail

    func testTailReturnsTheLastLinesInOrder() {
        let words = fourTurns()
        XCTAssertEqual(TranscriptRenderer.tail(words, turns: 2, youLabel: "You",
                                               farEndLabel: "Ivan"),
                       "You: Third one now\nIvan: Fourth and last")
    }

    func testTailReturnsEverythingWhenAskedForMoreTurnsThanExist() {
        let words = fourTurns()
        XCTAssertEqual(TranscriptRenderer.tail(words, turns: 99, youLabel: "You",
                                               farEndLabel: "Ivan"),
                       TranscriptRenderer.labelled(words, youLabel: "You",
                                                   farEndLabel: "Ivan"))
        XCTAssertEqual(TranscriptRenderer.tail(words, turns: 0, youLabel: "You",
                                               farEndLabel: "Ivan"), "")
        XCTAssertEqual(TranscriptRenderer.tail(words, turns: -3, youLabel: "You",
                                               farEndLabel: "Ivan"), "")
    }
}
