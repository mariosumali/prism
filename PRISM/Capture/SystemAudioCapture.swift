// SystemAudioCapture.swift
// PRISM
//
// The other side of the conversation (§5.32): an audio-only
// ScreenCaptureKit stream that hears what the meeting app is playing.
//
// PRISM already has the near side — it owns the microphone. The far side is
// the one thing a virtual-microphone app cannot get for free, because the
// remote voices never pass through any device PRISM publishes. macOS offers
// exactly two ways to reach them, and this file takes the one that works at
// PRISM's floor.
//
// **Why ScreenCaptureKit and not a Core Audio process tap.**
// `AudioHardwareCreateProcessTap` is the better API in every respect that
// matters — no display dependency, a user-database TCC grant that takes
// effect in-session with no relaunch and no recurring prompt — and it is
// `macos(14.2)`, shipped in practice at 14.4. PRISM's deployment target is
// 13.0, and the people most likely to be running Ventura are the ones with
// an installed camera extension and HAL plug-in. Taking taps only would
// mean the far end simply does not exist for them, with no explanation that
// is not "upgrade your operating system". So: SCK now, and the tap path as
// a runtime-gated fast path later, when it is an optimisation rather than
// the only implementation.
//
// **This is a second stream, deliberately.** §5.24's screen source is torn
// down and rebuilt whenever the selection or the output format changes.
// Sharing it would mean a transcript that stops mid-sentence because
// somebody switched from 720p to 1080p. Nothing about the far end should
// depend on what the camera is doing.
//
// **No video output is registered.** The 2×2 configuration is not a trick
// to make a small picture; it is the smallest legal size for a stream whose
// `.screen` output nobody ever adds, so nothing is ever encoded, decoded or
// copied. The 2022-era advice to attach a screen output and throw the
// frames away is stale.
//
// **Screen Recording is macOS's name for this permission, and the pane says
// so.** PRISM captures no pixels here. That the sound of another
// application is gated behind a permission called "Screen Recording" is
// Apple's decision, and the honest thing to do is explain it rather than
// let it read as PRISM asking to watch the screen.
//
// Licensed under the Apache License, Version 2.0.

import AVFAudio
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Seam

/// What `MeetingSession` needs from a far-end source, so it can be faked in
/// a test with no window server, no permission and no meeting.
/// Deliberately no `tap` member. The ring is how this implementation
/// happens to move samples; a consumer only ever needs a cursor and a read,
/// and exposing the ring would both leak that choice and drag an internal
/// type into a public protocol.
public protocol SystemAudioCapturing: AnyObject {
    var tapCursor: UInt64 { get }
    func read(from cursor: UInt64, into buffer: UnsafeMutablePointer<Float>,
              maxFrames: Int) -> (cursor: UInt64, frames: Int)
    /// True once a non-silent buffer has actually arrived — not merely that
    /// the stream reports running. See `hasHeardAnything`.
    var hasHeardAnything: Bool { get }
    var isRunning: Bool { get }
    func start(bundleID: String?) async
    func stop() async
    var onFailure: ((String) -> Void)? { get set }
}

// MARK: - Capture

public final class SystemAudioCapture: NSObject, SystemAudioCapturing,
                                SCStreamOutput, SCStreamDelegate {

    /// 10.9 s at 48 kHz mono, 2 MB — matching the microphone's ASR tap. The
    /// reader is the same 10 Hz drain and hitches for the same reasons.
    let tap = MicTapRing(capacityFrames: 1 << 19)

    /// The sentence the user is shown, and the redacted one for the §5.21
    /// log. Built together at the point of failure, as §5.24 does, because a
    /// redaction applied later by whoever remembers is one that stops being
    /// applied.
    public var onFailure: ((String) -> Void)?

    private let audioQueue = DispatchQueue(
        label: "horse.prism.PRISM.system-audio", qos: .userInitiated)

    private var stream: SCStream?
    private let stateLock = NSLock()
    private var _isRunning = false
    private var _hasHeardAnything = false
    /// Bumped on every start/stop so a slow async build cannot install a
    /// stream the caller has already abandoned. Same discipline as
    /// ScreenCapture's generation counter.
    private var generation: UInt64 = 0

    /// Preallocated mixdown scratch. SCK delivers non-interleaved stereo;
    /// the ring wants mono. 48 kHz × 2 channels × a generous callback is
    /// far under this.
    private static let scratchFrames = 16_384
    private let scratch: UnsafeMutablePointer<Float>

    public override init() {
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrames)
        scratch.initialize(repeating: 0, count: Self.scratchFrames)
        super.init()
        tap.setMaxWriteFrames(Self.scratchFrames)
    }

    deinit {
        scratch.deallocate()
    }

    // MARK: Reader side

    public var tapCursor: UInt64 { tap.head }

    public func read(from cursor: UInt64, into buffer: UnsafeMutablePointer<Float>,
                     maxFrames: Int) -> (cursor: UInt64, frames: Int) {
        tap.read(from: cursor, into: buffer, maxFrames: maxFrames)
    }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    /// Whether any buffer carrying actual signal has arrived.
    ///
    /// This exists because every layer of this stack reports success while
    /// producing silence. A stream can start, deliver callbacks at the full
    /// rate, and carry nothing but zeros — that is what a missing or revoked
    /// permission looks like from inside the process, and it is
    /// indistinguishable from a genuinely quiet meeting except that it never
    /// ends. `MeetingSession` gives it fifteen seconds and then says so,
    /// rather than producing half a transcript and letting the user work out
    /// which half is missing.
    public var hasHeardAnything: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _hasHeardAnything
    }

    // MARK: Lifecycle

    public func start(bundleID: String?) async {
        await stop()

        let gen = stateLock.withLock {
            generation &+= 1
            _hasHeardAnything = false
            return generation
        }

        guard CGPreflightScreenCaptureAccess() else {
            onFailure?("PRISM needs Screen Recording permission to hear the other side of "
                       + "the call. macOS calls it Screen Recording; PRISM captures no "
                       + "pixels for this.")
            return
        }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false) else {
            onFailure?("PRISM could not read the list of running applications, so it "
                       + "did not start listening to the other side.")
            return
        }
        guard isCurrent(gen) else { return }

        guard let display = content.displays.first else {
            // An audio-only filter still has to be anchored to a display —
            // ScreenCaptureKit has no audio-only filter at this floor. No
            // display means no far end, and saying so beats a stream that
            // reports running and delivers zeros forever.
            onFailure?("PRISM could not find a display to attach the audio capture to.")
            return
        }

        let ownApps = Self.ownApplications(in: content)
        guard !ownApps.isEmpty else {
            // §5.24's standard, applied to sound. PRISM must never record
            // itself: the mic check plays back the microphone, and a clip
            // can put audio on the call. Capturing that would put PRISM's
            // own output into the transcript as though somebody had said it.
            // A capture that does not start is recoverable; one that
            // transcribes its own echo is not obviously wrong until much
            // later.
            onFailure?("PRISM could not confirm its own sound would be left out of the "
                       + "capture, so it did not start one.")
            return
        }

        let filter: SCContentFilter
        if let bundleID, !bundleID.isEmpty,
           let target = Self.application(bundleID: bundleID, in: content) {
            // Per-application capture: a notification chime is not part of
            // the meeting, and neither is the music that was playing before
            // it started. Note the Swift label is `including:` —
            // `includingApplications:` is a Swift-3-era spelling the
            // compiler rejects.
            filter = SCContentFilter(display: display,
                                     including: [target],
                                     exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display,
                                     excludingApplications: ownApps,
                                     exceptingWindows: [])
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // The audio half of §5.24's self-exclusion, and independent of the
        // filter above: an application filter scopes what is captured, this
        // scopes what PRISM contributes.
        configuration.excludesCurrentProcessAudio = true
        // Smallest legal frame. No `.screen` output is ever registered, so
        // nothing decodes video; this only keeps the stream constructible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            // `.audio` only. Adding `.screen` here would start the video
            // pipeline for frames nobody reads.
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await stream.startCapture()
        } catch {
            onFailure?("PRISM could not listen to the other side — "
                       + error.localizedDescription)
            return
        }
        guard isCurrent(gen) else {
            try? await stream.stopCapture()
            return
        }
        stateLock.withLock {
            self.stream = stream
            _isRunning = true
        }
    }

    public func stop() async {
        let current = stateLock.withLock {
            generation &+= 1
            let current = stream
            stream = nil
            _isRunning = false
            return current
        }
        guard let current else { return }
        try? await current.stopCapture()
    }

    private func isCurrent(_ gen: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return gen == generation
    }

    // MARK: SCStreamOutput

    public func stream(_ stream: SCStream,
                       didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer) else { return }

        // SCK hands over non-interleaved Float32 — one AudioBuffer per
        // channel, 960 frames (20 ms) per callback at 48 kHz. That differs
        // from the interleaved layout a Core Audio tap produces, which is
        // exactly why both routes normalise to mono here rather than
        // downstream.
        //
        // The buffer list must not escape this closure: it is backed by the
        // sample buffer's block buffer, which is retained only for the
        // duration of the call.
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard list.count > 0 else { return }
            guard let first = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0, frames <= Self.scratchFrames else { return }

            if list.count >= 2, let second = list[1].mData?.assumingMemoryBound(to: Float.self) {
                let secondFrames = Int(list[1].mDataByteSize) / MemoryLayout<Float>.size
                let usable = min(frames, secondFrames)
                for i in 0..<usable {
                    scratch[i] = (first[i] + second[i]) * 0.5
                }
                writeAndNotice(frames: usable)
            } else {
                scratch.update(from: first, count: frames)
                writeAndNotice(frames: frames)
            }
        }
    }

    /// Writes the mixdown and, the first time it carries signal, records
    /// that the far end is genuinely audible. The threshold is deliberately
    /// far below `MeetingSettings.silenceRMS`: this answers "is anything
    /// arriving at all", not "is anyone speaking".
    private func writeAndNotice(frames: Int) {
        tap.writeMono(scratch, frameCount: frames)

        var peak: Float = 0
        for i in 0..<frames {
            let magnitude = abs(scratch[i])
            if magnitude > peak { peak = magnitude }
        }
        guard peak > 0.0005 else { return }
        stateLock.lock()
        let already = _hasHeardAnything
        if !already { _hasHeardAnything = true }
        stateLock.unlock()
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let wasCurrent = (stream === self.stream)
        if wasCurrent {
            self.stream = nil
            _isRunning = false
        }
        stateLock.unlock()
        guard wasCurrent else { return }
        onFailure?("PRISM stopped hearing the other side — " + error.localizedDescription)
    }

    // MARK: Content helpers

    /// PRISM's own applications, for the exclusion. Reuses §5.24's rule
    /// rather than restating it: the guarantee is that PRISM never captures
    /// itself, and one implementation of it is easier to keep true than two.
    static func ownApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        ScreenCapture.ownApplications(
            applications: content.applications,
            windowOwners: content.windows.map(\.owningApplication),
            bundleID: Bundle.main.bundleIdentifier)
    }

    static func application(bundleID: String,
                            in content: SCShareableContent) -> SCRunningApplication? {
        content.applications.first { $0.bundleIdentifier == bundleID }
    }

    /// Applications currently playing something, for the pane's picker.
    ///
    /// Every running application with an on-screen window is offered rather
    /// than trying to detect which are producing audio: there is no API for
    /// that at this floor, and a picker that hides the meeting app because
    /// nobody happened to be talking when it was opened is worse than one
    /// with extra rows.
    static func candidateApplications() async -> [(bundleID: String, name: String)] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true) else { return [] }
        let ownID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [(String, String)] = []
        for app in content.applications {
            let id = app.bundleIdentifier
            guard !id.isEmpty, id != ownID, seen.insert(id).inserted else { continue }
            let name = app.applicationName.isEmpty ? id : app.applicationName
            result.append((id, name))
        }
        return result.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }
}
