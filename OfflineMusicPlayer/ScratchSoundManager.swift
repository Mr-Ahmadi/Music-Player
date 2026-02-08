import Foundation
import AVFoundation
import Combine

/// Manages DJ jog wheel / vinyl scratch sound effects.
/// Uses AVAudioPlayer for reliable audio output.
final class ScratchSoundManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = ScratchSoundManager()
    
    // MARK: - Audio Player
    private var scratchPlayer: AVAudioPlayer?
    private var scratchFileURL: URL?
    private var isSessionActive = false
    
    // MARK: - State
    private var currentRate: Float = 1.0
    private var currentVolume: Float = 0.8
    
    private override init() {
        super.init()
        setupScratchAudio()
    }
    
    // MARK: - Setup
    private func setupScratchAudio() {
        // Check for bundled scratch sound first
        if let bundledURL = Bundle.main.url(forResource: "vinyl_scratch", withExtension: "wav") 
            ?? Bundle.main.url(forResource: "vinyl_scratch", withExtension: "m4a")
            ?? Bundle.main.url(forResource: "scratch", withExtension: "wav")
            ?? Bundle.main.url(forResource: "scratch", withExtension: "m4a") {
            scratchFileURL = bundledURL
            print("ScratchSoundManager: Using bundled scratch sound")
            return
        }
        
        // Generate scratch sound file
        generateScratchFile()
    }
    
    private func generateScratchFile() {
        let fileManager = FileManager.default
        guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            print("ScratchSoundManager: Failed to get cache directory")
            return
        }
        
        let scratchURL = cacheDir.appendingPathComponent("scratch_sound_v2.wav")
        scratchFileURL = scratchURL
        
        // Skip if already exists
        if fileManager.fileExists(atPath: scratchURL.path) {
            print("ScratchSoundManager: Using cached scratch sound")
            return
        }
        
        // Generate WAV file
        print("ScratchSoundManager: Generating enhanced scratch sound...")
        
        let sampleRate: Double = 44100
        let duration: Double = 2.0
        let frameCount = Int(sampleRate * duration)
        
        // Create audio buffer data
        var audioData = [Int16](repeating: 0, count: frameCount)
        
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            
            // 1. Deep sub-bass rumble (turntable motor)
            let rumble1 = sin(2.0 * .pi * t * 33.33) * 0.25 // 33 RPM turntable
            let rumble2 = sin(2.0 * .pi * t * 45.0) * 0.15  // 45 RPM
            let rumble3 = sin(2.0 * .pi * t * 80.0) * 0.1   // Harmonic
            
            // 2. Vinyl groove texture (characteristic "shhh" sound)
            let grooveFreq = 150.0 + sin(2.0 * .pi * t * 0.7) * 50.0
            let groove = sin(2.0 * .pi * t * grooveFreq) * 0.15
            
            // 3. High-frequency needle hiss
            let hiss = Double.random(in: -1.0...1.0) * 0.12
            
            // 4. Occasional vinyl pops and crackles
            let popChance = sin(2.0 * .pi * t * 3.7) > 0.97 ? 1.0 : 0.0
            let pop = popChance * Double.random(in: -1.0...1.0) * 0.4
            
            // 5. Scratch "whoosh" texture (mid-frequency sweep)
            let whooshFreq = 300.0 + sin(2.0 * .pi * t * 1.5) * 200.0
            let whoosh = sin(2.0 * .pi * t * whooshFreq) * 0.2
            
            // 6. Vinyl surface modulation
            let surfaceMod = (sin(2.0 * .pi * t * 0.5) * 0.3 + 0.7)
            
            // Apply fade envelope
            let fadeIn = min(1.0, t / 0.02)
            let fadeOut = min(1.0, (duration - t) / 0.02)
            let envelope = fadeIn * fadeOut
            
            // Mix all layers
            let mix = (rumble1 + rumble2 + rumble3 + groove + hiss + pop + whoosh) * surfaceMod * envelope
            
            // Apply soft saturation for warmth
            let saturated = tanh(mix * 1.5) * 0.8
            
            // Convert to 16-bit PCM
            audioData[i] = Int16(max(-32768, min(32767, saturated * 32767.0)))
        }
        
        // Write WAV file
        writeWAVFile(samples: audioData, sampleRate: Int(sampleRate), to: scratchURL)
        print("ScratchSoundManager: Generated enhanced scratch sound")
    }
    
    private func writeWAVFile(samples: [Int16], sampleRate: Int, to url: URL) {
        var header = Data()
        let dataSize = samples.count * 2
        let fileSize = 36 + dataSize
        
        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        
        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // chunk size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM format
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // 1 channel
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) }) // sample rate
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) }) // byte rate
        header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })  // block align
        header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits per sample
        
        // data chunk
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })
        
        // Sample data
        var sampleData = Data()
        for sample in samples {
            sampleData.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }
        
        let wavData = header + sampleData
        try? wavData.write(to: url)
    }
    
    // MARK: - Public API
    
    func beginScratchSession() {
        print("ScratchSoundManager: beginScratchSession requested. Enabled: \(JogEffectSettings.shared.isEnabled)")
        guard JogEffectSettings.shared.isEnabled else { return }
        
        guard let url = scratchFileURL else {
            print("ScratchSoundManager: No scratch file available")
            return
        }
        
        // Configure audio session for mixing
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("ScratchSoundManager: Audio session error: \(error)")
        }
        
        // Create and configure player
        do {
            scratchPlayer = try AVAudioPlayer(contentsOf: url)
            scratchPlayer?.delegate = self
            scratchPlayer?.enableRate = true
            scratchPlayer?.numberOfLoops = -1 // Loop infinitely
            scratchPlayer?.volume = 0.8
            scratchPlayer?.rate = 1.0
            scratchPlayer?.prepareToPlay()
            scratchPlayer?.play()
            isSessionActive = true
            print("ScratchSoundManager: Session started. Playing: \(scratchPlayer?.isPlaying ?? false)")
        } catch {
            print("ScratchSoundManager: Failed to create player: \(error)")
        }
    }
    
    func updateScratch(normalizedScrubSpeed: Double, directionForward: Bool) {
        guard JogEffectSettings.shared.isEnabled, isSessionActive, let player = scratchPlayer else { return }
        
        // Calculate rate based on scrub speed
        // Speed 0.5 -> rate 1.0, Speed 2.0 -> rate 2.5
        let speed = abs(normalizedScrubSpeed)
        let rate = Float(max(0.5, min(2.5, 0.5 + speed)))
        
        // Calculate volume based on speed
        let volume = Float(max(0.3, min(1.0, 0.3 + speed * 0.5)))
        
        player.rate = rate
        player.volume = volume
        
        currentRate = rate
        currentVolume = volume
    }
    
    func endScratchSession() {
        guard isSessionActive else { return }
        
        // Quick fade out
        scratchPlayer?.setVolume(0, fadeDuration: 0.05)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.scratchPlayer?.stop()
            self?.scratchPlayer = nil
            self?.isSessionActive = false
            print("ScratchSoundManager: Session ended")
        }
    }
    
    func stopScratch() {
        endScratchSession()
    }
    
    // MARK: - AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Loop is infinite, this shouldn't be called during session
    }
}
