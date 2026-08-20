// WhisperKitEngine.swift
// PRISM
//
// The one file in PRISM that imports a third-party package (§5.32).
//
// Everything WhisperKit-shaped stops here. The rest of the app talks to
// `SpeechRecognizing` and handles PRISM's own value types, so the package
// has exactly one point of contact with this codebase and project.yml
// excludes this directory from the test target — which is how the suite
// still builds ad-hoc signed on a checkout with nothing resolved.
//
// An actor, not a class with a queue, for a specific reason: WhisperKit's
// `TranscriptionResult` is a reference type whose own documentation warns
// that read-modify-write on its segments is not thread-safe, and the
// transcription entry points are `async`. Two overlapping decodes would
// race inside the package rather than inside PRISM, which is the worst
// place for a race to live. Serialising here makes that impossible to get
// wrong from the outside.
//
// This engine never opens a microphone. WhisperKit is perfectly capable of
// doing so — `AudioProcessor` will happily build an `AVAudioEngine` and
// start recording — and it must not, because PRISM already owns the
// microphone, publishes it as a virtual device, and applies §5.17 cleanup
// and §5.13 effects to it. Constructing `WhisperKit` does not touch audio
// hardware; only `startRecordingLive` does, and it is never called. Audio
// arrives here as a plain `[Float]` that PRISM captured, converted and
// gated itself.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import WhisperKit

actor WhisperKitEngine: SpeechRecognizing {

    private let model: SpeechModel
    private let modelsDirectory: URL
    private var whisper: WhisperKit?

    init(model: SpeechModel, modelsDirectory: URL = SpeechModelCatalog.directory) {
        self.model = model
        self.modelsDirectory = modelsDirectory
    }

    var supportsWordTimestamps: Bool {
        // The decoder advertises this; the tiny models do support it, but
        // asking rather than assuming means a future variant that does not
        // degrades to segment timings instead of returning nothing.
        whisper?.textDecoder.supportsWordTimestamps ?? false
    }

    // MARK: - Lifecycle

    func load(progress: @escaping (SpeechModelState) -> Void) async throws {
        if whisper != nil {
            progress(.ready)
            return
        }

        try FileManager.default.createDirectory(at: modelsDirectory,
                                                withIntermediateDirectories: true)

        // Download first, explicitly, rather than letting the constructor do
        // it silently. The constructor would work, but it reports nothing
        // until it finishes, and "nothing for four minutes" is
        // indistinguishable from a hang on a first run.
        if !SpeechModelCatalog.isDownloaded(model) {
            progress(.downloading(0))
            do {
                _ = try await WhisperKit.download(
                    variant: model.variant,
                    downloadBase: modelsDirectory,
                    useBackgroundSession: false,
                    from: SpeechModelCatalog.modelRepo,
                    progressCallback: { fraction in
                        progress(.downloading(fraction.fractionCompleted))
                    })
            } catch {
                let message = error.localizedDescription
                progress(.failed(message))
                throw SpeechEngineError.downloadFailed(message)
            }
        }

        progress(.loading)
        do {
            let config = WhisperKitConfig(
                model: model.variant,
                downloadBase: modelsDirectory,
                modelRepo: SpeechModelCatalog.modelRepo,
                verbose: false,
                logLevel: .error,
                // Core ML specialises a model to the chip on first load and
                // caches the result outside the app bundle. Prewarming does
                // that one model at a time, which keeps the peak memory of
                // a first run well under the §5.23 budget instead of
                // holding every weight plus the compiler's own working set.
                prewarm: true,
                load: true,
                download: true)
            whisper = try await WhisperKit(config)
            progress(.ready)
        } catch {
            let message = error.localizedDescription
            progress(.failed(message))
            throw SpeechEngineError.modelUnavailable(message)
        }
    }

    func unload() async {
        // Dropping the reference is the unload: WhisperKit releases its
        // Core ML models when it deinitialises. §5.23 requires this on
        // meeting stop — a quarter of a gigabyte resident for a feature
        // nobody is using is exactly what the resource budget exists to
        // prevent.
        whisper = nil
    }

    // MARK: - Decode

    func transcribe(_ request: SpeechRequest,
                    channel: ChannelProfile) async throws -> SpeechHypothesis {
        guard let whisper else { throw SpeechEngineError.notLoaded }
        guard !request.samples16k.isEmpty else { return SpeechHypothesis() }

        var options = DecodingOptions()
        options.verbose = false
        options.task = .transcribe
        options.language = request.language
        options.wantsWordTimestampsIfPossible(request.wantsWordTimestamps)
        options.withoutTimestamps = false
        // Conditioning the decode on the tail of what is already confirmed.
        // This is what keeps a proper noun spelled the same way in two
        // consecutive sentences.
        if !request.prefixTokens.isEmpty {
            options.prefixTokens = request.prefixTokens
        }
        // Everything before this point is context the model may read but
        // must not re-emit. Re-decoding with the previous sentence in the
        // window is what makes the second hypothesis agree with the first,
        // which is the whole basis of `LocalAgreement`.
        if request.clipFromSeconds > 0 {
            options.clipTimestamps = [request.clipFromSeconds]
        }
        // The rolling buffer is already VAD-gated and short, so the
        // package's own chunker has nothing to do and would only introduce
        // a second, differently-tuned segmentation policy.
        options.chunkingStrategy = nil
        // Whisper's failure mode on near-silence is a confident subtitle
        // credit, not an empty string. These are the thresholds that make it
        // give up instead; `TranscriptSanitizer` catches what still gets
        // through.
        options.noSpeechThreshold = 0.6
        options.compressionRatioThreshold = 2.4
        options.logProbThreshold = -1.0

        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(
                audioArray: request.samples16k,
                decodeOptions: options)
        } catch {
            throw SpeechEngineError.decodeFailed(error.localizedDescription)
        }

        return Self.hypothesis(from: results,
                               sampleOffset: request.sampleOffset,
                               channel: channel)
    }

    // MARK: - Mapping

    /// WhisperKit's word timings are seconds relative to the buffer that was
    /// decoded. PRISM's are milliseconds from the start of the meeting. The
    /// shift happens here, once, rather than at every call site — a
    /// buffer-relative timestamp that escapes this function is a bug that
    /// only surfaces after the first trim, by which time the transcript has
    /// silently rewound.
    static func hypothesis(from results: [TranscriptionResult],
                           sampleOffset: Int,
                           channel: ChannelProfile) -> SpeechHypothesis {
        let offsetMs = Int64((Double(sampleOffset) / 16_000.0) * 1000.0)
        var words: [TranscriptWord] = []
        var tokens: [[Int]] = []
        var text = ""

        for result in results {
            text += result.text
            let timings = result.allWords
            if !timings.isEmpty {
                for timing in timings {
                    let trimmed = timing.word.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    words.append(TranscriptWord(
                        text: timing.word,
                        startMs: offsetMs + Int64(timing.start * 1000),
                        endMs: offsetMs + Int64(timing.end * 1000),
                        channel: channel,
                        state: .final))
                    tokens.append(timing.tokens)
                }
            } else {
                // No word timings: fall back to segment times, splitting the
                // segment's text evenly across its duration. Coarse, but the
                // two-stream merge only needs enough resolution to order
                // one speaker's run against another's, and a segment is
                // already far shorter than a turn.
                for segment in result.segments {
                    let pieces = segment.text
                        .split(separator: " ", omittingEmptySubsequences: true)
                        .map(String.init)
                    guard !pieces.isEmpty else { continue }
                    let spanMs = max(1, Int64((segment.end - segment.start) * 1000))
                    let per = max(1, spanMs / Int64(pieces.count))
                    let base = offsetMs + Int64(segment.start * 1000)
                    for (index, piece) in pieces.enumerated() {
                        let start = base + per * Int64(index)
                        words.append(TranscriptWord(
                            text: piece,
                            startMs: start,
                            endMs: start + per,
                            channel: channel,
                            state: .final))
                        tokens.append(segment.tokens)
                    }
                }
            }
        }

        return SpeechHypothesis(words: words, tokensByWord: tokens, text: text)
    }
}

// MARK: - Option helpers

private extension DecodingOptions {
    /// Word timestamps cost a second decoder pass with cross-attention
    /// alignment. Worth it — the two-stream merge and the action-item
    /// citations both depend on knowing when a word was said — but asked
    /// for explicitly so the cost is visible at the call site.
    mutating func wantsWordTimestampsIfPossible(_ wanted: Bool) {
        wordTimestamps = wanted
    }
}
