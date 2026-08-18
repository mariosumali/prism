// DiagnosticsPane.swift
// PRISM
//
// The main window's Diagnostics pane — per-stage timings, drops, and the
// extension/plug-in health that the latency meter only summarises. Owned by
// the diagnostics track; this is its reserved seat in the navigation, next
// to About because that is where someone goes when they are about to file a
// report.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct DiagnosticsPane: View {
    var body: some View {
        Text("Diagnostics aren't built yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Metrics.gutter)
    }
}
