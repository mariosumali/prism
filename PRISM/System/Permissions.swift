// Permissions.swift
// PRISM
//
// Camera and microphone TCC state (§9, grant #1). Wraps
// AVCaptureDevice.authorizationStatus / requestAccess and publishes
// PermissionState for OnboardingView and the setup banner.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import Foundation

@MainActor
public final class Permissions: ObservableObject {

    @Published public private(set) var camera: PermissionState = .notDetermined
    @Published public private(set) var microphone: PermissionState = .notDetermined

    public init() {
        refresh()
    }

    /// Re-reads both authorization statuses. Cheap; call whenever the app
    /// becomes active — the user may have changed grants in System Settings.
    public func refresh() {
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Shows the system camera prompt when undetermined; otherwise resolves
    /// immediately from the recorded state. Returns whether access is granted.
    public func requestCamera() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        refresh()
        return granted
    }

    /// Microphone counterpart of `requestCamera()`.
    public func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized:
            return .granted
        case .denied, .restricted:
            // Restricted (parental controls / MDM) is indistinguishable from
            // denied for PRISM's purposes: the fix lives in System Settings.
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }
}
