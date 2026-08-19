// ShortcutsPane.swift
// PRISM
//
// The whole control surface in one pane (§5.19, §5.20): the global chords,
// the preset chords, and the switch that lets Shortcuts — and through it a
// Stream Deck, a Focus filter, an automation — drive PRISM.
//
// One pane for both because they answer the same question: what can reach
// PRISM without the window being open.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct ShortcutsPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            ShortcutsList()
            Section("Other apps") {
                Toggle("Allow control from Shortcuts",
                       isOn: Binding(get: { state.externalControlEnabled },
                                     set: { state.externalControlEnabled = $0 }))
                Text("Lets the Shortcuts app — and hardware that runs shortcuts, like a Stream Deck — freeze, mute, panic, replay, step away, and switch presets. Off until you turn it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Nothing here reads your camera, your microphone, or your replay buffer, and no shortcut can pick a device, change formats, load a file, quit PRISM, or edit this list. PRISM still makes no network connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
