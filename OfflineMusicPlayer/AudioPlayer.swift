import Foundation
import AVFoundation
import Combine
import MediaPlayer
import CryptoKit

final class AudioPlayer: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isPlaying: Bool = false
    @Published var currentURL: URL?
    @Published var currentTrackIndex: Int = -1
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var tracks: [URL] = [] {
        didSet { saveTracks() }
    }
    /// When set, the app should show "Keep this track?" for shared audio (e.g. from Telegram).
    @Published var pendingSharedTrackURL: URL?
    /// When non-empty, only tracks with at least one of these labels are played (next/prev/crossfade).
    @Published var labelFilterIds: Set<String> = [] {
        didSet { saveLabelFilter(); applyLabelFilterToPlayback() }
    }

    // MARK: - Private Properties
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var currentSecurityURL: URL?
    private var isAccessingSecurityResource: Bool = false
    private var bookmarks: [String: Data] = [:]
    private let bookmarksKey = "audioFileBookmarks"
    private var fileHashes: [String: String] = [:]
    private let fileHashesKey = "audioFileHashes"

    // Crossfade
    private var crossfadeNextPlayer: AVAudioPlayer?
    private var isCrossfading: Bool = false
    private var crossfadeTimer: Timer?
    private var crossfadeStartTime: Date?
    private var crossfadeOutURL: URL?   // Track we're fading out (for analytics)
    private var crossfadeOutDuration: TimeInterval = 0
    private var crossfadeInURL: URL?    // Next track we're fading in
    private var crossfadePreloadedPlayer: AVAudioPlayer?
    private var crossfadePreloadedURL: URL?
    /// 120 Hz volume ramp for ultra-smooth, Apple-style crossfade
    private static let crossfadeTickInterval: TimeInterval = 1.0 / 120.0
    /// Start next track this many seconds before fade begins so it's fully buffered (seamless)
    private static let crossfadeLeadTime: TimeInterval = 0.08
    /// Index in the current play queue (getPlayQueue); -1 when current track is not in queue.
    var currentPlayQueueIndex: Int = -1
    private let labelFilterKey = "playbackLabelFilterIds"

    // Scrubbing state
    private var isUserScrubbing: Bool = false
    private var wasPlayingBeforeScrub: Bool = false
    private var lastScrubTime: Date?
    private var lastScrubPosition: TimeInterval?

    // MARK: - Initialization
    override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupNotifications()
        loadBookmarks()
        loadFileHashes()
        loadLabelFilter()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadTracks()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let url = currentSecurityURL, isAccessingSecurityResource {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Audio Session Setup (FIXED)
    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            // FIXED: Use minimal, compatible options
            // Removed .duckOthers which causes -50 error on some iOS versions
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: []  // Empty options - most compatible
            )
            
            try audioSession.setActive(true)
            
            print("AudioPlayer: ✅ Audio session configured successfully")
        } catch {
            print("AudioPlayer: ⚠️ Audio session setup failed - \(error.localizedDescription)")
            
            // Secondary fallback: Try with minimum configuration
            do {
                try audioSession.setCategory(.playback)
                try audioSession.setActive(true)
                print("AudioPlayer: ✅ Fallback audio session activated")
            } catch {
                print("AudioPlayer: ❌ All audio session configurations failed")
            }
        }
    }

    // MARK: - Remote Command Center (Lock Screen Controls)
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if let player = self.audioPlayer, !player.isPlaying {
                player.play()
                self.isPlaying = true
                self.startTimer()
                self.updateNowPlayingInfo()
                return .success
            }
            return .commandFailed
        }

        // Pause command
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        // Toggle play/pause command
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // Next track command
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextTrack()
            return .success
        }

        // Previous track command
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousTrack()
            return .success
        }

        // Seek commands
        commandCenter.changePlaybackPositionCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.seek(to: event.positionTime)
            return .success
        }

        // Skip forward/backward commands (15 seconds)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let command = event.command as? MPSkipIntervalCommand,
                  let player = self.audioPlayer else {
                return .commandFailed
            }
            let newTime = min(player.currentTime + Double(truncating: command.preferredIntervals[0]), player.duration)
            self.seek(to: newTime)
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let command = event.command as? MPSkipIntervalCommand,
                  let player = self.audioPlayer else {
                return .commandFailed
            }
            let newTime = max(player.currentTime - Double(truncating: command.preferredIntervals[0]), 0)
            self.seek(to: newTime)
            return .success
        }

        print("AudioPlayer: Remote commands configured")
    }

    // MARK: - Notifications
    private func setupNotifications() {
        // Audio interruptions (calls, alarms, etc.)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        // Route changes (headphones plugged/unplugged)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            pause()
            print("AudioPlayer: Audio interrupted")

        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            if options.contains(.shouldResume) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, let player = self.audioPlayer else { return }
                    player.play()
                    self.isPlaying = true
                    self.startTimer()
                    self.updateNowPlayingInfo()
                    print("AudioPlayer: Resuming after interruption")
                }
            }

        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .oldDeviceUnavailable:
            pause()
            print("AudioPlayer: Audio device disconnected - pausing")

        case .newDeviceAvailable:
            print("AudioPlayer: New audio device connected")

        default:
            break
        }
    }

    // MARK: - Now Playing Info (FIXED for MSVEntitlementUtilities warning)
    private func updateNowPlayingInfo() {
        guard let url = currentURL else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var nowPlayingInfo = [String: Any]()
        let fileName = url.lastPathComponent
        let trackTitle = MusicMetadataManager.shared.getMetadata(for: fileName).displayName
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = trackTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Offline Music Player"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Local Library"

        if let player = audioPlayer {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.duration
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? 1.0 : 0.0
        }

        // FIXED: Generate proper artwork to eliminate MSVEntitlementUtilities warning
        nowPlayingInfo[MPMediaItemPropertyArtwork] = createProperArtwork()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        print("AudioPlayer: Updated Now Playing info for '\(trackTitle)'")
    }

    // MARK: - Proper Artwork Generation (FIXED)
    private func createProperArtwork() -> MPMediaItemArtwork {
        // Create artwork with standard size and proper rendering
        let artworkSize = CGSize(width: 512, height: 512)
        
        return MPMediaItemArtwork(boundsSize: artworkSize) { size in
            // Use UIGraphicsImageRenderer for proper iOS rendering context
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = true
            
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            
            return renderer.image { context in
                _ = CGRect(origin: .zero, size: size)
                
                // Background gradient
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                let colors = [
                    UIColor.systemIndigo.cgColor,
                    UIColor.systemPurple.cgColor
                ] as CFArray
                
                if let gradient = CGGradient(
                    colorsSpace: colorSpace,
                    colors: colors,
                    locations: [0.0, 1.0]
                ) {
                    context.cgContext.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: 0, y: 0),
                        end: CGPoint(x: size.width, y: size.height),
                        options: []
                    )
                }
                
                // Music icon
                let iconSize = size.width * 0.4
                let symbolConfig = UIImage.SymbolConfiguration(
                    pointSize: iconSize,
                    weight: .thin
                )
                
                if let musicIcon = UIImage(systemName: "music.note", withConfiguration: symbolConfig) {
                    let iconRect = CGRect(
                        x: (size.width - iconSize) / 2,
                        y: (size.height - iconSize) / 2,
                        width: iconSize,
                        height: iconSize
                    )
                    
                    // Draw with white color
                    UIColor.white.withAlphaComponent(0.85).setFill()
                    musicIcon.draw(in: iconRect, blendMode: .normal, alpha: 0.85)
                }
            }
        }
    }

    // MARK: - Playback Controls
    func togglePlayPause() {
        guard let player = audioPlayer else { return }

        if player.isPlaying {
            pause()
        } else {
            player.play()
            isPlaying = true
            startTimer()
            updateNowPlayingInfo()
        }
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
        updateNowPlayingInfo()
    }

    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        
        if isUserScrubbing && JogEffectSettings.shared.isEnabled {
            handleScrubbing(to: time)
        } else {
            // Standard seek behavior
            player.rate = 1.0
            player.currentTime = max(0, min(time, player.duration))
            progress = player.currentTime
            updateNowPlayingInfo()
        }
    }
    
    private func handleScrubbing(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        
        // 1. Update visual progress immediately
        let clampedTime = max(0, min(time, player.duration))
        player.currentTime = clampedTime
        progress = clampedTime
        
        // 2. Calculate velocity
        let now = Date()
        let lastTime = lastScrubTime ?? now
        let deltaTime = now.timeIntervalSince(lastTime)
        
        let lastPos = lastScrubPosition ?? progress
        let deltaPos = clampedTime - lastPos
        
        // Update state for next calculation
        lastScrubTime = now
        lastScrubPosition = clampedTime
        
        // Avoid division by zero
        guard deltaTime > 0 else { return }
        
        // 3. Normalized speed calculation
        // Speed = (fraction of track moved) / time
        // e.g. moving 10% of track in 1 second = 0.1 speed
        // We use absolute seconds for the math model in ScratchSoundManager,
        // but the prompt implies normalized to track width/duration.
        // Let's use: Speed = (pixels moved) / width ... wait, we don't have pixels here.
        // We have time. Let's map time-velocity to the "scrubSpeed" expected by the manager.
        // If we move 1 second of audio in 0.1 seconds of real time, that's 10x playback speed.
        // ScratchSoundManager expects a normalized value where ~0.5 is fast.
        // Let's deduce a reasonable mapping.
        // If track is 3 min (180s). moving 10s of audio (5% of track) in 0.1s -> very fast.
        
        // Let's try: normalizedSpeed = abs(deltaPos) / (Duration * deltaTime) * ScalingFactor
        // actually, let's just use raw playback rate equivalent:
        // rate = deltaPos / deltaTime
        // normalizedSpeed input for map = rate / someBaseRate
        
        // Prompt says: scrubSpeed = Math.abs(currentX - prevX) / progressBarWidth;
        // In our case: currentX/Width = currentTime/Duration.
        // So scrubSpeed (per event) = abs(deltaPos / Duration).
        // BUT, `updateScratch` expects a speed that relates to generated pitch.
        // The prompt *code* example in requirements uses `scrubSpeed` directly for pitch.
        // "scrubSpeed = Math.abs(currentX - prevX) / progressBarWidth"
        // This is "fraction of track traversed per event".
        // Since `seek` is called continuously by the slider, this is exactly what we need.
        
        guard player.duration > 0, deltaTime > 0 else { return }
        
        // Calculate velocity: fraction of track per second
        let fractionTraversed = abs(deltaPos) / player.duration
        let velocity = fractionTraversed / deltaTime
        
        print("AudioPlayer: Scrub velocity: \(velocity) (deltaPos: \(deltaPos), deltaTime: \(deltaTime))")
        
        // Pass velocity directly to manager
        let directionForward = deltaPos >= 0
        
        ScratchSoundManager.shared.updateScratch(normalizedScrubSpeed: velocity, directionForward: directionForward)
    }

    /// Call when user starts touching the progress bar (so we don’t overwrite progress from the timer).
    func beginScrubbing() {
        isUserScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        lastScrubTime = Date()
        lastScrubPosition = progress
        
        if JogEffectSettings.shared.isEnabled {
            print("AudioPlayer: beginScrubbing (Jog enabled)")
            pause() // Pause main audio
            ScratchSoundManager.shared.beginScratchSession()
        } else {
            print("AudioPlayer: beginScrubbing (Jog DISABLED)")
        }
    }

    /// Call when user releases the progress bar. Seeks main audio and resumes if was playing.
    func endScrubbing(finalPosition: TimeInterval?) {
        isUserScrubbing = false
        lastScrubTime = nil
        lastScrubPosition = nil
        
        // Stop scratch sound
        if JogEffectSettings.shared.isEnabled {
            ScratchSoundManager.shared.endScratchSession()
        }
        
        guard let player = audioPlayer else { return }
        player.rate = 1.0
        if let pos = finalPosition {
            let clamped = max(0, min(pos, player.duration))
            player.currentTime = clamped
            progress = clamped
        } else {
            progress = player.currentTime
        }
        if wasPlayingBeforeScrub {
            player.play()
            isPlaying = true
            startTimer()
        }
        updateNowPlayingInfo()
    }

    func nextTrack() {
        cancelCrossfade()
        let queue = getPlayQueue()
        guard !queue.isEmpty else { return }
        if currentPlayQueueIndex < 0 { currentPlayQueueIndex = 0 }
        else { currentPlayQueueIndex = (currentPlayQueueIndex + 1) % queue.count }
        let url = queue[currentPlayQueueIndex]
        currentTrackIndex = tracks.firstIndex(of: url) ?? -1
        play(url: url)
    }

    func previousTrack() {
        cancelCrossfade()
        let queue = getPlayQueue()
        guard !queue.isEmpty else { return }
        if currentPlayQueueIndex < 0 { currentPlayQueueIndex = queue.count - 1 }
        else { currentPlayQueueIndex = currentPlayQueueIndex > 0 ? currentPlayQueueIndex - 1 : queue.count - 1 }
        let url = queue[currentPlayQueueIndex]
        currentTrackIndex = tracks.firstIndex(of: url) ?? -1
        play(url: url)
    }

    // MARK: - Track Management
    func remove(atOffsets offsets: IndexSet) {
        let tracksToRemove = offsets.map { tracks[$0] }

        for url in tracksToRemove {
            removeTrack(url: url)
        }

        tracks.remove(atOffsets: offsets)

        if let currentURL = currentURL, !tracks.contains(currentURL) {
            stop()
        } else if let currentURL = currentURL, let newIndex = tracks.firstIndex(of: currentURL) {
            currentTrackIndex = newIndex
        }
    }

    private func stop() {
        cancelCrossfade()
        isUserScrubbing = false
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentURL = nil
        currentTrackIndex = -1
        progress = 0
        duration = 0
        stopTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        if let url = currentSecurityURL, isAccessingSecurityResource {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityResource = false
            currentSecurityURL = nil
        }
    }

    // MARK: - File Import (FIXED hash calculation position)
    func importTracks(urls: [URL]) {
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("AudioPlayer: Could not access documents directory")
            return
        }

        let importDir = documentsURL.appendingPathComponent("ImportedAudio")

        if !fileManager.fileExists(atPath: importDir.path) {
            do {
                try fileManager.createDirectory(at: importDir, withIntermediateDirectories: true)
            } catch {
                print("AudioPlayer: Failed to create import directory - \(error)")
                return
            }
        }

        var addedCount = 0
        var skippedCount = 0

        for url in urls {
            // Start accessing BEFORE calculating hash
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            // Calculate hash of incoming file
            guard let incomingHash = calculateFileHash(url) else {
                print("AudioPlayer: Could not calculate hash for \(url.lastPathComponent)")
                continue
            }

            // Check for duplicates
            if fileHashes.values.contains(incomingHash) {
                print("AudioPlayer: Skipping duplicate file \(url.lastPathComponent)")
                skippedCount += 1
                continue
            }

            // Generate unique filename
            let sanitizedFileName = url.lastPathComponent
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")

            var destURL = importDir.appendingPathComponent(sanitizedFileName)
            var counter = 1

            while fileManager.fileExists(atPath: destURL.path) {
                let nameWithoutExt = URL(fileURLWithPath: sanitizedFileName).deletingPathExtension().lastPathComponent
                let ext = URL(fileURLWithPath: sanitizedFileName).pathExtension
                let uniqueName = "\(nameWithoutExt)_\(counter).\(ext)"
                destURL = importDir.appendingPathComponent(uniqueName)
                counter += 1
            }

            do {
                guard fileManager.fileExists(atPath: url.path) else {
                    print("AudioPlayer: Source file not accessible at \(url.path)")
                    continue
                }

                try fileManager.copyItem(at: url, to: destURL)

                // Store hash for the destination file
                fileHashes[destURL.lastPathComponent] = incomingHash

                DispatchQueue.main.async {
                    self.tracks.append(destURL)
                }

                addedCount += 1
                print("AudioPlayer: Added track \(destURL.lastPathComponent)")
            } catch {
                print("AudioPlayer: Failed to copy \(url.lastPathComponent) - \(error.localizedDescription)")
            }
        }

        if addedCount > 0 {
            saveFileHashes()
        }

        print("AudioPlayer: Import complete - Added: \(addedCount), Skipped: \(skippedCount)")
    }

    /// Called when user chooses "Keep" for a shared track (e.g. from Telegram). Imports and optionally plays.
    func confirmKeepSharedTrack() {
        guard let url = pendingSharedTrackURL else { return }
        importTracks(urls: [url])
        pendingSharedTrackURL = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self, let lastTrack = self.tracks.last else { return }
            self.play(url: lastTrack)
        }
    }

    /// Called when user chooses "Don't keep" or dismisses the shared-track prompt.
    func clearPendingSharedTrack() {
        pendingSharedTrackURL = nil
    }

    /// Resolves the file URL for a track (used for sharing)
    func resolvedURL(for url: URL) -> URL? {
        resolveURL(fileName: url.lastPathComponent)
    }

    func play(url: URL) {
        cancelCrossfade()
        let fileName = url.lastPathComponent

        if let previousURL = currentSecurityURL, isAccessingSecurityResource {
            previousURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityResource = false
        }

        guard let resolvedURL = resolveURL(fileName: fileName) else {
            print("AudioPlayer: Could not resolve URL for \(fileName)")
            removeTrack(url: url)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            guard fileManager.fileExists(atPath: resolvedURL.path) else {
                print("AudioPlayer: File not found at path \(resolvedURL.path)")
                DispatchQueue.main.async { self.removeTrack(url: url) }
                return
            }

            do {
                let fileData = try Data(contentsOf: resolvedURL)
                let fileTypeHint = self.getFileTypeHint(for: resolvedURL)

                DispatchQueue.main.async {
                    do {
                        self.isUserScrubbing = false
                        self.audioPlayer = try AVAudioPlayer(data: fileData, fileTypeHint: fileTypeHint)
                        self.audioPlayer?.delegate = self
                        self.audioPlayer?.enableRate = true
                        self.audioPlayer?.prepareToPlay()
                        self.audioPlayer?.play()

                        self.currentURL = url
                        let queue = self.getPlayQueue()
                        self.currentPlayQueueIndex = queue.firstIndex(of: url) ?? -1
                        self.currentTrackIndex = self.tracks.firstIndex(of: url) ?? -1
                        self.isPlaying = true
                        self.duration = self.audioPlayer?.duration ?? 0

                        self.currentSecurityURL = resolvedURL
                        self.isAccessingSecurityResource = false

                        self.startTimer()
                        self.updateNowPlayingInfo()

                        print("AudioPlayer: Successfully playing \(fileName)")
                    } catch {
                        print("AudioPlayer: Failed to create audio player for \(fileName) - \(error.localizedDescription)")
                    }
                }
            } catch {
                print("AudioPlayer: Failed to read file data for \(fileName) - \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Helper Methods
    private func removeTrack(url: URL) {
        let fileName = url.lastPathComponent

        if let index = tracks.firstIndex(of: url) {
            tracks.remove(at: index)
        }

        bookmarks.removeValue(forKey: fileName)
        saveBookmarks()

        fileHashes.removeValue(forKey: fileName)
        saveFileHashes()

        let fileManager = FileManager.default
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let importDir = documentsURL.appendingPathComponent("ImportedAudio")
            let fileURL = importDir.appendingPathComponent(fileName)

            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                    print("AudioPlayer: Deleted file \(fileName)")
                } catch {
                    print("AudioPlayer: Failed to delete file \(fileName) - \(error)")
                }
            }
        }

        print("AudioPlayer: Removed track \(fileName)")
    }

    private func resolveURL(fileName: String) -> URL? {
        let fileManager = FileManager.default
        // 1. Check ImportedAudio in Documents
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = docs.appendingPathComponent("ImportedAudio").appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // 2. Check Bundle (for demo tracks)
        // Try exact match first, then with extensions if missing
        if let bundlePath = Bundle.main.path(forResource: fileName, ofType: nil) {
            return URL(fileURLWithPath: bundlePath)
        }
        // Try common extensions if filename has none
        let extensions = ["mp3", "m4a", "wav"]
        for ext in extensions {
             if let bundlePath = Bundle.main.path(forResource: fileName, ofType: ext) {
                 return URL(fileURLWithPath: bundlePath)
             }
        }
        
        print("AudioPlayer: No local copy found for \(fileName)")
        return nil
    }

    private func getFileTypeHint(for url: URL) -> String? {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "mp3":
            return AVFileType.mp3.rawValue
        case "m4a", "mp4":
            return AVFileType.m4a.rawValue
        case "wav":
            return AVFileType.wav.rawValue
        case "aac":
            return "com.apple.m4a-audio"
        case "flac":
            return "org.xiph.flac"
        case "ogg":
            return "org.xiph.ogg"
        case "ac3":
            return AVFileType.ac3.rawValue
        case "aiff":
            return AVFileType.aiff.rawValue
        default:
            return AVFileType.mp3.rawValue
        }
    }

    // MARK: - File Hash Calculation
    private func calculateFileHash(_ url: URL) -> String? {
        do {
            let fileData = try Data(contentsOf: url)
            let hash = SHA256.hash(data: fileData)
            return hash.compactMap { String(format: "%02x", $0) }.joined()
        } catch {
            print("AudioPlayer: Failed to calculate hash for \(url.lastPathComponent) - \(error)")
            return nil
        }
    }

    // MARK: - Timer Management
    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateProgress()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateProgress() {
        guard let player = audioPlayer else {
            progress = 0
            return
        }
        DispatchQueue.main.async {
            if !self.isUserScrubbing {
                self.progress = player.currentTime
            }
            self.duration = player.duration
            self.isPlaying = player.isPlaying
            self.checkCrossfadeStart()
        }
    }

    // MARK: - Crossfade
    private var crossfadeSettings: CrossfadeSettings { CrossfadeSettings.shared }

    /// Quintic smoothstep: smoother start/end than cubic (Apple Music–style seamless feel)
    private static func smoothstepQuintic(_ t: Float) -> Float {
        let x = max(0, min(1, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
    
    // MARK: - Crossfade Curves
    
    /// Linear fade
    private static func linearOut(_ t: Float) -> Float { 1.0 - t }
    private static func linearIn(_ t: Float) -> Float { t }
    
    /// Ease In/Out (Apple Music style)
    private static func easeInOutOut(_ t: Float) -> Float {
        let s = smoothstepQuintic(t)
        return 1.0 - s
    }
    private static func easeInOutIn(_ t: Float) -> Float {
        return smoothstepQuintic(t)
    }
    
    /// Constant Power (DJ-style equal loudness)
    private static func constantPowerOut(_ t: Float) -> Float {
        return cos(t * .pi / 2)
    }
    private static func constantPowerIn(_ t: Float) -> Float {
        return sin(t * .pi / 2)
    }
    
    /// Get fade values based on selected curve
    private func getFadeVolumes(t: Float) -> (outVol: Float, inVol: Float) {
        switch crossfadeSettings.curve {
        case .linear:
            return (Self.linearOut(t), Self.linearIn(t))
        case .easeInOut:
            return (Self.easeInOutOut(t), Self.easeInOutIn(t))
        case .constantPower:
            return (Self.constantPowerOut(t), Self.constantPowerIn(t))
        }
    }

    private func checkCrossfadeStart() {
        guard crossfadeSettings.isEnabled,
              !isCrossfading,
              let current = audioPlayer,
              getPlayQueue().count > 1,
              let currentURL = currentURL,
              currentPlayQueueIndex >= 0 else { return }
        let queue = getPlayQueue()
        let remaining = current.duration - current.currentTime
        let duration = crossfadeSettings.duration
        let nextIndex = (currentPlayQueueIndex + 1) % queue.count
        let nextURL = queue[nextIndex]

        // Preload well ahead (up to 8s or 3× fade) so next track is always ready – no hitch
        let preloadWhenRemaining = min(8.0, duration * 3.0)
        if remaining <= preloadWhenRemaining, remaining > duration + Self.crossfadeLeadTime, crossfadePreloadedURL != nextURL {
            preloadNextTrackForCrossfade(url: nextURL)
        }

        // Start crossfade with small lead time so next track is already playing when we ramp volume (seamless)
        let triggerWhenRemaining = duration + Self.crossfadeLeadTime
        guard remaining <= triggerWhenRemaining, remaining > 0 else { return }
        beginCrossfade(to: nextURL)
    }

    private func preloadNextTrackForCrossfade(url: URL) {
        let fileName = url.lastPathComponent
        guard resolveURL(fileName: fileName) != nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard let resolved = self.resolveURL(fileName: fileName),
                  let fileData = try? Data(contentsOf: resolved),
                  let nextPlayer = try? AVAudioPlayer(data: fileData, fileTypeHint: self.getFileTypeHint(for: resolved)) else {
                return
            }
            nextPlayer.enableRate = true
            nextPlayer.prepareToPlay()
            DispatchQueue.main.async {
                self.crossfadePreloadedPlayer?.stop()
                self.crossfadePreloadedPlayer = nil
                self.crossfadePreloadedPlayer = nextPlayer
                self.crossfadePreloadedURL = url
            }
        }
    }

    private func beginCrossfade(to nextURL: URL) {
        isCrossfading = true
        crossfadeOutURL = currentURL
        crossfadeOutDuration = audioPlayer?.duration ?? 0
        crossfadeInURL = nextURL

        let usePreloaded = crossfadePreloadedURL == nextURL, preloaded = crossfadePreloadedPlayer
        if usePreloaded, let nextPlayer = preloaded {
            crossfadePreloadedPlayer = nil
            crossfadePreloadedURL = nil
            nextPlayer.volume = 0
            nextPlayer.play()
            crossfadeNextPlayer = nextPlayer
            crossfadeStartTime = Date()
            crossfadeTimer?.invalidate()
            crossfadeTimer = Timer.scheduledTimer(withTimeInterval: Self.crossfadeTickInterval, repeats: true) { [weak self] _ in
                self?.updateCrossfadeVolumes()
            }
            RunLoop.main.add(crossfadeTimer!, forMode: .common)
            return
        }

        crossfadePreloadedPlayer = nil
        crossfadePreloadedURL = nil
        let fileName = nextURL.lastPathComponent
        guard let resolved = resolveURL(fileName: fileName) else {
            isCrossfading = false
            crossfadeOutURL = nil
            crossfadeInURL = nil
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: resolved.path),
                  let fileData = try? Data(contentsOf: resolved),
                  let nextPlayer = try? AVAudioPlayer(data: fileData, fileTypeHint: self.getFileTypeHint(for: resolved)) else {
                DispatchQueue.main.async {
                    self.isCrossfading = false
                    self.crossfadeOutURL = nil
                    self.crossfadeInURL = nil
                }
                return
            }
            DispatchQueue.main.async {
                nextPlayer.enableRate = true
                nextPlayer.volume = 0
                nextPlayer.prepareToPlay()
                nextPlayer.play()
                self.crossfadeNextPlayer = nextPlayer
                self.crossfadeStartTime = Date()
                self.crossfadeTimer?.invalidate()
                self.crossfadeTimer = Timer.scheduledTimer(withTimeInterval: Self.crossfadeTickInterval, repeats: true) { [weak self] _ in
                    self?.updateCrossfadeVolumes()
                }
                RunLoop.main.add(self.crossfadeTimer!, forMode: .common)
            }
        }
    }

    private func updateCrossfadeVolumes() {
        guard let start = crossfadeStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        let duration = crossfadeSettings.duration
        if elapsed >= duration {
            audioPlayer?.volume = 1.0
            crossfadeNextPlayer?.volume = 1.0
            finishCrossfade()
            return
        }
        let t = Float(elapsed / duration)
        let (outVol, inVol) = getFadeVolumes(t: t)
        audioPlayer?.volume = outVol
        crossfadeNextPlayer?.volume = inVol
    }

    private func finishCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        if let outURL = crossfadeOutURL {
            PlaybackAnalytics.shared.recordPlay(
                trackId: outURL.lastPathComponent,
                duration: crossfadeOutDuration
            )
        }
        audioPlayer?.stop()
        audioPlayer = nil
        audioPlayer = crossfadeNextPlayer
        crossfadeNextPlayer = nil
        audioPlayer?.delegate = self
        if let url = crossfadeInURL {
            currentURL = url
            let queue = getPlayQueue()
            currentPlayQueueIndex = queue.firstIndex(of: url) ?? 0
            currentTrackIndex = tracks.firstIndex(of: url) ?? -1
        }
        duration = audioPlayer?.duration ?? 0
        progress = 0
        isCrossfading = false
        crossfadeOutURL = nil
        crossfadeInURL = nil
        crossfadeStartTime = nil
        updateNowPlayingInfo()
    }

    private func cancelCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeNextPlayer?.stop()
        crossfadeNextPlayer = nil
        crossfadePreloadedPlayer?.stop()
        crossfadePreloadedPlayer = nil
        crossfadePreloadedURL = nil
        isCrossfading = false
        crossfadeOutURL = nil
        crossfadeInURL = nil
        crossfadeStartTime = nil
    }

    // MARK: - Play queue (label filter)
    /// Returns tracks to use for playback: all tracks, or only those with at least one selected label.
    func getPlayQueue() -> [URL] {
        guard !labelFilterIds.isEmpty else { return tracks }
        let meta = MusicMetadataManager.shared
        return tracks.filter { url in
            let fileMeta = meta.getMetadata(for: url.lastPathComponent)
            return fileMeta.labels.contains { labelFilterIds.contains($0) }
        }
    }

    private func saveLabelFilter() {
        let array = Array(labelFilterIds)
        UserDefaults.standard.set(array, forKey: labelFilterKey)
    }

    private func loadLabelFilter() {
        if let array = UserDefaults.standard.array(forKey: labelFilterKey) as? [String] {
            let set = Set(array)
            if set != labelFilterIds {
                labelFilterIds = set
            }
        }
    }

    private func applyLabelFilterToPlayback() {
        let queue = getPlayQueue()
        if let url = currentURL, queue.contains(url) {
            currentPlayQueueIndex = queue.firstIndex(of: url) ?? 0
            currentTrackIndex = tracks.firstIndex(of: url) ?? -1
        } else if !queue.isEmpty, isPlaying || audioPlayer != nil {
            currentPlayQueueIndex = 0
            play(url: queue[0])
        } else {
            currentPlayQueueIndex = -1
            if currentURL == nil { currentTrackIndex = -1 }
        }
    }

    // MARK: - Persistence
    private func saveTracks() {
        let fileNames = tracks.map { $0.lastPathComponent }
        UserDefaults.standard.set(fileNames, forKey: "savedTracks")
    }

    private func loadTracks() {
        guard let fileNames = UserDefaults.standard.array(forKey: "savedTracks") as? [String] else {
            print("AudioPlayer: Loaded 0 tracks")
            return
        }

        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let importDir = documentsURL.appendingPathComponent("ImportedAudio")
        var loadedTracks: [URL] = []

        for fileName in fileNames {
            let fileURL = importDir.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: fileURL.path) {
                loadedTracks.append(fileURL)
            } else {
                print("AudioPlayer: Track not found: \(fileName)")
            }
        }

        DispatchQueue.main.async {
            self.tracks = loadedTracks
            print("AudioPlayer: Loaded \(loadedTracks.count) tracks")
        }
    }

    private func saveBookmarks() {
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
    }

    private func loadBookmarks() {
        if let saved = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] {
            bookmarks = saved
        }
    }

    private func saveFileHashes() {
        UserDefaults.standard.set(fileHashes, forKey: fileHashesKey)
    }

    private func loadFileHashes() {
        if let saved = UserDefaults.standard.dictionary(forKey: fileHashesKey) as? [String: String] {
            fileHashes = saved
        }
    }
}

// MARK: - AVAudioPlayerDelegate
extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if isCrossfading { return }
        if flag {
            if let url = currentURL {
                PlaybackAnalytics.shared.recordPlay(
                    trackId: url.lastPathComponent,
                    duration: player.duration
                )
            }
            nextTrack()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("AudioPlayer: Decode error - \(error?.localizedDescription ?? "unknown")")
        isPlaying = false
        stopTimer()
    }
}
