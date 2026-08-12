// ExtensionProvider.swift
// PRISMCameraExtension — CMIOExtensionProviderSource publishing the single
// "PRISM Camera" device (SPEC §3.1–§3.2). The provider also relays client
// disconnects to the device source so the streaming-client list ('clnt')
// stays accurate.
//
// Licensed under the Apache License, Version 2.0.

import CoreMediaIO
import Foundation

final class PRISMExtensionProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    let deviceSource: PRISMDeviceSource

    init(clientQueue: DispatchQueue?) {
        deviceSource = PRISMDeviceSource()
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            // Without the device the extension is useless; crash loudly so
            // the failure is visible in the system log rather than silent.
            fatalError("PRISM camera extension: failed to add device: \(error)")
        }
    }

    // MARK: - CMIOExtensionProviderSource

    func connect(to client: CMIOExtensionClient) throws {
        prismLog.info("client connected: \(client.signingID ?? "unknown", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        prismLog.info("client disconnected: \(client.signingID ?? "unknown", privacy: .public)")
        deviceSource.noteClientDisconnected(client)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "PRISM"
        }
        if properties.contains(.providerName) {
            providerProperties.name = "PRISM Camera Provider"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // No settable provider properties. The app ↔ extension control
        // channel lives on the device object (pfmt/clnt/hoff).
    }
}
