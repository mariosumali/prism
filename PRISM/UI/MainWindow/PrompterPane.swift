// PrompterPane.swift
// PRISM
//
// The main window's Prompter pane (§5.27): the script, and everything about
// how it reads. The popover carries only show / start / top, because those
// are the controls you want while you are talking; this is where the words
// are written.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct PrompterPane: View {
    @EnvironmentObject var state: AppState

    private var settings: PrompterSettings { state.studio.prompter }

    var body: some View {
        Form {
            Section("Script") {
                TextEditor(text: scriptBinding)
                    .font(.body)
                    .frame(minHeight: 180)
                    .accessibilityLabel("Prompter script")
                HStack(spacing: Metrics.itemGap) {
                    Toggle("Show the prompter", isOn: enabledBinding)
                    Spacer(minLength: 0)
                    Button(state.prompterRunning ? "Pause" : "Start") {
                        state.togglePrompter()
                    }
                    .disabled(!settings.isActive)
                    Button("Back to the top") { state.resetPrompter() }
                }
                Text("\(state.shortcutLabel(.prompter).isEmpty ? "The prompter shortcut" : state.shortcutLabel(.prompter)) starts and holds the script without leaving the app you are talking in. Closing the panel puts the prompter away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Reading") {
                PrismSliderRow(label: "Speed", value: speedBinding,
                               range: 5...120, defaultValue: 30,
                               fractionDigits: 0, unit: " lpm", snap: 1)
                PrismSliderRow(label: "Size", value: fontSizeBinding,
                               range: 14...96, defaultValue: 34,
                               fractionDigits: 0, unit: " pt", snap: 1)
                PrismSliderRow(label: "Opacity", value: opacityBinding,
                               range: 0.2...1, defaultValue: 0.9,
                               fractionDigits: 2)
                Text("Speed is lines a minute at whatever size you have chosen, so changing the size does not change your pace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Where it sits") {
                Picker("Opens at", selection: anchorBinding) {
                    ForEach(PrompterAnchor.allCases, id: \.self) { anchor in
                        Text(anchor.displayName).tag(anchor)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Mirror the text", isOn: mirroredBinding)
                Text("Drag the panel to wherever your camera is — the closer to the lens you read, the more you are looking at the people you are talking to, and eye contact in the Scene pane closes the rest of the gap. Mirroring is for a beam splitter, where the script is read off glass in front of the lens and arrives reversed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                // The single most important sentence in this pane, so it is
                // standing rather than conditional (§8.4).
                Text("Nobody else can see the prompter. It is never drawn into the picture, and macOS keeps the panel out of every screen recording — including a screen share from another app, and including PRISM's own screen source. Your script does not go on the call.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The script is not part of a preset. Switching looks never loads somebody else's words onto your screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings

    private var scriptBinding: Binding<String> {
        Binding(
            get: { state.studio.prompter.script },
            set: { state.setPrompterScript($0) })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.studio.prompter.isEnabled },
            set: { state.setPrompterEnabled($0) })
    }

    private var speedBinding: Binding<Double> {
        Binding(
            get: { state.studio.prompter.speed },
            set: { state.setPrompterSpeed($0) })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { state.studio.prompter.fontSize },
            set: { state.setPrompterFontSize($0) })
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { state.studio.prompter.opacity },
            set: { state.setPrompterOpacity($0) })
    }

    private var mirroredBinding: Binding<Bool> {
        Binding(
            get: { state.studio.prompter.isMirrored },
            set: { state.setPrompterMirrored($0) })
    }

    private var anchorBinding: Binding<PrompterAnchor> {
        Binding(
            get: { state.studio.prompter.anchor },
            set: { state.setPrompterAnchor($0) })
    }
}
