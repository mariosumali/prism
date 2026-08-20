// HotkeyRecorder.swift
// PRISM
//
// The shortcut recorder (§5.19) and the shortcut list built from it, used
// by the main window's Shortcuts pane — one list, so nothing can disagree
// about what is bound.
//
// A recorder rather than a menu of chords: the combos worth binding outnumber
// any list worth reading, and pressing the key is how everyone expects to
// answer "what shortcut?".
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Recorder

struct HotkeyRecorderField: View {
    @EnvironmentObject var state: AppState

    let combo: HotkeyCombo?
    let label: String
    /// nil means the user cleared the binding.
    let onRecord: (HotkeyCombo?) -> Void

    @State private var recording = false

    var body: some View {
        Button {
            setRecording(true)
        } label: {
            Text(recording ? "Type a shortcut" : (combo?.displayString ?? "None"))
                .font(.body.monospaced())
                .foregroundStyle(recording ? Color.accentColor
                                 : (combo == nil ? .secondary : .primary))
                .frame(minWidth: 90)
                .padding(.vertical, 3)
                .padding(.horizontal, Metrics.itemGap)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.controlRadius)
                        .strokeBorder(recording ? Color.accentColor
                                      : Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .background(recorderOverlay)
        .help(recording
              ? "Press the keys you want, ⎋ to cancel, ⌫ to clear"
              : "Click, then press the keys you want")
        .accessibilityLabel(label)
        .accessibilityValue(combo?.displayString ?? "none")
        .onDisappear {
            // A pane switched away mid-recording must not leave the global
            // tap stopped — that would silently kill every chord in the app.
            if recording { setRecording(false) }
        }
    }

    @ViewBuilder
    private var recorderOverlay: some View {
        if recording {
            KeyCapture { event in
                switch event {
                case .cancel:
                    setRecording(false)
                case .clear:
                    onRecord(nil)
                    setRecording(false)
                case .combo(let recorded):
                    onRecord(recorded)
                    setRecording(false)
                }
            }
            .frame(width: 0, height: 0)
        }
    }

    private func setRecording(_ on: Bool) {
        guard recording != on else { return }
        recording = on
        // PRISM listens for these chords itself: without this, binding a key
        // to Panic would panic while you bound it.
        if on {
            state.beginShortcutRecording()
        } else {
            state.endShortcutRecording()
        }
    }
}

private enum RecordedKey {
    case combo(HotkeyCombo)
    case clear
    case cancel
}

/// Zero-sized first responder that swallows one keystroke.
///
/// `performKeyEquivalent` is overridden as well as `keyDown` because ⌘ chords
/// never reach `keyDown` — they are dispatched as key equivalents first, and
/// a recorder that cannot see ⌘ would silently record ⌥⌘F as ⌥F.
private struct KeyCapture: NSViewRepresentable {
    let onKey: (RecordedKey) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: KeyCaptureView, context: Context) {
        view.onKey = onKey
        view.claimFocus()
    }
}

private final class KeyCaptureView: NSView {
    var onKey: ((RecordedKey) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimFocus()
    }

    func claimFocus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        deliver(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        deliver(event)
        return true
    }

    private func deliver(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onKey?(.cancel)
        case kVK_Delete, kVK_ForwardDelete:
            onKey?(.clear)
        default:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            onKey?(.combo(HotkeyCombo(keyCode: event.keyCode,
                                      option: flags.contains(.option),
                                      command: flags.contains(.command),
                                      shift: flags.contains(.shift),
                                      control: flags.contains(.control))))
        }
    }
}

// MARK: - Shortcut list

/// Every bindable action plus every preset that has a chord, in one list.
/// Presets are here and not only in the Presets pane because they share the
/// keyboard with the built-ins: a conflict you cannot see is one you cannot
/// resolve.
struct ShortcutsList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Section("Keyboard shortcuts") {
            ForEach(ShortcutAction.allCases) { action in
                LabeledContent(action.displayName) {
                    HStack(spacing: Metrics.itemGap) {
                        HotkeyRecorderField(
                            combo: state.shortcut(for: action),
                            label: "Shortcut for \(action.displayName)") { combo in
                                state.setShortcut(combo, for: action)
                            }
                        Button {
                            state.resetShortcut(action)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .opacity(state.hotkeyBindings.isDefault(action) ? 0 : 1)
                        .disabled(state.hotkeyBindings.isDefault(action))
                        .accessibilityLabel("Reset \(action.displayName) shortcut")
                    }
                }
            }
            HStack {
                Button("Reset all shortcuts") { state.resetAllShortcuts() }
                    .disabled(state.hotkeyBindings.isDefaultEverywhere)
                Spacer()
            }
            Text("Shortcuts need ⌥ or ⌃ (function keys can stand alone). PRISM listens without swallowing the keystroke, so a ⌘ chord would reach the app in front of you as well.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Preset shortcuts") {
            ForEach(state.presets) { preset in
                LabeledContent(preset.name) {
                    HotkeyRecorderField(
                        combo: preset.hotkey,
                        label: "Shortcut for \(preset.name)") { combo in
                            state.setPresetShortcut(combo, for: preset.id)
                        }
                }
            }
        }
    }
}
