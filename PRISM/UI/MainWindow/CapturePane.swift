// CapturePane.swift
// PRISM
//
// The main window's Capture pane — stills and saved clips (§5.15, §5.16):
// the roomier surface over the same two intents the popover's tiles reach.
//
// Behaviour rather than look, so it edits AppState.studio directly and never
// touches the draft — the same rule as MomentsPane, and the same reason:
// switching from Meeting to Studio must never repoint somebody's folder.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

struct CapturePane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            clipSection
            stillSection
            folderSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Clips (§5.15)

    private var clipSection: some View {
        Section("Save the last seconds") {
            HStack {
                Button("Save now") { state.saveLastSeconds() }
                    .disabled(!state.studio.replay.isArmed)
                Spacer()
                Text(state.shortcutLabel(.saveClip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if state.studio.replay.isArmed {
                LabeledContent("Available",
                               value: state.bufferedSeconds < 1
                                   ? "buffering…"
                                   : String(format: "%.0f s", state.bufferedSeconds))
            } else {
                HStack {
                    Text("The rolling buffer is off, so there is nothing to save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Turn it on") { state.setBufferArmed(true) }
                }
            }
            if !state.clipConcealments.isEmpty {
                concealmentRow
            }
            Text("The file is a copy of the frames already in the rolling buffer, so saving re-encodes nothing and costs the live picture nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(ClipDisclosure.alwaysTrue) The buffer records the camera before the effects chain — that is what lets a replay run through your current look — so a saved clip shows the room, the face and the framing the camera saw, not the ones your call saw.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The standing caption states the rule; this states today's consequence.
    /// Both, always, because the rule is what teaches and the consequence is
    /// what stops someone.
    private var concealmentRow: some View {
        HStack(alignment: .top, spacing: Metrics.itemGap) {
            Image(systemName: "eye.trianglebadge.exclamationmark.fill")
                .foregroundStyle(.orange)
            Text("Right now that means the room behind \(ClipDisclosure.phrase(state.clipConcealments)). PRISM will ask before it writes the file.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Stills (§5.16)

    private var stillSection: some View {
        Section("Stills") {
            HStack {
                Button(countdownLabel) {
                    state.takeSnapshot()
                }
                Spacer()
                Text(state.shortcutLabel(.snapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker("Format", selection: formatBinding) {
                ForEach(StillFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.segmented)
            PrismSliderRow(label: "Countdown",
                           value: countdownBinding,
                           range: 0...10,
                           defaultValue: 0,
                           fractionDigits: 0,
                           unit: " s",
                           snap: 1)
            Toggle("Pick the sharpest of the last few frames", isOn: sharpBinding)
            Text("PRISM already scores every frame it produces for sharpness — it is how a freeze avoids landing mid-blink. With this on, a still is the best frame of the last fifth of a second rather than the one that happened to arrive when you pressed the key.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("It costs memory: keeping those frames means holding six finished pictures, about 50 MB at 1080p, for as long as this is on. Off, PRISM saves exactly the frame you were looking at and holds nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("A still is the finished picture — every effect, exactly what your call sees. This is the opposite of a saved clip, and deliberately so: a photo should look like you, and a clip you keep should not quietly be a recording you did not know you were making.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var countdownLabel: String {
        switch state.capturePhase {
        case .idle:
            let seconds = state.studio.capture.clampedCountdownSeconds
            return seconds > 0 ? "Take a still in \(seconds) s" : "Take a still"
        case .countdown(let remaining):
            return "Cancel (\(remaining))"
        case .writing:
            return "Saving…"
        }
    }

    // MARK: - Destination

    private var folderSection: some View {
        Section("Where files go") {
            HStack(spacing: Metrics.itemGap) {
                Text(folderLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…") { chooseFolder() }
                if !state.studio.capture.usesDefaultFolder {
                    Button("Reset") { state.setCaptureFolder(nil) }
                }
                Button("Reveal") { reveal() }
            }
            if let notice = state.notice, let url = notice.fileURL {
                HStack(spacing: Metrics.itemGap) {
                    Image(systemName: notice.symbolName)
                        .foregroundStyle(.green)
                    Text(notice.text)
                        .font(.caption)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            Text("Stills and clips share one folder and are named the way macOS names screenshots, so they sort into the order they happened.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var folderLabel: String {
        state.studio.capture.usesDefaultFolder
            ? "~/Movies/PRISM"
            : state.studio.capture.folderURL.path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                state.setCaptureFolder(url)
            }
        }
    }

    /// Creates the folder on the way, so "Reveal" on a first launch opens
    /// the place captures will land rather than failing on a folder that
    /// does not exist yet.
    private func reveal() {
        let folder = state.studio.capture.folderURL
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: - Bindings

    private var formatBinding: Binding<StillFormat> {
        Binding(get: { state.studio.capture.format },
                set: { state.studio.capture.format = $0 })
    }

    private var countdownBinding: Binding<Double> {
        Binding(get: { Double(state.studio.capture.clampedCountdownSeconds) },
                set: { state.studio.capture.countdownSeconds = Int($0.rounded()) })
    }

    private var sharpBinding: Binding<Bool> {
        Binding(get: { state.studio.capture.prefersSharp },
                set: { state.studio.capture.prefersSharp = $0 })
    }
}
