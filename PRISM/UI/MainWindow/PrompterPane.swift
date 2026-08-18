// PrompterPane.swift
// PRISM
//
// The main window's Prompter pane — the script, and the controls that
// scroll it over the picture. Owned by the prompter track; this is its
// reserved seat in the navigation. The ⌃⌥⌘T chord already answers with a
// warning rather than silence, and this pane says the same thing in the
// place the warning points at.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct PrompterPane: View {
    var body: some View {
        Text("The prompter isn't built yet.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Metrics.gutter)
    }
}
