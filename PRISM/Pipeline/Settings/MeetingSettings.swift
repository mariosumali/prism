// MeetingSettings.swift
// PRISM
//
// What gets transcribed, from where, and what is kept (§5.32).
//
// In StudioSettings rather than PipelineConfiguration, for the same reason
// the prompter's script is: a preset captures a *look*, and "transcribe this
// call" is not a look. Switching from Meeting to Studio must not start or
// stop listening to a conversation.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Far end

/// Where the *other* side of the conversation comes from.
///
/// PRISM already has the near side: it owns the microphone. The far side is
/// the meeting app's own output, which macOS only hands over under the
/// Screen Recording permission — a real cost, so this is off until asked
/// for, and a transcript of your own half is a supported outcome rather
/// than a broken one.
public enum FarEndSource: String, Codable, CaseIterable, Equatable {
    /// Your side only. No extra permission, nothing to explain.
    case off
    /// Everything this Mac plays, minus PRISM's own sound.
    case everything
    /// One application's audio. Cleaner, because a notification chime is
    /// not part of the meeting.
    case chosenApp

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .everything: return "Everything you hear"
        case .chosenApp: return "One app"
        }
    }

    public var detail: String {
        switch self {
        case .off:
            return "Only your microphone is transcribed."
        case .everything:
            return "Every sound this Mac plays, except PRISM's own."
        case .chosenApp:
            return "Just the meeting app, so notifications stay out of it."
        }
    }
}

// MARK: - Settings

public struct MeetingSettings: Codable, Equatable {

    /// The master switch. Off by default: a resident agent should cost
    /// nothing for a feature you are not using, and a speech model is the
    /// most expensive thing in this app.
    public var transcribes: Bool = false

    /// WhisperKit model variant. `base.en` is the smallest download that is
    /// actually usable for meetings — 147 MB against large-v3's 627 MB —
    /// and it is what a first run gets.
    public var model: String = "base.en"

    /// BCP-47-ish language hint passed to the recogniser. An `.en` model
    /// ignores it; a multilingual one needs it, because Whisper's language
    /// auto-detection on a three-word chunk is a coin flip.
    public var language: String = "en"

    public var farEnd: FarEndSource = .off
    /// Bundle identifier for `.chosenApp`. Nil means "not picked yet",
    /// which is a distinct state from "picked and then quit".
    public var farEndBundleID: String?

    /// What the other side is called in the transcript. Not a name PRISM
    /// invents: it has no way to know who is on the call, and a wrong name
    /// in a set of meeting notes is worse than a generic one.
    public var farEndLabel: String = "Them"

    /// Below this RMS, a chunk is not sent to the recogniser at all.
    ///
    /// This is the single cheapest quality control in the feature. Whisper
    /// hallucinates confidently on silence — "Thank you." and subtitle
    /// credits are the famous ones — so the fix is to not ask it. The value
    /// is calibrated rather than guessed: pure digital silence sits near
    /// 0.0001, room tone near 0.001, mic hiss near 0.003, and someone
    /// speaking softly from across a desk lands at 0.005 and up. humla
    /// shipped 0.008 first and had to lower it, because a person sitting
    /// more than about 40 cm from a laptop microphone reads at ~0.007 and
    /// was being silently dropped.
    public var silenceRMS: Double = 0.005        // 0.001…0.02

    /// Write the transcript to Application Support when the meeting ends.
    /// The audio never is, under any setting — see §5.32.
    public var savesTranscript: Bool = true

    /// Which note template `Write notes` uses.
    public var templateName: String = "Standard meeting"

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcribes = c.tolerant(.transcribes, false)
        model = c.tolerant(.model, "base.en")
        language = c.tolerant(.language, "en")
        farEnd = c.tolerant(.farEnd, FarEndSource.off)
        farEndBundleID = c.tolerant(.farEndBundleID, nil)
        farEndLabel = c.tolerant(.farEndLabel, "Them")
        silenceRMS = c.tolerant(.silenceRMS, 0.005)
        savesTranscript = c.tolerant(.savesTranscript, true)
        templateName = c.tolerant(.templateName, "Standard meeting")
    }

    public var clampedSilenceRMS: Double { min(max(silenceRMS, 0.001), 0.02) }

    /// A label that is safe to print. An empty field is a field the user
    /// cleared, and rendering `": said something"` is worse than falling
    /// back — a transcript line with no speaker silently glues itself onto
    /// the previous speaker's paragraph.
    public var resolvedFarEndLabel: String {
        let trimmed = farEndLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Them" : trimmed
    }

    /// The demand gate. Nothing is armed, no model is loaded and no audio is
    /// read unless this is true and a meeting is actually running.
    public var isActive: Bool { transcribes }

    /// Whether the far-end stream should be started. `.chosenApp` with no
    /// app picked is a half-finished setting, not a reason to capture
    /// everything the Mac plays.
    public var wantsFarEnd: Bool {
        switch farEnd {
        case .off: return false
        case .everything: return true
        case .chosenApp: return !(farEndBundleID ?? "").isEmpty
        }
    }
}
