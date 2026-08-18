// FramingPane.swift
// PRISM
//
// Every geometry control in one place: zoom/pan, rotation and orientation,
// the full mirror picker (the popover offers only the flip toggle), crop
// aspect, auto-framing, and a reset — all above a live preview. Edits here
// stage into the draft (previewed privately, applied from the Apply bar);
// writes keep the geometry stage's enabled flag in sync with identity,
// same as the popover and Settings.
//
// Licensed under the Apache License, Version 2.0.

import SwiftUI

struct FramingPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PanePreview()
                .padding([.top, .horizontal], Metrics.gutter)
            form
        }
    }

    private var form: some View {
        Form {
            Section("Zoom & pan") {
                PrismSliderRow(label: "Zoom",
                               value: geometryBinding(\.zoom),
                               range: 1...4,
                               defaultValue: 1,
                               fractionDigits: 1)
                PrismSliderRow(label: "Pan X",
                               value: geometryBinding(\.panX),
                               range: -1...1,
                               defaultValue: 0,
                               fractionDigits: 2)
                PrismSliderRow(label: "Pan Y",
                               value: geometryBinding(\.panY),
                               range: -1...1,
                               defaultValue: 0,
                               fractionDigits: 2)
                Text("Panning moves within the margin created by zoom or crop. Double-click a slider to reset it; hold ⌥ while dragging for fine adjustment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Rotation") {
                PrismSliderRow(label: "Rotate",
                               value: geometryBinding(\.rotationDegrees),
                               range: -180...180,
                               defaultValue: 0,
                               fractionDigits: 0,
                               unit: "°")
                Picker("Orientation", selection: geometryBinding(\.orientation)) {
                    ForEach(Orientation.allCases, id: \.self) { orientation in
                        Text("\(orientation.rawValue)°").tag(orientation)
                    }
                }
            }
            Section("Mirror & crop") {
                Picker("Mirror", selection: geometryBinding(\.mirror)) {
                    ForEach(Mirror.allCases, id: \.self) { mirror in
                        Text(mirror.displayName).tag(mirror)
                    }
                }
                // §5.4 — a mirror here flips what *others* see.
                Text("Others will see this flipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Crop aspect", selection: geometryBinding(\.cropAspect)) {
                    ForEach(CropAspect.allCases, id: \.self) { aspect in
                        Text(aspect.displayName).tag(aspect)
                    }
                }
            }
            Section("Auto-framing") {
                Toggle("Auto-frame", isOn: geometryBinding(\.autoFrame))
                if !state.editingConfig.flags(for: .blur).enabled {
                    // §8.4 — auto-framing rides on the segmentation request.
                    Text("Auto-framing uses the same subject detection as background blur, so it costs about the same")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Reset framing") {
                    state.updateEditing { config in
                        config.geometry = GeometrySettings()
                        var flags = config.flags[.geometry] ?? StageFlags()
                        flags.enabled = false
                        config.flags[.geometry] = flags
                    }
                }
                .disabled(state.editingConfig.geometry.isIdentity)
            }
        }
        .formStyle(.grouped)
    }

    /// Geometry writes keep the stage's enabled flag in sync with identity:
    /// framing has no separate enable switch anywhere in the UI. Edits go
    /// through updateEditing: live (mirrored in the popover instantly) by
    /// default, staged while preview-before-apply is on.
    private func geometryBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<GeometrySettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { state.editingConfig.geometry[keyPath: keyPath] },
            set: { newValue in
                state.updateEditing { config in
                    config.geometry[keyPath: keyPath] = newValue
                    var flags = config.flags[.geometry] ?? StageFlags()
                    flags.enabled = !config.geometry.isIdentity
                    config.flags[.geometry] = flags
                }
            })
    }
}
