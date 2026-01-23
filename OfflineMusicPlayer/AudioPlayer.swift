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

    // MARK: - Private Properties
    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var currentSecurityURL: URL?
    private var isAccessingSecurityResource: Bool = false
    private var bookmarks: [String: Data] = [:]
    private let bookmarksKey = "audioFileBookmarks"
    private var fileHashes: [String: String] = [:]
    private let fileHashesKey = "audioFileHashes"

    // MARK: - Initialization
    override init() {
        super.init()
        setupAudioSession()
        setupRemoteCommands()
        setupNotifications()
        loadBookmarks()
        loadFileHashes()

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
        let trackTitle = url.deletingPathExtension().lastPathComponent
        
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
        player.currentTime = max(0, min(time, player.duration))
        progress = player.currentTime
        updateNowPlayingInfo()
    }

    func nextTrack() {
        guard !tracks.isEmpty else { return }
        currentTrackIndex = (currentTrackIndex + 1) % tracks.count
        play(url: tracks[currentTrackIndex])
    }

    func previousTrack() {
        guard !tracks.isEmpty else { return }
        currentTrackIndex = currentTrackIndex > 0 ? currentTrackIndex - 1 : tracks.count - 1
        play(url: tracks[currentTrackIndex])
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

    func play(url: URL) {
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
                        self.audioPlayer = try AVAudioPlayer(data: fileData, fileTypeHint: fileTypeHint)
                        self.audioPlayer?.delegate = self
                        self.audioPlayer?.prepareToPlay()
                        self.audioPlayer?.play()

                        self.currentURL = url
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
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = docs.appendingPathComponent("ImportedAudio").appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
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
            self.progress = player.currentTime
            self.duration = player.duration
            self.isPlaying = player.isPlaying
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
        if flag {
            nextTrack()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("AudioPlayer: Decode error - \(error?.localizedDescription ?? "unknown")")
        isPlaying = false
        stopTimer()
    }
}
