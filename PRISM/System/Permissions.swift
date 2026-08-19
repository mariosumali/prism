// Permissions.swift
// PRISM
//
// Camera, microphone and screen-recording TCC state (§9, grant #1). Wraps
// AVCaptureDevice.authorizationStatus / requestAccess and CoreGraphics'
// screen-capture preflight, and publishes PermissionState for OnboardingView
// and the setup banner.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import CoreGraphics
import Foundation

@MainActor
public final class Permissions: ObservableObject {

    @Published public private(set) var camera: PermissionState = .notDetermined
    @Published public private(set) var microphone: PermissionState = .notDetermined
    /// §5.24 — screen capture is its own grant, and unlike the other two it
    /// is demanded only by a feature that ships off. Nothing here asks for it
    /// until the user asks for a screen.
    @Published public private(set) var screenRecording: PermissionState = .notDetermined

    /// Whether the screen-recording prompt has ever been raised. CoreGraphics
    /// answers "do I have it?" and nothing else, so an ungranted state is
    /// indistinguishable between "never asked" and "said no" — and the two
    /// need different copy. This is the only way to tell them apart.
    private static let askedKey = "PRISM.screenRecordingAsked"

    public init() {
        refresh()
    }

    /// Re-reads every authorization status. Cheap; call whenever the app
    /// becomes active — the user may have changed grants in System Settings.
    public func refresh() {
        camera = Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        microphone = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        screenRecording = Self.screenRecordingState()
    }

    /// Raises the system screen-recording prompt, which on macOS only ever
    /// offers to open System Settings — the grant itself is given there and
    /// takes effect when PRISM is next launched. Returns whether access is
    /// already in force, which right after a first grant is normally false.
    @discardableResult
    public func requestScreenRecording() -> Bool {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted
    }

    private static func screenRecordingState() -> PermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return UserDefaults.standard.bool(forKey: askedKey) ? .denied : .notDetermined
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
