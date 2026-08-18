// ClipExporter.swift
// PRISM
//
// Writes the rolling buffer to a .mov (§5.15) without re-encoding anything.
//
// The samples in the ring are already hardware-encoded H.264 with a valid
// format description and no frame reordering (§5.9), so the file is a
// remux: AVAssetWriterInput with `outputSettings: nil` is passthrough, the
// media engine is not asked to do anything, and the GPU is not touched at
// all. A save therefore costs the frame path nothing, which is the point —
// saving the last ten seconds must not be the thing that makes the next ten
// seconds stutter.
//
// Runs on a caller-supplied background queue: every wait in here blocks.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import CoreMedia
import Foundation

public enum ClipExporter {

    /// Same timescale the rolling buffer stamps its samples with, so the
    /// rebase is exact rather than nearly exact.
    static let timescale: CMTimeScale = 90_000

    /// Remuxes `samples` into `url`.
    ///
    /// - Returns: the plan that was written, so the caller can report the
    ///   clip's real duration rather than the duration that was asked for.
    @discardableResult
    public static func write(samples: [ReplayBuffer.RecordedFrame],
                             formatDescription: CMFormatDescription,
                             to url: URL) throws -> ClipPlan {
        guard let plan = ClipPlanner.plan(times: samples.map(\.seconds),
                                          keyframes: samples.map(\.isKeyframe)),
              !plan.frames.isEmpty else {
            throw CaptureError.nothingBuffered
        }

        // A previous attempt's remains would make AVAssetWriter refuse the
        // URL outright.
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw CaptureError.encodingFailed(error.localizedDescription)
        }

        // outputSettings: nil is what makes this a copy rather than a
        // transcode. The format hint is the ring's own description, which is
        // the only thing that lets the writer build a sample table for media
        // it is never going to look inside.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            discard(writer, at: url)
            throw CaptureError.encodingFailed("the buffered video is not writable as a movie")
        }
        writer.add(input)

        guard writer.startWriting() else {
            discard(writer, at: url)
            throw CaptureError.encodingFailed(reason(writer))
        }
        writer.startSession(atSourceTime: .zero)

        for frame in plan.frames {
            var timing = CMSampleTimingInfo(
                duration: CMTime(seconds: frame.durationSeconds,
                                 preferredTimescale: timescale),
                presentationTimeStamp: CMTime(seconds: frame.presentationSeconds,
                                              preferredTimescale: timescale),
                // Left invalid deliberately: reordering is off in the
                // recorder, so decode order is presentation order and the
                // writer derives the DTS itself.
                decodeTimeStamp: .invalid)

            var retimed: CMSampleBuffer?
            let status = CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: samples[frame.index].sample,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleBufferOut: &retimed)
            guard status == noErr, let sample = retimed else {
                discard(writer, at: url)
                throw CaptureError.encodingFailed("a buffered frame could not be retimed")
            }

            // Passthrough input on a background queue: the writer is never
            // unready for long, and sleeping is cheaper than a callback
            // pump for a file this size.
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard input.append(sample) else {
                discard(writer, at: url)
                throw CaptureError.encodingFailed(reason(writer))
            }
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()

        guard writer.status == .completed else {
            // finishWriting having failed still leaves a file behind.
            try? FileManager.default.removeItem(at: url)
            throw CaptureError.encodingFailed(reason(writer))
        }
        return plan
    }

    /// Never leave a half-written .mov. A zero-byte or truncated file in the
    /// user's folder is worse than no file: it looks like the save worked.
    private static func discard(_ writer: AVAssetWriter, at url: URL) {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func reason(_ writer: AVAssetWriter) -> String {
        writer.error?.localizedDescription ?? "the movie writer stopped"
    }
}
