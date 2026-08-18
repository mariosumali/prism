// PresetsPane.swift
// PRISM
//
// Full preset management (§5.5): apply, reorder, rename, duplicate, delete,
// JSON export/import, and hotkey assignment (⌥⌘1–9, the digits the Hotkeys
// tap matches). Built-ins can be applied, reordered, duplicated, and given
// hotkeys, but never renamed, edited, or deleted — PresetStore enforces the
// same rules, so this UI just mirrors them.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PresetsPane: View {
    @EnvironmentObject var state: AppState

    @State private var showingSaveSheet = false
    @State private var newPresetName = ""
    @State private var renameTarget: Preset?
    @State private var renameText = ""

    /// ANSI keycodes for the digit row, 1 through 9 (KeyCodeNames order).
    private static let digitKeyCodes: [(label: String, keyCode: UInt16)] = [
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23),
        ("6", 22), ("7", 26), ("8", 28), ("9", 25),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(state.presets) { preset in
                    row(for: preset)
                }
                .onMove { offsets, destination in
                    state.presetStore.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            Divider()
            HStack(spacing: Metrics.itemGap) {
                Button("Save current as preset…") {
                    newPresetName = ""
                    showingSaveSheet = true
                }
                Button("Import…") { importPreset() }
                Spacer()
                Text("Drag to reorder · right-click for more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Metrics.gutter)
        }
        .sheet(isPresented: $showingSaveSheet) { saveSheet }
        .sheet(item: $renameTarget) { preset in renameSheet(preset) }
    }

    // MARK: - Rows

    private func row(for preset: Preset) -> some View {
        let isActive = state.activePresetID == preset.id
        let ruleApp = ruleAppName(for: preset)
        return HStack(spacing: Metrics.itemGap) {
            Circle()
                .fill(isActive ? Color.accentColor : .clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                // §5.15: the same "why is this one on air" answer the
                // popover's chips give, in the roomier form this pane has
                // space for.
                if let ruleApp {
                    Text("Applied by a rule for \(ruleApp)")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                } else if preset.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            hotkeyMenu(for: preset)
            // Never disabled: activePresetID is not cleared when the live
            // configuration diverges from the preset, so "active" only means
            // "last applied" — re-applying must stay available (the popover's
            // chips behave the same way).
            Button("Apply") { state.selectPreset(preset.id) }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(preset.name)
        .accessibilityValue(ruleApp.map { "active, applied by a rule for \($0)" }
                            ?? (isActive ? "active" : "inactive"))
        .contextMenu {
            Button("Apply") { state.selectPreset(preset.id) }
            Button("Rename…") {
                renameText = preset.name
                renameTarget = preset
            }
            .disabled(preset.isBuiltIn)
            Button("Duplicate") {
                _ = state.presetStore.duplicate(preset.id)
            }
            Button("Delete", role: .destructive) {
                state.presetStore.delete(preset.id)
            }
            .disabled(preset.isBuiltIn)
            Divider()
            Button("Export as JSON…") { exportPreset(preset) }
        }
    }

    private func ruleAppName(for preset: Preset) -> String? {
        guard let rule = state.activeAppRule, rule.presetID == preset.id else { return nil }
        return CMIOSink.displayName(forSigningID: rule.signingID)
    }

    private func hotkeyMenu(for preset: Preset) -> some View {
        Menu(preset.hotkey?.displayString ?? "No hotkey") {
            Button("None") {
                state.presetStore.setHotkey(preset.id, hotkey: nil)
            }
            Divider()
            ForEach(Self.digitKeyCodes, id: \.keyCode) { digit in
                Button("⌥⌘\(digit.label)") {
                    state.presetStore.setHotkey(
                        preset.id,
                        hotkey: HotkeyCombo(keyCode: digit.keyCode,
                                            option: true, command: true))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Hotkey for \(preset.name)")
        .accessibilityValue(preset.hotkey?.displayString ?? "none")
    }

    // MARK: - Sheets

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            Text("Save preset")
                .font(.headline)
            TextField("Name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityLabel("Preset name")
            HStack {
                Spacer()
                Button("Cancel") {
                    showingSaveSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let name = newPresetName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        state.saveCurrentAsPreset(named: name)
                    }
                    showingSaveSheet = false
                    newPresetName = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Metrics.gutter)
    }

    private func renameSheet(_ preset: Preset) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionGap) {
            Text("Rename preset")
                .font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityLabel("Preset name")
            HStack {
                Spacer()
                Button("Cancel") {
                    renameTarget = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        state.presetStore.rename(preset.id, to: name)
                    }
                    renameTarget = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Metrics.gutter)
    }

    // MARK: - Export / import

    private func exportPreset(_ preset: Preset) {
        guard let data = state.presetStore.exportJSON(preset.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                guard let data = try? Data(contentsOf: url),
                      (try? state.presetStore.importJSON(data)) != nil else {
                    state.warning = WarningMessage(
                        text: "Couldn't read that preset. PRISM imports presets exported as JSON.")
                    return
                }
            }
        }
    }
}
