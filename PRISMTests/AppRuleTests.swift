// AppRuleTests.swift
// PRISMTests
//
// The §5.15 per-app rule logic: the resolver (including the two-clients-at-
// once conflict rule, which is the whole reason the resolver is a separate
// pure type), the flattening into the 'polc' wire payload, and tolerant
// decoding of the persisted settings.
//
// The wire-payload tests inspect raw JSON rather than round-tripping through
// `AccessPolicy`. The consumer is `ExtAccessPolicy` inside the camera
// extension, which is a separate target this bundle cannot link (SPEC §3.1),
// so the key names are the contract and a round trip would never notice one
// being renamed on both sides at once.
//
// Licensed under the Apache License, Version 2.0.

import XCTest

final class AppRuleTests: XCTestCase {

    private let zoom = "us.zoom.xos"
    private let facetime = "com.apple.FaceTime"
    private let teams = "com.microsoft.teams2"

    private let meeting = UUID(uuidString: "50524953-4D00-4000-8000-000000000002")!
    private let studio = UUID(uuidString: "50524953-4D00-4000-8000-000000000003")!

    /// Enabled by default, because every test below is about what happens
    /// once the user has opted in; the shipped default is covered separately.
    private func settings(_ rules: [AppRule],
                          defaultAccess: AppAccess = .allow) -> AppRuleSettings {
        var settings = AppRuleSettings()
        settings.isEnabled = true
        settings.defaultAccess = defaultAccess
        settings.rules = rules
        return settings
    }

    // MARK: - Defaults (§5.15 ships off)

    func testDefaultsAreInert() {
        let settings = AppRuleSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.defaultAccess, .allow)
        XCTAssertTrue(settings.rules.isEmpty)
        XCTAssertFalse(settings.blocksAnything)
        XCTAssertTrue(AppRuleResolver.policy(for: settings).isAllowAll)
    }

    func testDisabledSettingsAllowAndStyleNothing() {
        var settings = self.settings([
            AppRule(signingID: zoom, access: .block),
            AppRule(signingID: facetime, presetID: meeting),
        ], defaultAccess: .block)
        settings.isEnabled = false

        XCTAssertEqual(AppRuleResolver.access(for: zoom, in: settings), .allow)
        XCTAssertEqual(AppRuleResolver.access(for: "com.example.anything", in: settings), .allow)
        XCTAssertNil(AppRuleResolver.presetMatch(clients: [facetime], in: settings))
        XCTAssertTrue(AppRuleResolver.policy(for: settings).isAllowAll)
    }

    // MARK: - Access

    func testUnnamedAppTakesTheDefault() {
        let allowing = settings([AppRule(signingID: zoom, access: .block)])
        XCTAssertEqual(AppRuleResolver.access(for: facetime, in: allowing), .allow)

        let blocking = settings([AppRule(signingID: zoom, access: .allow)],
                                defaultAccess: .block)
        XCTAssertEqual(AppRuleResolver.access(for: facetime, in: blocking), .block)
        XCTAssertEqual(AppRuleResolver.access(for: zoom, in: blocking), .allow)
    }

    func testMatchingIsExactNotPrefix() {
        // The whole point of matching on a signing ID is that it is an
        // identity; a look-alike must not inherit the rule.
        let settings = settings([AppRule(signingID: zoom, access: .block)])
        XCTAssertEqual(AppRuleResolver.access(for: zoom, in: settings), .block)
        XCTAssertEqual(AppRuleResolver.access(for: "us.zoom.xos.helper", in: settings), .allow)
        XCTAssertEqual(AppRuleResolver.access(for: "US.ZOOM.XOS", in: settings), .allow)
        XCTAssertEqual(AppRuleResolver.access(for: "us.zoom", in: settings), .allow)
    }

    func testPRISMItselfIsNeverBlocked() {
        // Including under a deny-by-default list that names it explicitly:
        // a rule that refuses PRISM is a rule that turns PRISM off from
        // inside PRISM.
        let settings = settings([
            AppRule(signingID: AppRuleResolver.selfSigningID, access: .block),
        ], defaultAccess: .block)
        XCTAssertEqual(
            AppRuleResolver.access(for: AppRuleResolver.selfSigningID, in: settings), .allow)
        XCTAssertFalse(
            AppRuleResolver.policy(for: settings).blocked.contains(AppRuleResolver.selfSigningID))
    }

    func testFirstRuleForAnAppWins() {
        let settings = settings([
            AppRule(signingID: zoom, access: .allow, presetID: meeting),
            AppRule(signingID: zoom, access: .block, presetID: studio),
        ])
        XCTAssertEqual(AppRuleResolver.access(for: zoom, in: settings), .allow)
        XCTAssertEqual(AppRuleResolver.presetMatch(clients: [zoom], in: settings)?.presetID,
                       meeting)
    }

    func testEmptySigningIDMatchesNothing() {
        let settings = settings([
            AppRule(signingID: "   ", access: .block, presetID: studio),
        ], defaultAccess: .allow)
        XCTAssertEqual(AppRuleResolver.access(for: "", in: settings), .allow)
        XCTAssertNil(AppRuleResolver.presetMatch(clients: [""], in: settings))
        XCTAssertTrue(AppRuleResolver.policy(for: settings).blocked.isEmpty)
    }

    // MARK: - Preset resolution, one client

    func testRuleAppliesPresetForItsApp() {
        let settings = settings([AppRule(signingID: zoom, presetID: meeting)])
        let match = AppRuleResolver.presetMatch(clients: [zoom], in: settings)
        XCTAssertEqual(match, AppRuleMatch(signingID: zoom, presetID: meeting))
    }

    func testNoClientsMeansNoMatch() {
        let settings = settings([AppRule(signingID: zoom, presetID: meeting)])
        XCTAssertNil(AppRuleResolver.presetMatch(clients: [], in: settings))
    }

    func testUnruledClientLeavesTheLookAlone() {
        let settings = settings([AppRule(signingID: zoom, presetID: meeting)])
        XCTAssertNil(AppRuleResolver.presetMatch(clients: [facetime], in: settings))
    }

    func testRuleWithoutAPresetDecidesAccessOnly() {
        let settings = settings([AppRule(signingID: zoom, access: .allow, presetID: nil)])
        XCTAssertEqual(AppRuleResolver.access(for: zoom, in: settings), .allow)
        XCTAssertNil(AppRuleResolver.presetMatch(clients: [zoom], in: settings))
    }

    func testBlockedAppNeverDrivesTheLook() {
        // It should never reach 'clnt' at all, but a policy write still in
        // flight must not let it style the camera on its way to refusal.
        let settings = settings([AppRule(signingID: zoom, access: .block, presetID: studio)])
        XCTAssertNil(AppRuleResolver.presetMatch(clients: [zoom], in: settings))
    }

    // MARK: - Preset resolution, two clients at once

    func testListOrderDecidesWhenTwoAppsStream() {
        let zoomFirst = settings([
            AppRule(signingID: zoom, presetID: meeting),
            AppRule(signingID: facetime, presetID: studio),
        ])
        XCTAssertEqual(AppRuleResolver.presetMatch(clients: [zoom, facetime], in: zoomFirst),
                       AppRuleMatch(signingID: zoom, presetID: meeting))
        // Same two clients, same two rules, opposite order: the answer flips.
        // That is the entire user-facing contract of dragging the list.
        let facetimeFirst = settings([
            AppRule(signingID: facetime, presetID: studio),
            AppRule(signingID: zoom, presetID: meeting),
        ])
        XCTAssertEqual(AppRuleResolver.presetMatch(clients: [zoom, facetime], in: facetimeFirst),
                       AppRuleMatch(signingID: facetime, presetID: studio))
    }

    func testClientOrderDoesNotAffectTheOutcome() {
        // The extension reports whatever order clients happened to start in.
        // If that leaked into the look, the same two apps would produce a
        // different camera depending on which the user opened first.
        let settings = settings([
            AppRule(signingID: zoom, presetID: meeting),
            AppRule(signingID: facetime, presetID: studio),
        ])
        let forward = AppRuleResolver.presetMatch(clients: [zoom, facetime], in: settings)
        let reverse = AppRuleResolver.presetMatch(clients: [facetime, zoom], in: settings)
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward?.signingID, zoom)
    }

    func testLowerRuleWinsWhenTheHigherAppIsNotStreaming() {
        let settings = settings([
            AppRule(signingID: zoom, presetID: meeting),
            AppRule(signingID: facetime, presetID: studio),
        ])
        XCTAssertEqual(AppRuleResolver.presetMatch(clients: [facetime, teams], in: settings),
                       AppRuleMatch(signingID: facetime, presetID: studio))
    }

    func testHigherRuleWithoutAPresetDoesNotVetoALowerOne() {
        // "Zoom may use the camera" is not "Zoom decides the look" — the
        // first rule that actually names a preset is the one that wins.
        let settings = settings([
            AppRule(signingID: zoom, access: .allow, presetID: nil),
            AppRule(signingID: facetime, presetID: studio),
        ])
        XCTAssertEqual(AppRuleResolver.presetMatch(clients: [zoom, facetime], in: settings),
                       AppRuleMatch(signingID: facetime, presetID: studio))
    }

    func testBlockedHigherRuleDoesNotVetoALowerOne() {
        let settings = settings([
            AppRule(signingID: zoom, access: .block, presetID: meeting),
            AppRule(signingID: facetime, presetID: studio),
        ])
        XCTAssertEqual(AppRuleResolver.presetMatch(clients: [zoom, facetime], in: settings),
                       AppRuleMatch(signingID: facetime, presetID: studio))
    }

    // MARK: - blocksAnything

    func testBlocksAnythingTracksRealRefusals() {
        XCTAssertFalse(settings([AppRule(signingID: zoom, presetID: meeting)]).blocksAnything)
        XCTAssertTrue(settings([AppRule(signingID: zoom, access: .block)]).blocksAnything)
        XCTAssertTrue(settings([], defaultAccess: .block).blocksAnything)
        var off = settings([AppRule(signingID: zoom, access: .block)])
        off.isEnabled = false
        XCTAssertFalse(off.blocksAnything)
    }

    // MARK: - Wire payload ('polc')

    private func policyJSON(_ settings: AppRuleSettings) throws -> [String: Any] {
        let data = try XCTUnwrap(AppRuleResolver.policy(for: settings).jsonData)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPolicyPayloadKeysMatchTheExtensionMirror() throws {
        let object = try policyJSON(settings([
            AppRule(signingID: zoom, access: .block),
            AppRule(signingID: facetime, access: .allow),
        ], defaultAccess: .block))

        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["defaultAccess"] as? String, "block")
        XCTAssertEqual(object["blocked"] as? [String], [zoom])
        XCTAssertEqual(object["allowed"] as? [String], [facetime])
        XCTAssertEqual(Set(object.keys), ["version", "defaultAccess", "blocked", "allowed"])
    }

    func testPolicyPayloadSpellsAccessAsAllowAndBlock() throws {
        // ExtAccessPolicy compares the raw string, so these two spellings are
        // load-bearing across a target boundary the compiler cannot check.
        XCTAssertEqual(AppAccess.allow.rawValue, "allow")
        XCTAssertEqual(AppAccess.block.rawValue, "block")
        let object = try policyJSON(settings([], defaultAccess: .allow))
        XCTAssertEqual(object["defaultAccess"] as? String, "allow")
    }

    func testDisabledPolicyIsAnExplicitAllowAll() throws {
        // Not empty data: the extension persists what it is sent, so turning
        // the feature off has to actively overwrite the previous policy.
        var settings = self.settings([AppRule(signingID: zoom, access: .block)],
                                     defaultAccess: .block)
        settings.isEnabled = false
        let object = try policyJSON(settings)
        XCTAssertEqual(object["defaultAccess"] as? String, "allow")
        XCTAssertEqual(object["blocked"] as? [String], [])
    }

    func testFlatteningTakesTheFirstRulePerApp() {
        let policy = AppRuleResolver.policy(for: settings([
            AppRule(signingID: zoom, access: .block),
            AppRule(signingID: zoom, access: .allow),
            AppRule(signingID: facetime, access: .allow),
        ]))
        // Flattening is only lossless if a signing ID lands in exactly one
        // list — otherwise the extension's set test and the ordered walk
        // disagree about the same app.
        XCTAssertEqual(policy.blocked, [zoom])
        XCTAssertEqual(policy.allowed, [facetime])
        XCTAssertFalse(policy.allowed.contains(zoom))
    }

    func testIsAllowAllIgnoresTheAllowList() {
        var policy = AccessPolicy()
        policy.allowed = [zoom]
        XCTAssertTrue(policy.isAllowAll)
        policy.blocked = [facetime]
        XCTAssertFalse(policy.isAllowAll)
        policy.blocked = []
        policy.defaultAccess = .block
        XCTAssertFalse(policy.isAllowAll)
    }

    // MARK: - Tolerant decoding (§5.5 forward compatibility)

    private func decodeSettings(_ json: String) throws -> AppRuleSettings {
        try JSONDecoder().decode(AppRuleSettings.self, from: Data(json.utf8))
    }

    func testEmptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try decodeSettings("{}"), AppRuleSettings())
    }

    func testAbsentFieldsFallBackWithoutLosingPresentOnes() throws {
        let decoded = try decodeSettings(#"{"isEnabled":true}"#)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.defaultAccess, .allow)
        XCTAssertTrue(decoded.announcesPresetChanges)
        XCTAssertTrue(decoded.rules.isEmpty)
    }

    func testPartialNestedRuleKeepsTheRestOfTheRule() throws {
        // The version-skew case: a rule object written by a build that did
        // not have `access` yet must not take the whole list with it.
        let decoded = try decodeSettings(
            #"{"isEnabled":true,"rules":[{"signingID":"us.zoom.xos"}]}"#)
        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertEqual(decoded.rules[0].signingID, zoom)
        XCTAssertEqual(decoded.rules[0].access, .allow)
        XCTAssertNil(decoded.rules[0].presetID)
    }

    func testUnknownEnumValueFallsBackToAllow() throws {
        // Fail open here too: an access mode a future build understands must
        // not read as "block" on this one.
        let decoded = try decodeSettings(
            #"{"isEnabled":true,"defaultAccess":"quarantine","rules":[{"signingID":"us.zoom.xos","access":"quarantine"}]}"#)
        XCTAssertEqual(decoded.defaultAccess, .allow)
        XCTAssertEqual(decoded.rules[0].access, .allow)
        XCTAssertEqual(AppRuleResolver.access(for: zoom, in: decoded), .allow)
    }

    func testWronglyTypedFieldsFallBack() throws {
        let decoded = try decodeSettings(
            #"{"isEnabled":"yes","defaultAccess":7,"announcesPresetChanges":[]}"#)
        XCTAssertFalse(decoded.isEnabled)
        XCTAssertEqual(decoded.defaultAccess, .allow)
        XCTAssertTrue(decoded.announcesPresetChanges)
    }

    func testUnknownFieldsAreIgnored() throws {
        let decoded = try decodeSettings(
            #"{"isEnabled":true,"futureField":{"nested":1},"rules":[{"signingID":"us.zoom.xos","futureRuleField":2}]}"#)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertEqual(decoded.rules[0].signingID, zoom)
    }

    func testMalformedPresetIDLeavesTheRuleUsable() throws {
        let decoded = try decodeSettings(
            #"{"isEnabled":true,"rules":[{"signingID":"us.zoom.xos","presetID":"not-a-uuid"}]}"#)
        XCTAssertEqual(decoded.rules[0].signingID, zoom)
        XCTAssertNil(decoded.rules[0].presetID)
    }

    func testRoundTripPreservesEverything() throws {
        let original = settings([
            AppRule(signingID: zoom, access: .allow, presetID: meeting),
            AppRule(signingID: facetime, access: .block),
        ], defaultAccess: .block)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(AppRuleSettings.self, from: data), original)
    }

    func testAccessPolicyDecodesTolerantly() throws {
        let decoded = try JSONDecoder().decode(
            AccessPolicy.self, from: Data(#"{"blocked":["us.zoom.xos"]}"#.utf8))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.defaultAccess, .allow)
        XCTAssertEqual(decoded.blocked, [zoom])
        XCTAssertTrue(decoded.allowed.isEmpty)
    }

    // MARK: - CameraClient

    func testCameraClientDerivesItsDisplayName() {
        XCTAssertEqual(CameraClient(signingID: zoom).name, "Zoom")
        XCTAssertEqual(CameraClient(signingID: zoom).id, zoom)
        // Identity is the signing ID, not the label — two apps can share a
        // friendly name and must still be separate clients.
        XCTAssertNotEqual(CameraClient(signingID: "com.a.Studio"),
                          CameraClient(signingID: "com.b.Studio"))
    }
}
