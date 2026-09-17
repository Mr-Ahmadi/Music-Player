import Foundation

// MARK: - LRCLIB Client
/// Minimal client for https://lrclib.net — a free, open lyrics database with
/// time-synced lyrics. No API key needed; LRCLIB asks clients to send a
/// descriptive User-Agent.
struct LRCLIBClient {
    struct Track: Decodable, Equatable {
        let id: Int
        let trackName: String
        let artistName: String
        let albumName: String?
        let duration: Double?
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?

        var hasSyncedLyrics: Bool { !(syncedLyrics?.isEmpty ?? true) }
        var hasAnyLyrics: Bool { hasSyncedLyrics || !(plainLyrics?.isEmpty ?? true) }
    }

    enum ClientError: LocalizedError {
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .badStatus(let code): return "LRCLIB returned an unexpected response (\(code))."
            }
        }
    }

    private let baseURL = URL(string: "https://lrclib.net/api")!
    private let session: URLSession

    init(session: URLSession = .lrclib) {
        self.session = session
    }

    // MARK: - Lookup
    /// Finds the best lyrics for a track: an exact match first, then a fuzzy search
    /// ranked by how closely the duration matches and whether the lyrics are synced.
    func lyrics(title: String, artist: String?, album: String?, duration: TimeInterval?) async throws -> Track? {
        if let artist, let album, let duration,
           let exact = try await get(title: title, artist: artist, album: album, duration: duration),
           exact.hasAnyLyrics || exact.instrumental {
            return exact
        }

        if let match = Self.bestMatch(in: try await search(title: title, artist: artist), duration: duration) {
            return match
        }

        // Artist tags are often messy ("A feat. B", "A, B"). With a known duration
        // a title-only search is still precise enough to be worth trying.
        guard artist != nil, duration != nil else { return nil }
        return Self.bestMatch(in: try await search(title: title, artist: nil), duration: duration)
    }

    /// `GET /api/get` — exact signature match. LRCLIB tolerates ±2s of duration drift.
    func get(title: String, artist: String, album: String, duration: TimeInterval) async throws -> Track? {
        try await request("get", query: [
            "track_name": title,
            "artist_name": artist,
            "album_name": album,
            "duration": String(Int(duration.rounded()))
        ])
    }

    /// `GET /api/search` — fuzzy search by title and (optionally) artist.
    func search(title: String, artist: String?) async throws -> [Track] {
        var query = ["track_name": title]
        if let artist { query["artist_name"] = artist }
        return try await request("search", query: query) ?? []
    }

    // MARK: - Ranking
    static func bestMatch(in candidates: [Track], duration: TimeInterval?) -> Track? {
        let usable = candidates.filter { track in
            guard track.hasAnyLyrics || track.instrumental else { return false }
            // Different recordings (live, extended mix) have different lengths and
            // their timings wouldn't line up, so reject anything clearly off.
            guard let duration, let other = track.duration else { return true }
            return abs(other - duration) <= 8
        }

        return usable.min { lhs, rhs in
            if lhs.hasSyncedLyrics != rhs.hasSyncedLyrics { return lhs.hasSyncedLyrics }
            guard let duration else { return false }
            return abs((lhs.duration ?? .infinity) - duration) < abs((rhs.duration ?? .infinity) - duration)
        }
    }

    // MARK: - Networking
    /// Returns nil for 404 (LRCLIB's "not found").
    private func request<T: Decodable>(_ endpoint: String, query: [String: String]) async throws -> T? {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return try JSONDecoder().decode(T.self, from: data)
        case 404: return nil
        default: throw ClientError.badStatus(status)
        }
    }
}

extension URLSession {
    static let lrclib: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "OfflineMusicPlayer (https://github.com/Mr-Ahmadi/Music-Player)"
        ]
        return URLSession(configuration: config)
    }()
}
