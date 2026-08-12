// LoginItem.swift
// PRISM
//
// Launch-at-login via SMAppService (§7: default enabled, user-disableable).
// A one-shot UserDefaults flag guards the first-launch registration so a
// user who later disables the login item is never re-registered.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import ServiceManagement

public enum LoginItem {

    /// Set once the first-launch registration has run (regardless of its
    /// outcome), so PRISM never fights a user who turned the login item off.
    private static let didRegisterKey = "PRISMLoginItemDidRegister"

    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Not fatal: the Settings toggle reads `isEnabled` back, so the
            // UI reflects reality rather than the attempted change.
            NSLog("PRISM LoginItem: \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    /// §7 — launch at login defaults to ON. Called once at app startup;
    /// registers only on the very first launch so later user choices stick.
    public static func registerIfFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didRegisterKey) else { return }
        defaults.set(true, forKey: didRegisterKey)

        // If the user already configured the login item some other way
        // (e.g. System Settings), leave their choice alone.
        guard SMAppService.mainApp.status == .notRegistered else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            // .requiresApproval and similar are surfaced by System Settings
            // itself; there is nothing more PRISM should do here.
            NSLog("PRISM LoginItem: first-launch register failed: \(error.localizedDescription)")
        }
    }
}
