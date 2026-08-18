// Hotkeys.swift
// PRISM
//
// Global hotkeys (§5.2, §5.15): a table of ShortcutAction → HotkeyCombo the
// user can rebind, plus user-bound preset combos. Primary path is a
// listen-only CGEventTap on keyDown; when tap creation fails (no
// Accessibility / Input Monitoring permission) it falls back to NSEvent
// global+local monitors. The fallback cannot consume events — which is fine,
// PRISM never consumes any event. All callbacks fire on the main thread.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import CoreGraphics
import Foundation

public final class Hotkeys {

    // MARK: Callbacks (invoked on the main thread)

    /// A bound chord went down. The action names what to do; Hotkeys knows
    /// nothing about what any of them mean.
    public var onAction: ((ShortcutAction) -> Void)?
    /// A momentary action's key came back up (§5.12 lag switch). Fires only
    /// for `isMomentary` actions — nothing else observes releases.
    public var onActionRelease: ((ShortcutAction) -> Void)?
    public var onPreset: ((UUID) -> Void)?

    // MARK: State

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var bindings: [ShortcutAction: HotkeyCombo] =
        HotkeyBindings().resolved
    private var presetBindings: [(UUID, HotkeyCombo)] = []

    public init() {}

    deinit {
        stop()
    }

    /// Installs the built-in action bindings (§5.15). Call on the main
    /// thread; the tap's run-loop source lives on the main run loop, so
    /// matching reads this table on the main thread too.
    public func setBindings(_ bindings: [ShortcutAction: HotkeyCombo]) {
        self.bindings = bindings
    }

    /// Registers preset hotkeys (§5.5). Same threading rule as setBindings.
    public func setPresetBindings(_ bindings: [(UUID, HotkeyCombo)]) {
        presetBindings = bindings
    }

    /// Starts listening. Prefers a session-level, listen-only CGEventTap on
    /// keyDown; falls back to NSEvent monitors when the tap cannot be created
    /// (typically because the user has not granted input-monitoring access).
    public func start() {
        stop()

        // keyUp is in the mask only for the lag switch (§5.12), which is held
        // rather than toggled. Every other combo ignores it.
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue))
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue()

            // The WindowServer disables taps that stall; a listen-only tap
            // should never stall, but re-enable defensively either way.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = hotkeys.tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let keyCode = UInt16(truncatingIfNeeded:
                event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown {
                // Ignore key autorepeat: holding ⌥⌘F must not toggle freeze
                // on every repeat.
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    let flags = event.flags
                    hotkeys.match(keyCode: keyCode,
                                  option: flags.contains(.maskAlternate),
                                  command: flags.contains(.maskCommand),
                                  shift: flags.contains(.maskShift),
                                  control: flags.contains(.maskControl))
                }
            } else if type == .keyUp {
                hotkeys.matchRelease(keyCode: keyCode)
            }
            // Listen-only tap: the return value is ignored, but returning the
            // event unmodified is the documented convention.
            return Unmanaged.passUnretained(event)
        }

        if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                       place: .headInsertEventTap,
                                       options: .listenOnly,
                                       eventsOfInterest: mask,
                                       callback: callback,
                                       userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            self.tap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }

        // Fallback: NSEvent monitors. A global monitor observes key events in
        // other apps (it cannot consume them — fine, PRISM never consumes);
        // a local monitor covers keystrokes while PRISM itself is frontmost
        // (e.g. the popover is open), which global monitors do not see.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(nsEvent: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handle(nsEvent: event)
            return event   // never consume
        }
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFRunLoopSourceInvalidate(runLoopSource)
        }
        tap = nil
        runLoopSource = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    // MARK: - Matching

    private func handle(nsEvent event: NSEvent) {
        if event.type == .keyUp {
            matchRelease(keyCode: event.keyCode)
            return
        }
        guard !event.isARepeat else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        match(keyCode: event.keyCode,
              option: flags.contains(.option),
              command: flags.contains(.command),
              shift: flags.contains(.shift),
              control: flags.contains(.control))
    }

    /// Key releases are matched on the keycode alone, deliberately.
    ///
    /// Nobody releases ⌥, ⌘ and L in a defined order, so requiring the full
    /// combo on the way up would routinely miss the release and leave the lag
    /// switch stuck on — exactly the failure this app cares most about.
    /// Matching the bare keycode means a stray L keyup releases a lag that
    /// was not engaged, which is harmless.
    private func matchRelease(keyCode: UInt16) {
        for action in ShortcutAction.allCases where action.isMomentary {
            guard bindings[action]?.keyCode == keyCode else { continue }
            fire { $0.onActionRelease?(action) }
        }
    }

    /// Exact modifier matching over {⌥, ⌘, ⇧, ⌃} so ⌥⌘F and ⌥⌘⇧F stay
    /// distinct combos rather than one shadowing the other.
    ///
    /// At most one action can own a chord — the binding editor resolves
    /// collisions when they are made, not here — so the table is scanned in
    /// whatever order it comes in, and the first hit wins.
    private func match(keyCode: UInt16, option: Bool, command: Bool,
                       shift: Bool, control: Bool) {
        let pressed = HotkeyCombo(keyCode: keyCode, option: option,
                                  command: command, shift: shift,
                                  control: control)
        if let action = bindings.first(where: { $0.value == pressed })?.key {
            fire { $0.onAction?(action) }
        } else if let (id, _) = presetBindings.first(where: { $0.1 == pressed }) {
            fire { $0.onPreset?(id) }
        }
    }

    /// Delivers a callback on the main thread. The tap source lives on the
    /// main run loop so this is usually a direct call; the NSEvent fallback
    /// goes through the same funnel for uniformity.
    private func fire(_ action: @escaping (Hotkeys) -> Void) {
        if Thread.isMainThread {
            action(self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                action(self)
            }
        }
    }
}
