// DeviceMonitor.swift
// PRISM
//
// Hot-plug and wake monitoring (SPEC §5.1, §7). Watches camera arrivals and
// departures via AVCaptureDevice notifications, microphone changes via a
// CoreAudio property listener on kAudioHardwarePropertyDevices, and system
// wake via NSWorkspace.didWakeNotification. PRISM's own virtual devices are
// excluded from every list. All callbacks are marshalled to the main thread.
//
// Licensed under the Apache License, Version 2.0.

import AVFoundation
import AppKit
import CoreAudio
import Foundation

public final class DeviceMonitor {

    // MARK: - Public surface (CONTRACTS.md)

    public var onCamerasChanged: (([CameraDeviceInfo]) -> Void)?      // main thread
    public var onMicrophonesChanged: (([AudioDeviceInfo]) -> Void)?   // main thread
    public var onWake: (() -> Void)?                                  // §7, main thread

    public init() {}

    deinit {
        stop()
    }

    // MARK: - Private state

    private var cameraObservers: [NSObjectProtocol] = []
    private var wakeObserver: NSObjectProtocol?
    private var audioListenerInstalled = false
    private var audioListenerBlock: AudioObjectPropertyListenerBlock?
    private let audioListenerQueue = DispatchQueue(
        label: "horse.prism.PRISM.device-monitor", qos: .utility)

    private static var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    // MARK: - Lifecycle

    public func start() {
        stop()

        // Cameras: connect/disconnect notifications (§5.1).
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.notifyCamerasChanged()
        }
        cameraObservers.append(center.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil, queue: nil, using: handler))
        cameraObservers.append(center.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil, queue: nil, using: handler))

        // Microphones: CoreAudio hardware device-list listener (§5.1).
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notifyMicrophonesChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &DeviceMonitor.devicesAddress,
            audioListenerQueue,
            block)
        if status == noErr {
            audioListenerInstalled = true
            audioListenerBlock = block
        }

        // Wake (§7): capture layer restarts on this signal.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async { self.onWake?() }
        }

        // Prime observers with the current lists.
        notifyCamerasChanged()
        notifyMicrophonesChanged()
    }

    public func stop() {
        let center = NotificationCenter.default
        for observer in cameraObservers { center.removeObserver(observer) }
        cameraObservers.removeAll()

        if audioListenerInstalled, let block = audioListenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &DeviceMonitor.devicesAddress,
                audioListenerQueue,
                block)
            audioListenerInstalled = false
            audioListenerBlock = nil
        }

        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: - Snapshots

    /// Physical cameras, excluding "PRISM Camera" (§5.1).
    public static func cameras() -> [CameraDeviceInfo] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified)
        return discovery.devices
            .filter { !CameraCapture.isPrismVirtualCamera($0) }
            .map { CameraDeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Physical input devices, excluding "PRISM Microphone" (§5.1).
    public static func microphones() -> [AudioDeviceInfo] {
        CoreAudioDevices.allDeviceIDs().compactMap { id in
            guard CoreAudioDevices.inputChannelCount(id) > 0,
                  !CoreAudioDevices.isPrismVirtualMicrophone(id),
                  let uid = CoreAudioDevices.uid(of: id) else { return nil }
            let name = CoreAudioDevices.name(of: id) ?? uid
            return AudioDeviceInfo(id: uid, name: name)
        }
    }

    // MARK: - Dispatch

    private func notifyCamerasChanged() {
        let list = DeviceMonitor.cameras()
        DispatchQueue.main.async { [weak self] in
            self?.onCamerasChanged?(list)
        }
    }

    private func notifyMicrophonesChanged() {
        let list = DeviceMonitor.microphones()
        DispatchQueue.main.async { [weak self] in
            self?.onMicrophonesChanged?(list)
        }
    }
}

// MARK: - CoreAudio device helpers (shared with AudioCapture)

/// Thin, allocation-tolerant CoreAudio HAL queries. Setup-path only — never
/// call from a real-time thread.
enum CoreAudioDevices {

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
            size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                &size, buf.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { self.uid(of: $0) == uid }
    }

    static func uid(of deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    static func name(of deviceID: AudioDeviceID) -> String? {
        stringProperty(deviceID, selector: kAudioObjectPropertyName)
    }

    /// Input-scope channel total from the device's stream configuration.
    static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr
        else { return 0 }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// PRISM's own virtual microphone must never appear in pickers or be
    /// captured from (§5.1) — matching by UID and by published name.
    static func isPrismVirtualMicrophone(_ deviceID: AudioDeviceID) -> Bool {
        if let uid = uid(of: deviceID), uid == "horse.prism.PRISM.audio.device" {
            return true
        }
        if let name = name(of: deviceID), name == "PRISM Microphone" {
            return true
        }
        return false
    }

    private static func stringProperty(_ deviceID: AudioDeviceID,
                                       selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
