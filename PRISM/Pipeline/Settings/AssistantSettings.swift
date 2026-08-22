// AssistantSettings.swift
// PRISM
//
// The in-meeting assistant: which model answers, and how the panel behaves
// (§5.33).
//
// In StudioSettings, never in a preset — for the prompter's reason and one
// more. A preset is exportable, and a preset carrying a model endpoint would
// be a preset that quietly repoints somebody else's questions at a server
// they have never heard of. The API key is not here at all; it is in the
// Keychain (§5.33), because a settings struct gets encoded into UserDefaults
// as plain JSON.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Provider

/// Who answers. `none` is the default and means the network is never
/// touched — the transcript half of the feature (§5.32) is entirely
/// on-device and does not need this set at all.
public enum LLMProviderKind: String, Codable, CaseIterable, Equatable {
    case none
    /// Anthropic's API. Needs a key; the key lives in the Keychain.
    case anthropic
    /// Ollama on this Mac. Nothing leaves the machine.
    case ollama
    /// Any OpenAI-compatible endpoint — llama.cpp's server, LM Studio, vLLM.
    case openAICompatible

    public var displayName: String {
        switch self {
        case .none: return "Off"
        case .anthropic: return "Claude"
        case .ollama: return "Ollama, on this Mac"
        case .openAICompatible: return "Another endpoint"
        }
    }

    /// Whether choosing this sends anything off the machine. Drives the one
    /// sentence in the pane that people actually need to read.
    public var leavesThisMac: Bool { self == .anthropic || self == .openAICompatible }
}

// MARK: - Panel placement

/// Which corner the panel opens in. It is draggable afterwards and the
/// frame is remembered; this is only where it starts.
public enum AssistantAnchor: String, Codable, CaseIterable, Equatable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    public var displayName: String {
        switch self {
        case .topLeading: return "Top left"
        case .topTrailing: return "Top right"
        case .bottomLeading: return "Bottom left"
        case .bottomTrailing: return "Bottom right"
        }
    }
}

// MARK: - Settings

public struct AssistantSettings: Codable, Equatable {

    /// Panel on screen. Deliberately **not restored** from disk — see
    /// `init(from:)`.
    public var isEnabled: Bool = false

    public var provider: LLMProviderKind = .none

    /// Model identifiers, stored as editable text rather than an enum.
    /// Providers rename and retire models faster than an app ships, and a
    /// hardcoded identifier turns a working install into a 404 that only a
    /// release can fix.
    public var anthropicModel: String = "claude-opus-5"
    public var ollamaModel: String = ""
    public var compatibleBaseURL: String = ""
    public var compatibleModel: String = ""

    public var opacity: Double = 0.9             // 0.35…1
    public var anchor: AssistantAnchor = .topTrailing

    /// How much of the conversation goes with a typed question. Fourteen
    /// turns is cue's budget and it holds up: more history dilutes a direct
    /// answer rather than improving it.
    public var contextTurns: Int = 14            // 4…30

    /// Light up the composer when the other side appears to have asked
    /// something. A cue, never a request — see §5.33.
    public var highlightsQuestions: Bool = true

    /// Who you are and what you work on, sent with every answer. This is
    /// what makes the difference between a generic answer and a usable one,
    /// and the pane says plainly that it is sent.
    public var aboutMe: String = ""

    /// §5.34 — cards appear on their own while the call goes on. The one
    /// exception to push-to-ask, and a preference rather than a state: it is
    /// restored, because it can only act while `isEnabled` is true and
    /// `isEnabled` never is. Off by default, like everything that sends.
    public var liveInsights: Bool = false

    /// How eager §5.34 is allowed to be. The numbers live in `InsightPolicy`.
    public var insightPace: InsightPace = .balanced

    /// Which kinds of card the user wants. Stored as a set, decoded from a
    /// list of names so that a kind this build does not know is skipped
    /// rather than taking the whole selection with it.
    public var insightKinds: Set<InsightKind> = InsightKind.defaultSet

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Deliberately not decoded. PRISM launches at login for most people,
        // and a panel that reopened itself would put an answer to a question
        // from yesterday's call over whatever they actually opened their Mac
        // to do — on top of every other window, on every Space. The prompter
        // makes the same choice for the same reason.
        isEnabled = false
        provider = c.tolerant(.provider, LLMProviderKind.none)
        anthropicModel = c.tolerant(.anthropicModel, "claude-opus-5")
        ollamaModel = c.tolerant(.ollamaModel, "")
        compatibleBaseURL = c.tolerant(.compatibleBaseURL, "")
        compatibleModel = c.tolerant(.compatibleModel, "")
        opacity = c.tolerant(.opacity, 0.9)
        anchor = c.tolerant(.anchor, AssistantAnchor.topTrailing)
        contextTurns = c.tolerant(.contextTurns, 14)
        highlightsQuestions = c.tolerant(.highlightsQuestions, true)
        aboutMe = c.tolerant(.aboutMe, "")
        liveInsights = c.tolerant(.liveInsights, false)
        insightPace = c.tolerant(.insightPace, InsightPace.balanced)
        if let names: [String] = c.tolerant(.insightKinds, nil) {
            insightKinds = Set(names.compactMap(InsightKind.init(rawValue:)))
        } else {
            insightKinds = InsightKind.defaultSet
        }
    }

    /// The kinds a request asks for. An empty selection means the user
    /// switched every kind off, which is the same intent as switching the
    /// mode off — so it is treated that way by `wantsLiveInsights`, and
    /// never silently widened back to the default.
    public var effectiveInsightKinds: Set<InsightKind> { insightKinds }

    /// §5.34's demand gate: the mode is on, the panel is active with a
    /// provider, and there is at least one kind of card to ask for. The
    /// meeting being listened to is the fourth switch and lives on the
    /// session, not here.
    public var wantsLiveInsights: Bool {
        isActive && liveInsights && !insightKinds.isEmpty
    }

    public var clampedOpacity: Double { min(max(opacity, 0.35), 1) }
    public var clampedContextTurns: Int { min(max(contextTurns, 4), 30) }

    /// §8.7: the switch and the provider ask one question between them.
    /// A panel with nowhere to send a question is a panel that can only
    /// disappoint, so "on" means both.
    public var isActive: Bool { isEnabled && provider != .none }

    /// Whether a provider is configured well enough to be worth calling.
    /// The Anthropic key is not here — AppState checks the Keychain — so
    /// this is the settings-only half of the question.
    public var providerIsConfigured: Bool {
        switch provider {
        case .none: return false
        case .anthropic: return !anthropicModel.isEmpty
        case .ollama: return !ollamaModel.isEmpty
        case .openAICompatible:
            return !compatibleBaseURL.isEmpty && !compatibleModel.isEmpty
        }
    }
}
