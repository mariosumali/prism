// CaptureSection.swift
// PRISM
//
// The popover's Capture section — stills and saved clips. Owned by the
// capture track. It draws nothing yet, and PopoverView.unbuiltModules skips
// the row so the dropdown does not grow a blank band; the type exists so
// the module arm points at a real section rather than at an EmptyView the
// capture work would have to go find.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct CaptureSection: View {
    var body: some View {
        EmptyView()
    }
}
