import AppKit
import SwiftUI

final class StatusPanelWindow: NSWindow {
    static let shared = StatusPanelWindow()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
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
    }

    func setContent(monitor: SessionMonitor, alertManager: AlertManager) {
        let view = StatusPanelView(monitor: monitor, alertManager: alertManager)
        let hostingView = NSHostingView(rootView: view)
        // Let the hosting view size itself to its SwiftUI content
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = hostingView
        positionTopRight()
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
