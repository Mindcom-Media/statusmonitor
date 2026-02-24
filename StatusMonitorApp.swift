import SwiftUI
import AppKit

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
    private var attentionObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from dock
        NSApplication.shared.setActivationPolicy(.accessory)

        // Setup menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                   accessibilityDescription: "StatusMonitor")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle Panel", action: #selector(togglePanel), keyEquivalent: "t"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu

        // Setup floating panel
        let panel = StatusPanelWindow.shared
        panel.setContent(monitor: monitor, alertManager: alertManager)
        panel.show()

        // Wire up alert trigger
        monitor.onAttentionNeeded = { [weak self] in
            self?.alertManager.triggerAlert()
            self?.updateMenuBarIcon(needsAttention: true)
        }

        // Observe session changes to update menu bar icon
        attentionObserver = monitor.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                let anyNeedsAttention = sessions.contains { $0.needsAttention }
                self?.updateMenuBarIcon(needsAttention: anyNeedsAttention)
            }

        // Start monitoring
        monitor.startMonitoring()
    }

    private func updateMenuBarIcon(needsAttention: Bool) {
        guard let button = statusItem.button else { return }
        let symbolName = needsAttention
            ? "antenna.radiowaves.left.and.right.slash"
            : "antenna.radiowaves.left.and.right"
        button.image = NSImage(systemSymbolName: symbolName,
                               accessibilityDescription: "StatusMonitor")
        if needsAttention {
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = nil
        }
    }

    @objc private func togglePanel() {
        StatusPanelWindow.shared.toggle()
    }

    @objc private func quitApp() {
        monitor.stopMonitoring()
        NSApplication.shared.terminate(nil)
    }
}
