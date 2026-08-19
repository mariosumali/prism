// PrompterSection.swift
// PRISM
//
// The popover's Prompter section (§5.27): put the panel up, run it, send it
// back to the top. The script itself is written in the main window's Prompter
// pane, along with speed, size, opacity and the mirrored mode — a dropdown is
// not a place to draft a paragraph, and the controls you want mid-call are
// the three below.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct PrompterSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                Toggle("Show the prompter", isOn: enabledBinding)
                    .help("Float your script over your own screen\(state.shortcutSuffix(.prompter))")
                if state.studio.prompter.isEnabled {
                    HStack(spacing: Metrics.itemGap) {
                        Button(state.prompterRunning ? "Pause" : "Start") {
                            state.togglePrompter()
                        }
                        .controlSize(.small)
                        .disabled(!state.studio.prompter.isActive)
                        Button("Top") { state.resetPrompter() }
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .prismCard()
        } label: {
            HStack(spacing: Metrics.itemGap) {
                Text("Prompter")
                    .font(.headline)
                if let summary = collapsedSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A collapsed section must not hide that a panel is sitting on the
    /// user's screen — but it says nothing about being on air, because it
    /// isn't.
    private var collapsedSummary: String? {
        guard state.studio.prompter.isEnabled else { return nil }
        return state.prompterRunning ? "Reading" : "Holding"
    }

    /// One line, and only when there is something to say (§8.4). The empty
    /// script is the state people get stuck in, so it leads.
    private var caption: String {
        if state.studio.prompter.isEnabled,
           !state.studio.prompter.isActive {
            return "Write a script in the Prompter pane and it appears here."
        }
        return "The prompter shows on your screen only. It is never in the picture, and screen sharing cannot capture it."
    }

    // MARK: - Bindings

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { state.expandedSections.contains(.prompter) },
            set: { newValue in
                if newValue != state.expandedSections.contains(.prompter) {
                    state.toggleSection(.prompter)
                }
            })
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.studio.prompter.isEnabled },
            set: { state.setPrompterEnabled($0) })
    }
}
