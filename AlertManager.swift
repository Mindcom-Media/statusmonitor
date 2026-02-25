import Foundation
import AppKit
import AVFoundation

final class AlertManager: ObservableObject {
    @Published var isFlashing = false
    @Published var flashCycle = 0
    private var flashTimer: Timer?
    private var bellPlayer: AVAudioPlayer?
    private var donePlayer: AVAudioPlayer?

    init() {
        // Load bell sound (undertaker's bell) for permission alerts
        if let bundleURL = Bundle.module.url(forResource: "alert", withExtension: "mp3") {
            bellPlayer = try? AVAudioPlayer(contentsOf: bundleURL)
        } else {
            let fallback = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path)
                .appendingPathComponent("repos/statusmonitor/alert.mp3")
            bellPlayer = try? AVAudioPlayer(contentsOf: fallback)
        }
        bellPlayer?.prepareToPlay()

        // Load done sound (system Glass chime) for task completion
        let glassURL = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        donePlayer = try? AVAudioPlayer(contentsOf: glassURL)
        donePlayer?.prepareToPlay()
    }

    /// Permission prompt — undertaker's bell + aggressive flash
    func triggerPermissionAlert() {
        bellPlayer?.currentTime = 0
        bellPlayer?.play()
        NSApp.requestUserAttention(.criticalRequest)
        startFlashing(cycles: 16, interval: 0.25)
    }

    /// Session finished working — done chime + gentle flash
    func triggerDoneAlert() {
        donePlayer?.currentTime = 0
        donePlayer?.play()
        NSApp.requestUserAttention(.informationalRequest)
        startFlashing(cycles: 6, interval: 0.4)
    }

    private func startFlashing(cycles: Int, interval: TimeInterval) {
        flashTimer?.invalidate()
        flashCycle = 0
        isFlashing = true

        flashTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.flashCycle += 1
            self.isFlashing.toggle()
            if self.flashCycle >= cycles {
                timer.invalidate()
                self.flashTimer = nil
                self.isFlashing = false
            }
        }
    }
}
