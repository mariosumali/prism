// PanePreview.swift
// PRISM
//
// The preview block shared by the Studio, Framing, and Effects panes: the
// live output normally, the draft render while preview-before-apply is on,
// plus the toggle and the Apply / Discard bar. Editing is live (and
// mirrored in the popover instantly) unless the toggle stages it; the
// banner states the contract plainly — while a draft is pending, apps keep
// seeing the applied look.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct PanePreview: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            PreviewView(surface: .mainWindow, usesDraft: true)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius,
                                            style: .continuous))
                .accessibilityLabel(state.draftConfig == nil
                                    ? "Output preview"
                                    : "Draft preview of unapplied changes")
            HStack(spacing: Metrics.itemGap) {
                Toggle("Preview edits before applying", isOn: draftModeBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("On: edits show only here until you apply. Off: edits change the camera immediately.")
                Spacer(minLength: Metrics.itemGap)
                if state.draftConfig != nil {
                    Button("Discard") { state.discardDraft() }
                        .controlSize(.small)
                    Button("Apply") { state.applyDraft() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
            }
            if state.draftConfig != nil {
                Text("Apps still see the current look until you apply. Turning the toggle off discards these edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var draftModeBinding: Binding<Bool> {
        Binding(
            get: { state.draftConfig != nil },
            set: { on in
                if on {
                    state.beginDraft()
                } else {
                    state.discardDraft()
                }
            })
    }
}
