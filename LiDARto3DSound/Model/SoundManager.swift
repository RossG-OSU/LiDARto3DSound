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

    
    deinit {
        print("SoundManager deallocated")
    }
    
    init() {
        // Load the beep sound
        guard let soundURL = Bundle.main.url(forResource: "beep_333hz", withExtension: "wav") else {
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

    func playSounds(for values: [Float16]) {
        guard !values.isEmpty else {
            print("Values Empty")
            return
        }
        self.playIndex = 0

        //timer?.invalidate()
        print("Setting up timer with interval \(self.interval)")
        timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { [weak self] _ in
            print("Timer fired")
            self?.playNext(values: values)
        }
        
    }

    private func playNext(values: [Float16]) {
        print("playNext called with playIndex \(playIndex)")

        guard playIndex < values.count, playIndex < audioPlayers.count else {
            print("Invalid index. Stopping timer.")
            timer?.invalidate()
            return
        }

        // Volume adjustment logic
        let volume = max(0, min(1, values[playIndex]))
        print("Setting player volume to \(volume) at index \(playIndex)")
        
        let player = audioPlayers[playIndex]
        player.volume = Float(volume)
        player.play()
        playIndex += 1
    }
}

