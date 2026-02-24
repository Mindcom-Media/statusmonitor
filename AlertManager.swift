import Foundation
import AppKit
import AudioToolbox

final class AlertManager: ObservableObject {
    @Published var isFlashing = false

    func triggerAlert() {
        // Play system alert sound
        AudioServicesPlayAlertSound(kSystemSoundID_UserPreferredAlert)

        // Bounce menu bar icon
        NSApp.requestUserAttention(.criticalRequest)

        // Trigger flash animation
        DispatchQueue.main.async {
            self.isFlashing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.isFlashing = false
            }
        }
    }
}
