// PresetStore.swift
// PRISM
//
// Named pipeline configurations (§5.5): four built-ins with deterministic
// UUIDs, user CRUD + reorder, hotkey bindings, JSON export/import, and
// persistence at ~/Library/Application Support/PRISM/presets.json. Built-ins
// can be duplicated but never edited; their canonical name/configuration is
// restored on load so a tampered file cannot change them.
//
// Licensed under the Apache License, Version 2.0.

import Combine
import Foundation

@MainActor
public final class PresetStore: ObservableObject {
    @Published public private(set) var presets: [Preset]   // built-ins first

    // Deterministic built-in identifiers ("PRISM" spelled in the hex prefix).
    private static let naturalID = UUID(uuidString: "50524953-4D00-4000-8000-000000000001")!
    private static let meetingID = UUID(uuidString: "50524953-4D00-4000-8000-000000000002")!
    private static let studioID = UUID(uuidString: "50524953-4D00-4000-8000-000000000003")!
    private static let lowLatencyID = UUID(uuidString: "50524953-4D00-4000-8000-000000000004")!

    /// §5.5 — Natural (pass-through), Meeting (mild adjust + balanced blur +
    /// auto-frame), Studio (LUT + adjust, no blur, quality policy),
    /// Low latency (geometry only, lowest policy).
    public static let builtIns: [Preset] = {
        // Natural: everything off, balanced policy — the defaults.
        let natural = PipelineConfiguration()

        var meeting = PipelineConfiguration()
        meeting.adjust.exposureEV = 0.2
        meeting.adjust.contrast = 1.05
        meeting.blur.quality = .balanced
        meeting.geometry.autoFrame = true
        meeting.flags[.adjust] = StageFlags(enabled: true)
        meeting.flags[.blur] = StageFlags(enabled: true)
        meeting.flags[.geometry] = StageFlags(enabled: true)

        var studio = PipelineConfiguration()
        studio.lut.lutName = "Film"
        studio.adjust.contrast = 1.1
        studio.adjust.saturation = 1.1
        studio.flags[.lut] = StageFlags(enabled: true)
        studio.flags[.adjust] = StageFlags(enabled: true)
        studio.latencyPolicy = .quality

        var lowLatency = PipelineConfiguration()
        lowLatency.flags[.geometry] = StageFlags(enabled: true)
        lowLatency.latencyPolicy = .lowest

        return [
            Preset(id: naturalID, name: "Natural", isBuiltIn: true, configuration: natural),
            Preset(id: meetingID, name: "Meeting", isBuiltIn: true, configuration: meeting),
            Preset(id: studioID, name: "Studio", isBuiltIn: true, configuration: studio),
            Preset(id: lowLatencyID, name: "Low latency", isBuiltIn: true, configuration: lowLatency),
        ]
    }()

    // MARK: Lifecycle

    private let storeURL: URL

    public convenience init() {
        self.init(storeURL: Self.defaultStoreURL)
    }

    /// Internal seam so tests can persist to a temporary location; the public
    /// initializer uses the real Application Support path (identical behavior).
    init(storeURL: URL) {
        self.storeURL = storeURL
        presets = Self.merge(loaded: Self.loadFromDisk(from: storeURL))
    }

    // MARK: CRUD

    public func add(_ preset: Preset) {
        var added = preset
        added.isBuiltIn = false
        if presets.contains(where: { $0.id == added.id }) {
            added.id = UUID()
        }
        presets.append(added)
        save()
    }

    public func duplicate(_ id: UUID) -> Preset? {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = presets[index]
        copy.id = UUID()
        copy.isBuiltIn = false
        copy.name += " copy"
        copy.hotkey = nil          // two presets must not share one hotkey
        presets.insert(copy, at: index + 1)
        save()
        return copy
    }

    public func rename(_ id: UUID, to name: String) {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltIn else { return }
        presets[index].name = name
        save()
    }

    public func delete(_ id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltIn else { return }
        presets.remove(at: index)
        save()
    }

    /// SwiftUI `onMove` semantics: the moved elements end up (in order)
    /// before the element that sat at `toOffset` prior to the move.
    public func move(fromOffsets: IndexSet, toOffset: Int) {
        let offsets = fromOffsets.filter { presets.indices.contains($0) }
        guard !offsets.isEmpty, toOffset >= 0, toOffset <= presets.count else { return }
        let moving = offsets.map { presets[$0] }
        let destination = toOffset - offsets.filter { $0 < toOffset }.count
        for index in offsets.sorted(by: >) {
            presets.remove(at: index)
        }
        presets.insert(contentsOf: moving, at: destination)
        save()
    }

    public func update(_ id: UUID, configuration: PipelineConfiguration) {
        guard let index = presets.firstIndex(where: { $0.id == id }),
              !presets[index].isBuiltIn else { return }
        presets[index].configuration = configuration
        save()
    }

    /// Hotkeys may bind to built-ins too — the binding is user state, not
    /// part of the (immutable) built-in configuration.
    public func setHotkey(_ id: UUID, hotkey: HotkeyCombo?) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        if let hotkey {
            // A combo can drive only one preset; steal it from any other holder.
            for other in presets.indices where presets[other].hotkey == hotkey {
                presets[other].hotkey = nil
            }
        }
        presets[index].hotkey = hotkey
        save()
    }

    // MARK: Export / import (§5.5 — shareable JSON)

    public func exportJSON(_ id: UUID) -> Data? {
        guard let preset = presets.first(where: { $0.id == id }) else { return nil }
        var shareable = preset
        shareable.hotkey = nil     // hotkeys are machine-local
        shareable.isBuiltIn = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(shareable)
    }

    public func importJSON(_ data: Data) throws -> Preset {
        var imported = try JSONDecoder().decode(Preset.self, from: data)
        imported.id = UUID()       // never collide with an existing preset
        imported.isBuiltIn = false
        imported.hotkey = nil      // never silently claim a hotkey on import
        presets.append(imported)
        save()
        return imported
    }

    // MARK: Persistence

    public func save() {
        let url = storeURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(presets)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("PRISM PresetStore: save failed: \(error)")
        }
    }

    // MARK: Private

    private static var defaultStoreURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("PRISM", isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    private static func loadFromDisk(from url: URL) -> [Preset]? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Preset].self, from: data) else {
            return nil
        }
        return decoded
    }

    /// The persisted file stores the full array so ordering and hotkey
    /// bindings survive relaunch. Built-in entries have their canonical
    /// name/configuration restored (built-ins are not editable); unknown
    /// entries claiming isBuiltIn are demoted; missing built-ins are
    /// reinserted at the front in canonical order.
    private static func merge(loaded: [Preset]?) -> [Preset] {
        guard let loaded, !loaded.isEmpty else { return builtIns }
        let canonical = Dictionary(uniqueKeysWithValues: builtIns.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var result: [Preset] = []
        for var preset in loaded {
            guard !seen.contains(preset.id) else { continue }
            seen.insert(preset.id)
            if let builtIn = canonical[preset.id] {
                preset.name = builtIn.name
                preset.configuration = builtIn.configuration
                preset.isBuiltIn = true
            } else {
                preset.isBuiltIn = false
            }
            result.append(preset)
        }
        let missing = builtIns.filter { !seen.contains($0.id) }
        result.insert(contentsOf: missing, at: 0)
        return result
    }
}
