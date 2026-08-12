// main.swift
// PRISMCameraExtension — process entry point for the PRISM camera system
// extension. Builds the provider source and hands it to CoreMediaIO, then
// parks the main thread in a run loop for the life of the process.
//
// Licensed under the Apache License, Version 2.0.

import CoreMediaIO
import Foundation

// All provider/device/stream source callbacks are serialized onto this queue.
// It is user-interactive because the sink → source frame relay rides on it
// and has a 3 ms handoff budget (SPEC §6).
let providerQueue = DispatchQueue(label: "horse.prism.PRISM.camera.provider",
                                  qos: .userInteractive)

let providerSource = PRISMExtensionProviderSource(clientQueue: providerQueue)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
