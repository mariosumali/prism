// KeyCodeNames.swift
// PRISM
//
// Renders a virtual keycode as the glyph the user will actually press.
// Two sources, in order: a fixed table for the keys whose label is the same
// on every layout (function keys, arrows, the editing block, the keypad),
// and UCKeyTranslate against the current keyboard layout for everything
// else. Only if both fail does a keycode fall back to an ANSI table.
//
// This matters because bindings are recorded, not chosen from a list: the
// user presses a key and PRISM has to name it back to them. A fixed 26-entry
// table names A–Z and the digit row on a US layout and nothing else — a
// French user binding ⌥⌘A would be told they bound ⌥⌘Q, and anyone binding
// a function key or a punctuation key would be shown "key57".
//
// Licensed under the Apache License, Version 2.0.

import Carbon.HIToolbox
import Foundation

public enum KeyCodeNames {

    /// The glyph to print for `keyCode` in a shortcut string.
    public static func name(for keyCode: UInt16) -> String {
        if let fixed = fixedNames[keyCode] { return fixed }
        if let translated = KeyboardLayout.shared.character(for: keyCode) {
            return translated
        }
        return ansiFallback[keyCode] ?? "Key \(keyCode)"
    }

    /// Function keys are the one family that is safe to bind bare: they type
    /// nothing, so a binding without modifiers cannot fire mid-sentence.
    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys.contains(keyCode)
    }

    /// Keys that cannot carry a binding on their own — pressing one is how
    /// you *start* a chord, not how you finish it.
    public static func isModifier(_ keyCode: UInt16) -> Bool {
        modifierKeys.contains(keyCode)
    }

    private static let functionKeys: Set<UInt16> = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4),
        UInt16(kVK_F5), UInt16(kVK_F6), UInt16(kVK_F7), UInt16(kVK_F8),
        UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15), UInt16(kVK_F16),
        UInt16(kVK_F17), UInt16(kVK_F18), UInt16(kVK_F19), UInt16(kVK_F20),
    ]

    private static let modifierKeys: Set<UInt16> = [
        UInt16(kVK_Command), UInt16(kVK_RightCommand),
        UInt16(kVK_Shift), UInt16(kVK_RightShift),
        UInt16(kVK_Option), UInt16(kVK_RightOption),
        UInt16(kVK_Control), UInt16(kVK_RightControl),
        UInt16(kVK_CapsLock), UInt16(kVK_Function),
    ]

    /// Layout-independent names. The glyphs are the ones macOS itself prints
    /// in menus, so a PRISM shortcut reads like any other shortcut.
    private static let fixedNames: [UInt16: String] = [
        UInt16(kVK_Return): "↩",
        UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Space): "Space",
        UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋",
        UInt16(kVK_Home): "↖",
        UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞",
        UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_Help): "Help",
        UInt16(kVK_LeftArrow): "←",
        UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑",
        UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
        UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
        // The keypad shares its glyphs with the number row, so it has to be
        // named separately or ⌥⌘7 and ⌥⌘keypad-7 print identically while
        // matching as different bindings.
        UInt16(kVK_ANSI_Keypad0): "Keypad 0",
        UInt16(kVK_ANSI_Keypad1): "Keypad 1",
        UInt16(kVK_ANSI_Keypad2): "Keypad 2",
        UInt16(kVK_ANSI_Keypad3): "Keypad 3",
        UInt16(kVK_ANSI_Keypad4): "Keypad 4",
        UInt16(kVK_ANSI_Keypad5): "Keypad 5",
        UInt16(kVK_ANSI_Keypad6): "Keypad 6",
        UInt16(kVK_ANSI_Keypad7): "Keypad 7",
        UInt16(kVK_ANSI_Keypad8): "Keypad 8",
        UInt16(kVK_ANSI_Keypad9): "Keypad 9",
        UInt16(kVK_ANSI_KeypadDecimal): "Keypad .",
        UInt16(kVK_ANSI_KeypadPlus): "Keypad +",
        UInt16(kVK_ANSI_KeypadMinus): "Keypad −",
        UInt16(kVK_ANSI_KeypadMultiply): "Keypad ×",
        UInt16(kVK_ANSI_KeypadDivide): "Keypad ÷",
        UInt16(kVK_ANSI_KeypadEquals): "Keypad =",
        UInt16(kVK_ANSI_KeypadClear): "Keypad ⌧",
        UInt16(kVK_ANSI_KeypadEnter): "⌤",
    ]

    /// Last resort. UCKeyTranslate needs a keyboard layout input source, and
    /// there are contexts (a headless test host, a login-window session)
    /// where that lookup returns nothing at all. Naming the ANSI positions
    /// then is far better than printing a raw keycode.
    private static let ansiFallback: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]
}

/// Caches the translation of keycodes through the active keyboard layout.
///
/// UCKeyTranslate is not expensive, but the layout it translates against can
/// change under us at any moment (⌃Space), and every shortcut label in the
/// app would then be stale. Watching the input-source notification and
/// dropping the cache is cheaper and more correct than either re-translating
/// on every draw or never noticing.
private final class KeyboardLayout {
    static let shared = KeyboardLayout()

    private let lock = NSLock()
    private var cache: [UInt16: String] = [:]

    private init() {
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(layoutChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil)
    }

    @objc private func layoutChanged() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func character(for keyCode: UInt16) -> String? {
        lock.lock()
        if let hit = cache[keyCode] {
            lock.unlock()
            return hit.isEmpty ? nil : hit
        }
        lock.unlock()

        let translated = translate(keyCode) ?? ""
        lock.lock()
        cache[keyCode] = translated
        lock.unlock()
        return translated.isEmpty ? nil : translated
    }

    private func translate(_ keyCode: UInt16) -> String? {
        guard let data = layoutData() else { return nil }
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 8)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return OSStatus(paramErr) }
            // kUCKeyActionDisplay with no modifier bits asks the layout what
            // this key *is called*, which is not always what it types: on a
            // French layout keycode 18 types "&" and is called "1".
            return UCKeyTranslate(base,
                                  keyCode,
                                  UInt16(kUCKeyActionDisplay),
                                  0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState,
                                  characters.count,
                                  &length,
                                  &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        // Control characters translate to unprintable scalars; those keys are
        // in the fixed table already, and printing a control glyph would be
        // worse than falling through.
        guard let scalar = text.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !text.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return text.uppercased()
    }

    private func layoutData() -> Data? {
        // The selected source can be an input method with no layout data at
        // all (Pinyin, Kotoeri); the ASCII-capable source is what macOS
        // itself falls back to for shortcut display in that case.
        if let data = layoutData(from: TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue()) {
            return data
        }
        return layoutData(from: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeRetainedValue())
    }

    private func layoutData(from source: TISInputSource?) -> Data? {
        guard let source,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }
}
