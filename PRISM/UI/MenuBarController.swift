// MenuBarController.swift
// PRISM
//
// Owns the native, square status item and presents the SwiftUI control
// surface in an NSPopover. A custom SwiftUI MenuBarExtra label reserves 40
// points even for a 19-point image; this 24-point item remains available on
// notched displays where macOS has very little room for third-party items.
//
// Licensed under the Apache License, Version 2.0.

import AppKit
import Combine
import SwiftUI

private final class MenuBarFallbackButton: NSButton {
    var onPress: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

private final class MenuBarFallbackPanel: NSPanel {
    var onPress: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onPress?()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var menuBarStateObservation: AnyCancellable?
    private var fallbackPanels: [MenuBarFallbackPanel] = []
    private var placementTimer: Timer?
    private var renderedImage: NSImage?
    private var renderedTint: NSColor?
    private var renderedDescription = "PRISM"

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // A stable name lets AppKit preserve the user's position and lets
        // Tahoe associate this item with PRISM's "Allow in the Menu Bar"
        // switch across rebuilds.
        statusItem.autosaveName = "PRISMMenuBarItem"
        statusItem.behavior = .removalAllowed
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .imageOnly
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: PopoverView().environmentObject(state)
        )

        updateStatusItem(for: state.menuBarState)
        menuBarStateObservation = state.$menuBarState
            .removeDuplicates()
            .sink { [weak self] newState in
                self?.updateStatusItem(for: newState)
            }

        // macOS 26 can retain an off-screen slot for a repeatedly rebuilt
        // development app even while "Allow in the Menu Bar" is enabled.
        // Check after Control Center has made its placement decision, and
        // keep watching so the fallback goes away if the native slot returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshPlacement()
            guard let self else { return }
            self.placementTimer = Timer.scheduledTimer(withTimeInterval: 2,
                                                       repeats: true) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPlacement() }
            }
            self.placementTimer?.tolerance = 0.25
        }
    }

    @objc private func togglePopover(_ sender: NSButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        let availableHeight = sender.window?.screen?.visibleFrame.height
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(availableScreenHeight: availableHeight)
                .environmentObject(state)
        )
        state.popoverOpen = true
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        state.popoverOpen = false
    }

    private func updateStatusItem(for newState: MenuBarState) {
        guard let button = statusItem.button else { return }
        let icon = MenuBarIcon(state: newState)
        let iconSide = min(NSStatusBar.system.thickness, 24)
        let renderer = ImageRenderer(
            content: icon.frame(width: iconSide, height: iconSide)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        if let image = renderer.nsImage {
            image.isTemplate = true
            image.size = NSSize(width: iconSide, height: iconSide)
            button.image = image
            renderedImage = image
        } else {
            let fallback = NSImage(systemSymbolName: "triangle",
                                   accessibilityDescription: "PRISM")
            fallback?.isTemplate = true
            button.image = fallback
            renderedImage = fallback
        }

        button.contentTintColor = icon.isAlerting ? .systemRed : nil
        button.toolTip = icon.accessibilityDescription
        button.setAccessibilityLabel(icon.accessibilityDescription)
        renderedTint = button.contentTintColor
        renderedDescription = icon.accessibilityDescription
        updateFallbackButtons()
    }

    private func refreshPlacement() {
        if nativeItemIsUsable {
            fallbackPanels.forEach { $0.orderOut(nil) }
            fallbackPanels.removeAll()
            return
        }

        if fallbackPanels.count != NSScreen.screens.count {
            fallbackPanels.forEach { $0.orderOut(nil) }
            fallbackPanels = NSScreen.screens.map(makeFallbackPanel)
        }
        positionFallbackPanels()
        updateFallbackButtons()
        fallbackPanels.forEach { $0.orderFrontRegardless() }
    }

    /// An off-screen status item on Tahoe has a real NSWindow, but its frame
    /// sits at the lower-left of no display. Also reject a frame underneath a
    /// Control Center item (the other bad restoration position we observed).
    private var nativeItemIsUsable: Bool {
        guard let frame = statusItem.button?.window?.frame,
              NSScreen.screens.contains(where: { screen in
                  let barHeight = menuBarHeight(for: screen)
                  let strip = NSRect(x: screen.frame.minX,
                                     y: screen.frame.maxY - barHeight,
                                     width: screen.frame.width,
                                     height: barHeight)
                  return strip.intersects(frame)
              }) else {
            return false
        }

        let quartzFrame = NSRect(x: frame.minX,
                                 y: (NSScreen.screens.first?.frame.maxY ?? 0) - frame.maxY,
                                 width: frame.width,
                                 height: frame.height)
        return !statusWindows(excludingPRISM: true).contains { $0.intersects(quartzFrame) }
    }

    private func makeFallbackPanel(for screen: NSScreen) -> MenuBarFallbackPanel {
        let height = menuBarHeight(for: screen)
        let panel = MenuBarFallbackPanel(
            contentRect: NSRect(x: 0, y: 0, width: 24, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // Control Center owns an input shield at the status-bar level on
        // Tahoe. The fallback must sit at pop-up-menu level to receive the
        // click its pixels visibly invite.
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]

        let button = MenuBarFallbackButton(
            frame: NSRect(x: 0, y: 0, width: 24, height: height)
        )
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.onPress = { [weak self, weak button] in
            guard let self, let button else { return }
            self.togglePopover(button)
        }
        panel.onPress = button.onPress
        panel.contentView = button
        return panel
    }

    private func positionFallbackPanels() {
        let windows = statusWindows(excludingPRISM: true)
        for (panel, screen) in zip(fallbackPanels, NSScreen.screens) {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                             as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
            let quartzScreen = displayID.map(CGDisplayBounds) ?? .zero
            let barWindows = windows.filter {
                abs($0.minY - quartzScreen.minY) < 4 &&
                $0.height <= menuBarHeight(for: screen) + 4 &&
                $0.minX >= quartzScreen.minX && $0.maxX <= quartzScreen.maxX
            }
            let leftEdge = barWindows.map(\.minX).min() ?? (screen.frame.maxX - 180)
            let x = max(screen.frame.minX, leftEdge - panel.frame.width - 4)
            let y = screen.frame.maxY - panel.frame.height
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func updateFallbackButtons() {
        for case let button as NSButton in fallbackPanels.compactMap(\.contentView) {
            button.image = renderedImage
            button.contentTintColor = renderedTint
            button.toolTip = renderedDescription
            button.setAccessibilityLabel(renderedDescription)
        }
    }

    private func menuBarHeight(for screen: NSScreen) -> CGFloat {
        max(NSStatusBar.system.thickness, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    private func statusWindows(excludingPRISM: Bool) -> [NSRect] {
        guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly,
                                                    kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { window in
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
            guard layer == Int(CGWindowLevelForKey(.statusWindow)) else { return nil }
            let owner = window[kCGWindowOwnerName as String] as? String
            if excludingPRISM && owner == "PRISM" { return nil }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue else {
                return nil
            }
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }
}
