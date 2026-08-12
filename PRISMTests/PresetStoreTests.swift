// PresetStoreTests.swift
// PRISMTests
//
// Locks down §5.5: the four built-ins ship with their specified shapes and
// are immutable (rename/delete/update are no-ops), duplication yields an
// editable copy, export/import round-trips a configuration as shareable
// JSON, reordering follows SwiftUI onMove semantics, and the whole array —
// ordering, user presets, hotkey bindings — persists across relaunch while
// tampered built-ins are restored to canonical form. All persistence goes
// through a per-test temporary file via the store's internal seam.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

@MainActor
final class PresetStoreTests: XCTestCase {

    private var directory: URL!
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRISMPresetStoreTests-\(UUID().uuidString)",
                                    isDirectory: true)
        storeURL = directory.appendingPathComponent("presets.json")
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        storeURL = nil
        super.tearDown()
    }

    private func makeStore() -> PresetStore {
        PresetStore(storeURL: storeURL)
    }

    private func makeUserPreset(named name: String) -> Preset {
        var config = PipelineConfiguration()
        config.adjust.exposureEV = 0.7
        config.lut.lutName = "Cool"
        config.flags[.lut] = StageFlags(enabled: true, pinned: true)
        config.latencyPolicy = .quality
        return Preset(name: name, configuration: config)
    }

    // MARK: - Built-ins (§5.5 shapes)

    func testFourBuiltInsPresentInOrderOnFreshStore() {
        let store = makeStore()
        XCTAssertEqual(store.presets.count, 4)
        XCTAssertEqual(store.presets.map(\.name),
                       ["Natural", "Meeting", "Studio", "Low latency"])
        XCTAssertTrue(store.presets.allSatisfy(\.isBuiltIn))
        XCTAssertEqual(store.presets, PresetStore.builtIns)
    }

    func testNaturalIsPassThroughWithBalancedPolicy() throws {
        let natural = try XCTUnwrap(PresetStore.builtIns.first { $0.name == "Natural" })
        // Pass-through: the default configuration exactly — no stage enabled,
        // balanced policy, default format.
        XCTAssertEqual(natural.configuration, PipelineConfiguration())
        XCTAssertEqual(natural.configuration.latencyPolicy, .balanced)
        for id in [StageID.geometry, .adjust, .lut, .blur] {
            XCTAssertFalse(natural.configuration.flags(for: id).enabled)
        }
    }

    func testMeetingEnablesMildAdjustBalancedBlurAndAutoFrame() throws {
        let meeting = try XCTUnwrap(PresetStore.builtIns.first { $0.name == "Meeting" })
        let config = meeting.configuration
        XCTAssertTrue(config.flags(for: .adjust).enabled)
        XCTAssertTrue(config.flags(for: .blur).enabled)
        XCTAssertTrue(config.flags(for: .geometry).enabled)
        XCTAssertEqual(config.blur.quality, .balanced)
        XCTAssertTrue(config.geometry.autoFrame)
        // "Mild" adjust — nudged, not neutral, and within spec ranges.
        XCTAssertFalse(config.adjust.isIdentity)
        XCTAssertLessThanOrEqual(abs(config.adjust.exposureEV), 0.5)
        XCTAssertEqual(config.latencyPolicy, .balanced)
    }

    func testStudioEnablesLUTAndAdjustNoBlurQualityPolicy() throws {
        let studio = try XCTUnwrap(PresetStore.builtIns.first { $0.name == "Studio" })
        let config = studio.configuration
        XCTAssertTrue(config.flags(for: .lut).enabled)
        XCTAssertTrue(config.flags(for: .adjust).enabled)
        XCTAssertFalse(config.flags(for: .blur).enabled)
        XCTAssertNotEqual(config.lut.lutName, "Neutral")
        XCTAssertEqual(config.latencyPolicy, .quality)
    }

    func testLowLatencyIsGeometryOnlyWithLowestPolicy() throws {
        let low = try XCTUnwrap(PresetStore.builtIns.first { $0.name == "Low latency" })
        let config = low.configuration
        XCTAssertTrue(config.flags(for: .geometry).enabled)
        XCTAssertFalse(config.flags(for: .adjust).enabled)
        XCTAssertFalse(config.flags(for: .lut).enabled)
        XCTAssertFalse(config.flags(for: .blur).enabled)
        XCTAssertEqual(config.latencyPolicy, .lowest)
    }

    // MARK: - Built-in immutability

    func testRenameBuiltInIsNoOp() {
        let store = makeStore()
        let natural = store.presets[0]
        store.rename(natural.id, to: "Hacked")
        XCTAssertEqual(store.presets[0].name, "Natural")
    }

    func testDeleteBuiltInIsNoOp() {
        let store = makeStore()
        store.delete(store.presets[0].id)
        XCTAssertEqual(store.presets.count, 4)
        XCTAssertEqual(store.presets[0].name, "Natural")
    }

    func testUpdateBuiltInConfigurationIsNoOp() {
        let store = makeStore()
        let natural = store.presets[0]
        var config = PipelineConfiguration()
        config.latencyPolicy = .lowest
        config.adjust.contrast = 1.9
        store.update(natural.id, configuration: config)
        XCTAssertEqual(store.presets[0].configuration, natural.configuration)
    }

    // MARK: - Duplicate → editable copy

    func testDuplicateBuiltInCreatesEditableCopy() throws {
        let store = makeStore()
        let meeting = store.presets[1]
        let copy = try XCTUnwrap(store.duplicate(meeting.id))

        XCTAssertNotEqual(copy.id, meeting.id)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.name, "Meeting copy")
        XCTAssertEqual(copy.configuration, meeting.configuration)
        XCTAssertNil(copy.hotkey)
        // Inserted directly after the original.
        XCTAssertEqual(store.presets[2].id, copy.id)

        // The copy, unlike the original, accepts edits and deletion.
        store.rename(copy.id, to: "My meeting")
        XCTAssertEqual(store.presets[2].name, "My meeting")
        var config = copy.configuration
        config.blur.quality = .accurate
        store.update(copy.id, configuration: config)
        XCTAssertEqual(store.presets[2].configuration.blur.quality, .accurate)
        store.delete(copy.id)
        XCTAssertEqual(store.presets.count, 4)
    }

    func testDuplicateUnknownIDReturnsNil() {
        let store = makeStore()
        XCTAssertNil(store.duplicate(UUID()))
    }

    // MARK: - Add

    func testAddForcesUserStatusAndUniqueID() {
        let store = makeStore()
        var clone = PresetStore.builtIns[0]      // claims Natural's id + isBuiltIn
        clone.name = "Impostor"
        store.add(clone)
        XCTAssertEqual(store.presets.count, 5)
        let added = store.presets[4]
        XCTAssertEqual(added.name, "Impostor")
        XCTAssertFalse(added.isBuiltIn)
        XCTAssertNotEqual(added.id, PresetStore.builtIns[0].id)
    }

    // MARK: - Export / import JSON round-trip

    func testExportImportRoundTripPreservesConfiguration() throws {
        let store = makeStore()
        var preset = makeUserPreset(named: "Interview")
        preset.hotkey = HotkeyCombo(keyCode: 18, option: true, command: true)
        store.add(preset)
        let storedID = store.presets[4].id

        let data = try XCTUnwrap(store.exportJSON(storedID))

        // Exported JSON is shareable: machine-local hotkey stripped, never
        // flagged as built-in.
        let exported = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertNil(exported.hotkey)
        XCTAssertFalse(exported.isBuiltIn)
        XCTAssertEqual(exported.name, "Interview")
        XCTAssertEqual(exported.configuration, preset.configuration)

        // Importing into a second store preserves the configuration and mints
        // a fresh identity.
        let otherURL = directory.appendingPathComponent("other.json")
        let other = PresetStore(storeURL: otherURL)
        let imported = try other.importJSON(data)
        XCTAssertEqual(imported.name, "Interview")
        XCTAssertEqual(imported.configuration, preset.configuration)
        XCTAssertNil(imported.hotkey)
        XCTAssertFalse(imported.isBuiltIn)
        XCTAssertNotEqual(imported.id, storedID)
        XCTAssertEqual(other.presets.count, 5)
        XCTAssertEqual(other.presets[4].id, imported.id)
    }

    func testExportUnknownIDReturnsNil() {
        XCTAssertNil(makeStore().exportJSON(UUID()))
    }

    func testImportMalformedJSONThrows() {
        let store = makeStore()
        XCTAssertThrowsError(try store.importJSON(Data("nonsense".utf8)))
        XCTAssertEqual(store.presets.count, 4)
    }

    // MARK: - Reorder

    func testMoveFollowsOnMoveSemantics() {
        let store = makeStore()
        store.add(makeUserPreset(named: "A"))    // index 4
        store.add(makeUserPreset(named: "B"))    // index 5

        // Move B before A: SwiftUI onMove(from: [5], to: 4).
        store.move(fromOffsets: IndexSet(integer: 5), toOffset: 4)
        XCTAssertEqual(store.presets.map(\.name),
                       ["Natural", "Meeting", "Studio", "Low latency", "B", "A"])

        // Move A (now index 5) to the very front.
        store.move(fromOffsets: IndexSet(integer: 5), toOffset: 0)
        XCTAssertEqual(store.presets.map(\.name),
                       ["A", "Natural", "Meeting", "Studio", "Low latency", "B"])

        // Move the front element to the end: toOffset == count.
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 6)
        XCTAssertEqual(store.presets.map(\.name),
                       ["Natural", "Meeting", "Studio", "Low latency", "B", "A"])
    }

    func testMoveWithInvalidOffsetsIsNoOp() {
        let store = makeStore()
        let before = store.presets
        store.move(fromOffsets: IndexSet(integer: 99), toOffset: 0)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 99)
        XCTAssertEqual(store.presets, before)
    }

    // MARK: - Persistence

    func testPersistenceRoundTripsUserPresetsOrderingAndHotkeys() throws {
        let first = makeStore()
        first.add(makeUserPreset(named: "Mine"))
        let mineID = first.presets[4].id
        first.setHotkey(mineID, hotkey: HotkeyCombo(keyCode: 19, option: true, command: true))
        // Hotkeys may bind to built-ins too — user state, not configuration.
        let naturalID = first.presets[0].id
        first.setHotkey(naturalID, hotkey: HotkeyCombo(keyCode: 18, option: true, command: true))
        first.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.presets.map(\.name),
                       ["Mine", "Natural", "Meeting", "Studio", "Low latency"])
        XCTAssertEqual(reloaded.presets[0].id, mineID)
        XCTAssertEqual(reloaded.presets[0].hotkey,
                       HotkeyCombo(keyCode: 19, option: true, command: true))
        XCTAssertEqual(reloaded.presets[0].configuration,
                       makeUserPreset(named: "Mine").configuration)
        XCTAssertEqual(reloaded.presets[1].hotkey,
                       HotkeyCombo(keyCode: 18, option: true, command: true))
        XCTAssertTrue(reloaded.presets[1].isBuiltIn)
    }

    func testTamperedBuiltInIsRestoredToCanonicalFormOnLoad() throws {
        let store = makeStore()
        store.add(makeUserPreset(named: "Keep me"))

        // Tamper with the persisted file: rename Natural, gut its config,
        // and promote the user preset to isBuiltIn.
        var onDisk = try JSONDecoder().decode(
            [Preset].self, from: Data(contentsOf: storeURL))
        onDisk[0].name = "Totally different"
        onDisk[0].configuration.latencyPolicy = .lowest
        onDisk[4].isBuiltIn = true
        let encoded = try JSONEncoder().encode(onDisk)
        try encoded.write(to: storeURL)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.presets[0].name, "Natural")
        XCTAssertEqual(reloaded.presets[0].configuration,
                       PresetStore.builtIns[0].configuration)
        XCTAssertTrue(reloaded.presets[0].isBuiltIn)
        // The impostor is demoted back to a user preset (and stays deletable).
        XCTAssertFalse(reloaded.presets[4].isBuiltIn)
        reloaded.delete(reloaded.presets[4].id)
        XCTAssertEqual(reloaded.presets.count, 4)
    }

    func testMissingBuiltInsAreReinsertedAtFront() throws {
        // Persist a file containing only a user preset — all four built-ins
        // must come back, in canonical order, ahead of it.
        let user = makeUserPreset(named: "Only me")
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode([user]).write(to: storeURL)

        let store = makeStore()
        XCTAssertEqual(store.presets.map(\.name),
                       ["Natural", "Meeting", "Studio", "Low latency", "Only me"])
    }

    func testHotkeyIsStolenFromPreviousHolder() {
        let store = makeStore()
        store.add(makeUserPreset(named: "A"))
        store.add(makeUserPreset(named: "B"))
        let aID = store.presets[4].id
        let bID = store.presets[5].id
        let combo = HotkeyCombo(keyCode: 18, option: true, command: true)

        store.setHotkey(aID, hotkey: combo)
        store.setHotkey(bID, hotkey: combo)
        XCTAssertNil(store.presets[4].hotkey, "a combo drives only one preset")
        XCTAssertEqual(store.presets[5].hotkey, combo)
    }
}
