// AppRuleSettings.swift
// PRISM
//
// Per-app rules (§5.18): which preset PRISM wears for a given client, and
// whether that client is allowed to open the camera at all. Matched on the
// client's code-signing identifier, which the extension already reports
// (§3.2) — a bundle path or a process name is trivially spoofed and changes
// with every app update.
//
// Behaviour, not a look: these rules *choose* looks, so they cannot live
// inside the thing they choose. They ride in `StudioSettings`, alongside the
// other settings a preset must not carry.
//
// Everything in this file is pure. The resolver in particular has one
// genuinely interesting case — two clients streaming at once, because the
// camera fans out — and that case is specified here rather than left to
// emerge from whatever order the extension happens to report clients in.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

// MARK: - Access

public enum AppAccess: String, Codable, CaseIterable, Identifiable {
    case allow
    /// The client sees the camera as busy rather than as broken — a black
    /// frame reads as a bug and generates a support thread, a busy device
    /// reads as a decision.
    case block

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
    /// The client's signing identifier, e.g. "us.zoom.xos". Compared
    /// case-insensitively; see `matches`.
    public var signingID: String
    /// Human label for the list. Falls back to the signing ID when blank.
    public var name: String
    /// Preset to switch to when this client connects; nil leaves the current
    /// look alone, so a rule can control access without also seizing the look.
    public var presetID: UUID?
    public var access: AppAccess

    public init(id: UUID = UUID(),
                signingID: String = "",
                name: String = "",
                presetID: UUID? = nil,
                access: AppAccess = .allow) {
        self.id = id
        self.signingID = signingID
        self.name = name
        self.presetID = presetID
        self.access = access
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Same reasoning as OverlayLayer: an id has no sensible default, so a
        // fresh one is minted rather than failing the whole rules list.
        id = c.tolerant(.id, UUID())
        signingID = c.tolerant(.signingID, "")
        name = c.tolerant(.name, "")
        presetID = (try? c.decodeIfPresent(UUID.self, forKey: .presetID)) ?? nil
        access = c.tolerant(.access, .allow)
    }

    public var displayName: String {
        name.isEmpty ? signingID : name
    }

    /// A rule with no app named matches nothing and would silently occupy a
    /// row; the editor drops these rather than persisting dead weight.
    public var isMeaningful: Bool {
        !signingID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whole-string match, never a prefix: a signing ID is an identity, and
    /// prefix matching would let "us.zoom.xos.evil" inherit a rule written
    /// for Zoom. Case-insensitive because signing identifiers are
    /// case-insensitive in practice and users type them by hand.
    public func matches(_ clientSigningID: String) -> Bool {
        isMeaningful
            && signingID.caseInsensitiveCompare(clientSigningID) == .orderedSame
    }
}

// MARK: - The rule list

public struct AppRulesSettings: Codable, Equatable {
    /// The master switch, off. Rules that fire before the user has looked at
    /// the list would change what a call looks like — or refuse a call — for
    /// reasons the user never chose. This is also the only feature in PRISM
    /// that can leave an app without a camera while PRISM is not running.
    public var isEnabled: Bool = false
    /// What happens to a client no rule names. Allow: PRISM is a camera, and
    /// a camera that defaults to refusing is a broken camera.
    public var defaultAccess: AppAccess = .allow
    /// Ordered: earlier rules win (see `rule(for:)` and `AppRuleResolver`).
    public var rules: [AppRule] = []
    /// Say so when a rule changes the look. On by default — a preset that
    /// swapped itself without a word is indistinguishable from a bug — but
    /// switchable, because the same message on every call is nagging.
    public var announcesPresetChanges: Bool = true
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.tolerant(.isEnabled, false)
        defaultAccess = c.tolerant(.defaultAccess, .allow)
        rules = c.tolerant(.rules, [])
        announcesPresetChanges = c.tolerant(.announcesPresetChanges, true)
    }

    /// First match wins, so a user can order specific rules above general
    /// ones the same way they order layers.
    public func rule(for clientSigningID: String) -> AppRule? {
        guard isEnabled else { return nil }
        return rules.first { $0.matches(clientSigningID) }
    }

    public func access(for clientSigningID: String) -> AppAccess {
        // PRISM itself is never policed: the app writing frames into the sink
        // is not a client to police, and a rule that refused it would be a
        // rule that turns PRISM off from inside PRISM.
        guard isEnabled,
              clientSigningID.caseInsensitiveCompare(AppRuleResolver.selfSigningID)
                != .orderedSame
        else { return .allow }
        return rule(for: clientSigningID)?.access ?? defaultAccess
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
/// Single-client access is `AppRulesSettings.access(for:)`; what lives here
/// is everything that needs more than one client, or that has to leave the
/// process.
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

    /// PRISM's own signing ID. Never blockable — see
    /// `AppRulesSettings.access(for:)` and the extension's mirror of this.
    public static let selfSigningID = "horse.prism.PRISM"

    /// The preset a rule wants applied, given everything currently
    /// streaming. nil means "leave the user's look alone".
    public static func presetMatch(clients: [String],
                                   in settings: AppRulesSettings) -> AppRuleMatch? {
        guard settings.isEnabled, !clients.isEmpty else { return nil }
        for rule in settings.rules where rule.isMeaningful {
            guard clients.contains(where: { rule.matches($0) }) else { continue }
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
    /// Lossless because matching is whole-string: each signing ID lands in
    /// exactly one list, taken from the first rule that names it, so the
    /// extension's set membership test gives the same answer as walking the
    /// ordered list would. Both sides fold case, so the lists are shipped
    /// folded and the extension compares folded.
    public static func policy(for settings: AppRulesSettings) -> AccessPolicy {
        guard settings.isEnabled else { return .allowAll }
        var policy = AccessPolicy()
        policy.defaultAccess = settings.defaultAccess
        var decided = Set<String>([selfSigningID.lowercased()])
        for rule in settings.rules where rule.isMeaningful {
            let folded = rule.signingID.lowercased()
            guard decided.insert(folded).inserted else { continue }
            switch rule.access {
            case .block: policy.blocked.append(folded)
            case .allow: policy.allowed.append(folded)
            }
        }
        return policy
    }
}

// MARK: - Wire format ('polc')

/// What crosses to the extension over the 'polc' custom property
/// (CONTRACTS.md "CMIO custom properties"). Deliberately smaller than
/// `AppRulesSettings`: the extension decides one thing — may this client
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
    /// Signing IDs, case-folded. See `AppRuleResolver.policy(for:)`.
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
