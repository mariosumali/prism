// TranscriptDeltaTests.swift
// PRISMTests
//
// The stitcher's two promises: no word twice, no word lost (§5.32).
//
// Both failure modes are invisible in a thirty-second demo and obvious in a
// recording of a real meeting, which is the worst place to find them. A
// duplicate reads as a stutter — "I think I think we should" — and looks
// like the recogniser's fault. A dropped word reads as a sentence that
// almost makes sense, and nobody ever traces it back here, because the
// transcript has no gap where the word used to be.
//
// So these tests live at the seams: the exact millisecond at which a word is
// or is not below the watermark, the word held back at the end of every
// batch, and the three conditions that decide whether two half-words are one
// word. The held word gets the most attention because it is the only piece
// of state that can be lost outright — emitted twice if a stitch forgets it
// was already out, or never at all if the stream ends between batches.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class TranscriptDeltaTests: XCTestCase {

    private func word(_ text: String, _ startMs: Int64, _ endMs: Int64) -> TranscriptWord {
        TranscriptWord(text: text, startMs: startMs, endMs: endMs, channel: .directMic)
    }

    // MARK: - Dedup

    func testDedupDropsWordsThatEndAtOrBeforeTheMark() {
        let words = [word(" a", 0, 100), word(" b", 100, 200),
                     word(" c", 200, 300), word(" d", 300, 400)]
        let kept = TranscriptChannelState.dedup(words, mark: 200)
        XCTAssertEqual(kept.map(\.text), [" c", " d"])
    }

    func testDedupTreatsTheMarkItselfAsAlreadySeen() {
        // The word ending exactly on the mark is the one the previous batch
        // finished with. Off by one here duplicates a word per batch.
        let onTheMark = [word(" a", 400, 500)]
        XCTAssertTrue(TranscriptChannelState.dedup(onTheMark, mark: 500).isEmpty)

        let oneMillisecondPast = [word(" a", 400, 501)]
        XCTAssertEqual(TranscriptChannelState.dedup(oneMillisecondPast, mark: 500).count, 1)
    }

    func testDedupOfAnEmptyBatchIsEmpty() {
        XCTAssertTrue(TranscriptChannelState.dedup([], mark: 0).isEmpty)
    }

    // MARK: - Idempotence

    func testResubmittingAnIdenticalFinalBatchChangesNothing() {
        var state = TranscriptChannelState(channel: .directMic)
        let batch = [word(" one", 0, 100), word(" two", 100, 200), word(" three", 200, 300)]

        let first = state.applyFinal(batch)
        XCTAssertEqual(first.newWords.map(\.text), [" one", " two"])

        // The recogniser resends the same three seconds, as they all do.
        let second = state.applyFinal(batch)
        XCTAssertTrue(second.isEmpty)
    }

    func testAPartialInsideAnAlreadyFinalRegionContributesNothing() {
        var state = TranscriptChannelState(channel: .directMic)
        _ = state.applyFinal([word(" hello", 0, 500), word(" world", 500, 1000)])

        let preview = state.applyPartial([word(" hello", 0, 500), word(" world", 500, 1000)])
        XCTAssertTrue(preview.isEmpty)
    }

    func testAStalePreviewCannotReappearUnderneathAFinal() {
        var state = TranscriptChannelState(channel: .directMic)
        // The preview runs ahead: two words, out to 2000 ms.
        _ = state.applyPartial([word(" a", 0, 1000), word(" b", 1000, 2000)])
        // A final lands behind it, covering only the first.
        _ = state.applyFinal([word(" a", 0, 1000), word(" b", 1000, 1200)])
        XCTAssertEqual(state.watermark, 1200)

        // A late copy of the old preview arrives. Deduping against the
        // partial mark alone would let it back in below the final.
        let stale = state.applyPartial([word(" a", 0, 1000), word(" b", 1000, 1500)])
        XCTAssertEqual(stale.partials.count, 1)
        XCTAssertTrue(stale.partials.allSatisfy { $0.endMs > state.watermark })
    }

    // MARK: - The held word

    func testTheHeldWordIsEmittedExactlyOnceAcrossTwoBatches() {
        var state = TranscriptChannelState(channel: .directMic)
        let a = word(" a", 0, 100)
        let b = word(" b", 100, 200)
        let c = word(" c", 900, 1000)
        let d = word(" d", 1000, 1100)

        var emitted: [String] = []
        let first = state.applyFinal([a, b])
        XCTAssertEqual(first.newWords.map(\.text), [" a"], "b is held for stitching")
        emitted += first.newWords.map(\.id)

        let second = state.applyFinal([a, b, c, d])
        XCTAssertEqual(second.newWords.map(\.text), [" b", " c"])
        emitted += second.newWords.map(\.id)

        emitted += state.finish().newWords.map(\.id)

        XCTAssertEqual(emitted, [a.id, b.id, c.id, d.id])
        XCTAssertEqual(Set(emitted).count, emitted.count, "no word emitted twice")
    }

    func testTheHeldWordIsEmittedOnFinishWhenNoSecondBatchArrives() {
        var state = TranscriptChannelState(channel: .directMic)
        let a = word(" a", 0, 100)
        let b = word(" b", 100, 200)
        _ = state.applyFinal([a, b])

        let end = state.finish()
        XCTAssertEqual(end.newWords.map(\.id), [b.id])

        // Whatever calls finish twice — teardown racing a stop — gets nothing.
        let again = state.finish()
        XCTAssertTrue(again.isEmpty)
    }

    func testEveryWordSurvivesAStreamOfOverlappingBatches() {
        // The whole contract in one run: twenty words handed over in four
        // heavily overlapping batches, the way a recogniser actually emits.
        var state = TranscriptChannelState(channel: .directMic)
        let words = (0..<20).map { word(" w\($0)", Int64($0) * 100, Int64($0 + 1) * 100) }
        let batches = [0..<5, 2..<8, 5..<12, 9..<20]

        var emitted: [TranscriptWord] = []
        for range in batches {
            emitted += state.applyFinal(Array(words[range])).newWords
        }
        emitted += state.finish().newWords

        XCTAssertEqual(emitted.map(\.id), words.map(\.id))
        XCTAssertEqual(emitted.map(\.text).joined(),
                       words.map(\.text).joined())
    }

    // MARK: - Stitching

    func testAStitchJoinsASplitWordIntoOne() {
        var state = TranscriptChannelState(channel: .directMic)
        let head = word("Hel", 0, 100)
        _ = state.applyFinal([head])

        let delta = state.applyFinal([word("lo", 120, 300), word(" there", 300, 500)])
        XCTAssertEqual(delta.newWords.count, 1)
        let joined = delta.newWords[0]
        XCTAssertEqual(joined.text, "Hello")
        XCTAssertEqual(joined.startMs, 0, "the joined word starts where the tail did")
        XCTAssertEqual(joined.endMs, 300, "and ends where the head did")
        XCTAssertEqual(joined.id, head.id)
        XCTAssertTrue(delta.replacedIds.isEmpty,
                      "the tail was never emitted, so there is nothing to replace")
    }

    func testAStitchOntoAnEmittedWordReplacesIt() {
        var state = TranscriptChannelState(channel: .directMic)
        let head = word("Hel", 0, 100)
        _ = state.applyFinal([head])
        let end = state.finish()
        XCTAssertEqual(end.newWords.map(\.id), [head.id])

        // The stream resumes mid-word. Now the tail is in the consumer's
        // store, so joining onto it is a correction rather than a first sight.
        let delta = state.applyFinal([word("lo", 120, 300), word(" again", 300, 500)])
        XCTAssertEqual(delta.replacedIds, [head.id])
        XCTAssertEqual(delta.newWords.map(\.text), ["Hello"])
        XCTAssertEqual(delta.newWords.first?.id, head.id)
    }

    func testAReplacementIsNeverHeldBackWithoutItsWord() {
        // The dangerous shape: the joined word is also the batch's last word,
        // so the usual hold-back rule would retract a word from the store and
        // put nothing in its place until the next batch — or forever.
        var state = TranscriptChannelState(channel: .directMic)
        let head = word("Hel", 0, 100)
        _ = state.applyFinal([head])
        _ = state.finish()

        let delta = state.applyFinal([word("lo", 120, 300)])
        XCTAssertEqual(delta.replacedIds, [head.id])
        XCTAssertEqual(delta.newWords.map(\.text), ["Hello"])
    }

    func testASentenceBoundaryPreventsAStitch() {
        var state = TranscriptChannelState(channel: .directMic)
        _ = state.applyFinal([word("end.", 0, 100)])

        // 20 ms apart and no leading space, so only the boundary rule can
        // save this from becoming "end.Next".
        let delta = state.applyFinal([word("Next", 120, 200), word(" more", 200, 300)])
        XCTAssertEqual(delta.newWords.map(\.text), ["end.", "Next"])
    }

    func testAPeriodWithoutACapitalIsNotASentenceBoundary() {
        // Decimals and abbreviations are why the rule needs both halves.
        var state = TranscriptChannelState(channel: .directMic)
        _ = state.applyFinal([word("3.", 0, 100)])

        let delta = state.applyFinal([word("5", 100, 200), word(" percent", 200, 300)])
        XCTAssertEqual(delta.newWords.map(\.text), ["3.5"])
    }

    func testALeadingSpaceOnTheHeadPreventsAStitch() {
        var state = TranscriptChannelState(channel: .directMic)
        _ = state.applyFinal([word("Hel", 0, 100)])

        let delta = state.applyFinal([word(" lo", 120, 300), word(" there", 300, 500)])
        XCTAssertEqual(delta.newWords.map(\.text), ["Hel", " lo"])
    }

    func testAGapWiderThanTheStitchWindowPreventsAStitch() {
        var state = TranscriptChannelState(channel: .directMic)
        _ = state.applyFinal([word("Hel", 0, 100)])

        // 301 ms of silence between the two halves.
        let delta = state.applyFinal([word("lo", 401, 600), word(" there", 600, 800)])
        XCTAssertEqual(delta.newWords.map(\.text), ["Hel", "lo"])
    }

    func testAGapExactlyAtTheStitchWindowStillStitches() {
        var state = TranscriptChannelState(channel: .directMic)
        _ = state.applyFinal([word("Hel", 0, 100)])

        let start = 100 + TranscriptChannelState.maxStitchGapMs
        let delta = state.applyFinal([word("lo", start, 600), word(" there", 600, 800)])
        XCTAssertEqual(delta.newWords.map(\.text), ["Hello"])
    }

    // MARK: - Watermark

    func testTheWatermarkNeverDecreases() {
        var state = TranscriptChannelState(channel: .directMic)
        _ = state.applyFinal([word(" a", 4000, 4500), word(" b", 4500, 5000)])
        XCTAssertEqual(state.watermark, 5000)

        // A late batch from a recogniser that restarted its own clock, or a
        // retry that arrived after the batch behind it.
        let late = state.applyFinal([word(" x", 0, 100), word(" y", 100, 200)])
        XCTAssertTrue(late.isEmpty)
        XCTAssertEqual(state.watermark, 5000)
    }

    func testTheWatermarkCoversTheHeldWord() {
        // Otherwise the next copy of the same batch looks like news, which is
        // the duplicate this whole file exists to prevent.
        var state = TranscriptChannelState(channel: .directMic)
        _ = state.applyFinal([word(" a", 0, 100), word(" b", 100, 200)])
        XCTAssertEqual(state.watermark, 200)
    }

    // MARK: - Bounding

    func testPreviewStateStaysUnderTheWordCap() {
        var state = TranscriptChannelState(channel: .farEnd)
        var delta = TranscriptDelta()
        // Four thousand preview words, 100 ms apart: nearly seven minutes of
        // speech nobody ever finalised.
        for index in 0..<4_000 {
            let start = Int64(index) * 100
            delta = state.applyPartial([
                TranscriptWord(text: " w\(index)", startMs: start, endMs: start + 100,
                               channel: .farEnd, state: .pending)
            ])
        }
        XCTAssertLessThanOrEqual(delta.partials.count,
                                 TranscriptChannelState.maxPartialWords)
        XCTAssertFalse(delta.partials.isEmpty)
    }

    func testPreviewStateStaysInsideTheTimeWindow() {
        var state = TranscriptChannelState(channel: .farEnd)
        var delta = TranscriptDelta()
        // Long words, so the count cap never fires and the window has to.
        for index in 0..<400 {
            let start = Int64(index) * 1_000
            delta = state.applyPartial([
                TranscriptWord(text: " w\(index)", startMs: start, endMs: start + 1_000,
                               channel: .farEnd, state: .pending)
            ])
        }
        guard let first = delta.partials.first, let last = delta.partials.last else {
            return XCTFail("expected a preview")
        }
        XCTAssertLessThanOrEqual(last.endMs - first.startMs,
                                 TranscriptChannelState.maxPartialWindowMs)
        XCTAssertLessThanOrEqual(delta.partials.count,
                                 TranscriptChannelState.maxPartialWords)
    }

    // MARK: - Reset

    func testResetForgetsEverything() {
        var state = TranscriptChannelState(channel: .directMic)
        let batch = [word(" a", 0, 100), word(" b", 100, 200)]
        _ = state.applyFinal(batch)
        _ = state.applyPartial([word(" c", 200, 300)])

        state.reset()
        XCTAssertEqual(state.watermark, 0)
        XCTAssertEqual(state.partialWatermark, 0)

        let end = state.finish()
        XCTAssertTrue(end.isEmpty, "the held word went with the reset")

        // The same batch is news again, which is the point: reset is what a
        // new session starts from.
        let replayed = state.applyFinal(batch)
        XCTAssertEqual(replayed.newWords.map(\.text), [" a"])
    }
}
