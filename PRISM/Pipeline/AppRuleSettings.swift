// AppRuleSettings.swift
// PRISM
//
// Per-app rules (§5.15): an ordered list mapping a client signing ID to a
// preset and to whether that app may use PRISM Camera at all. Two halves of
// one question — "what happens when this app picks up the camera" — so they
// are one row, not two lists.
//
// Deliberately NOT part of PipelineConfiguration, for the same reason as
// StudioSettings: a preset captures a look, and "Zoom gets the Meeting look"
// is a rule *about* presets. A preset that contained rules could apply
// itself.
//
// Everything in this file is pure. The resolver in particular has one
// genuinely interesting case — two clients streaming at once, because the
// camera fans out — and that case is specified here rather than left to
// emerge from whatever order the extension happens to report clients in.
//
// Persisted whole in UserDefaults by AppState.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Access

/// Whether an app may start streaming from PRISM Camera.
public enum AppAccess: String, Codable, CaseIterable, Identifiable {
    case allow, block

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .allow: return "Allow"
        case .block: return "Block"
        }
    }
}

// MARK: - One rule

/// One app, and what PRISM does when it picks up the camera. `presetID` is
/// optional because "block this app" and "give this app the Meeting look"
/// are both complete thoughts on their own.
public struct AppRule: Codable, Equatable, Identifiable {
    public var id: UUID
    /// The client's code-signing ID, exactly as the extension reports it in
    /// 'clnt' ("us.zoom.xos"). Matched by exact equality: a signing ID is an
    /// identity, and prefix matching would let "com.evil.zoom" inherit a
    /// rule written for Zoom.
    public var signingID: String
    public var access: AppAccess
    /// nil leaves the look alone — a rule that only decides access.
    public var presetID: UUID?

    public init(id: UUID = UUID(),
                signingID: String,
                access: AppAccess = .allow,
                presetID: UUID? = nil) {
        self.id = id
        self.signingID = signingID
        self.access = access
        self.presetID = presetID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.tolerant(.id, UUID())
        signingID = c.tolerant(.signingID, "")
        access = c.tolerant(.access, .allow)
        presetID = (try? c.decodeIfPresent(UUID.self, forKey: .presetID)) ?? nil
    }

    /// A rule with no app named matches nothing and would silently occupy a
    /// row; the editor drops these rather than persisting dead weight.
    public var isMeaningful: Bool {
        !signingID.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - The rule list

public struct AppRuleSettings: Codable, Equatable {
    /// Ships off. Per-app rules are the only thing in PRISM that can leave a
    /// camera dark while PRISM is not running, so nothing here does anything
    /// until the user deliberately turns it on.
    public var isEnabled: Bool = false
    /// What happens to an app no rule names. `.allow` is the only safe
    /// default; `.block` turns the list into an allow-list, which is a real
    /// thing to want and a real way to lock yourself out.
    public var defaultAccess: AppAccess = .allow
    /// Ordered: earlier rules win (see AppRuleResolver).
    public var rules: [AppRule] = []
    /// Say so when a rule changes the look. On by default — a preset that
    /// swapped itself without a word is indistinguishable from a bug — but
    /// switchable, because the same message on every call is nagging.
    public var announcesPresetChanges: Bool = true

    public init() {}

    public enum CodingKeys: String, CodingKey {
        case isEnabled, defaultAccess, rules, announcesPresetChanges
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.tolerant(.isEnabled, false)
        defaultAccess = c.tolerant(.defaultAccess, .allow)
        rules = c.tolerant(.rules, [AppRule]())
        announcesPresetChanges = c.tolerant(.announcesPresetChanges, true)
    }

    /// True when at least one app would actually be refused. Drives the
    /// "you can lock yourself out" warnings, which must not appear for a
    /// list that only assigns presets.
    public var blocksAnything: Bool {
        isEnabled && (defaultAccess == .block
                      || rules.contains { $0.access == .block && $0.isMeaningful })
    }
}

// MARK: - Resolution

/// Which client won, and what it asked for. The signing ID rides along so
/// the notification can name the app that caused the change.
public struct AppRuleMatch: Equatable {
    public var signingID: String
    public var presetID: UUID

    public init(signingID: String, presetID: UUID) {
        self.signingID = signingID
        self.presetID = presetID
    }
}

/// Pure resolution of a rule list against the set of streaming clients.
///
/// **The two-client rule.** PRISM Camera is one camera with one picture; the
/// extension's source stream fans that one picture out to every client. So
/// when Zoom and FaceTime stream at the same time there is no honest way to
/// give them different looks, and picking "the most recent to connect" would
/// make the look depend on the order the user opened their apps — a rule
/// nobody can predict or write down.
///
/// The rule is therefore **list order**: the earliest rule in the list whose
/// app is streaming wins, and the user reorders the list to say which app
/// matters more. That is a rule you can read off the screen.
public enum AppRuleResolver {

    /// PRISM's own signing ID. Never blockable — the app writing frames into
    /// the sink is not a client to police, and a rule that refused it would
    /// be a rule that turns PRISM off from inside PRISM.
    public static let selfSigningID = "horse.prism.PRISM"

    /// The first rule naming this app, or nil.
    public static func rule(for signingID: String,
                            in settings: AppRuleSettings) -> AppRule? {
        settings.rules.first { $0.isMeaningful && $0.signingID == signingID }
    }

    public static func access(for signingID: String,
                              in settings: AppRuleSettings) -> AppAccess {
        guard settings.isEnabled, signingID != selfSigningID else { return .allow }
        return rule(for: signingID, in: settings)?.access ?? settings.defaultAccess
    }

    /// The preset a rule wants applied, given everything currently
    /// streaming. nil means "leave the user's look alone".
    public static func presetMatch(clients: [String],
                                   in settings: AppRuleSettings) -> AppRuleMatch? {
        guard settings.isEnabled, !clients.isEmpty else { return nil }
        let streaming = Set(clients)
        for rule in settings.rules where rule.isMeaningful {
            guard streaming.contains(rule.signingID) else { continue }
            // A blocked app has no business choosing the look. It should
            // never appear in 'clnt' at all, but a policy write that has not
            // landed yet would otherwise let it style the camera on its way
            // to being refused.
            guard rule.access == .allow, let presetID = rule.presetID else { continue }
            return AppRuleMatch(signingID: rule.signingID, presetID: presetID)
        }
        return nil
    }

    /// Flattens the rule list into the payload the extension understands.
    ///
    /// Lossless because matching is exact equality: each signing ID lands in
    /// exactly one list, taken from the first rule that names it, so the
    /// extension's set membership test gives the same answer as walking the
    /// ordered list would.
    public static func policy(for settings: AppRuleSettings) -> AccessPolicy {
        guard settings.isEnabled else { return .allowAll }
        var policy = AccessPolicy()
        policy.defaultAccess = settings.defaultAccess
        var decided = Set<String>([selfSigningID])
        for rule in settings.rules where rule.isMeaningful {
            guard decided.insert(rule.signingID).inserted else { continue }
            switch rule.access {
            case .block: policy.blocked.append(rule.signingID)
            case .allow: policy.allowed.append(rule.signingID)
            }
        }
        return policy
    }
}

// MARK: - Wire format ('polc')

/// What crosses to the extension over the 'polc' custom property
/// (CONTRACTS.md "CMIO custom properties"). Deliberately smaller than
/// `AppRuleSettings`: the extension decides one thing — may this client
/// start — and shipping it presets it cannot use would be handing root a
/// copy of the user's configuration for nothing.
///
/// The extension keeps its own Codable mirror of this (`ExtAccessPolicy`);
/// it must not link app sources (§3.1), so these key names are a contract.
public struct AccessPolicy: Codable, Equatable {
    /// Bumped only if the shape changes incompatibly. An extension that
    /// does not recognise the version fails open.
    public var version: Int = 1
    public var defaultAccess: AppAccess = .allow
    public var blocked: [String] = []
    public var allowed: [String] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.tolerant(.version, 1)
        defaultAccess = c.tolerant(.defaultAccess, .allow)
        blocked = c.tolerant(.blocked, [String]())
        allowed = c.tolerant(.allowed, [String]())
    }

    /// The payload that turns policing off entirely. Written whenever the
    /// feature is off, so quitting a PRISM that never blocked anything can
    /// never leave a stale block behind.
    public static let allowAll = AccessPolicy()

    public var isAllowAll: Bool {
        defaultAccess == .allow && blocked.isEmpty
    }

    public var jsonData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}
