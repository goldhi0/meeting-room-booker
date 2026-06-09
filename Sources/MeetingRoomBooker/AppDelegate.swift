import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Dock 아이콘 숨김, 메뉴바 전용

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "calendar.badge.plus",
                                   accessibilityDescription: "회의실 예약")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua) // 토스 라이트 테마 고정 (다크모드에서도 동일)
        popover.contentViewController = NSHostingController(rootView: BookingView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
