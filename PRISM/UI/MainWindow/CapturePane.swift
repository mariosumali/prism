// CapturePane.swift
// PRISM
//
// The main window's Capture pane — stills and saved clips. Owned by the
// capture track; this is its reserved seat in the navigation, holding the
// row so the pane order stops moving under everyone else. The line is here
// rather than an empty detail view because a blank pane reads as a bug the
// user should report, and this one is not one.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct CapturePane: View {
    var body: some View {
        Text("Stills and saved clips aren't built yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Metrics.gutter)
    }
}
