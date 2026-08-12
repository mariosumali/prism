// MenuBarLayoutPane.swift
// PRISM
//
// Customizes the menu bar dropdown: every module of the popover can be
// shown or hidden, and dragged into any order. The setup banner, the
// warning row, and the bottom bar are exempt — hiding a "finish setup" or
// "approve the extension" message behind a preference is how users end up
// with a half-installed PRISM and no explanation.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct MenuBarLayoutPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Metrics.itemGap) {
                Text("Menu bar dropdown")
                    .font(.headline)
                Text("Choose what the PRISM menu bar item shows, and drag to reorder. Setup steps, warnings, and the Settings/quit bar always appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Metrics.gutter)
            List {
                ForEach(state.popoverLayout) { item in
                    HStack(spacing: Metrics.itemGap) {
                        Image(systemName: item.module.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(item.module.displayName)
                            .foregroundStyle(item.visible ? .primary : .secondary)
                        Spacer()
                        Toggle(item.module.displayName, isOn: visibleBinding(item.module))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .accessibilityLabel(item.module.displayName)
                            .accessibilityValue(item.visible ? "shown" : "hidden")
                    }
                    .padding(.vertical, 2)
                }
                .onMove { offsets, destination in
                    state.movePopoverModules(fromOffsets: offsets, toOffset: destination)
                }
            }
            Divider()
            HStack {
                Button("Reset to default") { state.resetPopoverLayout() }
                    .disabled(state.popoverLayout == PopoverModuleItem.defaultLayout)
                Spacer()
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Metrics.gutter)
        }
    }

    private var summaryLine: String {
        let visible = state.visiblePopoverModules.count
        let total = state.popoverLayout.count
        return "\(visible) of \(total) shown"
    }

    private func visibleBinding(_ module: PopoverModule) -> Binding<Bool> {
        Binding(
            get: {
                state.popoverLayout.first { $0.module == module }?.visible ?? true
            },
            set: { state.setPopoverModule(module, visible: $0) })
    }
}
