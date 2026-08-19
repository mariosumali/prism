// HotkeyBindings.swift
// PRISM
//
// The persisted rebinding table for the global actions (§5.19). The actions
// themselves — and the chords they ship with — are `ShortcutAction` in
// Hotkeys.swift, next to the tap that matches them; this file is only the
// user's deviations from those defaults, plus the rules about what may be
// deviated to.
//
// Hotkeys matches against `resolved`; the Shortcuts pane edits it through
// AppState, which is where collisions are arbitrated.
//
// Licensed under the Apache License, Version 2.0.

import Foundation

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
