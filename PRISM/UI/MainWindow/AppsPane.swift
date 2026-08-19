// AppsPane.swift
// PRISM
//
// The main window's Apps pane (§5.18): the ordered rule list, the default
// for apps nobody wrote a rule for, and the unblock-everything escape hatch.
//
// This lives only in the main window, not the popover. §8.3 puts deeper
// controls in the roomier surface, and a rule list is about as deep as PRISM
// gets — but the *consequences* of a rule are popover-visible: the preset
// chips say which look a rule chose, and the warning row says when a block
// is refusing someone. The two surfaces agree about what is happening; they
// differ only in where you go to change it.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

struct AppsPane: View {
    @EnvironmentObject var state: AppState

    @State private var manualSigningID = ""

    var body: some View {
        Form {
            switchSection
            if state.appRules.isEnabled {
                rulesSection
                addSection
                defaultSection
                escapeHatchSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - The one switch

    private var switchSection: some View {
        Section("Per-app rules") {
            Toggle("Use per-app rules", isOn: Binding(
                get: { state.appRules.isEnabled },
                set: { state.setAppRulesEnabled($0) }))
            Text("Give each app its own preset when it picks up PRISM Camera, and decide which apps may use it at all.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !state.clientsInUse.isEmpty {
                LabeledContent("Using PRISM Camera now",
                               value: state.clientsInUse.joined(separator: ", "))
            }
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section("Rules") {
            if state.appRules.rules.isEmpty {
                Text("No rules yet. Add one below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(state.appRules.rules.enumerated()), id: \.element.id) { index, rule in
                    ruleRow(rule, at: index)
                }
                Text("When two apps use PRISM Camera at once there is only one picture to give them, so the higher rule decides the look.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func ruleRow(_ rule: AppRule, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: Metrics.itemGap) {
            HStack(spacing: Metrics.itemGap) {
                // Buttons rather than drag: order is the conflict rule, so
                // reordering has to work from the keyboard and VoiceOver
                // (§8.5) and not only from a pointer.
                priorityButtons(at: index)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.displayName)
                        .font(.body)
                    Text(rule.signingID)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker("Access", selection: accessBinding(rule)) {
                    ForEach(AppAccess.allCases) { access in
                        Text(access.displayName).tag(access)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Access for \(rule.signingID)")
                Button {
                    state.removeAppRule(rule.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Remove rule for \(rule.signingID)")
            }
            // A blocked app never gets a look, so offering it a preset would
            // be a control wired to nothing (§8.7).
            if rule.access == .allow {
                Picker("Preset", selection: presetBinding(rule)) {
                    Text("Leave my look alone").tag(UUID?.none)
                    ForEach(state.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .accessibilityLabel("Preset for \(rule.signingID)")
                if let presetID = rule.presetID,
                   !state.presets.contains(where: { $0.id == presetID }) {
                    Text("That preset was deleted. This rule leaves your look alone until you pick another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if state.isStreamingNow(rule.signingID) {
                Text("It is using PRISM Camera right now. PRISM does not cut a call that is already running — the block starts the next time this app opens the camera.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func priorityButtons(at index: Int) -> some View {
        VStack(spacing: 2) {
            Button {
                state.moveAppRules(fromOffsets: IndexSet(integer: index),
                                   toOffset: index - 1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .accessibilityLabel("Raise priority")
            Button {
                state.moveAppRules(fromOffsets: IndexSet(integer: index),
                                   toOffset: index + 2)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index >= state.appRules.rules.count - 1)
            .accessibilityLabel("Lower priority")
        }
        .buttonStyle(.plain)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    // MARK: - Adding

    /// The apps currently streaming are the ones worth one tap, because they
    /// are the ones whose signing ID the user could not otherwise know.
    private var addSection: some View {
        Section("Add a rule") {
            ForEach(unruledClients) { client in
                Button {
                    state.addAppRule(signingID: client.signingID)
                } label: {
                    Label("Add rule for \(client.displayName)", systemImage: "plus")
                }
            }
            HStack(spacing: Metrics.itemGap) {
                TextField("Signing ID (us.zoom.xos)", text: $manualSigningID)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("App signing ID")
                Button("Add") {
                    state.addAppRule(signingID: manualSigningID)
                    manualSigningID = ""
                }
                .disabled(manualSigningID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Open an app on PRISM Camera and it appears here. Otherwise type its signing ID exactly — PRISM matches the whole ID, so a near miss silently matches nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var unruledClients: [CameraClient] {
        state.clients.filter { client in
            !state.appRules.rules.contains { $0.matches(client.signingID) }
        }
    }

    // MARK: - Default

    private var defaultSection: some View {
        Section("Apps without a rule") {
            Picker("Access", selection: Binding(
                get: { state.appRules.defaultAccess },
                set: { setDefaultAccess($0) })) {
                ForEach(AppAccess.allCases) { access in
                    Text(access.displayName).tag(access)
                }
            }
            if state.appRules.defaultAccess == .block {
                Text("Only the apps you allowed above can use PRISM Camera. Anything else — including an app you install later — gets nothing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Tell me when a rule changes my look", isOn: Binding(
                get: { state.appRules.announcesPresetChanges },
                set: { state.setAppRulesAnnounce($0) }))
        }
    }

    // MARK: - Escape hatch

    private var escapeHatchSection: some View {
        Section {
            Button("Unblock every app", role: .destructive) {
                state.clearAllBlocks()
            }
            .disabled(!state.appRules.blocksAnything)
            Text("Blocks are enforced by the camera extension, which keeps running when PRISM does not. This is the one thing in PRISM that can leave an app without a camera while PRISM is closed — so it is also the one thing with a button that undoes all of it at once. Preset rules are kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Removing PRISM removes the extension, and every block with it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private func accessBinding(_ rule: AppRule) -> Binding<AppAccess> {
        Binding(
            get: { rule.access },
            set: { access in
                guard access == .block, state.isStreamingNow(rule.signingID) else {
                    state.updateAppRule(rule.id) { $0.access = access }
                    return
                }
                confirmBlockingLiveApp(rule)
            })
    }

    private func presetBinding(_ rule: AppRule) -> Binding<UUID?> {
        Binding(
            get: { rule.presetID },
            set: { presetID in
                state.updateAppRule(rule.id) { $0.presetID = presetID }
            })
    }

    /// Blocking the app you are on a call in is the mistake this feature
    /// makes easy, so it is the one that gets asked about. The block still
    /// only bites on the next camera start; the alert says so rather than
    /// implying the call is about to end.
    private func confirmBlockingLiveApp(_ rule: AppRule) {
        let name = rule.displayName
        let alert = NSAlert()
        alert.messageText = "\(name) is using PRISM Camera right now. Block it anyway?"
        alert.informativeText = "The call you are on keeps its video. \(name) gets nothing the next time it opens the camera, until you unblock it here."
        alert.addButton(withTitle: "Block")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.updateAppRule(rule.id) { $0.access = .block }
    }

    private func setDefaultAccess(_ access: AppAccess) {
        guard access == .block else {
            state.setAppRulesDefaultAccess(access)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Block every app you have not allowed?"
        alert.informativeText = "Only apps with an Allow rule will be able to use PRISM Camera. Apps you install later will need a rule before they can see you."
        alert.addButton(withTitle: "Block by default")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.setAppRulesDefaultAccess(.block)
    }
}
