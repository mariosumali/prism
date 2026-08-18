// PrompterSection.swift
// PRISM
//
// The popover's Prompter section — the run/pause controls over a script
// that is written in the main window. Owned by the prompter track. It draws
// nothing yet, and PopoverView.unbuiltModules skips the row so the dropdown
// does not grow a blank band; the type exists so the module arm points at a
// real section rather than at an EmptyView the prompter work would have to
// go find.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct PrompterSection: View {
    var body: some View {
        EmptyView()
    }
}
