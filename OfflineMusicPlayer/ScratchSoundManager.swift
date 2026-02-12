import Foundation
import AVFoundation
import Combine

/// Manages DJ jog wheel / vinyl scratch sound effects with real-time synthesis.
/// Uses AVAudioEngine with AVAudioSourceNode for dynamic, velocity-responsive scratch sounds.
final class ScratchSoundManager: NSObject, ObservableObject {
    static let shared = ScratchSoundManager()
    
    // MARK: - Audio Engine
    private var audioEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var mixerNode: AVAudioMixerNode?
    
    // MARK: - State
    private var isSessionActive = false
    private var currentVelocity: Double = 0.0
    private var currentDirection: Bool = true // true = forward
    private var targetVolume: Float = 0.0
    private var currentVolume: Float = 0.0
    
    // Audio Buffer for realistic scratching
    private var scratchBuffer: AVAudioPCMBuffer?
    private var bufferFrameCount: AVAudioFramePosition = 0
    private var bufferPointer: UnsafeMutablePointer<Float>?
    private var bufferPosition: Double = 0.0
    
    // MARK: - Sound Generation Parameters
    private var phase: Double = 0.0
    private var noisePhase: Double = 0.0
    private var crackleTimer: Double = 0.0
    private var lastDirection: Bool = true
    private var directionChangeIntensity: Float = 0.0
    
    // Random state for natural variation
    private var randomSeed: UInt64 = 0
    
    // MARK: - Audio Format
    private let sampleRate: Double = 44100.0
    
    private override init() {
        super.init()
        randomSeed = UInt64.random(in: 0..<UInt64.max)
    }
    
    // MARK: - Public API
    
    func beginScratchSession(with buffer: AVAudioPCMBuffer? = nil) {
        print("ScratchSoundManager: beginScratchSession requested. Enabled: \(JogEffectSettings.shared.isEnabled)")
        guard JogEffectSettings.shared.isEnabled else { return }
        
        // If we get a buffer, use it for realistic scratching
        if let buffer = buffer {
            self.scratchBuffer = buffer
            self.bufferFrameCount = AVAudioFramePosition(buffer.frameLength)
            // We use the first channel for simplicity in synthesis
            self.bufferPointer = buffer.floatChannelData?[0]
            self.bufferPosition = Double(buffer.frameLength) / 2.0 // Start in middle of buffer
        }
        
        guard !isSessionActive else { return }
        
        setupAudioEngine()
        isSessionActive = true
        print("ScratchSoundManager: Session started with \(buffer != nil ? "realistic buffer" : "real-time synthesis")")
    }
    
    func updateScratch(normalizedScrubSpeed: Double, directionForward: Bool) {
        guard JogEffectSettings.shared.isEnabled, isSessionActive else { return }
        
        // Detect direction change for "chirp" effect
        if directionForward != lastDirection {
            directionChangeIntensity = min(Float(1.0), Float(abs(normalizedScrubSpeed) * 3.0))
            lastDirection = directionForward
        }
        
        currentVelocity = normalizedScrubSpeed
        currentDirection = directionForward
        
        // Calculate target volume based on velocity
        // Faster movement = louder scratch
        let speed = abs(normalizedScrubSpeed)
        targetVolume = Float(min(1.0, 0.2 + speed * 2.0))
    }
    
    func endScratchSession() {
        guard isSessionActive else { return }
        
        // Fade out smoothly
        targetVolume = 0.0
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.teardownAudioEngine()
            self?.isSessionActive = false
            self?.resetState()
            print("ScratchSoundManager: Session ended")
        }
    }
    
    func stopScratch() {
        endScratchSession()
    }
    
    // MARK: - Audio Engine Setup
    
    private func setupAudioEngine() {
        // Configure audio session
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("ScratchSoundManager: Audio session error: \(error)")
            return
        }
        
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        
        // Create source node for real-time audio generation
        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            return self.generateAudioSamples(frameCount: frameCount, audioBufferList: audioBufferList)
        }
        
        guard let sourceNode = sourceNode else { return }
        
        mixerNode = AVAudioMixerNode()
        guard let mixerNode = mixerNode else { return }
        
        engine.attach(sourceNode)
        engine.attach(mixerNode)
        
        engine.connect(sourceNode, to: mixerNode, format: format)
        engine.connect(mixerNode, to: engine.mainMixerNode, format: format)
        
        mixerNode.outputVolume = 0.8
        
        do {
            try engine.start()
        } catch {
            print("ScratchSoundManager: Failed to start engine: \(error)")
        }
    }
    
    private func teardownAudioEngine() {
        audioEngine?.stop()
        
        if let sourceNode = sourceNode {
            audioEngine?.detach(sourceNode)
        }
        if let mixerNode = mixerNode {
            audioEngine?.detach(mixerNode)
        }
        
        sourceNode = nil
        mixerNode = nil
        audioEngine = nil
    }
    
    private func resetState() {
        currentVelocity = 0.0
        currentVolume = 0.0
        targetVolume = 0.0
        phase = 0.0
        noisePhase = 0.0
        directionChangeIntensity = 0.0
        scratchBuffer = nil
        bufferPointer = nil
        bufferFrameCount = 0
        bufferPosition = 0.0
    }
    
    // MARK: - Real-time Audio Generation
    
    private func generateAudioSamples(frameCount: UInt32, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        
        // Smooth volume transition
        let volumeStep: Float = 0.02
        if currentVolume < targetVolume {
            currentVolume = min(targetVolume, currentVolume + volumeStep)
        } else if currentVolume > targetVolume {
            currentVolume = max(targetVolume, currentVolume - volumeStep)
        }
        
        // Decay direction change intensity
        directionChangeIntensity *= 0.95
        
        let velocity = currentVelocity
        let speed = abs(velocity)
        
        for frame in 0..<Int(frameCount) {
            let sample = generateScratchSample(speed: speed, velocity: velocity)
            
            // Apply volume envelope
            let finalSample = sample * currentVolume
            
            // Write to both channels (stereo)
            for buffer in ablPointer {
                let buf = buffer.mData?.assumingMemoryBound(to: Float.self)
                buf?[frame] = finalSample
            }
        }
        
        return noErr
    }
    
    private func generateScratchSample(speed: Double, velocity: Double) -> Float {
        let dt = 1.0 / sampleRate
        
        // 1. Realistic Buffer Playback (The "Real" Sound)
        var realisticSample: Float = 0.0
        if let ptr = bufferPointer, bufferFrameCount > 0 {
            // Speed factor for buffer playback
            // Normalizing velocity: 1.0 velocity = normal speed playback
            let playbackSpeed = velocity * 1.5 // Multiplier for more aggressive scratch feel
            
            // Update buffer position with interpolation
            let posIntegral = floor(bufferPosition)
            let posFraction = Float(bufferPosition - posIntegral)
            
            let idx1 = Int(posIntegral) % Int(bufferFrameCount)
            let idx2 = (idx1 + 1) % Int(bufferFrameCount)
            
            // Linear interpolation
            let s1 = ptr[idx1]
            let s2 = ptr[idx2]
            realisticSample = s1 + posFraction * (s2 - s1)
            
            // Advance position
            bufferPosition += playbackSpeed
            
            // Keep position within bounds (loop slightly if needed, though usually session is short)
            if bufferPosition < 0 {
                bufferPosition += Double(bufferFrameCount)
            } else if bufferPosition >= Double(bufferFrameCount) {
                bufferPosition -= Double(bufferFrameCount)
            }
        }
        
        // 2. Base frequency modulated by speed (heavier vinyl feel)
        let baseFreq = 60.0 + speed * 350.0
        let freqModulation = sin(phase * 0.5) * 15.0
        let frequency = baseFreq + freqModulation
        
        phase += dt * (realisticSample == 0 ? frequency : speed * 100.0) * 2.0 * .pi
        if phase > 2.0 * .pi * 1000 { phase -= 2.0 * .pi * 1000 }
        
        // 3. Main vinyl "whoosh" sound - filtered noise
        let whoosh = generateWhoosh(frequency: frequency, speed: speed)
        
        // 4. Vinyl surface texture (crackle and hiss)
        let texture = generateVinylTexture(speed: speed)
        
        // 5. Motor rumble (low frequency)
        let rumble = generateMotorRumble()
        
        // 6. Direction change "chirp" (transient pop)
        let chirp = generateDirectionChirp()
        
        // Mix all components
        let speedFactor = Float(min(1.0, speed * 2.5))
        
        var mix: Float = 0.0
        
        if realisticSample != 0 {
            // Use realistic sample as the primary source
            mix += realisticSample * 0.85
            mix += whoosh * 0.15 * speedFactor // Subtle whoosh
        } else {
            // Fallback to pure synthesis
            mix += whoosh * 0.40 * speedFactor
        }
        
        mix += texture * 0.15
        mix += rumble * 0.20 * (1.0 - speedFactor * 0.4)
        mix += chirp * 0.60
        
        // Soft saturation for warmth
        mix = tanh(mix * 1.6) * 0.9
        
        return mix
    }
    
    private func generateWhoosh(frequency: Double, speed: Double) -> Float {
        noisePhase += 1.0 / sampleRate
        
        // Two noise sources
        let noise1 = pseudoRandom(seed: &randomSeed)
        let noise2 = pseudoRandom(seed: &randomSeed)
        
        // Filter
        let filterFreq = frequency * (1.2 + speed * 1.5)
        let alpha = Float(min(1.0, filterFreq / (sampleRate * 0.5)))
        
        let rawNoise = (noise1 + noise2) * 0.5
        
        // Amplitude Modulation (Chaotic) for "swish" effect
        // Modulate volume based on phase to simulate vinyl warping/irregularity
        let am = 0.7 + 0.3 * sin(phase * 0.1 + noisePhase * 50.0)
        
        // Resonant filter
        let resonance = sin(phase * 0.8) * 0.2
        let filtered = rawNoise * alpha + Float(resonance) * (1.0 - alpha)
        
        return filtered * Float(am)
    }
    
    private func generateVinylTexture(speed: Double) -> Float {
        crackleTimer += 1.0 / sampleRate
        
        var texture: Float = 0.0
        
        // Continuous hiss - slightly brighter
        let hiss = pseudoRandom(seed: &randomSeed) * 0.25
        texture += hiss
        
        // Occasional pops
        let popRate = 0.05 + speed * 0.2 // More pops at speed
        if crackleTimer > popRate {
            crackleTimer = 0.0
            if pseudoRandom(seed: &randomSeed) > 0.6 {
                texture += pseudoRandom(seed: &randomSeed) * 0.9
            }
        }
        
        return texture
    }
    
    private func generateMotorRumble() -> Float {
        // Lower harmonics for "sub" feel
        let rumble1 = Float(sin(phase * 0.015)) * 0.6
        let rumble2 = Float(sin(phase * 0.03)) * 0.3
        return rumble1 + rumble2
    }
    
    private func generateDirectionChirp() -> Float {
        guard directionChangeIntensity > 0.01 else { return 0.0 }
        
        // Higher pitch chirp for "scratch" bite
        let chirpFreq = 1000.0 + Double(directionChangeIntensity) * 2000.0
        let chirpSample = Float(sin(phase * chirpFreq / 80.0)) * directionChangeIntensity
        
        // Add bit of noise
        let chirpNoise = pseudoRandom(seed: &randomSeed) * directionChangeIntensity * 0.4
        
        return chirpSample + chirpNoise
    }
    
    private func generateNeedleFriction(speed: Double) -> Float {
        // High frequency scraping sound
        let frictionFreq = 1200.0 + speed * 1500.0
        
        let friction1 = Float(sin(phase * frictionFreq / 40.0)) * 0.3
        
        // Granular noise for "sandpaper" texture
        let grainNoise = pseudoRandom(seed: &randomSeed) * 0.4
        
        // Bandpass approximation (multiply sine by noise)
        return (friction1 * grainNoise) * Float(min(1.0, speed * 2.0))
    }
    
    // MARK: - Pseudo-random Number Generator (for audio thread safety)
    
    private func pseudoRandom(seed: inout UInt64) -> Float {
        // xorshift64 - fast and thread-safe
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        
        // Convert to float in range [-1, 1]
        return Float(Int64(bitPattern: seed) % 32768) / 32768.0
    }
}
