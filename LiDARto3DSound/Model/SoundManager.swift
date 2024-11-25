//
//  SoundManager.swift
//  LiDARto3DSound
//
//  Created by Andrew Bottom on 11/21/24.
//
import Foundation
import AVFoundation

import Foundation
import AVFoundation

class SoundManager {
    private var audioPlayers: [AVAudioPlayer] = []
    private var timer: Timer?
    private var playIndex = 0
    private let interval: TimeInterval = 0.1 // Playback interval
    var sounds: [Float16] = [0, 0, 0, 0, 0] // Shared state

    deinit {
        print("SoundManager deallocated")
    }

    init() {
        // Load the beep sound
        guard let soundURL = Bundle.main.url(forResource: "beep_333hz", withExtension: "wav") else {
            fatalError("Beep sound file not found")
        }

        // Create AVAudioPlayer instances for each pan level
        for pan in [-1.0, -0.35, 0.0, 0.35, 1.0] as [Float] {
            do {
                let player = try AVAudioPlayer(contentsOf: soundURL)
                player.pan = pan
                player.prepareToPlay()
                audioPlayers.append(player)
            } catch {
                print("Error initializing audio player: \(error)")
            }
        }

        // Start the timer immediately
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate() // Ensure no duplicate timers
        print("Starting timer with interval \(interval)")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.playNext()
        }
    }

    private func playNext() {
        guard !sounds.isEmpty else {
            print("No sounds to play.")
            return
        }

        // Reset playIndex if it exceeds the sounds array size
        if playIndex >= sounds.count {
            playIndex = 0
        }
        
        // Adjust volume and play sound
        let volume = max(0, min(1, sounds[playIndex]))
        let player = audioPlayers[playIndex]
        player.volume = Float(volume)
        player.play()

        // Move to the next sound in the array
        playIndex += 1
    }
}

