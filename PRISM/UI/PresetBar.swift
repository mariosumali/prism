// PresetBar.swift
// PRISM
//
// Horizontally scrolling preset chips (§8.3/§5.5): active dot indicator,
// tap to switch (200ms crossfade handled by AppState), ＋ chip saves the
// current configuration, context menu for rename/duplicate/delete/export
// and the hotkey display.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PresetBar: View {
    @EnvironmentObject var state: AppState

    @State private var showingSaveSheet = false
    @State private var newPresetName = ""
    @State private var renameTarget: Preset?
    @State private var renameText = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.itemGap) {
                ForEach(state.presets) { preset in
                    chip(for: preset)
                }
                addChip
            }
        }
        .sheet(isPresented: $showingSaveSheet) { saveSheet }
        .sheet(item: $renameTarget) { preset in renameSheet(preset) }
        .accessibilityLabel("Presets")
    }

    // MARK: - Chips

    private func chip(for preset: Preset) -> some View {
        let isActive = state.activePresetID == preset.id
        return Button {
            state.selectPreset(preset.id)
        } label: {
            HStack(spacing: 5) {
                if isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
                Text(preset.name)
                    .font(.body)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityValue(isActive ? "active" : "inactive")
        .contextMenu {
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
            Button("Export as JSON…") {
                exportPreset(preset)
            }
            Divider()
            if let hotkey = preset.hotkey {
                Text("Hotkey: \(hotkey.displayString)")
            } else {
                Text("No hotkey")
            }
        }
    }

    private var addChip: some View {
        Button {
            newPresetName = ""
            showingSaveSheet = true
        } label: {
            Image(systemName: "plus")
                .font(.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Save current settings as preset")
    }

    // MARK: - Save sheet

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

    // MARK: - Rename sheet

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

    // MARK: - Export

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
}
