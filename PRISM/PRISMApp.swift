// PRISMApp.swift
// PRISM
//
// App entry. An AppKit square status item hosts the SwiftUI popover; the main
// PRISM window (also owned by the delegate, so nothing shows at login-item
// launch) is the full control surface, including the Menu Bar pane that
// customizes the popover itself.
//
// The empty SwiftUI `Settings` scene exists only to host commands. The main
// AppKit window remains the single settings surface, and ⌘, opens it.
//
// PRISM appears in both the Dock and the menu bar. That overrides SPEC §1,
// which specifies LSUIElement = true (menu bar only) — see PRISM/Info.plist.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import SwiftUI
import UserNotifications

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
        // PRISM's visible windows are AppKit-owned. A Settings scene keeps the
        // SwiftUI app lifecycle without opening an untitled window at launch;
        // its standard command is replaced below with the real PRISM window.
        Settings { EmptyView() }
        // Point the standard Settings command at the window that owns every
        // setting instead of at the empty lifecycle scene.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { state.showMainWindow() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class PRISMAppDelegate: NSObject, NSApplicationDelegate,
                              UNUserNotificationCenterDelegate {
    @MainActor static var pendingState: AppState?
    /// A square AppKit item uses 24 points instead of SwiftUI's 40-point
    /// custom-label slot. That difference keeps PRISM visible on notched
    /// displays with a crowded right-hand side of the menu bar.
    @MainActor private var menuBarController: MenuBarController?
    /// Created lazily on first open and kept for the process lifetime.
    @MainActor private var mainWindowController: MainWindowController?
    /// §5.27 — created the first time the prompter is asked for and kept
    /// afterwards, so the panel remembers where the user dragged it.
    @MainActor private var prompterPanelController: PrompterPanelController?
    /// §5.33 — same arrangement as the prompter's panel, and for the same
    /// reason: it remembers where it was dragged to.
    @MainActor private var assistantPanelController: AssistantPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.delegate = self
        MeetingPromptNotification.registerActions()

        Task { @MainActor in
            guard let state = PRISMAppDelegate.pendingState else { return }
            menuBarController = MenuBarController(state: state)
            // §5.32. The real speech engine is installed here, from the app
            // target only — `PRISM/AI/Engines/` is excluded from the test
            // bundle, which is what keeps the suite ad-hoc signed and free
            // of the WhisperKit package. AppState never names it.
            SpeechEngineRegistry.factory = { model in
                WhisperKitEngine(model: model)
            }
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
            state.assistantPanelHandler = { [weak self, weak state] visible in
                guard let self else { return }
                guard visible else {
                    self.assistantPanelController?.hide()
                    return
                }
                guard let state else { return }
                if self.assistantPanelController == nil {
                    self.assistantPanelController = AssistantPanelController(state: state)
                }
                self.assistantPanelController?.show()
            }
            state.meetingJoinPromptHandler = { candidate in
                MeetingPromptNotification.post(candidate)
            }
            state.meetingJoinEndedHandler = { signingIDs in
                MeetingPromptNotification.remove(for: signingIDs)
            }
            state.clearMeetingJoinPromptsHandler = {
                MeetingPromptNotification.removeAll()
            }
            state.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // menu bar agents outlive their windows
    }

    /// Clicking the Dock icon opens (or raises) the main PRISM window —
    /// unconditionally, because gating on hasVisibleWindows would let any
    /// other visible window (the prompter panel, say) swallow the click. The
    /// popover belongs to the menu bar item and cannot be summoned
    /// programmatically.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            PRISMAppDelegate.pendingState?.showMainWindow()
        }
        return true
    }

    /// Notifications still appear when PRISM is frontmost (for example while
    /// its preview is open). Merely clicking the notification opens PRISM;
    /// only the explicit action starts Meeting mode.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let signingID = MeetingPromptNotification.signingID(from: response)
        Task { @MainActor in
            if action == MeetingPromptNotification.startActionIdentifier,
               let signingID {
                PRISMAppDelegate.pendingState?.startMeeting(
                    fromPromptFor: signingID)
            } else if action == UNNotificationDefaultActionIdentifier {
                PRISMAppDelegate.pendingState?.showMainWindow()
            }
        }
        completionHandler()
    }
}
