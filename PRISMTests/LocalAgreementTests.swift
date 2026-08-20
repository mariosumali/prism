// LocalAgreementTests.swift
// PRISMTests
//
// The confirmation policy behind the live transcript (§5.32).
//
// Three bugs live in this algorithm and none of them announce themselves.
// Confirming too eagerly rewrites text the reader has already read, which is
// the exact failure LocalAgreement exists to prevent and the one nobody
// catches in a demo, because a demo is thirty seconds long and the model
// rarely changes its mind that fast. Confirming too little never settles
// anything: the transcript stays dim forever, and the notes prompt has
// nothing final to quote. And mishandling the overlap between successive
// decodes stutters — "and then we and then we shipped" — which looks like a
// model defect and is a bookkeeping one.
//
// So these tests are mostly counting. Exactly which words came out settled,
// exactly how many times each word appears in the committed run, and what
// happens at the three moments where the bookkeeping is easiest to get
// wrong: the first hypothesis, a hypothesis that shrinks, and a hypothesis
// that repeats a phrase already committed.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class LocalAgreementTests: XCTestCase {

    // MARK: - Helpers

    /// A hypothesis built from a sentence, one word per token, laid out on a
    /// regular grid. Real decodes are not this tidy, but nothing in the
    /// policy reads a duration — only `startMs` versus the last committed
    /// `endMs` — so a grid is enough to place words either side of that line.
    private func hypothesis(_ text: String, from startMs: Int64 = 0,
                            step: Int64 = 300,
                            channel: ChannelProfile = .directMic) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, token in
            let start = startMs + Int64(index) * step
            return TranscriptWord(text: String(token),
                                  startMs: start,
                                  endMs: start + step - 50,
                                  channel: channel)
        }
    }

    private func text(_ words: [TranscriptWord]) -> [String] {
        words.map(\.trimmed)
    }

    // MARK: - Word agreement

    func testCaseAndTrailingPunctuationAreNotDisagreement() {
        let bare = TranscriptWord(text: "prism", startMs: 0, endMs: 250,
                                  channel: .directMic)
        let dressed = TranscriptWord(text: "Prism,", startMs: 12, endMs: 268,
                                     channel: .directMic)
        XCTAssertTrue(LocalAgreement.agree(bare, dressed))
    }

    func testLeadingWhitespaceIsNotDisagreement() {
        // The recogniser emits words with a leading space more often than not.
        let spaced = TranscriptWord(text: " listening", startMs: 0, endMs: 250,
                                    channel: .directMic)
        let bare = TranscriptWord(text: "listening", startMs: 0, endMs: 250,
                                  channel: .directMic)
        XCTAssertTrue(LocalAgreement.agree(spaced, bare))
    }

    func testInteriorPunctuationStillDistinguishesWords() {
        let contracted = TranscriptWord(text: "don't", startMs: 0, endMs: 250,
                                        channel: .directMic)
        let plain = TranscriptWord(text: "dont", startMs: 0, endMs: 250,
                                   channel: .directMic)
        XCTAssertFalse(LocalAgreement.agree(contracted, plain))
    }

    func testABarePunctuationTokenAgreesWithNothing() {
        // Not even with itself: there is no word there to confirm.
        let comma = TranscriptWord(text: ",", startMs: 0, endMs: 40,
                                   channel: .directMic)
        XCTAssertFalse(LocalAgreement.agree(comma, comma))
    }

    func testAgreementIgnoresTimesEntirely() {
        // The same word re-decoded shifts by tens of milliseconds; a policy
        // that compared times would agree with nothing and settle nothing.
        let early = TranscriptWord(text: "shipped", startMs: 1_000, endMs: 1_250,
                                   channel: .directMic)
        let late = TranscriptWord(text: "shipped", startMs: 1_080, endMs: 1_390,
                                  channel: .farEnd)
        XCTAssertTrue(LocalAgreement.agree(early, late))
    }

    // MARK: - Prefix and suffix

    func testLongestCommonPrefixTakesTheNewerDecodesWords() {
        let older = hypothesis("the model has changed its mind")
        let newer = hypothesis("The model has other ideas entirely")
        let prefix = LocalAgreement.longestCommonPrefix(older, newer)
        XCTAssertEqual(text(prefix), ["The", "model", "has"])
        XCTAssertEqual(prefix.map(\.id), newer.prefix(3).map(\.id))
    }

    func testDivergentSuffixIsWhatIsLeftOfTheNewerHypothesis() {
        let older = hypothesis("the model has changed its mind")
        let newer = hypothesis("the model has other ideas entirely")
        XCTAssertEqual(text(LocalAgreement.divergentSuffix(older, newer)),
                       ["other", "ideas", "entirely"])
    }

    func testPrefixAndSuffixPartitionTheNewerHypothesis() {
        let older = hypothesis("one two three four")
        let newer = hypothesis("one two nine ten eleven")
        let rejoined = LocalAgreement.longestCommonPrefix(older, newer)
            + LocalAgreement.divergentSuffix(older, newer)
        XCTAssertEqual(rejoined, newer)
    }

    // MARK: - The first hypothesis

    func testTheFirstHypothesisConfirmsNothing() {
        var buffer = HypothesisBuffer()
        let confirmed = buffer.insert(hypothesis("prism is listening"))
        XCTAssertTrue(confirmed.isEmpty)
        XCTAssertTrue(buffer.committed.isEmpty)
        XCTAssertEqual(text(buffer.provisional), ["prism", "is", "listening"])
        XCTAssertTrue(buffer.provisional.allSatisfy { $0.state == .pending })
    }

    // MARK: - Agreement across decodes

    func testTwoIdenticalHypothesesConfirmAllOfIt() {
        var buffer = HypothesisBuffer()
        let heard = hypothesis("prism is listening")
        buffer.insert(heard)
        let confirmed = buffer.insert(heard)
        XCTAssertEqual(text(confirmed), ["prism", "is", "listening"])
        XCTAssertTrue(confirmed.allSatisfy { $0.state == .final })
        XCTAssertEqual(text(buffer.committed), ["prism", "is", "listening"])
        XCTAssertTrue(buffer.provisional.isEmpty)
    }

    func testDivergenceAfterThreeWordsConfirmsExactlyThoseThree() {
        var buffer = HypothesisBuffer()
        buffer.insert(hypothesis("the model has changed its mind"))
        let confirmed = buffer.insert(hypothesis("the model has other ideas entirely"))
        XCTAssertEqual(text(confirmed), ["the", "model", "has"])
        XCTAssertEqual(text(buffer.provisional), ["other", "ideas", "entirely"])
    }

    func testARestyledWordStillSettlesAndKeepsTheNewerSpelling() {
        var buffer = HypothesisBuffer()
        buffer.insert(hypothesis("prism is live"))
        let dressed = [
            TranscriptWord(text: "Prism", startMs: 0, endMs: 250, channel: .directMic),
            TranscriptWord(text: " is", startMs: 300, endMs: 550, channel: .directMic),
            TranscriptWord(text: "live.", startMs: 600, endMs: 850, channel: .directMic),
        ]
        let confirmed = buffer.insert(dressed)
        XCTAssertEqual(confirmed.count, 3)
        // The newer decode heard more audio around the word, so its
        // capitalisation and its full stop are the ones that survive.
        XCTAssertEqual(text(buffer.committed), ["Prism", "is", "live."])
    }

    func testAThirdHypothesisExtendsTheConfirmationWithoutRepeatingIt() {
        var buffer = HypothesisBuffer()
        buffer.insert(hypothesis("one two three"))
        XCTAssertEqual(text(buffer.insert(hypothesis("one two three four five"))),
                       ["one", "two", "three"])
        // The third decode still re-emits the whole window, including words
        // already committed. Only the newly agreed pair may come out.
        XCTAssertEqual(text(buffer.insert(hypothesis("one two three four five six"))),
                       ["four", "five"])
        XCTAssertEqual(text(buffer.committed),
                       ["one", "two", "three", "four", "five"])
        XCTAssertEqual(text(buffer.provisional), ["six"])
    }

    func testCommittedWordsAreNeverDuplicatedAcrossDecodes() {
        var buffer = HypothesisBuffer()
        for length in 3...8 {
            let sentence = ["one", "two", "three", "four", "five",
                            "six", "seven", "eight"].prefix(length).joined(separator: " ")
            buffer.insert(hypothesis(sentence))
        }
        XCTAssertEqual(text(buffer.committed),
                       ["one", "two", "three", "four", "five", "six", "seven"])
        XCTAssertEqual(Set(buffer.committed.map(\.id)).count, buffer.committed.count)
    }

    func testAWordKeepsItsIdFromProvisionalThroughSettled() {
        // The UI transitions a row in place rather than deleting one and
        // inserting another, and a late correction aimed at the provisional
        // word still names the committed one.
        var buffer = HypothesisBuffer()
        buffer.insert(hypothesis("one two three"))
        let provisionalIds = buffer.provisional.map(\.id)
        buffer.insert(hypothesis("one two three"))
        XCTAssertEqual(buffer.committed.map(\.id), provisionalIds)
    }

    // MARK: - Never un-committing

    func testAShrunkHypothesisNeverUncommitsAnything() {
        var buffer = HypothesisBuffer()
        let full = hypothesis("alpha beta gamma delta")
        buffer.insert(full)
        buffer.insert(full)
        XCTAssertEqual(buffer.committed.count, 4)

        // The model revised its mind and emitted fewer words. Everything it
        // dropped has already been read; it stays exactly as it was drawn.
        let confirmed = buffer.insert(hypothesis("alpha beta"))
        XCTAssertTrue(confirmed.isEmpty)
        XCTAssertEqual(text(buffer.committed), ["alpha", "beta", "gamma", "delta"])
    }

    func testAContradictoryHypothesisCannotRewriteCommittedText() {
        var buffer = HypothesisBuffer()
        let heard = hypothesis("we shipped it")
        buffer.insert(heard)
        buffer.insert(heard)
        buffer.insert(hypothesis("we sank it entirely"))
        XCTAssertEqual(text(buffer.committed), ["we", "shipped", "it"])
    }

    // MARK: - The n-gram guard

    /// Six words ending at 1750 ms, the committed run every guard test
    /// compares against.
    private var committedRun: [TranscriptWord] {
        hypothesis("one two three four five six")
    }

    func testTheGuardDropsAOneWordRepeat() {
        let repeated = hypothesis("six seven eight", from: 1_500)
        let kept = LocalAgreement.droppingRepeatedPrefix(repeated, after: committedRun)
        XCTAssertEqual(text(kept), ["seven", "eight"])
    }

    func testTheGuardDropsAThreeWordRepeat() {
        let repeated = hypothesis("four five six seven eight", from: 900)
        let kept = LocalAgreement.droppingRepeatedPrefix(repeated, after: committedRun)
        XCTAssertEqual(text(kept), ["seven", "eight"])
    }

    func testTheGuardDropsAFiveWordRepeat() {
        // Re-decoded 100 ms early, which is exactly why the time trim alone
        // cannot catch this and the guard has to.
        let repeated = hypothesis("two three four five six seven", from: 800)
        let kept = LocalAgreement.droppingRepeatedPrefix(repeated, after: committedRun)
        XCTAssertEqual(text(kept), ["seven"])
    }

    func testTheGuardIgnoresAHypothesisThatStartsOutsideTheWindow() {
        // Far past the committed text: the model has moved on, and a phrase
        // matching here is speech repeating itself, not a re-emission.
        let later = hypothesis("four five six seven eight", from: 5_000)
        let kept = LocalAgreement.droppingRepeatedPrefix(later, after: committedRun)
        XCTAssertEqual(text(kept), ["four", "five", "six", "seven", "eight"])
    }

    func testTheGuardReachesNoFurtherThanFiveWordsBack() {
        // whisper_streaming's cap, kept deliberately: matching further back
        // starts deleting words somebody genuinely said twice.
        let repeated = hypothesis("one two three four five six seven", from: 800)
        let kept = LocalAgreement.droppingRepeatedPrefix(repeated, after: committedRun)
        XCTAssertEqual(kept.count, 7)
    }

    func testTheGuardLeavesAnUnrelatedHypothesisAlone() {
        let fresh = hypothesis("seven eight nine", from: 1_800)
        let kept = LocalAgreement.droppingRepeatedPrefix(fresh, after: committedRun)
        XCTAssertEqual(text(kept), ["seven", "eight", "nine"])
    }

    func testTheGuardIsANoOpBeforeAnythingIsCommitted() {
        let first = hypothesis("one two three")
        XCTAssertEqual(LocalAgreement.droppingRepeatedPrefix(first, after: []), first)
    }

    // MARK: - Reset

    func testResetClearsCommittedAndProvisional() {
        var buffer = HypothesisBuffer()
        buffer.insert(hypothesis("one two three"))
        buffer.insert(hypothesis("one two three four"))
        XCTAssertFalse(buffer.committed.isEmpty)
        XCTAssertFalse(buffer.provisional.isEmpty)

        buffer.reset()
        XCTAssertTrue(buffer.committed.isEmpty)
        XCTAssertTrue(buffer.provisional.isEmpty)
        // And the next hypothesis is a first hypothesis again: nothing left
        // over from before the reset may confirm it.
        XCTAssertTrue(buffer.insert(hypothesis("one two three")).isEmpty)
    }
}
