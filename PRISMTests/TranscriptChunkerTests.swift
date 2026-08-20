// TranscriptChunkerTests.swift
// PRISMTests
//
// The splitter that decides how much of a meeting a small model gets to see
// (§5.32).
//
// Two classes of bug live here and neither of them arrives as a crash. The
// first is a chunk that quietly overruns the window — the estimate drifts,
// or the prompt reserve gets spent twice, and one notes run in twenty comes
// back stopping mid-sentence with no error anywhere. The second is a loop
// that does not terminate, or terminates after ten thousand near-identical
// chunks. Progress per iteration is the break point minus the overlap, and
// both of those are caller-influenced, so an overlap wider than the budget
// or a text with no spaces in it is enough to hang a notes run. Neither
// adversarial case is hypothetical: a hundred-thousand-character "word" is
// what a transcript of a screen-shared terminal or a pasted stack trace
// looks like.
//
// The seam tests are the ones worth reading. Chunks are only useful if they
// overlap and only correct if, laid end to end with the overlap discounted,
// they are the original text — no gap, no reordering, nothing dropped. Both
// long-input tests rebuild the input from the chunks and compare, which is
// a stronger claim than counting them.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class TranscriptChunkerTests: XCTestCase {

    // MARK: - Fixtures

    /// Meeting-shaped prose: ordinary word lengths, a sentence end every
    /// ninth word, and deliberately aperiodic. Aperiodic matters — the seam
    /// checks below look for the longest repeated run between two chunks,
    /// and text that repeats on a fixed cycle can hand them a coincidence
    /// instead of the real overlap.
    private func transcript(wordCount: Int, seed: UInt64 = 0x5EED_1234) -> String {
        let vocabulary = ["we", "should", "ship", "the", "beta", "before",
                          "review", "Marta", "will", "own", "rollout",
                          "budget", "slipped", "again", "quarter", "hiring",
                          "freeze", "ends", "in", "March", "nobody", "signed",
                          "off", "yet", "revisit", "Thursday", "instead"]
        var state = seed
        var words: [String] = []
        words.reserveCapacity(wordCount)
        for index in 0..<wordCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let word = vocabulary[Int((state >> 33) % UInt64(vocabulary.count))]
            words.append(index % 9 == 8 ? word + "." : word)
        }
        return words.joined(separator: " ")
    }

    /// How many trailing characters of `a` are also the leading characters
    /// of `b` — the seam two consecutive chunks share.
    private func seamLength(_ a: [Character], _ b: [Character]) -> Int {
        var length = min(a.count, b.count)
        while length > 0 {
            let offset = a.count - length
            var index = 0
            while index < length, a[offset + index] == b[index] {
                index += 1
            }
            if index == length { return length }
            length -= 1
        }
        return 0
    }

    /// Lays the chunks end to end, discounting each seam. If the chunker is
    /// correct this is the input again, exactly.
    private func rebuild(_ chunks: [String]) -> String {
        guard var result = chunks.first.map(Array.init) else { return "" }
        for chunk in chunks.dropFirst() {
            let next = Array(chunk)
            result.append(contentsOf: next.dropFirst(seamLength(result, next)))
        }
        return String(result)
    }

    // MARK: - The estimate

    func testRoughTokenCountIsTheCeilingOfThirtyFivePercentOfTheCharacters() {
        XCTAssertEqual(TranscriptChunker.roughTokenCount("abcdefghij"), 4)
        XCTAssertEqual(TranscriptChunker.roughTokenCount(""), 0)
        XCTAssertEqual(TranscriptChunker.roughTokenCount("a"), 1)
        // Twenty characters is where 0.35 lands on a whole number, and where
        // a floating-point ceiling would be free to answer either 7 or 8.
        XCTAssertEqual(TranscriptChunker.roughTokenCount(String(repeating: "a", count: 20)), 7)
        XCTAssertEqual(TranscriptChunker.roughTokenCount(String(repeating: "a", count: 21)), 8)
        XCTAssertEqual(TranscriptChunker.roughTokenCount(String(repeating: "a", count: 100)), 35)
    }

    // MARK: - Not splitting

    func testATextThatFitsIsReturnedUnchangedAsOneChunk() {
        let text = transcript(wordCount: 100)
        let chunks = TranscriptChunker.chunks(text, tokenBudget: 1_000)
        XCTAssertEqual(chunks, [text])
        // Not merely equal in content: the caller may have built structure
        // into the string that the model is meant to see, so nothing here
        // trims or normalises it.
        XCTAssertEqual(chunks.first?.count, text.count)
    }

    func testNothingToSummariseProducesNoChunks() {
        // An empty array, not an array holding one blank string: the map
        // stage should make no request at all rather than one about nothing.
        XCTAssertEqual(TranscriptChunker.chunks("", tokenBudget: 1_000), [])
        XCTAssertEqual(TranscriptChunker.chunks("   \n\t  ", tokenBudget: 1_000), [])
        // The empty check runs before the degenerate-budget guard, so a bad
        // budget cannot resurrect an empty transcript as a chunk.
        XCTAssertEqual(TranscriptChunker.chunks("  ", tokenBudget: 200), [])
    }

    // MARK: - Splitting

    func testNoChunkEverExceedsTheTokenBudget() {
        let text = transcript(wordCount: 3_000)
        let chunks = TranscriptChunker.chunks(text, tokenBudget: 1_000)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(TranscriptChunker.roughTokenCount(chunk), 1_000)
        }
        XCTAssertEqual(rebuild(chunks), text)
    }

    func testEachChunkRepeatsTheTailOfTheOneBefore() {
        let text = transcript(wordCount: 3_000)
        let chunks = TranscriptChunker.chunks(text, tokenBudget: 1_000, overlapTokens: 100)
        XCTAssertGreaterThan(chunks.count, 1)
        let pieces = chunks.map(Array.init)
        for (index, pair) in zip(pieces, pieces.dropFirst()).enumerated() {
            // A floor, not an equality. The exact seam depends on the
            // token-to-character conversion and on the half-chunk clamp, and
            // pinning it would fail on any retune of a constant that has not
            // actually broken the property under test — which is only that a
            // sentence straddling the boundary is seen twice, not halved.
            XCTAssertGreaterThanOrEqual(seamLength(pair.0, pair.1), 100,
                                        "chunk \(index + 1) does not restate the tail of chunk \(index)")
        }
    }

    // MARK: - Where the cut lands

    func testABoundaryPrefersTheEndOfASentence() {
        // Budget 335 leaves 35 usable tokens, which is 100 characters, and
        // the backwards search covers the last 50 of them.
        let sentence = String(repeating: "a", count: 78) + ". "
        let text = sentence + String(repeating: "b", count: 220)
        let chunks = TranscriptChunker.chunks(text, tokenBudget: 335)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.first, sentence)
        XCTAssertEqual(chunks.first?.count, 80)
    }

    func testABoundaryFallsBackToASpaceWhenNoSentenceEnds() {
        // Same geometry, no period anywhere: the cut must still land on the
        // space rather than in the middle of the run of b's.
        let head = String(repeating: "a", count: 79) + " "
        let text = head + String(repeating: "b", count: 220)
        let chunks = TranscriptChunker.chunks(text, tokenBudget: 335)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.first, head)
        XCTAssertEqual(chunks.first?.last, " ")
    }

    // MARK: - Adversarial input

    func testAHundredThousandCharacterWordIsSplitAndFullyCovered() {
        // No space and no period anywhere, so every boundary is a hard cut.
        // Built from zero-padded counters rather than a repeated character
        // so the rebuild below cannot be satisfied by a coincidence.
        let word = (0..<20_000).map { index -> String in
            let digits = String(index)
            return String(repeating: "0", count: 5 - digits.count) + digits
        }.joined()
        XCTAssertEqual(word.count, 100_000)

        let chunks = TranscriptChunker.chunks(word, tokenBudget: 1_000)
        XCTAssertGreaterThan(chunks.count, 1)
        // Terminating is not enough — advancing one character at a time also
        // terminates, and would issue a hundred thousand prompts.
        XCTAssertLessThan(chunks.count, 200)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(TranscriptChunker.roughTokenCount(chunk), 1_000)
        }
        XCTAssertEqual(rebuild(chunks), word)
    }

    func testAnOverlapWiderThanTheBudgetStillMakesProgress() {
        // 310 tokens leaves 10 usable, which is 28 characters, against an
        // overlap request of five thousand tokens. Unclamped, every chunk
        // would start before the previous one did.
        let text = transcript(wordCount: 300)
        let chunks = TranscriptChunker.chunks(text, tokenBudget: 310, overlapTokens: 5_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks.count, text.count)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(TranscriptChunker.roughTokenCount(chunk), 310)
        }
        XCTAssertEqual(rebuild(chunks), text)
    }

    func testABudgetBelowThePromptReserveReturnsTheWholeTextRatherThanHanging() {
        // There is no room for text at all once the prompt is paid for. The
        // honest failure is to hand the caller everything and let the model
        // truncate it, which is visible; returning [] drops the meeting and
        // looping on a zero-width chunk never returns.
        let text = transcript(wordCount: 400)
        XCTAssertEqual(TranscriptChunker.chunks(text, tokenBudget: 200), [text])
        XCTAssertEqual(TranscriptChunker.chunks(text, tokenBudget: 300), [text])
    }

    // MARK: - Agreement between the two entry points

    func testFitsInOnePassAndChunksAgreeOnTheBoundary() {
        let text = String(repeating: "a", count: 100)
        XCTAssertEqual(TranscriptChunker.roughTokenCount(text), 35)

        // 35 tokens of text plus the 300-token reserve is exactly 335.
        XCTAssertTrue(TranscriptChunker.fitsInOnePass(text, contextBudget: 335))
        XCTAssertFalse(TranscriptChunker.fitsInOnePass(text, contextBudget: 334))

        // And the splitter draws the line in the same place, which is the
        // point: a caller told the text fits must not then get two chunks.
        XCTAssertEqual(TranscriptChunker.chunks(text, tokenBudget: 335), [text])
        XCTAssertGreaterThan(TranscriptChunker.chunks(text, tokenBudget: 334).count, 1)
    }
}
