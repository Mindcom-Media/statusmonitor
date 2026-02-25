import SwiftUI
import AppKit
import Combine

@main
struct StatusMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = SessionMonitor()
    private let alertManager = AlertManager()
    private var sessionObserver: AnyCancellable?
    private var autoHideTimer: Timer?
    private var panelManuallyToggled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApplication.shared.setActivationPolicy(.accessory)

        // Setup menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(sessions: [])

        // Click action on the status item button
        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Setup floating panel (starts hidden)
        let panel = StatusPanelWindow.shared
        panel.setContent(monitor: monitor, alertManager: alertManager)

        // Wire up alert trigger — show panel when attention needed
        monitor.onAttentionNeeded = { [weak self] type in
            guard let self else { return }
            switch type {
            case .permission:
                self.alertManager.triggerPermissionAlert()
            case .done:
                self.alertManager.triggerDoneAlert()
            }
            self.autoHideTimer?.invalidate()
            self.panelManuallyToggled = false
            StatusPanelWindow.shared.show()
        }

        // Observe session changes for menu bar color and auto-hide
        sessionObserver = monitor.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                self.updateMenuBarIcon(sessions: sessions)

                let anyNeedsAttention = sessions.contains { $0.needsAttention }

                if !anyNeedsAttention && StatusPanelWindow.shared.isVisible && !self.panelManuallyToggled {
                    // All clear — auto-hide after 3 seconds
                    self.autoHideTimer?.invalidate()
                    self.autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                        StatusPanelWindow.shared.orderOut(nil)
                    }
                } else if anyNeedsAttention {
                    // Cancel any pending auto-hide
                    self.autoHideTimer?.invalidate()
                }
            }

        // Start monitoring
        monitor.startMonitoring()
    }

    private func updateMenuBarIcon(sessions: [ClaudeSession]) {
        guard let button = statusItem.button else { return }

        let color: NSColor
        let anyWaiting = sessions.contains { $0.status == .waiting }
        let anyIdle = sessions.contains { $0.status == .idle }

        if sessions.isEmpty {
            color = .systemGray
        } else if anyWaiting {
            color = .systemRed
        } else if anyIdle {
            color = .systemYellow
        } else {
            color = .systemGreen
        }

        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "StatusMonitor")
        button.image = image
        button.contentTintColor = color

        // Show session count next to icon
        if sessions.isEmpty {
            button.title = ""
        } else {
            button.title = " \(sessions.count)"
        }
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // Right-click shows menu
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Quit StatusMonitor", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            // Clear menu so left-click works next time
            DispatchQueue.main.async { self.statusItem.menu = nil }
        } else {
            // Left-click toggles panel
            panelManuallyToggled = true
            autoHideTimer?.invalidate()
            StatusPanelWindow.shared.toggle()
        }
    }

    @objc private func quitApp() {
        monitor.stopMonitoring()
        NSApplication.shared.terminate(nil)
    }
}
