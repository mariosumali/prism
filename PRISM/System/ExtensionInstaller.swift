// ExtensionInstaller.swift
// PRISM
//
// Drives installation and status of the camera system extension
// (horse.prism.PRISM.camera) via OSSystemExtensionManager (§9). Publishes
// ExtensionStatus for OnboardingView and the setup banner.
//
// Licensed under the Apache License, Version 2.0.

import Foundation
import os
import SystemExtensions

@MainActor
public final class ExtensionInstaller: NSObject, ObservableObject {

    /// Fixed identifier from CONTRACTS.md.
    public static let extensionIdentifier = "horse.prism.PRISM.camera"

    /// Activation failures are otherwise invisible (no UI open, request never
    /// reaches sysextd): `log stream --predicate 'subsystem == "horse.prism.PRISM"'`.
    private static let log = Logger(subsystem: "horse.prism.PRISM",
                                    category: "ExtensionInstaller")

    @Published public private(set) var status: ExtensionStatus = .unknown

    /// The in-flight activation request, if any. Delegate callbacks compare
    /// identity so a status poll never clobbers an activation in progress.
    private var activationRequest: OSSystemExtensionRequest?
    private var propertiesRequest: OSSystemExtensionRequest?

    /// One-shot per launch: a version-mismatch replacement request.
    private var autoReplaceSubmitted = false

    /// CFBundleVersion of the extension embedded in THIS app bundle; nil if
    /// the bundle layout is unexpected. Compared against the installed copy
    /// so an updated build replaces a stale extension automatically.
    static let embeddedExtensionVersion: String? = {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions")
            .appendingPathComponent("\(extensionIdentifier).systemextension")
        guard let bundle = Bundle(url: url) else { return nil }
        return bundle.infoDictionary?["CFBundleVersion"] as? String
    }()

    public override init() {
        super.init()
    }

    /// Submits an activation request for the embedded camera extension.
    /// On upgrade, the existing extension is replaced (`.replace`) — never
    /// left in place — so a new build always wins. Approval, success, and
    /// failure all land back in `status` on the main queue.
    public func install() {
        Self.log.info("submitting activation request for \(Self.extensionIdentifier, privacy: .public)")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main)
        request.delegate = self
        activationRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Polls the list of installed system extensions matching our identifier
    /// and maps it to ExtensionStatus. Safe to call repeatedly (onboarding
    /// polls while the user is off in System Settings).
    public func checkStatus() {
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main)
        request.delegate = self
        propertiesRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - Delegate handling (main actor)

    fileprivate func handleNeedsApproval(_ request: OSSystemExtensionRequest) {
        Self.log.info("activation needs user approval in System Settings")
        guard request === activationRequest else { return }
        // §8.4: the UI shows "Approve PRISM Camera in System Settings to
        // continue" for this state.
        status = .needsApproval
    }

    fileprivate func handleFinish(_ request: OSSystemExtensionRequest,
                                  result: OSSystemExtensionRequest.Result) {
        if request === propertiesRequest {
            // Status was already derived in handleFoundProperties.
            propertiesRequest = nil
            return
        }
        guard request === activationRequest else { return }
        activationRequest = nil
        Self.log.info("activation finished with result \(result.rawValue)")
        switch result {
        case .completed:
            status = .installed
        case .willCompleteAfterReboot:
            // §9 operational hazard: extension updates frequently require a
            // reboot. ExtensionStatus has no dedicated case, so surface it as
            // an actionable failure message rather than claiming "installed".
            status = .failed("Restart your Mac to finish installing PRISM Camera")
        @unknown default:
            status = .failed("Unexpected system extension result")
        }
    }

    fileprivate func handleFailure(_ request: OSSystemExtensionRequest, error: Error) {
        let nsError = error as NSError
        let kind = request === propertiesRequest ? "status poll" : "activation"
        Self.log.error("\(kind, privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code) — \(nsError.localizedDescription, privacy: .public)")
        if request === propertiesRequest {
            propertiesRequest = nil
            if let osError = error as? OSSystemExtensionError,
               osError.code == .extensionNotFound {
                status = .notInstalled
            }
            // Any other poll failure: keep the current status; a poll must
            // never invent an error state.
            return
        }
        guard request === activationRequest else { return }
        activationRequest = nil

        guard let osError = error as? OSSystemExtensionError else {
            status = .failed(error.localizedDescription)
            return
        }
        switch osError.code {
        case .requestCanceled, .requestSuperseded:
            // Another request took over (or the user canceled); not a failure.
            return
        case .unsupportedParentBundleLocation:
            // The most common contributor mistake: running from DerivedData
            // or ~/Downloads. Errors state what happened and what to do (§8.4).
            status = .failed("Move PRISM to /Applications, then try again")
        case .extensionNotFound:
            status = .failed("The camera extension is missing from the app bundle. Rebuild PRISM")
        case .codeSignatureInvalid, .validationFailed:
            status = .failed("The camera extension's signature is invalid. Rebuild with your Team ID (see README)")
        case .missingEntitlement:
            // Code 9 also covers non-entitlement preconditions (e.g. a missing
            // NSSystemExtensionUsageDescription in the extension's Info.plist),
            // so pass the system's own message through rather than guessing.
            status = .failed("macOS rejected the extension: \(error.localizedDescription)")
        case .forbiddenBySystemPolicy:
            status = .failed("A system policy is blocking the extension. Check Privacy & Security in System Settings")
        default:
            status = .failed(error.localizedDescription)
        }
    }

    fileprivate func handleFoundProperties(_ request: OSSystemExtensionRequest,
                                           properties: [OSSystemExtensionProperties]) {
        Self.log.info("status poll found \(properties.count) matching extension(s)")
        guard request === propertiesRequest else { return }
        // Ignore copies that are on their way out; they say nothing about
        // whether a usable extension is present.
        let active = properties.filter { !$0.isUninstalling }
        if let enabled = active.first(where: { $0.isEnabled }) {
            status = .installed
            // Stale copy? An extension serving an outdated property contract
            // fails in ways indistinguishable from app bugs, so replace it
            // the moment a version skew is seen (once per launch).
            if let embedded = Self.embeddedExtensionVersion,
               enabled.bundleVersion != embedded,
               !autoReplaceSubmitted {
                autoReplaceSubmitted = true
                Self.log.info("installed extension v\(enabled.bundleVersion, privacy: .public) != embedded v\(embedded, privacy: .public); submitting replacement")
                install()
            }
        } else if active.contains(where: { $0.isAwaitingUserApproval }) {
            status = .needsApproval
        } else if active.isEmpty {
            status = .notInstalled
        } else {
            // Present but neither enabled nor awaiting approval — treat as
            // needing the user's attention in System Settings.
            status = .needsApproval
        }
    }
}

// MARK: - OSSystemExtensionRequestDelegate

// The delegate protocol is nonisolated; requests are submitted with
// `queue: .main`, and each callback hops onto the main actor explicitly so
// the @MainActor state above is never touched off-actor.
extension ExtensionInstaller: OSSystemExtensionRequestDelegate {

    public nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Upgrades always replace the installed extension (§9): the extension
        // is a thin relay and a stale copy is worse than a reload.
        return .replace
    }

    public nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.handleNeedsApproval(request)
        }
    }

    public nonisolated func request(_ request: OSSystemExtensionRequest,
                                    didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.handleFinish(request, result: result)
        }
    }

    public nonisolated func request(_ request: OSSystemExtensionRequest,
                                    didFailWithError error: Error) {
        Task { @MainActor in
            self.handleFailure(request, error: error)
        }
    }

    public nonisolated func request(_ request: OSSystemExtensionRequest,
                                    foundProperties properties: [OSSystemExtensionProperties]) {
        Task { @MainActor in
            self.handleFoundProperties(request, properties: properties)
        }
    }
}
