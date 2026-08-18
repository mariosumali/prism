// AppRuleSettings.swift
// PRISM
//
// Per-app rules: which preset PRISM wears for a given client, and whether
// that client is allowed to open the camera at all. Matched on the client's
// code-signing identifier, which the extension already reports (§3.2) — a
// bundle path or a process name is trivially spoofed and changes with every
// app update.
//
// Behaviour, not a look: these rules *choose* looks, so they cannot live
// inside the thing they choose.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

public enum AppAccess: String, Codable, CaseIterable {
    case allow
    /// The client sees the camera as busy rather than as broken — a black
    /// frame reads as a bug and generates a support thread, a busy device
    /// reads as a decision.
    case block

    public var displayName: String {
        switch self {
        case .allow: return "Allow"
        case .block: return "Block"
        }
    }
}

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

    /// Signing identifiers are case-insensitive in practice and users type
    /// them by hand, so matching is too.
    public func matches(_ clientSigningID: String) -> Bool {
        !signingID.isEmpty
            && signingID.caseInsensitiveCompare(clientSigningID) == .orderedSame
    }
}

public struct AppRulesSettings: Codable, Equatable {
    /// The master switch, off. Rules that fire before the user has looked at
    /// the list would change what a call looks like — or refuse a call — for
    /// reasons the user never chose.
    public var isEnabled: Bool = false
    /// What happens to a client no rule names. Allow: PRISM is a camera, and
    /// a camera that defaults to refusing is a broken camera.
    public var defaultAccess: AppAccess = .allow
    public var rules: [AppRule] = []
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = c.tolerant(.isEnabled, false)
        defaultAccess = c.tolerant(.defaultAccess, .allow)
        rules = c.tolerant(.rules, [])
    }

    /// First match wins, so a user can order specific rules above general
    /// ones the same way they order layers.
    public func rule(for clientSigningID: String) -> AppRule? {
        guard isEnabled else { return nil }
        return rules.first { $0.matches(clientSigningID) }
    }

    public func access(for clientSigningID: String) -> AppAccess {
        guard isEnabled else { return .allow }
        return rule(for: clientSigningID)?.access ?? defaultAccess
    }
}
