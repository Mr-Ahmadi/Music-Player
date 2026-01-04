import Foundation
import AVFoundation
import Combine

final class AudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentURL: URL?
    @Published var currentTrackIndex: Int = -1
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var tracks: [URL] = [] {
        didSet { saveTracks() }
    }

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    private var currentSecurityURL: URL?
    private var isAccessingSecurityResource: Bool = false
    private var bookmarks: [String: Data] = [:] // Store security scope bookmarks by filename
    private let bookmarksKey = "audioFileBookmarks"

    override init() {
        super.init()
        setupAudioSession()
        loadBookmarks()
        // Load saved tracks off the main thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.loadTracks()
        }
    }

    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("AudioPlayer: failed to setup audio session ", error)
        }
    }

    func add(urls: [URL]) {
        // Copy picked files into app container (avoids security-scope on iOS)
        let fileManager = FileManager.default
        let importDir: URL = {
            let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dir = docs.appendingPathComponent("ImportedAudio", isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }()

        for url in urls {
            // Sanitize filename by removing problematic characters (pipe, etc.)
            let sanitizedFileName = url.lastPathComponent
                .replacingOccurrences(of: "|", with: "-")
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: "\0", with: "")
            
            // ensure unique destination filename
            var dest = importDir.appendingPathComponent(sanitizedFileName)
            var counter = 1
            while fileManager.fileExists(atPath: dest.path) {
                let base = URL(fileURLWithPath: sanitizedFileName).deletingPathExtension().lastPathComponent
                let ext = URL(fileURLWithPath: sanitizedFileName).pathExtension
                let newName = "\(base) - \(counter)\(ext.isEmpty ? "" : ".\(ext)")"
                dest = importDir.appendingPathComponent(newName)
                counter += 1
            }

            DispatchQueue.global(qos: .userInitiated).async {
                // Start accessing security-scoped resource FIRST
                let shouldStopAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if shouldStopAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                
                do {
                    // Verify file exists before copying
                    guard fileManager.fileExists(atPath: url.path) else {
                        print("AudioPlayer: source file not accessible at \(url.path)")
                        return
                    }
                    
                    // Copy the file into app container
                    try fileManager.copyItem(at: url, to: dest)
                    DispatchQueue.main.async {
                        if !self.tracks.contains(dest) {
                            self.tracks.append(dest)
                        }
                    }
                    print("AudioPlayer: successfully copied file to \(dest.lastPathComponent)")
                } catch {
                    print("AudioPlayer: failed to copy file \(url) -> \(dest): \(error)")
                }
            }
        }
    }
    
    private func storeBookmark(for url: URL) {
        #if os(macOS)
        do {
            let bookmark = try url.bookmarkData(options: [.minimalBookmark, .withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            let fileName = url.lastPathComponent
            bookmarks[fileName] = bookmark
            saveBookmarks()
        } catch {
            print("AudioPlayer: failed to create bookmark for \(url.lastPathComponent) - \(error)")
        }
        #endif
    }
    
    private func resolveURL(fileName: String) -> URL? {
        #if os(macOS)
        guard let bookmark = bookmarks[fileName] else {
            print("AudioPlayer: no bookmark found for \(fileName)")
            return nil
        }

        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("AudioPlayer: bookmark is stale for \(fileName), refreshing...")
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: resolvedURL.path) {
                    storeBookmark(for: resolvedURL)
                }
            }

            return resolvedURL
        } catch {
            print("AudioPlayer: failed to resolve bookmark for \(fileName) - \(error)")
            return nil
        }
        #else
        // On iOS we store copied files in app container; try to find by filename
        let fileManager = FileManager.default
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = docs.appendingPathComponent("ImportedAudio/").appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        print("AudioPlayer: no local copy found for \(fileName)")
        return nil
        #endif
    }

    func play(url: URL) {
        let fileName = url.lastPathComponent
        
        // Stop accessing previous security-scoped resource
        if let previousURL = currentSecurityURL, isAccessingSecurityResource {
            previousURL.stopAccessingSecurityScopedResource()
            isAccessingSecurityResource = false
        }
        // Resolve file URL (bookmarks on macOS, local copy on iOS)
        guard let resolvedURL = resolveURL(fileName: fileName) else {
            print("AudioPlayer: could not resolve URL for \(fileName)")
            removeTrack(url: url)
            return
        }

        // Perform file I/O off the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default

            #if os(macOS)
            // For macOS, handle security-scoped access
            var shouldStopAccessing = false
            if resolvedURL.startAccessingSecurityScopedResource() {
                shouldStopAccessing = true
            }
            #endif

            guard fileManager.fileExists(atPath: resolvedURL.path) else {
                print("AudioPlayer: file not found at path \(resolvedURL.path)")
                #if os(macOS)
                if shouldStopAccessing {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
                #endif
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

                        // Keep track of security-scoped URL for cleanup (macOS only)
                        #if os(macOS)
                        self.currentSecurityURL = resolvedURL
                        self.isAccessingSecurityResource = shouldStopAccessing
                        #else
                        self.currentSecurityURL = nil
                        self.isAccessingSecurityResource = false
                        #endif

                        self.currentURL = url
                        self.currentTrackIndex = self.tracks.firstIndex(of: url) ?? -1
                        self.duration = self.audioPlayer?.duration ?? 0
                        self.isPlaying = true
                        self.startTimer()

                        print("AudioPlayer: successfully playing \(fileName)")
                    } catch {
                        print("AudioPlayer: failed to initialize player for \(fileName) - \(error)")
                        // Release security access if initialization failed
                        #if os(macOS)
                        if shouldStopAccessing {
                            resolvedURL.stopAccessingSecurityScopedResource()
                        }
                        #endif
                        self.removeTrack(url: url)
                    }
                }
            } catch {
                print("AudioPlayer: failed to read file data for \(fileName) - \(error)")
                #if os(macOS)
                if shouldStopAccessing {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }
                #endif
                DispatchQueue.main.async { self.removeTrack(url: url) }
            }
        }
    }
    
    private func removeTrack(url: URL) {
        let fileName = url.lastPathComponent
        if let index = tracks.firstIndex(of: url) {
            tracks.remove(at: index)
            // Remove associated bookmark (macOS)
            #if os(macOS)
            bookmarks.removeValue(forKey: fileName)
            saveBookmarks()
            #endif

            // If file exists in app container, delete it asynchronously
            let fileManager = FileManager.default
            DispatchQueue.global(qos: .utility).async {
                if fileManager.fileExists(atPath: url.path) {
                    do {
                        try fileManager.removeItem(at: url)
                        print("AudioPlayer: deleted local file \(fileName)")
                    } catch {
                        print("AudioPlayer: failed to delete local file \(fileName) - \(error)")
                    }
                }
            }
            print("AudioPlayer: removed track \(fileName)")
        }
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
            return AVFileType.mp3.rawValue  // Default fallback
        }
    }

    func nextTrack() {
        guard !tracks.isEmpty else { return }
        let nextIndex = (currentTrackIndex + 1) % tracks.count
        play(url: tracks[nextIndex])
    }

    func previousTrack() {
        guard !tracks.isEmpty else { return }
        let prevIndex = currentTrackIndex > 0 ? currentTrackIndex - 1 : tracks.count - 1
        play(url: tracks[prevIndex])
    }

    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
    }

    func togglePlayPause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            pause()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to seconds: Double) {
        guard let player = audioPlayer else { return }
        player.currentTime = seconds
        updateProgress()
    }

    func remove(atOffsets offsets: IndexSet) {
        tracks.remove(atOffsets: offsets)
    }

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

    private func saveTracks() {
        // Save track filenames to allow recovery
        let fileNames = tracks.map { $0.lastPathComponent }
        UserDefaults.standard.set(fileNames, forKey: "savedTrackNames")
    }

    private func loadTracks() {
        var resolvedURLs: [URL] = []
        if let fileNames = UserDefaults.standard.stringArray(forKey: "savedTrackNames") {
            // Try to reconstruct URLs from bookmarks or local copies
            for fileName in fileNames {
                if let resolvedURL = resolveURL(fileName: fileName) {
                    resolvedURLs.append(resolvedURL)
                }
            }
        }

        if !resolvedURLs.isEmpty {
            DispatchQueue.main.async {
                for url in resolvedURLs where !self.tracks.contains(url) {
                    self.tracks.append(url)
                }
            }
        }
    }
    
    private func saveBookmarks() {
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
    }
    
    private func loadBookmarks() {
        if let stored = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] {
            bookmarks = stored
        }
    }
    
    deinit {
        // Clean up security-scoped resource access
        if let url = currentSecurityURL, isAccessingSecurityResource {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Release security access when playback finishes
        if let url = currentSecurityURL, isAccessingSecurityResource {
            url.stopAccessingSecurityScopedResource()
            isAccessingSecurityResource = false
            currentSecurityURL = nil
        }
        nextTrack()
    }
}
