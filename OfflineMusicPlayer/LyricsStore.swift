import Foundation
import CryptoKit

// MARK: - Lyrics Store
/// Loads lyrics for the playing track from LRCLIB and keeps them on disk, so a
/// track only needs a connection the first time its lyrics are opened.
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    enum State: Equatable {
        case idle
        case loading
        case loaded(Lyrics)
        case notFound
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// The track `state` belongs to.
    @Published private(set) var fileName: String?
    /// Per-track timing correction in seconds. Positive shows lines later.
    @Published private var offsets: [String: Double] {
        didSet { UserDefaults.standard.set(offsets, forKey: offsetsKey) }
    }

    private let client = LRCLIBClient()
    private var loadTask: Task<Void, Never>?
    private let offsetsKey = "lyricsTimingOffsets"
    /// "Not found" answers are retried after this long, in case LRCLIB gained the track.
    private let notFoundLifetime: TimeInterval = 7 * 24 * 60 * 60

    private lazy var cacheDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        offsets = UserDefaults.standard.dictionary(forKey: "lyricsTimingOffsets") as? [String: Double] ?? [:]
    }

    // MARK: - Loading
    /// Shows lyrics for `fileName`, from disk when possible and LRCLIB otherwise.
    /// - Parameter forceRefresh: skips the cache (the "Search Again" action).
    func load(fileName: String, url: URL?, duration: TimeInterval, forceRefresh: Bool = false) {
        if !forceRefresh, self.fileName == fileName, state != .idle, !isFailed { return }

        loadTask?.cancel()
        self.fileName = fileName

        if !forceRefresh, let cached = readCache(for: fileName), !cached.isExpired(notFoundLifetime) {
            state = cached.state
            return
        }

        state = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            let tags = await self.tags(for: fileName, url: url)
            let query = LyricsQuery(
                fileName: fileName,
                tags: tags,
                displayName: MusicMetadataManager.shared.getMetadata(for: fileName).displayName,
                duration: tags?.duration ?? (duration > 0 ? duration : nil)
            )

            do {
                let track = try await self.client.lyrics(
                    title: query.title,
                    artist: query.artist,
                    album: query.album,
                    duration: query.duration
                )
                guard !Task.isCancelled else { return }
                let entry = CachedLyrics(track: track)
                self.writeCache(entry, for: fileName)
                self.state = entry.state
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.state = .failed(Self.message(for: error))
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Embedded tags give the cleanest search terms. They're read in the
    /// background, so wait briefly for them if this track hasn't been read yet.
    private func tags(for fileName: String, url: URL?) async -> TrackTags? {
        let tagStore = TrackTagStore.shared
        if let tags = tagStore.tags(for: fileName, resolvedURL: url) { return tags }
        guard url != nil else { return nil }

        return await withTaskGroup(of: TrackTags?.self) { group in
            group.addTask { @MainActor in
                for await all in tagStore.$tags.values {
                    if let tags = all[fileName] { return tags }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Connect to the internet to download lyrics for this song."
            case .timedOut:
                return "LRCLIB took too long to respond."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    // MARK: - Timing Offset
    func offset(for fileName: String) -> Double {
        offsets[fileName] ?? 0
    }

    func setOffset(_ value: Double, for fileName: String) {
        let rounded = (value * 10).rounded() / 10
        offsets[fileName] = rounded == 0 ? nil : rounded
    }

    // MARK: - Disk Cache
    private func cacheURL(for fileName: String) -> URL {
        let digest = SHA256.hash(data: Data(fileName.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func readCache(for fileName: String) -> CachedLyrics? {
        guard let data = try? Data(contentsOf: cacheURL(for: fileName)) else { return nil }
        return try? JSONDecoder().decode(CachedLyrics.self, from: data)
    }

    private func writeCache(_ entry: CachedLyrics, for fileName: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: cacheURL(for: fileName), options: .atomic)
    }
}

// MARK: - Cached Lyrics
private struct CachedLyrics: Codable {
    var syncedLyrics: String?
    var plainLyrics: String?
    var instrumental: Bool
    var fetchedAt: Date

    init(track: LRCLIBClient.Track?) {
        syncedLyrics = track?.syncedLyrics.nilIfBlank
        plainLyrics = track?.plainLyrics.nilIfBlank
        instrumental = track?.instrumental ?? false
        fetchedAt = Date()
    }

    var state: LyricsStore.State {
        if let syncedLyrics {
            let lines = LRCParser.parse(syncedLyrics)
            if !lines.isEmpty { return .loaded(.synced(lines)) }
        }
        if let plainLyrics { return .loaded(.plain(plainLyrics)) }
        if instrumental { return .loaded(.instrumental) }
        return .notFound
    }

    /// Only negative answers expire; found lyrics are kept for good.
    func isExpired(_ notFoundLifetime: TimeInterval) -> Bool {
        let isNotFound = syncedLyrics == nil && plainLyrics == nil && !instrumental
        return isNotFound && Date().timeIntervalSince(fetchedAt) > notFoundLifetime
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}

// MARK: - Lyrics Query
/// Search terms for a track: embedded tags when present, otherwise the
/// "Artist - Title" convention most downloaded files are named with.
struct LyricsQuery: Equatable {
    var title: String
    var artist: String?
    var album: String?
    var duration: TimeInterval?

    init(fileName: String, tags: TrackTags?, displayName: String, duration: TimeInterval?) {
        var title = tags?.title
        var artist = tags?.artist ?? tags?.albumArtist

        if title == nil {
            let name = displayName.isEmpty ? (fileName as NSString).deletingPathExtension : displayName
            let parts = name.components(separatedBy: " - ")
            if artist == nil, parts.count >= 2 {
                artist = parts[0]
                title = parts.dropFirst().joined(separator: " - ")
            } else {
                title = name
            }
        }

        self.title = Self.clean(title ?? displayName)
        self.artist = artist.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        self.album = tags?.album
        self.duration = duration
    }

    private static let noise = try! NSRegularExpression(
        pattern: #"\s*[\(\[][^\)\]]*\b(official|lyrics?|audio|video|visualizer|hd|hq|4k|remaster(ed)?)\b[^\)\]]*[\)\]]"#,
        options: [.caseInsensitive]
    )

    /// Removes "(Official Video)"-style decorations that would spoil the search.
    static func clean(_ text: String) -> String {
        noise.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
