import Foundation
import AppKit
import AVFoundation

final class AlertManager: ObservableObject {
    @Published var isFlashing = false
    @Published var flashCycle = 0
    private var flashTimer: Timer?
    private var audioPlayer: AVAudioPlayer?

    init() {
        // Load alert sound — try bundle first, fallback to project directory
        if let bundleURL = Bundle.module.url(forResource: "alert", withExtension: "mp3") {
            audioPlayer = try? AVAudioPlayer(contentsOf: bundleURL)
        } else {
            let fallback = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
                .appendingPathComponent("repos/statusmonitor/alert.mp3")
            audioPlayer = try? AVAudioPlayer(contentsOf: fallback)
        }
        audioPlayer?.prepareToPlay()
    }

    func triggerAlert() {
        // Play the undertaker's bell once
        audioPlayer?.currentTime = 0
        audioPlayer?.play()

        // Bounce dock icon
        NSApp.requestUserAttention(.criticalRequest)

        // Start rapid flash cycle
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
