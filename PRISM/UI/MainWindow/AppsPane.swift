// AppsPane.swift
// PRISM
//
// The main window's Apps pane — the per-app rules (which preset PRISM wears
// for a client, and whether that client may open the camera at all). Owned
// by the app-rules track; this is its reserved seat in the navigation. Two
// warnings already send people here with an "App rules" button, so the row
// must exist before the list does.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct AppsPane: View {
    var body: some View {
        Text("Per-app rules aren't built yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Metrics.gutter)
    }
}
