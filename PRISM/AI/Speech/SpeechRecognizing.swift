// SpeechRecognizing.swift
// PRISM
//
// The seam between PRISM and whatever is doing the listening (§5.32).
//
// Everything above this protocol is PRISM's own code, testable with a fake
// and compiled into PRISMTests. Everything below it is one directory,
// PRISM/AI/Engines/, which is the only place in the repository that imports
// a third-party package — and which project.yml excludes from the test
// target for exactly that reason.
//
// The seam is not architectural decoration. WhisperKit's manifest declares
// macOS 13 while its README says macOS 14; if that ever turns out to be
// wrong in practice, the fallback is to build whisper.cpp's XCFramework at
// the right floor and write a different engine — and every line of the
// transcript core, the resampler, the agreement policy and the sanitizer
// survives untouched, because none of them has ever heard of WhisperKit.
// A dependency you can replace in one directory is a dependency you have
// priced correctly.
//
// The other thing this protocol encodes is that PRISM hands the recogniser
// audio it already has. WhisperKit can open a microphone itself; it must
// never be allowed to. PRISM owns the microphone, publishes it as a virtual
// device, and applies §5.17 cleanup and §5.13 effects to it — a second
// AVAudioEngine pulling the same device would be a second capture client,
// a second permission story, and a second answer to "is the mic on".
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Request

/// One decode: some 16 kHz mono audio, and everything the recogniser needs
/// to place its output in the meeting rather than in the buffer.
public struct SpeechRequest {
    /// 16 kHz mono Float32. The recogniser's native rate; converting is
    /// PRISM's job, not the model's (see `SpeechResampler`).
    public var samples16k: [Float]

    /// Where `samples16k[0]` sits in the meeting, in samples at 16 kHz.
    /// Word times come back relative to the buffer and are shifted by this
    /// on the way out — a chunk-relative timestamp is a bug that surfaces
    /// the first time the rolling buffer is trimmed.
    public var sampleOffset: Int

    /// Skip decoding the first n seconds of the buffer. The audio is still
    /// present as context for the model, which is the point: re-decoding
    /// with the previous sentence in the window is what makes the second
    /// hypothesis agree with the first.
    public var clipFromSeconds: Float

    /// Tokens the model is forced to start from — the tail of what has
    /// already been confirmed. Conditioning on prior context is worth
    /// several points of word error rate on conversational speech, and it
    /// is how proper nouns stay spelled the same way twice.
    public var prefixTokens: [Int]

    /// Language hint. An English-only model ignores it; a multilingual one
    /// needs it, because auto-detection on a three-second chunk is a coin
    /// flip and a meeting that switches language mid-sentence is rarer than
    /// a meeting the model decides is Welsh.
    public var language: String

    public var wantsWordTimestamps: Bool

    public init(samples16k: [Float],
                sampleOffset: Int,
                clipFromSeconds: Float = 0,
                prefixTokens: [Int] = [],
                language: String = "en",
                wantsWordTimestamps: Bool = true) {
        self.samples16k = samples16k
        self.sampleOffset = sampleOffset
        self.clipFromSeconds = clipFromSeconds
        self.prefixTokens = prefixTokens
        self.language = language
        self.wantsWordTimestamps = wantsWordTimestamps
    }
}

// MARK: - Result

/// What came back. Words carry absolute meeting time; the caller decides
/// what to trust (see `LocalAgreement`).
public struct SpeechHypothesis {
    public var words: [TranscriptWord]
    /// The token ids behind each word, in the same order, so the next
    /// request can be conditioned on the tail of this one. Empty when the
    /// engine cannot supply them.
    public var tokensByWord: [[Int]]
    /// The engine's own text, unsegmented. Kept because the sanitizer's
    /// repetition and attribution checks work on whole utterances, and
    /// rebuilding the string from words loses the model's spacing.
    public var text: String

    public init(words: [TranscriptWord] = [], tokensByWord: [[Int]] = [], text: String = "") {
        self.words = words
        self.tokensByWord = tokensByWord
        self.text = text
    }

    public var isEmpty: Bool { words.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Model state

/// Where the model is, as the UI needs to draw it. `downloading` carries a
/// fraction because a first run is a 147 MB download and a progress bar is
/// the difference between "working" and "broken".
public enum SpeechModelState: Equatable {
    case absent
    case downloading(Double)
    case loading
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }
}

/// A model the user can pick, with the number that actually decides it.
public struct SpeechModel: Identifiable, Equatable {
    public var id: String { variant }
    /// WhisperKit variant string, e.g. `openai_whisper-base.en`.
    public var variant: String
    /// The short name stored in settings, e.g. `base.en`.
    public var shortName: String
    public var displayName: String
    /// Download size in megabytes. Stated in the UI before anything starts.
    public var megabytes: Int
    /// One line about the trade.
    public var detail: String

    public init(variant: String, shortName: String, displayName: String,
                megabytes: Int, detail: String) {
        self.variant = variant
        self.shortName = shortName
        self.displayName = displayName
        self.megabytes = megabytes
        self.detail = detail
    }
}

// MARK: - Protocol

/// Anything that can turn 16 kHz mono audio into timed words.
///
/// An `actor` in practice: decodes must not overlap, because WhisperKit's
/// `TranscriptionResult` is a reference type whose own documentation warns
/// that read-modify-write on its segments is not thread-safe. The protocol
/// is `async` throughout so a conforming actor satisfies it directly, and a
/// synchronous fake satisfies it just as easily.
public protocol SpeechRecognizing: AnyObject {
    /// Whether word-level timings are available. Without them the two-stream
    /// merge falls back to segment times, which is coarser but still ordered.
    var supportsWordTimestamps: Bool { get async }

    /// Loads the model, reporting download and warm-up progress.
    func load(progress: @escaping (SpeechModelState) -> Void) async throws

    /// Releases the model. Called when a meeting stops — a ~250 MB resident
    /// model for a feature nobody is using is exactly what §5.23 exists to
    /// prevent.
    func unload() async

    /// One decode. `channel` is stamped onto every word that comes back.
    func transcribe(_ request: SpeechRequest,
                    channel: ChannelProfile) async throws -> SpeechHypothesis
}

// MARK: - Registry

/// Where the real engine gets plugged in.
///
/// The seam has to be a registry rather than a direct reference because
/// `PRISM/AI/Engines/` is excluded from the test target — that exclusion is
/// what keeps the suite ad-hoc signed and free of the package. AppState
/// lives in both targets, so if it named `WhisperKitEngine` the tests would
/// not compile.
///
/// The app installs the real factory at launch. Nothing installs one in a
/// test, and the fallback below is what a test gets: an engine that reports
/// honestly that it cannot transcribe, rather than one that silently
/// returns nothing and makes a broken pipeline look like a quiet room.
public enum SpeechEngineRegistry {

    /// Installed once, from the app target only.
    public static var factory: ((SpeechModel) -> SpeechRecognizing)?

    public static func make(_ model: SpeechModel) -> SpeechRecognizing {
        factory?(model) ?? UnavailableSpeechEngine()
    }
}

/// The stand-in when no engine is registered.
public final class UnavailableSpeechEngine: SpeechRecognizing {
    public init() {}
    public var supportsWordTimestamps: Bool { get async { false } }

    public func load(progress: @escaping (SpeechModelState) -> Void) async throws {
        progress(.failed("No speech engine is available in this build."))
        throw SpeechEngineError.modelUnavailable("this build")
    }

    public func unload() async {}

    public func transcribe(_ request: SpeechRequest,
                           channel: ChannelProfile) async throws -> SpeechHypothesis {
        throw SpeechEngineError.notLoaded
    }
}

// MARK: - Errors

public enum SpeechEngineError: LocalizedError, Equatable {
    case modelUnavailable(String)
    case downloadFailed(String)
    case notLoaded
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let name):
            return "PRISM can't find the \(name) speech model. Choose another in the Meeting pane."
        case .downloadFailed(let reason):
            return "The speech model didn't finish downloading — \(reason)"
        case .notLoaded:
            return "The speech model isn't loaded yet"
        case .decodeFailed(let reason):
            return "PRISM couldn't transcribe that — \(reason)"
        }
    }
}
