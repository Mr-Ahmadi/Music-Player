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
    @Published var pendingSharedTrackURLs: [URL] = []
    /// When non-empty, only tracks with at least one of these labels are played (next/prev/crossfade).
    @Published var labelFilterIds: Set<String> = [] {
        didSet { saveLabelFilter(); applyLabelFilterToPlayback() }
    }
    /// Tracks the user explicitly queued up. These play before the normal queue
    /// continues and are consumed as they play.
    @Published private(set) var userQueue: [URL] = [] {
        didSet { saveUserQueue() }
    }
    /// True while the sleep timer is fading the music out.
    @Published private(set) var isFadingOut: Bool = false

    // MARK: - Audio Engine (for EQ effects)
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var eqNode: AVAudioUnitEQ?
    /// Applies playback speed without changing pitch.
    private var timePitchNode: AVAudioUnitTimePitch?
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    
    // MARK: - Legacy AVAudioPlayer (fallback)
    private var audioPlayer: AVAudioPlayer?
    
    // MARK: - Private Properties
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
    
    // Audio Settings observers
    private var settingsObserver: AnyCancellable?
    private var rateObserver: AnyCancellable?
    private var skipObserver: AnyCancellable?
    private var shuffleObserver: AnyCancellable?

    // Shuffle
    /// A shuffled permutation of the current play queue. Rebuilt when shuffle is
    /// switched on, when the queue contents change, or when a shuffled pass ends.
    private var shuffleOrder: [URL] = []
    private let userQueueKey = "userPlayQueue"

    // Sleep timer fade
    private var fadeOutTimer: Timer?
    
    // Track playback position for engine-based playback
    private var engineStartTime: AVAudioTime?
    private var pausedPosition: AVAudioFramePosition = 0
    private var playbackSegmentID = UUID()
    /// Identifies the latest requested play action so stale async work can't start old tracks.
    private var playRequestID = UUID()
    
    // Analytics
    private var playbackStartTime: Date?
    private var accruedListenDuration: TimeInterval = 0
    /// Position to jump to once the next track is loaded (resume support).
    private var pendingResumePosition: TimeInterval = 0
    private var hasRecordedCurrentSession: Bool = false  // Prevent double-recording

    // MARK: - Initialization
    override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupNotifications()
        loadBookmarks()
        loadFileHashes()
        loadLabelFilter()
        setupSettingsObserver()
        setupShuffleObserver()
        setupSleepTimer()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadTracks()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        settingsObserver?.cancel()
        rateObserver?.cancel()
        skipObserver?.cancel()
        shuffleObserver?.cancel()
        fadeOutTimer?.invalidate()
        // Save current listening session before deallocs
        saveCurrentListeningSession()
        if let url = currentSecurityURL, isAccessingSecurityResource {
            url.stopAccessingSecurityScopedResource()
        }
        teardownAudioEngine()
    }
    
    // MARK: - Settings Observer
    private func setupSettingsObserver() {
        // Apply equalizer edits to the live audio graph as the user drags a slider.
        let eq = EqualizerSettings.shared
        settingsObserver = Publishers.CombineLatest3(eq.$isEnabled, eq.$gains, eq.$preamp)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (enabled, gains, preamp) in
                self?.applyEqualizer(enabled: enabled, gains: gains, preamp: preamp)
            }

        rateObserver = PlaybackPreferences.shared.$playbackRate
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in
                self?.applyPlaybackRate(rate)
            }

        skipObserver = PlaybackPreferences.shared.$skipInterval
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] interval in
                self?.updateSkipIntervals(interval)
            }
    }

    // MARK: - Audio Session Setup
    private func setupAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setCategory(
                .playback,
                mode: .default,
                options: []
            )
            
            try audioSession.setActive(true)
            
            print("AudioPlayer: ✅ Audio session configured successfully")
        } catch {
            print("AudioPlayer: ⚠️ Audio session setup failed - \(error.localizedDescription)")
            
            do {
                try audioSession.setCategory(.playback)
                try audioSession.setActive(true)
                print("AudioPlayer: ✅ Fallback audio session activated")
            } catch {
                print("AudioPlayer: ❌ All audio session configurations failed")
            }
        }
    }
    
    // MARK: - Audio Engine Setup
    private func setupAudioEngine() {
        teardownAudioEngine()
        
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        // Full 10-band equalizer
        eqNode = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)
        timePitchNode = AVAudioUnitTimePitch()

        guard let engine = audioEngine,
              let player = playerNode,
              let eq = eqNode,
              let timePitch = timePitchNode else { return }

        configureEqualizerBands()
        timePitch.rate = PlaybackPreferences.shared.playbackRate
        // Keep the singer sounding like the singer at 1.5x.
        timePitch.pitch = 0

        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(eq)

        // Connect: PlayerNode -> TimePitch -> EQ -> MainMixer -> Output
        // Connections will be made when we have audio format
    }
    
    /// Lays out one parametric band per equalizer frequency. Gains are applied
    /// separately by `applyEqualizer` so presets can change without rebuilding nodes.
    private func configureEqualizerBands() {
        guard let eq = eqNode else { return }
        let frequencies = EqualizerSettings.frequencies

        for (index, band) in eq.bands.enumerated() {
            guard index < frequencies.count else {
                band.bypass = true
                continue
            }
            // Shelves at the extremes so the lowest and highest bands actually
            // move the energy you can hear, peaks everywhere in between.
            if index == 0 {
                band.filterType = .lowShelf
            } else if index == frequencies.count - 1 {
                band.filterType = .highShelf
            } else {
                band.filterType = .parametric
            }
            band.frequency = frequencies[index]
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }

        let settings = EqualizerSettings.shared
        applyEqualizer(enabled: settings.isEnabled, gains: settings.gains, preamp: settings.preamp)
    }

    private func applyEqualizer(enabled: Bool, gains: [Float], preamp: Float) {
        guard let eq = eqNode else { return }

        guard enabled else {
            eq.globalGain = 0
            for band in eq.bands { band.gain = 0 }
            return
        }

        eq.globalGain = min(max(preamp, -12), 12)
        for (index, band) in eq.bands.enumerated() {
            band.gain = index < gains.count ? min(max(gains[index], -12), 12) : 0
        }
    }

    private func applyPlaybackRate(_ rate: Float) {
        let clamped = min(max(rate, 0.5), 2.0)
        timePitchNode?.rate = clamped
        audioPlayer?.enableRate = true
        audioPlayer?.rate = clamped
        crossfadePreloadedPlayer?.rate = clamped
        crossfadeNextPlayer?.rate = clamped
        updateNowPlayingInfo()
    }

    private func teardownAudioEngine() {
        audioEngine?.stop()
        
        if let player = playerNode {
            player.stop()
            audioEngine?.detach(player)
        }
        if let eq = eqNode {
            audioEngine?.detach(eq)
        }
        if let timePitch = timePitchNode {
            audioEngine?.detach(timePitch)
        }

        playerNode = nil
        eqNode = nil
        timePitchNode = nil
        audioEngine = nil
        audioFile = nil
        audioFormat = nil
    }
    
    private func connectAndStartEngine(format: AVAudioFormat) {
        guard let engine = audioEngine,
              let player = playerNode,
              let eq = eqNode,
              let timePitch = timePitchNode else { return }

        // Player -> TimePitch (speed) -> EQ -> MainMixer
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()

            let settings = EqualizerSettings.shared
            applyEqualizer(enabled: settings.isEnabled, gains: settings.gains, preamp: settings.preamp)
            timePitch.rate = PlaybackPreferences.shared.playbackRate

            print("AudioPlayer: ✅ Audio engine started with 10-band EQ")
        } catch {
            print("AudioPlayer: ❌ Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Remote Command Center (Lock Screen Controls)
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Play command
        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.resumePlayback()
            return .success
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

        // Skip forward/backward commands (interval is user-configurable)
        let skip = NSNumber(value: PlaybackPreferences.shared.skipInterval)
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [skip]
        commandCenter.skipForwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let command = event.command as? MPSkipIntervalCommand else {
                return .commandFailed
            }
            let currentTime = self.getCurrentPlaybackTime()
            let newTime = min(currentTime + Double(truncating: command.preferredIntervals[0]), self.duration)
            self.seek(to: newTime)
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [skip]
        commandCenter.skipBackwardCommand.addTarget { [weak self] event in
            guard let self = self,
                  let command = event.command as? MPSkipIntervalCommand else {
                return .commandFailed
            }
            let currentTime = self.getCurrentPlaybackTime()
            let newTime = max(currentTime - Double(truncating: command.preferredIntervals[0]), 0)
            self.seek(to: newTime)
            return .success
        }

        // Rating / like button on the lock screen mirrors the in-app favourite.
        commandCenter.likeCommand.isEnabled = true
        commandCenter.likeCommand.localizedTitle = "Favorite"
        commandCenter.likeCommand.addTarget { [weak self] _ in
            guard let fileName = self?.currentURL?.lastPathComponent else { return .commandFailed }
            MusicMetadataManager.shared.toggleFavorite(fileName: fileName)
            return .success
        }

        print("AudioPlayer: Remote commands configured")
    }

    private func updateSkipIntervals(_ interval: Int) {
        let value = NSNumber(value: interval)
        MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [value]
        MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [value]
    }

    /// Jumps by the user's configured skip interval.
    func skipForward() {
        let interval = TimeInterval(PlaybackPreferences.shared.skipInterval)
        seek(to: min(getCurrentPlaybackTime() + interval, duration))
    }

    func skipBackward() {
        let interval = TimeInterval(PlaybackPreferences.shared.skipInterval)
        seek(to: max(getCurrentPlaybackTime() - interval, 0))
    }
    
    // MARK: - Get Current Playback Time
    private func getCurrentPlaybackTime() -> TimeInterval {
        // Try engine-based playback first
        if let engine = audioEngine, engine.isRunning,
           let player = playerNode,
           let nodeTime = player.lastRenderTime,
           let playerTime = player.playerTime(forNodeTime: nodeTime) {
            let sampleRate = playerTime.sampleRate
            let currentFrame = pausedPosition + playerTime.sampleTime
            return Double(currentFrame) / sampleRate
        }
        
        // Fallback if node time isn't ready (avoids 0.0 flash)
        if let file = audioFile {
            return Double(pausedPosition) / file.processingFormat.sampleRate
        }
        
        // Fall back to AVAudioPlayer
        return audioPlayer?.currentTime ?? 0
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
        
        // App lifecycle - save insights when app goes to background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
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
                    self?.resumePlayback()
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
    
    @objc private func handleAppWillResignActive() {
        print("AudioPlayer: App will resign active - saving listening session")
        saveCurrentListeningSession()
    }
    
    @objc private func handleAppDidEnterBackground() {
        print("AudioPlayer: App did enter background - saving listening session")
        saveCurrentListeningSession()
    }

    // MARK: - Now Playing Info
    private func updateNowPlayingInfo() {
        guard let url = currentURL else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var nowPlayingInfo = [String: Any]()
        let fileName = url.lastPathComponent
        let trackTitle = MusicMetadataManager.shared.getMetadata(for: fileName).displayName
        let tags = TrackTagStore.shared.cachedTags(for: fileName)

        nowPlayingInfo[MPMediaItemPropertyTitle] = trackTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = tags?.artist ?? "Unknown Artist"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = tags?.album ?? "Local Library"
        if let genre = tags?.genre { nowPlayingInfo[MPMediaItemPropertyGenre] = genre }

        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = getCurrentPlaybackTime()
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(PlaybackPreferences.shared.playbackRate) : 0.0

        let order = playbackOrder()
        if currentPlayQueueIndex >= 0 {
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentPlayQueueIndex
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueCount] = order.count
        }

        // Prefer the file's own cover art; fall back to the generated tile.
        if let cover = TrackTagStore.shared.artwork(for: fileName) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: cover.size) { _ in cover }
        } else {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = createProperArtwork()
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        print("AudioPlayer: Updated Now Playing info for '\(trackTitle)'")
    }

    // MARK: - Proper Artwork Generation
    private func createProperArtwork() -> MPMediaItemArtwork {
        let artworkSize = CGSize(width: 512, height: 512)
        
        return MPMediaItemArtwork(boundsSize: artworkSize) { size in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = true
            
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            
            return renderer.image { context in
                _ = CGRect(origin: .zero, size: size)
                
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
                    
                    UIColor.white.withAlphaComponent(0.85).setFill()
                    musicIcon.draw(in: iconRect, blendMode: .normal, alpha: 0.85)
                }
            }
        }
    }

    // MARK: - Playback Controls
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resumePlayback()
        }
    }
    
    private func resumePlayback() {
        cancelFadeOut()
        // Try engine-based playback first
        if let engine = audioEngine, let player = playerNode, let file = audioFile {
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    print("AudioPlayer: Failed to restart engine: \(error)")
                }
            }
            
            // Schedule remaining audio from paused position
            let frameCount = AVAudioFrameCount(file.length - pausedPosition)
            if frameCount > 0 {
                // Generate new segment ID
                playbackSegmentID = UUID()
                let captureID = playbackSegmentID
                
                player.scheduleSegment(file, startingFrame: pausedPosition, frameCount: frameCount, at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, self.playbackSegmentID == captureID else { return }
                        self.handlePlaybackFinished()
                    }
                }
            }
            player.play()
            isPlaying = true
            playbackStartTime = Date()
            startTimer()
            updateNowPlayingInfo()
            
            // Restart live session
            if let currentURL = currentURL {
                PlaybackAnalytics.shared.startLiveSession(trackId: currentURL.lastPathComponent, accruedDuration: accruedListenDuration)
            }
            return
        }
        
        // Fall back to AVAudioPlayer
        if let player = audioPlayer, !player.isPlaying {
            player.play()
            isPlaying = true
            playbackStartTime = Date()
            startTimer()
            updateNowPlayingInfo()
            
            // Restart live session
            if let currentURL = currentURL {
                PlaybackAnalytics.shared.startLiveSession(trackId: currentURL.lastPathComponent, accruedDuration: accruedListenDuration)
            }
        }
    }

    func pause() {
        // Invalidate current playback segment so stop() doesn't trigger next track
        playbackSegmentID = UUID()

        // Handle engine-based playback
        if let player = playerNode, player.isPlaying {
            // Save current position
            if let nodeTime = player.lastRenderTime,
               let playerTime = player.playerTime(forNodeTime: nodeTime) {
                pausedPosition += playerTime.sampleTime
            }
            player.stop()
        }
        
        // Handle AVAudioPlayer fallback
        audioPlayer?.pause()
        
        // Update accrued duration
        if let startTime = playbackStartTime {
            accruedListenDuration += Date().timeIntervalSince(startTime)
            playbackStartTime = nil
        }
        
        isPlaying = false
        stopTimer()
        updateNowPlayingInfo()
        rememberResumePosition()

        // Update live session with accrued duration and pause it
        if let currentURL = currentURL {
            PlaybackAnalytics.shared.endLiveSession()
            PlaybackAnalytics.shared.startLiveSession(trackId: currentURL.lastPathComponent, accruedDuration: accruedListenDuration)
        }
        
        // Save current listening session when pausing
        saveCurrentListeningSession()
    }
    
    /// Saves the current listening session to analytics if any time has been accrued.
    /// This ensures partial listens are always recorded, even if the track didn't finish.
    /// Prevents double-recording by tracking whether the current session has already been saved.
    private func saveCurrentListeningSession() {
        guard let url = currentURL, !hasRecordedCurrentSession else { return }
        
        // Add any current playback time to accrued duration
        let totalListenTime = accruedListenDuration + (playbackStartTime.map { Date().timeIntervalSince($0) } ?? 0)
        
        // Only save if meaningful progress was made (at least 5 seconds)
        // This filters out accidental plays
        guard totalListenTime >= 5.0 else { return }
        
        // Mark this session as recorded to prevent double-recording
        hasRecordedCurrentSession = true
        
        PlaybackAnalytics.shared.recordPlay(
            trackId: url.lastPathComponent,
            duration: duration,
            listenDuration: totalListenTime
        )
        
        print("AudioPlayer: Saved partial listen for \(url.lastPathComponent) (\(Int(totalListenTime))s)")
    }

    /// Extracts a segment of audio data from the current file for scratching
    func getAudioBuffer(for duration: TimeInterval = 2.0) -> AVAudioPCMBuffer? {
        guard let file = audioFile else { return nil }
        
        let sampleRate = file.processingFormat.sampleRate
        let frameCount = AVAudioFrameCount(min(Double(file.length), duration * sampleRate))
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount) else {
            return nil
        }
        
        do {
            // Read from current position
            let startFrame = max(0, min(file.length - Int64(frameCount), pausedPosition))
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: frameCount)
            return buffer
        } catch {
            print("AudioPlayer: Failed to read buffer for scratching: \(error)")
            return nil
        }
    }

    func seek(to time: TimeInterval) {
        if isUserScrubbing && JogEffectSettings.shared.isEnabled {
            handleScrubbing(to: time)
        } else {
            performSeek(to: time)
        }
    }
    
    private func performSeek(to time: TimeInterval) {
        let clampedTime = max(0, min(time, duration))
        
        // Handle engine-based seeking
        if let player = playerNode, let file = audioFile {
            let wasPlaying = player.isPlaying
            
            // Invalidate current segment ID
            playbackSegmentID = UUID()
            player.stop()
            
            let sampleRate = file.processingFormat.sampleRate
            pausedPosition = AVAudioFramePosition(clampedTime * sampleRate)
            
            let remainingFrames = file.length - pausedPosition
            if remainingFrames > 0 {
                let captureID = playbackSegmentID
                
                player.scheduleSegment(file, startingFrame: pausedPosition, frameCount: AVAudioFrameCount(remainingFrames), at: nil) { [weak self] in
                    DispatchQueue.main.async {
                        guard let self = self, self.playbackSegmentID == captureID else { return }
                        self.handlePlaybackFinished()
                    }
                }
                
                if wasPlaying {
                    player.play()
                }
            }
            
            progress = clampedTime
            updateNowPlayingInfo()
            return
        }
        
        // Fall back to AVAudioPlayer
        if let player = audioPlayer {
            player.currentTime = clampedTime
            progress = clampedTime
            updateNowPlayingInfo()
        }
    }
    
    private func handleScrubbing(to time: TimeInterval) {
        let clampedTime = max(0, min(time, duration))
        progress = clampedTime
        
        // Calculate velocity for scratch sound
        let now = Date()
        let lastTime = lastScrubTime ?? now
        let deltaTime = now.timeIntervalSince(lastTime)
        
        let lastPos = lastScrubPosition ?? progress
        let deltaPos = clampedTime - lastPos
        
        lastScrubTime = now
        lastScrubPosition = clampedTime
        
        guard deltaTime > 0, duration > 0 else { return }
        
        let fractionTraversed = abs(deltaPos) / duration
        let velocity = fractionTraversed / deltaTime
        let directionForward = deltaPos >= 0
        
        ScratchSoundManager.shared.updateScratch(normalizedScrubSpeed: velocity, directionForward: directionForward)
    }

    /// Call when user starts touching the progress bar
    func beginScrubbing() {
        isUserScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        lastScrubTime = Date()
        lastScrubPosition = progress
        
        if JogEffectSettings.shared.isEnabled {
            print("AudioPlayer: beginScrubbing (Jog enabled)")
            let scratchBuffer = getAudioBuffer()
            pause()
            ScratchSoundManager.shared.beginScratchSession(with: scratchBuffer)
        } else {
            print("AudioPlayer: beginScrubbing (Jog DISABLED)")
        }
    }

    /// Call when user releases the progress bar
    func endScrubbing(finalPosition: TimeInterval?) {
        isUserScrubbing = false
        lastScrubTime = nil
        lastScrubPosition = nil
        
        if JogEffectSettings.shared.isEnabled {
            ScratchSoundManager.shared.endScratchSession()
        }
        
        if let pos = finalPosition {
            performSeek(to: pos)
        }
        
        if wasPlayingBeforeScrub {
            resumePlayback()
        }
    }

    /// Skip forward. A manual skip always moves on, even in Repeat One.
    func nextTrack() {
        advance(automatic: false)
    }

    /// Restarts the current track when more than a few seconds in, otherwise
    /// steps back — the behaviour people expect from a back button.
    func previousTrack() {
        if currentURL != nil, progress > 3.0 {
            cancelCrossfade()
            performSeek(to: 0)
            return
        }

        cancelCrossfade()
        let order = playbackOrder()
        guard !order.isEmpty else { return }
        if currentPlayQueueIndex < 0 { currentPlayQueueIndex = order.count - 1 }
        else { currentPlayQueueIndex = currentPlayQueueIndex > 0 ? currentPlayQueueIndex - 1 : order.count - 1 }
        let url = order[currentPlayQueueIndex]
        currentTrackIndex = tracks.firstIndex(of: url) ?? -1
        play(url: url, allowResume: false)
    }

    /// Moves to the next thing that should play.
    /// - Parameter automatic: true when a track ended on its own, which is the only
    ///   case where Repeat One replays and the sleep timer may stop playback.
    private func advance(automatic: Bool) {
        cancelCrossfade()

        if automatic, SleepTimer.shared.shouldStopAfterCurrentTrack() {
            pause()
            performSeek(to: 0)
            return
        }

        // Anything the user queued by hand jumps the line.
        if !userQueue.isEmpty {
            let url = userQueue.removeFirst()
            play(url: url, allowResume: false)
            return
        }

        if automatic, PlaybackPreferences.shared.repeatMode == .one, let url = currentURL {
            play(url: url, allowResume: false)
            return
        }

        let order = playbackOrder()
        guard !order.isEmpty else { return }

        var index = currentPlayQueueIndex
        if index < 0 {
            index = 0
        } else {
            index += 1
        }

        if index >= order.count {
            let repeatMode = PlaybackPreferences.shared.repeatMode
            // Repeat Off means the library plays out and stops; a manual skip
            // still wraps, because the user asked for another track.
            guard repeatMode != .off || !automatic else {
                pause()
                performSeek(to: 0)
                return
            }
            if PlaybackPreferences.shared.shuffleEnabled {
                // Reshuffle so the next pass isn't the same running order.
                rebuildShuffleOrder(startingAt: nil)
            }
            index = 0
        }

        let refreshed = playbackOrder()
        guard refreshed.indices.contains(index) else { return }
        let url = refreshed[index]
        currentPlayQueueIndex = index
        currentTrackIndex = tracks.firstIndex(of: url) ?? -1
        play(url: url, allowResume: false)
    }

    // MARK: - Shuffle
    private func setupShuffleObserver() {
        shuffleObserver = PlaybackPreferences.shared.$shuffleEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    // Start the shuffled run from whatever is playing right now.
                    self.rebuildShuffleOrder(startingAt: self.currentURL)
                } else {
                    self.shuffleOrder = []
                }
                self.syncQueueIndexToCurrentTrack()
            }
    }

    private func rebuildShuffleOrder(startingAt url: URL?) {
        var order = getPlayQueue()
        order.shuffle()
        if let url, let index = order.firstIndex(of: url) {
            order.remove(at: index)
            order.insert(url, at: 0)
        }
        shuffleOrder = order
    }

    /// The order tracks actually play in: the label-filtered queue, shuffled when shuffle is on.
    func playbackOrder() -> [URL] {
        let base = getPlayQueue()
        guard PlaybackPreferences.shared.shuffleEnabled else { return base }
        if shuffleOrder.count != base.count || Set(shuffleOrder) != Set(base) {
            rebuildShuffleOrder(startingAt: currentURL)
        }
        return shuffleOrder
    }

    private func syncQueueIndexToCurrentTrack() {
        guard let url = currentURL else {
            currentPlayQueueIndex = -1
            return
        }
        currentPlayQueueIndex = playbackOrder().firstIndex(of: url) ?? -1
    }

    func toggleShuffle() {
        PlaybackPreferences.shared.shuffleEnabled.toggle()
    }

    func cycleRepeatMode() {
        PlaybackPreferences.shared.repeatMode = PlaybackPreferences.shared.repeatMode.next
    }

    // MARK: - Up Next queue
    /// Inserts a track so it plays as soon as the current one ends.
    func playNext(_ url: URL) {
        userQueue.removeAll { $0 == url }
        userQueue.insert(url, at: 0)
    }

    /// Appends a track to the end of the manual queue.
    func addToQueue(_ url: URL) {
        guard !userQueue.contains(url) else { return }
        userQueue.append(url)
    }

    func removeFromQueue(atOffsets offsets: IndexSet) {
        userQueue.remove(atOffsets: offsets)
    }

    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        userQueue.move(fromOffsets: offsets, toOffset: destination)
    }

    func clearQueue() {
        userQueue.removeAll()
    }

    /// Plays a queued track immediately and drops everything ahead of it.
    func jumpToQueued(_ url: URL) {
        guard let index = userQueue.firstIndex(of: url) else { return }
        userQueue.removeSubrange(0...index)
        play(url: url)
    }

    /// Shuffles the whole (filtered) library and starts playing.
    func shuffleAll() {
        let base = getPlayQueue()
        guard !base.isEmpty else { return }
        PlaybackPreferences.shared.shuffleEnabled = true
        rebuildShuffleOrder(startingAt: nil)
        userQueue.removeAll()
        currentPlayQueueIndex = 0
        play(url: shuffleOrder.first ?? base[0])
    }

    // MARK: - Sleep Timer
    private func setupSleepTimer() {
        SleepTimer.shared.onFire = { [weak self] in
            self?.fadeOutAndPause()
        }
    }

    /// Eases the volume down over a few seconds before pausing, so the timer
    /// doesn't cut the music dead.
    private func fadeOutAndPause(duration: TimeInterval = 5.0) {
        guard isPlaying else {
            pause()
            return
        }

        fadeOutTimer?.invalidate()
        isFadingOut = true

        let steps = Int(duration / 0.05)
        var step = 0
        let engineStartVolume = audioEngine?.mainMixerNode.outputVolume ?? 1.0
        let playerStartVolume = audioPlayer?.volume ?? 1.0

        fadeOutTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            step += 1
            let remaining = max(0, 1.0 - Float(step) / Float(max(steps, 1)))
            self.audioEngine?.mainMixerNode.outputVolume = engineStartVolume * remaining
            self.audioPlayer?.volume = playerStartVolume * remaining

            if step >= steps {
                timer.invalidate()
                self.fadeOutTimer = nil
                self.pause()
                // Restore full volume so the next play isn't silent.
                self.audioEngine?.mainMixerNode.outputVolume = engineStartVolume
                self.audioPlayer?.volume = playerStartVolume
                self.isFadingOut = false
            }
        }
        if let fadeOutTimer { RunLoop.main.add(fadeOutTimer, forMode: .common) }
    }

    private func cancelFadeOut() {
        fadeOutTimer?.invalidate()
        fadeOutTimer = nil
        if isFadingOut {
            audioEngine?.mainMixerNode.outputVolume = 1.0
            audioPlayer?.volume = 1.0
            isFadingOut = false
        }
    }

    // MARK: - Track Management
    func remove(atOffsets offsets: IndexSet) {
        let validOffsets = IndexSet(offsets.filter { $0 >= 0 && $0 < tracks.count })
        guard !validOffsets.isEmpty else { return }

        let tracksToRemove = validOffsets.map { tracks[$0] }
        let removingCurrentTrack = currentURL.map { tracksToRemove.contains($0) } ?? false

        tracks.remove(atOffsets: validOffsets)
        let removedSet = Set(tracksToRemove)
        userQueue.removeAll { removedSet.contains($0) }
        shuffleOrder.removeAll { removedSet.contains($0) }

        for url in tracksToRemove {
            removeTrack(url: url, removeFromTracks: false)
        }

        if removingCurrentTrack {
            stop()
        } else if let currentURL = currentURL, let newIndex = tracks.firstIndex(of: currentURL) {
            currentTrackIndex = newIndex
        }
    }

    private func stop() {
        playRequestID = UUID()
        playbackSegmentID = UUID()
        cancelCrossfade()
        isUserScrubbing = false
        
        // Save current listening session before stopping
        saveCurrentListeningSession()
        
        // End live session tracking
        PlaybackAnalytics.shared.endLiveSession()
        
        // Stop engine
        playerNode?.stop()
        audioEngine?.stop()
        
        // Stop AVAudioPlayer
        audioPlayer?.stop()
        audioPlayer = nil
        
        isPlaying = false
        currentURL = nil
        currentTrackIndex = -1
        progress = 0
        duration = 0
        pausedPosition = 0
        stopTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        if let url = currentSecurityURL, isAccessingSecurityResource {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityResource = false
            currentSecurityURL = nil
        }
    }

    /// Stops every active playback path before starting a newly selected track.
    private func stopActivePlaybackForSwitch() {
        playbackSegmentID = UUID()
        cancelCrossfade()
        isUserScrubbing = false

        playerNode?.stop()
        audioEngine?.stop()
        audioFile = nil
        pausedPosition = 0

        if let oldPlayer = audioPlayer {
            oldPlayer.delegate = nil
            oldPlayer.stop()
        }
        audioPlayer = nil

        PlaybackAnalytics.shared.endLiveSession()
        isPlaying = false
        progress = 0
        duration = 0
        stopTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - File Import
    func importTracks(urls: [URL]) {
        let fileManager = FileManager.default
        
        // Try to use Library/Audio first (preferred, no document coordination)
        var importDir: URL?
        if let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            importDir = libraryURL.appendingPathComponent("Audio")
        } else if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            // Fallback to Documents if Library is unavailable
            importDir = documentsURL.appendingPathComponent("ImportedAudio")
        }
        
        guard let importDir = importDir else {
            print("AudioPlayer: Could not access import directory")
            return
        }

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
        var importedURLs: [URL] = []

        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let incomingHash = calculateFileHash(url) else {
                print("AudioPlayer: Could not calculate hash for \(url.lastPathComponent)")
                continue
            }

            if fileHashes.values.contains(incomingHash) {
                print("AudioPlayer: Skipping duplicate file \(url.lastPathComponent)")
                skippedCount += 1
                continue
            }

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
                
                // Disable document collaboration and iCloud sync for this file
                var attributes = try fileManager.attributesOfItem(atPath: destURL.path)
                attributes[FileAttributeKey.protectionKey] = FileProtectionType.none
                try fileManager.setAttributes(attributes, ofItemAtPath: destURL.path)
                
                // Prevent document coordination
                try (destURL as NSURL).setResourceValue(NSNumber(value: true), forKey: URLResourceKey(rawValue: "NSURLIsExcludedFromBackupKey") as URLResourceKey)

                fileHashes[destURL.lastPathComponent] = incomingHash

                DispatchQueue.main.async {
                    self.tracks.append(destURL)
                }

                importedURLs.append(destURL)
                addedCount += 1
                print("AudioPlayer: Added track \(destURL.lastPathComponent)")
            } catch {
                print("AudioPlayer: Failed to copy \(url.lastPathComponent) - \(error.localizedDescription)")
            }
        }

        if addedCount > 0 {
            saveFileHashes()
            // Read cover art and tags for the new files right away.
            TrackTagStore.shared.prefetch(importedURLs.map { ($0.lastPathComponent, $0) })
        }

        print("AudioPlayer: Import complete - Added: \(addedCount), Skipped: \(skippedCount)")
    }


    func resolvedURL(for url: URL) -> URL? {
        resolveURL(fileName: url.lastPathComponent)
    }

    /// - Parameter allowResume: when true (a deliberate tap), a remembered
    ///   position inside a long track is restored. Auto-advance passes false so
    ///   the next track always starts at the beginning.
    func play(url: URL, allowResume: Bool = true) {
        pendingResumePosition = allowResume
            ? MusicMetadataManager.shared.resumePosition(for: url.lastPathComponent)
            : 0
        let requestID = UUID()
        playRequestID = requestID
        cancelCrossfade()
        cancelFadeOut()
        let fileName = url.lastPathComponent

        // Save current listening session before switching tracks
        saveCurrentListeningSession()
        rememberResumePosition()
        stopActivePlaybackForSwitch()
        
        // Reset analytics for new track
        accruedListenDuration = 0
        playbackStartTime = nil
        hasRecordedCurrentSession = false  // Allow recording of the new track's session

        if let previousURL = currentSecurityURL, isAccessingSecurityResource {
            previousURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityResource = false
        }

        guard let resolvedURL = resolveURL(fileName: fileName) else {
            print("AudioPlayer: Could not resolve URL for \(fileName)")
            removeTrack(url: url)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fileManager = FileManager.default

            guard fileManager.fileExists(atPath: resolvedURL.path) else {
                print("AudioPlayer: File not found at path \(resolvedURL.path)")
                DispatchQueue.main.async { self.removeTrack(url: url) }
                return
            }

            // Try to use AVAudioEngine for EQ support
            do {
                let file = try AVAudioFile(forReading: resolvedURL)
                
                DispatchQueue.main.async {
                    guard self.playRequestID == requestID else { return }
                    self.playWithEngine(file: file, url: url)
                }
            } catch {
                // Fall back to AVAudioPlayer
                print("AudioPlayer: Engine failed, falling back to AVAudioPlayer: \(error)")
                
                do {
                    let fileData = try Data(contentsOf: resolvedURL)
                    let fileTypeHint = self.getFileTypeHint(for: resolvedURL)
                    
                    DispatchQueue.main.async {
                        guard self.playRequestID == requestID else { return }
                        self.playWithAudioPlayer(data: fileData, fileTypeHint: fileTypeHint, url: url)
                    }
                } catch {
                    print("AudioPlayer: Failed to read file data for \(fileName) - \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func playWithEngine(file: AVAudioFile, url: URL) {
        playbackSegmentID = UUID() // Invalidate old segment
        isUserScrubbing = false
        teardownAudioEngine()
        setupAudioEngine()
        
        guard audioEngine != nil,
              let player = playerNode,
              eqNode != nil else {
            print("AudioPlayer: Engine setup failed")
            return
        }
        
        audioFile = file
        audioFormat = file.processingFormat
        pausedPosition = 0
        
        // Connect with the file's format
        connectAndStartEngine(format: file.processingFormat)
        
        // Schedule the file
        playbackSegmentID = UUID()
        let captureID = playbackSegmentID
        
        player.scheduleFile(file, at: nil) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.playbackSegmentID == captureID else { return }
                self.handlePlaybackFinished()
            }
        }
        
        player.play()

        currentURL = url
        currentPlayQueueIndex = playbackOrder().firstIndex(of: url) ?? -1
        currentTrackIndex = tracks.firstIndex(of: url) ?? -1
        isPlaying = true
        duration = Double(file.length) / file.processingFormat.sampleRate
        
        // Update live session with actual duration
        playbackStartTime = Date()
        PlaybackAnalytics.shared.startLiveSession(trackId: url.lastPathComponent, accruedDuration: 0)
        
        currentSecurityURL = nil
        isAccessingSecurityResource = false
        
        startTimer()
        applyPendingResume()
        updateNowPlayingInfo()

        print("AudioPlayer: ✅ Playing with AVAudioEngine + EQ: \(url.lastPathComponent)")
    }
    
    private func playWithAudioPlayer(data: Data, fileTypeHint: String?, url: URL) {
        do {
            isUserScrubbing = false
            audioPlayer = try AVAudioPlayer(data: data, fileTypeHint: fileTypeHint)
            audioPlayer?.delegate = self
            audioPlayer?.enableRate = true
            audioPlayer?.rate = PlaybackPreferences.shared.playbackRate
            audioPlayer?.volume = 1.0
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()

            currentURL = url
            currentPlayQueueIndex = playbackOrder().firstIndex(of: url) ?? -1
            currentTrackIndex = tracks.firstIndex(of: url) ?? -1
            isPlaying = true
            duration = audioPlayer?.duration ?? 0

            currentSecurityURL = nil
            isAccessingSecurityResource = false
            
            // Update live session with actual duration
            playbackStartTime = Date()
            PlaybackAnalytics.shared.startLiveSession(trackId: url.lastPathComponent, accruedDuration: 0)

            startTimer()
            applyPendingResume()
            updateNowPlayingInfo()

            print("AudioPlayer: Playing with AVAudioPlayer (no EQ): \(url.lastPathComponent)")
        } catch {
            print("AudioPlayer: Failed to create audio player - \(error.localizedDescription)")
        }
    }
    
    private func applyPendingResume() {
        let position = pendingResumePosition
        pendingResumePosition = 0
        guard position > 1, position < duration - 5 else { return }
        performSeek(to: position)
        print("AudioPlayer: Resumed at \(Int(position))s")
    }

    private func handlePlaybackFinished() {
        if isCrossfading { return }
        // Only record if we haven't already saved this session
        if !hasRecordedCurrentSession, let url = currentURL {
            let totalListenTime = accruedListenDuration + (playbackStartTime.map { Date().timeIntervalSince($0) } ?? 0)
            PlaybackAnalytics.shared.recordPlay(
                trackId: url.lastPathComponent,
                duration: duration,
                listenDuration: totalListenTime
            )
            hasRecordedCurrentSession = true
        }
        // A finished track has no resume point.
        if let url = currentURL {
            MusicMetadataManager.shared.setResumePosition(0, duration: duration, for: url.lastPathComponent)
        }
        advance(automatic: true)
    }

    // MARK: - Helper Methods
    private func removeTrack(url: URL, removeFromTracks: Bool = true) {
        let fileName = url.lastPathComponent

        if removeFromTracks, let index = tracks.firstIndex(of: url) {
            tracks.remove(at: index)
        }

        bookmarks.removeValue(forKey: fileName)
        saveBookmarks()

        fileHashes.removeValue(forKey: fileName)
        saveFileHashes()
        MusicMetadataManager.shared.removeMusicMetadata(fileName: fileName)

        let fileManager = FileManager.default
        var deleted = false
        
        // Try deleting from Library/Audio (new location)
        if let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let fileURL = libraryURL.appendingPathComponent("Audio").appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                    print("AudioPlayer: Deleted file from Library/Audio: \(fileName)")
                    deleted = true
                } catch {
                    print("AudioPlayer: Failed to delete file from Library/Audio \(fileName) - \(error)")
                }
            }
        }
        
        // Try deleting from Documents/ImportedAudio (legacy location)
        if !deleted {
            if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                let importDir = documentsURL.appendingPathComponent("ImportedAudio")
                let fileURL = importDir.appendingPathComponent(fileName)

                if fileManager.fileExists(atPath: fileURL.path) {
                    do {
                        try fileManager.removeItem(at: fileURL)
                        print("AudioPlayer: Deleted file from ImportedAudio: \(fileName)")
                    } catch {
                        print("AudioPlayer: Failed to delete file from ImportedAudio \(fileName) - \(error)")
                    }
                }
            }
        }

        print("AudioPlayer: Removed track \(fileName)")
    }

    private func resolveURL(fileName: String) -> URL? {
        let fileManager = FileManager.default
        
        // 1. Check Library/Audio (Preferred)
        if let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let candidate = libraryURL.appendingPathComponent("Audio").appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        
        // 2. Check Documents/ImportedAudio (Legacy)
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = docs.appendingPathComponent("ImportedAudio").appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let bundlePath = Bundle.main.path(forResource: fileName, ofType: nil) {
            return URL(fileURLWithPath: bundlePath)
        }
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
        DispatchQueue.main.async {
            if !self.isUserScrubbing {
                self.progress = self.getCurrentPlaybackTime()
            }
            
            // Disable auto-sync of isPlaying to prevent UI flickering
            // The explicit state management in play/pause/stop is more reliable
            /*
            if let player = self.playerNode {
                self.isPlaying = player.isPlaying
            } else if let player = self.audioPlayer {
                self.isPlaying = player.isPlaying
            }
            */
            
            self.checkCrossfadeStart()
        }
    }

    // MARK: - Crossfade
    private var crossfadeSettings: CrossfadeSettings { CrossfadeSettings.shared }

    private static func smoothstepQuintic(_ t: Float) -> Float {
        let x = max(0, min(1, t))
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
    
    private static func linearOut(_ t: Float) -> Float { 1.0 - t }
    private static func linearIn(_ t: Float) -> Float { t }
    
    private static func easeInOutOut(_ t: Float) -> Float {
        let s = smoothstepQuintic(t)
        return 1.0 - s
    }
    private static func easeInOutIn(_ t: Float) -> Float {
        return smoothstepQuintic(t)
    }
    
    private static func constantPowerOut(_ t: Float) -> Float {
        return cos(t * .pi / 2)
    }
    private static func constantPowerIn(_ t: Float) -> Float {
        return sin(t * .pi / 2)
    }
    
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
              !isFadingOut,
              currentURL != nil,
              let nextURL = upcomingTrackForCrossfade() else { return }

        // `remaining` is in file time; at 1.5x speed it drains 1.5x faster, so the
        // fade has to start proportionally earlier in file time to last as long.
        let rate = Double(max(PlaybackPreferences.shared.playbackRate, 0.1))
        let remaining = duration - progress
        let fadeDuration = crossfadeSettings.duration * rate

        let preloadWhenRemaining = min(8.0 * rate, fadeDuration * 3.0)
        if remaining <= preloadWhenRemaining, remaining > fadeDuration + Self.crossfadeLeadTime, crossfadePreloadedURL != nextURL {
            preloadNextTrackForCrossfade(url: nextURL)
        }

        let triggerWhenRemaining = fadeDuration + Self.crossfadeLeadTime
        guard remaining <= triggerWhenRemaining, remaining > 0 else { return }
        beginCrossfade(to: nextURL)
    }

    /// What crossfade should blend into, mirroring `advance(automatic: true)`
    /// without changing any state. Returns nil when nothing should follow.
    private func upcomingTrackForCrossfade() -> URL? {
        // The sleep timer is about to stop us; don't start another track.
        if SleepTimer.shared.stopsAtEndOfTrack { return nil }
        if let queued = userQueue.first { return queued }

        let prefs = PlaybackPreferences.shared
        // Repeat One re-plays the same file; crossfading a track into itself
        // would double it up, so let the normal restart handle it.
        if prefs.repeatMode == .one { return nil }

        let order = playbackOrder()
        guard order.count > 1, currentPlayQueueIndex >= 0 else { return nil }

        let nextIndex = currentPlayQueueIndex + 1
        if nextIndex < order.count { return order[nextIndex] }
        return prefs.repeatMode == .all ? order.first : nil
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
            nextPlayer.rate = PlaybackPreferences.shared.playbackRate
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
        crossfadeOutDuration = duration
        crossfadeInURL = nextURL

        let usePreloaded = crossfadePreloadedURL == nextURL, preloaded = crossfadePreloadedPlayer
        if usePreloaded, let nextPlayer = preloaded {
            crossfadePreloadedPlayer = nil
            crossfadePreloadedURL = nil
            nextPlayer.volume = 0
            nextPlayer.enableRate = true
            nextPlayer.rate = PlaybackPreferences.shared.playbackRate
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
                nextPlayer.rate = PlaybackPreferences.shared.playbackRate
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
        // Wall-clock fade: the configured duration is what the listener hears,
        // regardless of playback speed.
        let fadeDuration = crossfadeSettings.duration
        if elapsed >= fadeDuration {
            audioPlayer?.volume = 1.0
            crossfadeNextPlayer?.volume = 1.0
            finishCrossfade()
            return
        }
        let t = Float(elapsed / fadeDuration)
        let (outVol, inVol) = getFadeVolumes(t: t)
        audioPlayer?.volume = outVol
        audioEngine?.mainMixerNode.outputVolume = outVol
        crossfadeNextPlayer?.volume = inVol
    }

    private func finishCrossfade() {
        playbackSegmentID = UUID() // Invalidate pending completion handlers from engine stop
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        
        // End live session for outgoing track
        PlaybackAnalytics.shared.endLiveSession()
        
        if !hasRecordedCurrentSession, let outURL = crossfadeOutURL {
            // For crossfade, we assume the track played to the end (or near it)
            // But let's use the actual accrued time if available
            let totalListenTime = accruedListenDuration + (playbackStartTime.map { Date().timeIntervalSince($0) } ?? 0)
            PlaybackAnalytics.shared.recordPlay(
                trackId: outURL.lastPathComponent,
                duration: crossfadeOutDuration,
                listenDuration: totalListenTime
            )
            hasRecordedCurrentSession = true
        }
        
        // Stop engine and old player
        playerNode?.stop()
        audioEngine?.stop()
        audioFile = nil // Clear old file so getCurrentPlaybackTime falls back to audioPlayer
        
        // CRITICAL: Clear delegate from old player BEFORE stopping to prevent stale callbacks
        let oldPlayer = audioPlayer
        audioPlayer = nil
        oldPlayer?.delegate = nil
        oldPlayer?.stop()
        
        audioPlayer = crossfadeNextPlayer
        crossfadeNextPlayer = nil
        audioPlayer?.delegate = self
        if let url = crossfadeInURL {
            // If we faded into a hand-queued track, consume it from the queue.
            if userQueue.first == url { userQueue.removeFirst() }
            currentURL = url
            currentPlayQueueIndex = playbackOrder().firstIndex(of: url) ?? -1
            currentTrackIndex = tracks.firstIndex(of: url) ?? -1
            
            // Reset analytics for new track and start live session
            accruedListenDuration = 0
            playbackStartTime = Date()
            hasRecordedCurrentSession = false
            PlaybackAnalytics.shared.startLiveSession(trackId: url.lastPathComponent, accruedDuration: 0)
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
    func getPlayQueue() -> [URL] {
        guard !labelFilterIds.isEmpty else { return tracks }
        let meta = MusicMetadataManager.shared
        return tracks.filter { url in
            let fileMeta = meta.getMetadata(for: url.lastPathComponent)
            return fileMeta.labels.contains { labelFilterIds.contains($0) }
        }
    }

    private func saveUserQueue() {
        UserDefaults.standard.set(userQueue.map { $0.lastPathComponent }, forKey: userQueueKey)
    }

    private func loadUserQueue() {
        guard let fileNames = UserDefaults.standard.array(forKey: userQueueKey) as? [String] else { return }
        let byName = Dictionary(tracks.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
        let restored = fileNames.compactMap { byName[$0] }
        if restored != userQueue { userQueue = restored }
    }

    /// Reads embedded tags and cover art in the background so the library can show them.
    private func prefetchTags(for urls: [URL]) {
        let items: [(fileName: String, url: URL)] = urls.compactMap { url in
            guard let resolved = self.resolveURL(fileName: url.lastPathComponent) else { return nil }
            return (url.lastPathComponent, resolved)
        }
        guard !items.isEmpty else { return }
        TrackTagStore.shared.prefetch(items)
    }

    /// Stores where the listener stopped, so long tracks can pick up where they left off.
    private func rememberResumePosition() {
        guard let url = currentURL, duration > 0 else { return }
        MusicMetadataManager.shared.setResumePosition(
            getCurrentPlaybackTime(),
            duration: duration,
            for: url.lastPathComponent
        )
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
        let queue = playbackOrder()
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
        var loadedTracks: [URL] = []
        
        // Try to find tracks in both Library and Documents directories
        let possibleDirs: [URL] = {
            var dirs: [URL] = []
            
            // Check Library/Audio first
            if let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first {
                dirs.append(libraryURL.appendingPathComponent("Audio"))
            }
            
            // Check Documents/ImportedAudio for legacy files
            if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
                dirs.append(documentsURL.appendingPathComponent("ImportedAudio"))
            }
            
            return dirs
        }()

        for fileName in fileNames {
            for dir in possibleDirs {
                let fileURL = dir.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: fileURL.path) {
                    loadedTracks.append(fileURL)
                    break  // Found file, move to next fileName
                }
            }
        }

        DispatchQueue.main.async {
            // Merge with existing tracks to prevent overriding imports that happened while loading
            // This fixes the "disappearing tracks" bug if import happens before load finishes
            let currentTracksSet = Set(self.tracks)
            let newTracks = loadedTracks.filter { !currentTracksSet.contains($0) }
            self.tracks.append(contentsOf: newTracks)
            
            // Self-healing: Ensure all tracks have hashes for duplicate detection
            self.ensureHashesForTracks()
            self.loadUserQueue()
            self.prefetchTags(for: self.tracks)

            print("AudioPlayer: Loaded \(loadedTracks.count) tracks (Total: \(self.tracks.count))")
        }
    }
    
    private func ensureHashesForTracks() {
        var updated = false
        for trackURL in tracks {
            let fileName = trackURL.lastPathComponent
            if fileHashes[fileName] == nil {
                if let hash = calculateFileHash(trackURL) {
                    fileHashes[fileName] = hash
                    updated = true
                    print("AudioPlayer: Generated missing hash for \(fileName)")
                }
            }
        }
        
        if updated {
            saveFileHashes()
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
            // Only record if we haven't already saved this session
            if !hasRecordedCurrentSession, let url = currentURL {
                let totalListenTime = accruedListenDuration + (playbackStartTime.map { Date().timeIntervalSince($0) } ?? 0)
                PlaybackAnalytics.shared.recordPlay(
                    trackId: url.lastPathComponent,
                    duration: player.duration,
                    listenDuration: totalListenTime
                )
                hasRecordedCurrentSession = true
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
