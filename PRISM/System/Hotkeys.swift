// Hotkeys.swift
// PRISM
//
// Global hotkeys (§5.2, §5.19): a table of ShortcutAction → HotkeyCombo the
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

/// One case per global intent PRISM can be driven by, and the chord that
/// reaches it by default.
///
/// The shape this replaced — a constant, a callback and a rung of an if/else
/// ladder per chord — made every new shortcut a three-place edit, and made a
/// rebindable chord impossible, since matching could only ever compare
/// against constants. With the binding as data, `match` is a lookup and the
/// receiver switches over the action exhaustively: a shortcut cannot be added
/// without the compiler asking what it does.
///
/// Every chord below is a *default*, not a constant: §5.19 lets the user
/// rebind any of them, and `HotkeyBindings` is where their choices live. The
/// chords stay documented here because a default nobody can find is the same
/// as no default.
///
/// Every chord shares the ⌥⌘ family prefix except the two that add ⌃ for the
/// reason documented on their cases.
public enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    case freeze                 // ⌥⌘F
    case mute                   // ⌥⌘M
    case freezeAndMute          // ⌥⌘⇧F
    case replay                 // ⌥⌘R
    case away                   // ⌥⌘A
    /// Deliberately un-shifted: a panic key you have to reach for is not one.
    case panic                  // ⌥⌘P
    case eyeContact             // ⌥⌘E
    /// §5.12. The only action that also reports its key release, so it can be
    /// held rather than toggled — which is what "switch" means.
    case lag                    // ⌥⌘L
    /// §5.14: B for bad connection. A toggle, not a hold — the stunt runs for
    /// minutes, and nobody holds a chord through a meeting.
    case badConnection          // ⌥⌘B
    /// §5.13: voice changer on/off, recalling the last used effect. ⌥⌘V is
    /// Finder's "Move Item Here" (and Xcode's paste-preserving-formatting),
    /// so the plain combo would put a chipmunk on air every time someone
    /// moved files mid-call — and ⌥⇧⌘V is the system-wide Paste and Match
    /// Style, so ⌃ it is.
    case voice                  // ⌃⌥⌘V
    case saveClip               // ⌥⌘S
    /// The shifted sibling of save, exactly as freeze+mute is the shifted
    /// sibling of freeze: matching is exact over all four modifiers, so
    /// ⌥⌘S and ⌥⌘⇧S are two chords rather than one shadowing the other.
    case snapshot               // ⌥⌘⇧S
    case screenSource           // ⌥⌘D
    /// Carries ⌃ for the same reason the voice changer does: PRISM's tap
    /// never consumes, so a plain ⌥⌘T would also open the frontmost app's
    /// Show Fonts panel every time the prompter was toggled.
    case prompter               // ⌃⌥⌘T
    /// §5.32: start or stop transcribing this call. ⌃ for the prompter's
    /// reason — ⌥⌘M is already mute, and matching is exact over all four
    /// modifiers, so these are two chords rather than one shadowing the
    /// other.
    case meeting                // ⌃⌥⌘M
    /// §5.33: ask the assistant. Also ⌃-carrying, and deliberately not the
    /// away loop's ⌥⌘A.
    ///
    /// The chord never dismisses the panel. Copying the prompter's
    /// asymmetry: the key you reach for mid-sentence means "answer this",
    /// never "make it disappear", because dismissing something you cannot
    /// see you dismissed is unrecoverable.
    case ask                    // ⌃⌥⌘A
    /// §5.34: live insights on or off. A toggle, unlike `ask`, because the
    /// thing it controls is a mode rather than an act — and a mode that
    /// sends the transcript on its own needs a key that turns it off as
    /// readily as it turned it on. Turning it on also starts listening and
    /// shows the panel (§8.7): the chord means "start showing me things",
    /// and a chord that did nothing until two other switches were found is
    /// a chord nobody would press twice.
    case insights               // ⌃⌥⌘I

    /// ANSI key codes: F = 3, M = 46, R = 15, A = 0, P = 35, E = 14,
    /// L = 37, B = 11, V = 9, S = 1, D = 2, T = 17, I = 34.
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
            return HotkeyCombo(keyCode: 35, option: true, command: true)
        case .eyeContact:
            return HotkeyCombo(keyCode: 14, option: true, command: true)
        case .lag:
            return HotkeyCombo(keyCode: 37, option: true, command: true)
        case .badConnection:
            return HotkeyCombo(keyCode: 11, option: true, command: true)
        case .voice:
            return HotkeyCombo(keyCode: 9, option: true, command: true, control: true)
        case .saveClip:
            return HotkeyCombo(keyCode: 1, option: true, command: true)
        case .snapshot:
            return HotkeyCombo(keyCode: 1, option: true, command: true, shift: true)
        case .screenSource:
            return HotkeyCombo(keyCode: 2, option: true, command: true)
        case .prompter:
            return HotkeyCombo(keyCode: 17, option: true, command: true, control: true)
        case .meeting:
            return HotkeyCombo(keyCode: 46, option: true, command: true, control: true)
        case .ask:
            return HotkeyCombo(keyCode: 0, option: true, command: true, control: true)
        case .insights:
            return HotkeyCombo(keyCode: 34, option: true, command: true, control: true)
        }
    }

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
        case .saveClip: return "Save the last seconds"
        case .snapshot: return "Take a still"
        case .screenSource: return "Share a screen"
        case .prompter: return "Prompter"
        case .meeting: return "Transcribe this call"
        case .ask: return "Ask the assistant"
        case .insights: return "Live insights"
        }
    }

    /// §5.12: the lag switch is the only action whose key *release* is
    /// observed, so it can be held rather than toggled — which is what
    /// "switch" means. A property rather than a comparison at the two call
    /// sites, so a second held action is one line here and not a hunt.
    public var isMomentary: Bool { self == .lag }

    /// For `ForEach` over the binding editor's rows (§5.19).
    public var id: String { rawValue }
}

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
    /// Starts on the defaults so a Hotkeys nobody has configured still works;
    /// AppState overwrites this the moment the persisted table is loaded.
    private var bindings: [ShortcutAction: HotkeyCombo] =
        HotkeyBindings().resolved
    private var presetBindings: [(UUID, HotkeyCombo)] = []

    public init() {}

    deinit {
        stop()
    }

    /// Installs the chord table (§5.19). The map is taken as given rather
    /// than back-filled with defaults: an action the user has deliberately
    /// unbound is *absent*, and re-adding its default here would hand back
    /// the chord they just took away. Call on the main thread; the tap's
    /// run-loop source lives on the main run loop, so matching reads this
    /// table on the main thread too.
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
    ///
    /// The keycode comes from the current binding, not a constant: a rebound
    /// lag switch that could be pressed but never released would be the worst
    /// possible outcome of rebinding it.
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
