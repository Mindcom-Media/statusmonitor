import Foundation
import AppKit
import AudioToolbox

final class AlertManager: ObservableObject {
    @Published var isFlashing = false
    @Published var flashCycle = 0
    private var flashTimer: Timer?
    private var bellTimer: Timer?

    func triggerAlert() {
        // Play alert sound 3 times with spacing
        AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
        var bellCount = 0
        bellTimer?.invalidate()
        bellTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
            bellCount += 1
            AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)
            if bellCount >= 2 {
                timer.invalidate()
                self?.bellTimer = nil
            }
        }

        // Bounce dock icon aggressively
        NSApp.requestUserAttention(.criticalRequest)

        // Start rapid flash cycle — toggles on/off 8 times over 4 seconds
        startFlashing()
    }

    private func startFlashing() {
        flashTimer?.invalidate()
        flashCycle = 0
        isFlashing = true

        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.flashCycle += 1
            self.isFlashing.toggle()
            if self.flashCycle >= 16 {
                timer.invalidate()
                self.flashTimer = nil
                self.isFlashing = false
            }
        }
    }
}
