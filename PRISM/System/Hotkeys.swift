// Hotkeys.swift
// PRISM
//
// Global hotkeys (§5.2): ⌥⌘F freeze, ⌥⌘M mute, ⌥⌘⇧F freeze+mute, plus
// user-bound preset combos. Primary path is a listen-only CGEventTap on
// keyDown; when tap creation fails (no Accessibility / Input Monitoring
// permission) it falls back to NSEvent global+local monitors. The fallback
// cannot consume events — which is fine, PRISM never consumes any event.
// All callbacks fire on the main thread.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import CoreGraphics
import Foundation

public final class Hotkeys {

    // MARK: Fixed combos
    //
    // §5.2 originals plus the studio chords (§5.6, §5.9–§5.11). All share the
    // ⌥⌘ prefix so they read as one family and none collide with an app
    // shortcut a user is likely to have muscle memory for. ANSI keycodes:
    // F = 3, M = 46, R = 15, A = 0, P = 35, E = 14.

    public static let freezeCombo = HotkeyCombo(keyCode: 3, option: true, command: true)
    public static let muteCombo = HotkeyCombo(keyCode: 46, option: true, command: true)
    public static let freezeAndMuteCombo = HotkeyCombo(keyCode: 3, option: true, command: true, shift: true)
    public static let replayCombo = HotkeyCombo(keyCode: 15, option: true, command: true)
    public static let awayCombo = HotkeyCombo(keyCode: 0, option: true, command: true)
    /// Deliberately un-shifted: a panic key you have to reach for is not one.
    public static let panicCombo = HotkeyCombo(keyCode: 35, option: true, command: true)
    public static let eyeContactCombo = HotkeyCombo(keyCode: 14, option: true, command: true)
    /// §5.12. The only combo that also reports its key release, so it can be
    /// held rather than toggled — which is what "switch" means.
    public static let lagCombo = HotkeyCombo(keyCode: 37, option: true, command: true)

    // MARK: Callbacks (invoked on the main thread)

    public var onFreeze: (() -> Void)?             // ⌥⌘F
    public var onMute: (() -> Void)?               // ⌥⌘M
    public var onFreezeAndMute: (() -> Void)?      // ⌥⌘⇧F
    public var onReplay: (() -> Void)?             // ⌥⌘R
    public var onAway: (() -> Void)?               // ⌥⌘A
    public var onPanic: (() -> Void)?              // ⌥⌘P
    public var onEyeContact: (() -> Void)?         // ⌥⌘E
    /// ⌥⌘L press and release. `true` on keyDown, `false` on keyUp, so the
    /// receiver can implement either hold-to-lag or a toggle (§5.12).
    public var onLag: ((Bool) -> Void)?
    public var onPreset: ((UUID) -> Void)?

    // MARK: State

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var presetBindings: [(UUID, HotkeyCombo)] = []

    public init() {}

    deinit {
        stop()
    }

    /// Registers preset hotkeys (§5.5). Call on the main thread; the tap's
    /// run-loop source lives on the main run loop, so matching reads this
    /// array on the main thread too.
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
        guard keyCode == Self.lagCombo.keyCode else { return }
        fire { $0.onLag?(false) }
    }

    /// Exact modifier matching over {⌥, ⌘, ⇧, ⌃} so ⌥⌘F and ⌥⌘⇧F stay
    /// distinct combos rather than one shadowing the other.
    private func match(keyCode: UInt16, option: Bool, command: Bool,
                       shift: Bool, control: Bool) {
        func matches(_ combo: HotkeyCombo) -> Bool {
            combo.keyCode == keyCode
                && combo.option == option
                && combo.command == command
                && combo.shift == shift
                && combo.control == control
        }

        if matches(Self.freezeAndMuteCombo) {
            fire { $0.onFreezeAndMute?() }
        } else if matches(Self.freezeCombo) {
            fire { $0.onFreeze?() }
        } else if matches(Self.muteCombo) {
            fire { $0.onMute?() }
        } else if matches(Self.replayCombo) {
            fire { $0.onReplay?() }
        } else if matches(Self.awayCombo) {
            fire { $0.onAway?() }
        } else if matches(Self.panicCombo) {
            fire { $0.onPanic?() }
        } else if matches(Self.eyeContactCombo) {
            fire { $0.onEyeContact?() }
        } else if matches(Self.lagCombo) {
            fire { $0.onLag?(true) }
        } else if let (id, _) = presetBindings.first(where: { matches($0.1) }) {
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
