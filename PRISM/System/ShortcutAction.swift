// ShortcutAction.swift
// PRISM
//
// The bindable global actions (§5.15) and the persisted binding table.
// Hotkeys matches against this; AppState.perform executes it; the Shortcuts
// pane edits it. One enum so the three cannot drift: adding a case adds the
// chord, the row in the UI, and the reset-to-default entry at once.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

/// Everything a global chord can trigger. Deliberately not "every intent
/// AppState exposes": a shortcut fires with no window focused and no
/// confirmation, so the list is the verbs that are safe to hit by accident —
/// each one is either reversible by pressing it again, or makes PRISM show
/// less rather than more.
public enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case freeze
    case mute
    case freezeAndMute
    case replay
    case away
    case panic
    case eyeContact
    case lag
    case badConnection
    case voice

    public var id: String { rawValue }

    /// §8.4: named by what the user controls, matching the popover tiles.
    public var displayName: String {
        switch self {
        case .freeze: return "Freeze"
        case .mute: return "Mute"
        case .freezeAndMute: return "Freeze and mute"
        case .replay: return "Instant replay"
        case .away: return "Away loop"
        case .panic: return "Panic"
        case .eyeContact: return "Eye contact"
        case .lag: return "Lag switch"
        case .badConnection: return "Bad connection"
        case .voice: return "Voice changer"
        }
    }

    /// §5.2 originals plus the studio chords (§5.6, §5.9–§5.14). All share
    /// the ⌥⌘ prefix so they read as one family — except the voice changer,
    /// which adds ⌃ because ⌥⌘V is Finder's "Move Item Here" (and ⌥⇧⌘V the
    /// system-wide Paste and Match Style), so the plain combo would put a
    /// chipmunk on air every time someone moved files mid-call.
    /// ANSI keycodes: F = 3, M = 46, R = 15, A = 0, P = 35, E = 14, L = 37,
    /// B = 11, V = 9.
    public var defaultCombo: HotkeyCombo {
        switch self {
        case .freeze:
            return HotkeyCombo(keyCode: 3, option: true, command: true)
        case .mute:
            return HotkeyCombo(keyCode: 46, option: true, command: true)
        case .freezeAndMute:
            return HotkeyCombo(keyCode: 3, option: true, command: true, shift: true)
        case .replay:
            return HotkeyCombo(keyCode: 15, option: true, command: true)
        case .away:
            return HotkeyCombo(keyCode: 0, option: true, command: true)
        case .panic:
            // Deliberately un-shifted: a panic key you have to reach for is
            // not one.
            return HotkeyCombo(keyCode: 35, option: true, command: true)
        case .eyeContact:
            return HotkeyCombo(keyCode: 14, option: true, command: true)
        case .lag:
            return HotkeyCombo(keyCode: 37, option: true, command: true)
        case .badConnection:
            return HotkeyCombo(keyCode: 11, option: true, command: true)
        case .voice:
            return HotkeyCombo(keyCode: 9, option: true, command: true, control: true)
        }
    }

    /// §5.12: the lag switch is the only action whose key *release* is
    /// observed, so it can be held rather than toggled — which is what
    /// "switch" means.
    public var isMomentary: Bool { self == .lag }
}

/// Which existing binding a candidate combo would collide with.
public enum ShortcutConflict: Equatable {
    case action(ShortcutAction)
    case preset(id: UUID, name: String)

    public var ownerName: String {
        switch self {
        case .action(let action): return action.displayName
        case .preset(_, let name): return name
        }
    }
}

/// The user's deviations from the defaults, persisted whole.
///
/// Two dictionaries rather than one `[ShortcutAction: HotkeyCombo?]`,
/// because "unbound" and "never touched" are different answers and JSON
/// nulls make them look alike. Both are keyed by raw string, which is what
/// keeps a downgrade honest: a build that has never heard of a future
/// action carries its binding through untouched instead of deleting it on
/// the first save.
public struct HotkeyBindings: Codable, Equatable {
    private var assigned: [String: HotkeyCombo] = [:]
    private var cleared: Set<String> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assigned = c.tolerant(.assigned, [:])
        cleared = c.tolerant(.cleared, [])
    }

    /// nil means "no chord fires this", which is a legitimate choice — a
    /// user who has never wanted the lag switch should be able to take the
    /// chord back rather than live with it.
    public func combo(for action: ShortcutAction) -> HotkeyCombo? {
        if let assigned = assigned[action.rawValue] { return assigned }
        if cleared.contains(action.rawValue) { return nil }
        return action.defaultCombo
    }

    public func isDefault(_ action: ShortcutAction) -> Bool {
        combo(for: action) == action.defaultCombo
    }

    public mutating func set(_ combo: HotkeyCombo?, for action: ShortcutAction) {
        if let combo {
            assigned[action.rawValue] = combo
            cleared.remove(action.rawValue)
        } else {
            assigned.removeValue(forKey: action.rawValue)
            cleared.insert(action.rawValue)
        }
    }

    public mutating func reset(_ action: ShortcutAction) {
        assigned.removeValue(forKey: action.rawValue)
        cleared.remove(action.rawValue)
    }

    /// Only clears what this build knows about, for the same reason the
    /// storage is string-keyed: "reset shortcuts" must not be a way to lose
    /// bindings that belong to an app version you are about to run again.
    public mutating func resetAll() {
        for action in ShortcutAction.allCases { reset(action) }
    }

    public var isDefaultEverywhere: Bool {
        ShortcutAction.allCases.allSatisfy(isDefault)
    }

    /// What Hotkeys matches against: unbound actions simply do not appear.
    public var resolved: [ShortcutAction: HotkeyCombo] {
        var table: [ShortcutAction: HotkeyCombo] = [:]
        for action in ShortcutAction.allCases {
            if let combo = combo(for: action) { table[action] = combo }
        }
        return table
    }

    public func conflict(for combo: HotkeyCombo,
                         excluding action: ShortcutAction?) -> ShortcutAction? {
        ShortcutAction.allCases.first { candidate in
            candidate != action && self.combo(for: candidate) == combo
        }
    }

    /// A binding must be reachable without being reachable by accident.
    ///
    /// PRISM's tap is listen-only, so it never consumes the keystroke: a
    /// ⌘-only or ⇧-only binding would fire the front app's menu command at
    /// the same moment it froze your camera, and a bare letter would fire
    /// every time you typed it. ⌥ and ⌃ chords are rare enough in menus to
    /// be safe, and function keys type nothing at all.
    public static func isBindable(_ combo: HotkeyCombo) -> Bool {
        guard !KeyCodeNames.isModifier(combo.keyCode) else { return false }
        if KeyCodeNames.isFunctionKey(combo.keyCode) { return true }
        return combo.option || combo.control
    }
}
