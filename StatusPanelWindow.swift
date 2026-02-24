import AppKit
import SwiftUI

final class StatusPanelWindow: NSWindow {
    static let shared = StatusPanelWindow()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
        self.isMovableByWindowBackground = true
        self.hasShadow = true
        positionTopRight()
    }

    func setContent(monitor: SessionMonitor, alertManager: AlertManager) {
        let view = StatusPanelView(monitor: monitor, alertManager: alertManager)
        let hostingView = NSHostingView(rootView: view)
        self.contentView = hostingView
    }

    func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.maxX - frame.width - 16
        let y = visibleFrame.maxY - frame.height - 16
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    func show() {
        orderFront(nil)
    }

    func toggle() {
        if isVisible {
            orderOut(nil)
        } else {
            show()
        }
    }
}
