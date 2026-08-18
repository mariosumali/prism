// ShortcutBindingTests.swift
// PRISMTests
//
// The rebindable shortcut table (§5.15): key naming through the keyboard
// layout, what may be bound, collision detection, and the tolerant decoding
// that keeps a saved binding table from evaporating on upgrade.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class ShortcutBindingTests: XCTestCase {

    // MARK: Key names

    func testLayoutIndependentKeysAreNamedNotNumbered() {
        // These are the keys the old fixed table had no entry for at all;
        // every one of them used to print as "key105".
        XCTAssertEqual(KeyCodeNames.name(for: 105), "F13")
        XCTAssertEqual(KeyCodeNames.name(for: 122), "F1")
        XCTAssertEqual(KeyCodeNames.name(for: 49), "Space")
        XCTAssertEqual(KeyCodeNames.name(for: 53), "⎋")
        XCTAssertEqual(KeyCodeNames.name(for: 123), "←")
        XCTAssertEqual(KeyCodeNames.name(for: 76), "⌤")
        XCTAssertEqual(KeyCodeNames.name(for: 83), "Keypad 1")
    }

    func testCharacterKeysResolveThroughTheLayout() {
        // Letters, digits and punctuation: whatever the active layout, each
        // has to come back as a printable name rather than the placeholder.
        for code: UInt16 in [0, 3, 18, 29, 39, 41, 42, 43, 44, 47, 50] {
            let name = KeyCodeNames.name(for: code)
            XCTAssertFalse(name.isEmpty, "keycode \(code)")
            XCTAssertFalse(name.hasPrefix("Key "), "keycode \(code) fell through to a number")
        }
    }

    func testKeypadDigitsDoNotCollideWithTheNumberRow() {
        // They match as different bindings, so they must read as different
        // bindings — otherwise the list shows two identical rows.
        XCTAssertNotEqual(KeyCodeNames.name(for: 18), KeyCodeNames.name(for: 83))
    }

    func testModifierAndFunctionKeyClassification() {
        XCTAssertTrue(KeyCodeNames.isModifier(55))       // ⌘
        XCTAssertTrue(KeyCodeNames.isModifier(57))       // caps lock
        XCTAssertFalse(KeyCodeNames.isModifier(3))       // F on ANSI
        XCTAssertTrue(KeyCodeNames.isFunctionKey(105))   // F13
        XCTAssertFalse(KeyCodeNames.isFunctionKey(3))
    }

    func testDisplayStringModifierOrder() {
        let combo = HotkeyCombo(keyCode: 105, option: true, command: true,
                                shift: true, control: true)
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘F13")
    }

    // MARK: Bindability

    func testCommandOnlyChordsAreRefused() {
        // PRISM's tap is listen-only, so a ⌘ chord would run the front app's
        // menu command at the same moment it ran PRISM's action.
        XCTAssertFalse(HotkeyBindings.isBindable(
            HotkeyCombo(keyCode: 3, command: true)))
        XCTAssertFalse(HotkeyBindings.isBindable(
            HotkeyCombo(keyCode: 3, command: true, shift: true)))
        XCTAssertFalse(HotkeyBindings.isBindable(HotkeyCombo(keyCode: 3)))
    }

    func testOptionOrControlChordsAndBareFunctionKeysAreBindable() {
        XCTAssertTrue(HotkeyBindings.isBindable(
            HotkeyCombo(keyCode: 3, option: true, command: true)))
        XCTAssertTrue(HotkeyBindings.isBindable(
            HotkeyCombo(keyCode: 3, control: true)))
        XCTAssertTrue(HotkeyBindings.isBindable(HotkeyCombo(keyCode: 105)))
    }

    func testModifierKeysCannotBeBoundAlone() {
        XCTAssertFalse(HotkeyBindings.isBindable(
            HotkeyCombo(keyCode: 55, command: true)))
    }

    // MARK: The table

    func testDefaultsMatchTheDocumentedChords() {
        let bindings = HotkeyBindings()
        XCTAssertTrue(bindings.isDefaultEverywhere)
        XCTAssertEqual(bindings.combo(for: .freeze),
                       HotkeyCombo(keyCode: 3, option: true, command: true))
        XCTAssertEqual(bindings.combo(for: .freezeAndMute),
                       HotkeyCombo(keyCode: 3, option: true, command: true, shift: true))
        // §5.13: the one chord that takes ⌃, because ⌥⌘V is Finder's.
        XCTAssertEqual(bindings.combo(for: .voice),
                       HotkeyCombo(keyCode: 9, option: true, command: true, control: true))
        XCTAssertEqual(bindings.resolved.count, ShortcutAction.allCases.count)
    }

    func testEveryDefaultIsBindableAndUnique() {
        let combos = ShortcutAction.allCases.map(\.defaultCombo)
        XCTAssertEqual(Set(combos).count, combos.count)
        for combo in combos {
            XCTAssertTrue(HotkeyBindings.isBindable(combo), combo.displayString)
        }
    }

    func testUnbindingIsDistinctFromResetting() {
        var bindings = HotkeyBindings()
        bindings.set(nil, for: .lag)
        XCTAssertNil(bindings.combo(for: .lag))
        XCTAssertFalse(bindings.isDefault(.lag))
        // An unbound action must not reappear in what the tap matches.
        XCTAssertNil(bindings.resolved[.lag])
        bindings.reset(.lag)
        XCTAssertEqual(bindings.combo(for: .lag), ShortcutAction.lag.defaultCombo)
    }

    func testConflictFindsTheCurrentOwnerAndIgnoresItself() {
        let bindings = HotkeyBindings()
        let freeze = ShortcutAction.freeze.defaultCombo
        XCTAssertEqual(bindings.conflict(for: freeze, excluding: nil), .freeze)
        XCTAssertNil(bindings.conflict(for: freeze, excluding: .freeze))
        XCTAssertNil(bindings.conflict(
            for: HotkeyCombo(keyCode: 105), excluding: nil))
    }

    func testConflictSeesReassignedChordsNotDefaults() {
        var bindings = HotkeyBindings()
        let f13 = HotkeyCombo(keyCode: 105)
        bindings.set(f13, for: .panic)
        XCTAssertEqual(bindings.conflict(for: f13, excluding: nil), .panic)
        // Panic's old chord is nobody's now.
        XCTAssertNil(bindings.conflict(for: ShortcutAction.panic.defaultCombo,
                                       excluding: nil))
    }

    func testResetAllRestoresEveryKnownAction() {
        var bindings = HotkeyBindings()
        bindings.set(HotkeyCombo(keyCode: 105), for: .panic)
        bindings.set(nil, for: .lag)
        XCTAssertFalse(bindings.isDefaultEverywhere)
        bindings.resetAll()
        XCTAssertTrue(bindings.isDefaultEverywhere)
    }

    // MARK: Persistence

    func testBindingsRoundTrip() throws {
        var bindings = HotkeyBindings()
        bindings.set(HotkeyCombo(keyCode: 105, control: true), for: .panic)
        bindings.set(nil, for: .badConnection)
        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode(HotkeyBindings.self, from: data)
        XCTAssertEqual(decoded, bindings)
        XCTAssertEqual(decoded.combo(for: .panic),
                       HotkeyCombo(keyCode: 105, control: true))
        XCTAssertNil(decoded.combo(for: .badConnection))
    }

    func testEmptyAndPartialJSONDecodeToDefaults() throws {
        // A build that adds a field to HotkeyBindings must not wipe the
        // bindings written by the build before it.
        let empty = try JSONDecoder().decode(
            HotkeyBindings.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.isDefaultEverywhere)

        let partial = try JSONDecoder().decode(
            HotkeyBindings.self,
            from: Data(#"{"cleared":["lag"]}"#.utf8))
        XCTAssertNil(partial.combo(for: .lag))
        XCTAssertEqual(partial.combo(for: .freeze), ShortcutAction.freeze.defaultCombo)
    }

    func testUnknownActionsSurviveADowngrade() throws {
        // The table is keyed by raw string precisely so a build that has
        // never heard of an action carries its binding through instead of
        // deleting it on the next save.
        let json = #"{"assigned":{"teleport":{"keyCode":105,"control":true}}}"#
        let decoded = try JSONDecoder().decode(HotkeyBindings.self,
                                               from: Data(json.utf8))
        let reencoded = String(decoding: try JSONEncoder().encode(decoded),
                               as: UTF8.self)
        XCTAssertTrue(reencoded.contains("teleport"))
    }

    func testComboToleratesMissingModifiersButNotAMissingKeycode() throws {
        let sparse = try JSONDecoder().decode(
            HotkeyCombo.self, from: Data(#"{"keyCode":105}"#.utf8))
        XCTAssertEqual(sparse, HotkeyCombo(keyCode: 105))
        // Defaulting the keycode would silently bind the user to ⌥⌘A; the
        // throw is what makes the enclosing tolerant decode fall back.
        XCTAssertThrowsError(try JSONDecoder().decode(
            HotkeyCombo.self, from: Data(#"{"option":true}"#.utf8)))
    }

    func testMalformedComboLeavesTheRestOfTheTableIntact() throws {
        let json = #"{"assigned":{"panic":{"option":true}},"cleared":["lag"]}"#
        let decoded = try JSONDecoder().decode(HotkeyBindings.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded.combo(for: .panic), ShortcutAction.panic.defaultCombo)
        XCTAssertNil(decoded.combo(for: .lag))
    }

    // MARK: Actions

    func testOnlyTheLagSwitchIsMomentary() {
        // §5.12: it is the only chord whose key release is observed.
        let momentary = ShortcutAction.allCases.filter(\.isMomentary)
        XCTAssertEqual(momentary, [.lag])
    }
}
