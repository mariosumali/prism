// PRISMApp.swift
// PRISM
//
// App entry. MenuBarExtra (.window style) hosts the popover; the Settings
// scene hosts quick preferences (§8.3); the main PRISM window (an AppKit
// window owned by the delegate via MainWindowController, so nothing shows
// at login-item launch) is the full control surface, including the Menu Bar
// pane that customizes the popover itself.
//
// PRISM appears in both the Dock and the menu bar. That overrides SPEC §1,
// which specifies LSUIElement = true (menu bar only) — see PRISM/Info.plist.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

@main
struct PRISMApp: App {
    @NSApplicationDelegateAdaptor(PRISMAppDelegate.self) private var delegate
    @StateObject private var state: AppState

    init() {
        let appState = AppState()
        _state = StateObject(wrappedValue: appState)
        PRISMAppDelegate.pendingState = appState
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(state)
                .onAppear { state.popoverOpen = true }
                .onDisappear { state.popoverOpen = false }
        } label: {
            MenuBarIcon(state: state.menuBarState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

final class PRISMAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var pendingState: AppState?
    /// Created lazily on first open and kept for the process lifetime.
    @MainActor private var mainWindowController: MainWindowController?
    /// §5.27 — created the first time the prompter is asked for and kept
    /// afterwards, so the panel remembers where the user dragged it.
    @MainActor private var prompterPanelController: PrompterPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            guard let state = PRISMAppDelegate.pendingState else { return }
            // AppState cannot depend on the UI layer (PRISMTests excludes
            // UI/**), so the window controller is reached through this hook.
            state.openMainWindowHandler = { [weak self, weak state] in
                guard let self, let state else { return }
                if self.mainWindowController == nil {
                    self.mainWindowController = MainWindowController(state: state)
                }
                self.mainWindowController?.show()
            }
            state.prompterPanelHandler = { [weak self, weak state] visible in
                guard let self else { return }
                guard visible else {
                    self.prompterPanelController?.hide()
                    return
                }
                guard let state else { return }
                if self.prompterPanelController == nil {
                    self.prompterPanelController = PrompterPanelController(state: state)
                }
                self.prompterPanelController?.show()
            }
            state.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // menu bar agents outlive their windows
    }

    /// Clicking the Dock icon opens (or raises) the main PRISM window —
    /// unconditionally, because gating on hasVisibleWindows would let a
    /// visible Settings window swallow the click. The popover belongs to the
    /// menu bar item and cannot be summoned programmatically.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            PRISMAppDelegate.pendingState?.showMainWindow()
        }
        return true
    }
}
