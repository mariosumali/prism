// MainWindowController.swift
// PRISM
//
// The main PRISM window: an AppKit-managed NSWindow hosting the SwiftUI
// MainWindowView. AppKit rather than a SwiftUI Window scene because a
// login-item agent must never show a window at launch, and suppressing a
// scene's launch presentation needs macOS 15; an owned controller opens
// exactly when asked (Dock click, popover button) on macOS 13.
//
// Ownership: the app delegate creates this lazily and keeps it for the
// process lifetime; closing hides the window (isReleasedWhenClosed = false)
// and drops preview demand via state.mainWindowOpen.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let state: AppState

    init(state: AppState) {
        self.state = state
        let hosting = NSHostingController(
            rootView: MainWindowView().environmentObject(state))
        // Default sizingOptions would push SwiftUI's derived minimum (well
        // below the designed floor) onto the window and defeat
        // contentMinSize; the window owns its own sizing.
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "PRISM"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 940, height: 620))
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.center()
        // After center() so a saved frame wins over the centered default.
        window.setFrameAutosaveName("PRISM.MainWindow")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainWindowController is code-only")
    }

    func show() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        state.mainWindowOpen = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// mainWindowOpen must track actual visibility, not just close: a
    /// miniaturized or ⌘H-hidden window showing no preview must not hold the
    /// camera (captureDemand) — "never around the clock" is the product's
    /// stated contract. Occlusion covers minimize, hide, and full cover;
    /// deminiaturize/unhide re-arm through the same notification.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        refreshOpenState()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        refreshOpenState()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        refreshOpenState()
    }

    func windowWillClose(_ notification: Notification) {
        state.mainWindowOpen = false
    }

    private func refreshOpenState() {
        guard let window else { return }
        let open = window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        if state.mainWindowOpen != open {
            state.mainWindowOpen = open
        }
    }
}
