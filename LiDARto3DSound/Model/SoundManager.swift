//
//  SoundManager.swift
//  LiDARto3DSound
//
//  Created by Andrew Bottom on 11/21/24.
//
import Foundation
import AVFoundation

class SoundManager {
    private var audioPlayers: [AVAudioPlayer] = []
    private var timer: Timer?
    private var playIndex = 0
    private var interval: TimeInterval = 0.5 // Adjust playback interval

    init() {
        // Load the beep sound
        guard let soundURL = Bundle.main.url(forResource: "beep", withExtension: "wav") else {
            fatalError("Beep sound file not found")
        }
        
        // Create AVAudioPlayer instances for each pan level
        for pan in [-1.0, -0.5, 0.0, 0.5, 1.0] as [Float] {
            do {
                let player = try AVAudioPlayer(contentsOf: soundURL)
                player.pan = pan
                player.prepareToPlay()
                audioPlayers.append(player)
            } catch {
                print("Error initializing audio player: \(error)")
            }
        }
    }

    func playSounds(for values: [Float32], interval: TimeInterval) {
        guard !values.isEmpty else { return }
        self.interval = interval
        self.playIndex = 0

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.playNext(values: values)
        }
    }

    private func playNext(values: [Float32]) {
        guard playIndex < values.count, playIndex < audioPlayers.count else {
            timer?.invalidate()
            return
        }

        // Adjust the volume based on the depth value
        let volume = max(0, min(1, values[playIndex]))
        let player = audioPlayers[playIndex]
        player.volume = volume
        player.play()

        playIndex += 1
    }
}

