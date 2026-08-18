// GesturesPane.swift
// PRISM
//
// The main window's Gestures pane — hand poses as a second hotkey surface,
// and the bindings from pose to intent. Owned by the gestures track; this
// is its reserved seat in the navigation. Gestures misfire, so the pane
// that turns them off has to be findable before the recogniser ships.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct GesturesPane: View {
    var body: some View {
        Text("Hand gestures aren't built yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Metrics.gutter)
    }
}
