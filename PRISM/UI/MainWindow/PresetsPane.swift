// PresetsPane.swift
// PRISM
//
// Full preset management (§5.5): apply, reorder, rename, duplicate, delete,
// JSON export/import, and hotkey assignment via the §5.15 recorder. Built-ins
// can be applied, reordered, duplicated, and given hotkeys, but never
// renamed, edited, or deleted — PresetStore enforces the same rules, so this
// UI just mirrors them.
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
        return HStack(spacing: Metrics.itemGap) {
            Circle()
                .fill(isActive ? Color.accentColor : .clear)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.body)
                if preset.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            hotkeyRecorder(for: preset)
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
        .accessibilityValue(isActive ? "active" : "inactive")
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

    /// The same recorder the built-in shortcuts use, so preset chords are
    /// not limited to the nine digits a menu could list — and so they go
    /// through the same conflict check, which a menu of ⌥⌘1–9 never did.
    private func hotkeyRecorder(for preset: Preset) -> some View {
        HotkeyRecorderField(combo: preset.hotkey,
                            label: "Shortcut for \(preset.name)") { combo in
            state.setPresetShortcut(combo, for: preset.id)
        }
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
