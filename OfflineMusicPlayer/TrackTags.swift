import Foundation
import AVFoundation
import UIKit
import SwiftUI
import CryptoKit

// MARK: - Track Tags
/// Metadata read from the audio file itself (ID3 / iTunes / Vorbis comments).
struct TrackTags: Codable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: String?
    var duration: Double?
    var hasArtwork: Bool = false

    var isEmpty: Bool {
        title == nil && artist == nil && album == nil && genre == nil && !hasArtwork
    }

    /// "Artist — Album", falling back to whichever half exists.
    var subtitle: String? {
        let parts = [artist, album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}

// MARK: - Track Tag Store
/// Reads and caches embedded tags and cover art for the library.
///
/// Reading is lazy and off the main thread: views ask for tags, get whatever is
/// cached right now, and are re-rendered when the real values arrive. Parsed tags
/// live in UserDefaults; cover art is written to Caches as JPEG so it survives
/// relaunches without bloating the defaults database.
final class TrackTagStore: ObservableObject {
    static let shared = TrackTagStore()

    @Published private(set) var tags: [String: TrackTags] = [:]
    /// Bumped whenever new artwork lands on disk so SwiftUI re-reads the cache.
    @Published private(set) var artworkRevision: Int = 0

    private let tagsKey = "embeddedTrackTags"
    private let artworkCache = NSCache<NSString, UIImage>()
    private var inFlight = Set<String>()

    private lazy var artworkDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private init() {
        artworkCache.countLimit = 120
        loadTags()
    }

    // MARK: - Lookup
    /// Returns cached tags, kicking off a background read the first time a track is seen.
    func tags(for fileName: String, resolvedURL: @autoclosure () -> URL?) -> TrackTags? {
        if let cached = tags[fileName] { return cached }
        if let url = resolvedURL() { read(fileName: fileName, url: url) }
        return nil
    }

    func cachedTags(for fileName: String) -> TrackTags? { tags[fileName] }

    /// Cover art for a track, or nil when it has none / hasn't been read yet.
    func artwork(for fileName: String) -> UIImage? {
        if let image = artworkCache.object(forKey: fileName as NSString) { return image }
        guard tags[fileName]?.hasArtwork == true else { return nil }
        let url = artworkURL(for: fileName)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        artworkCache.setObject(image, forKey: fileName as NSString)
        return image
    }

    /// Forces a re-read, e.g. after a file is replaced.
    func invalidate(fileName: String) {
        artworkCache.removeObject(forKey: fileName as NSString)
        try? FileManager.default.removeItem(at: artworkURL(for: fileName))
        DispatchQueue.main.async {
            self.tags.removeValue(forKey: fileName)
            self.saveTags()
        }
    }

    /// Warms the cache for a batch of tracks (used right after an import).
    func prefetch(_ items: [(fileName: String, url: URL)]) {
        for item in items where tags[item.fileName] == nil {
            read(fileName: item.fileName, url: item.url)
        }
    }

    // MARK: - Reading
    private func read(fileName: String, url: URL) {
        // `inFlight` is only ever touched on the main thread.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.read(fileName: fileName, url: url) }
            return
        }
        guard !inFlight.contains(fileName) else { return }
        inFlight.insert(fileName)

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let (parsed, artwork) = await Self.parse(url: url)
            if let artwork, let data = artwork.jpegData(compressionQuality: 0.85) {
                try? data.write(to: self.artworkURL(for: fileName), options: .atomic)
            }
            await MainActor.run {
                if let artwork {
                    self.artworkCache.setObject(artwork, forKey: fileName as NSString)
                }
                self.artworkRevision &+= 1
                self.tags[fileName] = parsed
                self.inFlight.remove(fileName)
                self.saveTags()
            }
        }
    }

    private static func parse(url: URL) async -> (TrackTags, UIImage?) {
        var result = TrackTags()
        let asset = AVURLAsset(url: url)

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { result.duration = seconds }
        }

        var items: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []
        // FLAC/OGG expose Vorbis comments through the format-specific metadata instead.
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let extra = try? await asset.loadMetadata(for: format) {
                    items.append(contentsOf: extra)
                }
            }
        }

        var artwork: UIImage?

        for item in items {
            let key = Self.normalizedKey(for: item)
            guard !key.isEmpty else { continue }

            if key.matchesTag("title", "tit2", "nam") {
                if result.title == nil {
                    result.title = (try? await item.load(.stringValue))?.cleanedTag
                }
            } else if key.matchesTag("albumartist", "aart", "tpe2") {
                if result.albumArtist == nil {
                    result.albumArtist = (try? await item.load(.stringValue))?.cleanedTag
                }
            } else if key.matchesTag("artist", "tpe1", "art") {
                if result.artist == nil {
                    result.artist = (try? await item.load(.stringValue))?.cleanedTag
                }
            } else if key.matchesTag("albumname", "album", "talb", "alb") {
                if result.album == nil {
                    result.album = (try? await item.load(.stringValue))?.cleanedTag
                }
            } else if key.matchesTag("genre", "tcon", "gen", "type") {
                if result.genre == nil {
                    result.genre = (try? await item.load(.stringValue))?.cleanedTag
                }
            } else if key.matchesTag("creationdate", "date", "year", "tyer", "tdrc", "day") {
                if result.year == nil {
                    result.year = (try? await item.load(.stringValue))?.cleanedTag
                }
            } else if key.matchesTag("artwork", "covr", "apic", "metadata_block_picture") {
                if artwork == nil,
                   let data = try? await item.load(.dataValue),
                   let image = UIImage(data: data) {
                    artwork = image.downscaled(maxDimension: 600)
                }
            }
        }

        result.hasArtwork = artwork != nil
        return (result, artwork)
    }


    /// Metadata keys arrive as common keys, four-char codes, or identifiers like
    /// "id3/TIT2" depending on the container. Fold them all into one lowercase string.
    private static func normalizedKey(for item: AVMetadataItem) -> String {
        var parts: [String] = []
        if let common = item.commonKey?.rawValue { parts.append(common) }
        if let identifier = item.identifier?.rawValue { parts.append(identifier) }
        if let string = item.key as? String {
            parts.append(string)
        } else if let number = item.key as? NSNumber {
            // Four-character codes such as 'covr' come through as an integer.
            let value = number.uint32Value
            let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
            parts.append(String(decoding: bytes, as: UTF8.self))
        }
        return parts.joined(separator: "/").lowercased()
    }

    // MARK: - Persistence
    private func artworkURL(for fileName: String) -> URL {
        // File names can contain anything, so key the cache by a hash instead.
        let digest = SHA256.hash(data: Data(fileName.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return artworkDirectory.appendingPathComponent("\(name).jpg")
    }

    private func saveTags() {
        guard let data = try? JSONEncoder().encode(tags) else { return }
        UserDefaults.standard.set(data, forKey: tagsKey)
    }

    private func loadTags() {
        guard let data = UserDefaults.standard.data(forKey: tagsKey),
              let decoded = try? JSONDecoder().decode([String: TrackTags].self, from: data) else { return }
        tags = decoded
    }
}

// MARK: - Helpers
private extension String {
    /// True when this normalized metadata key contains any of the given tag names.
    func matchesTag(_ names: String...) -> Bool {
        let segments = split(whereSeparator: { $0 == "/" || $0 == "." })
        return names.contains { name in segments.contains { $0.hasSuffix(name) } }
    }

    /// Trims whitespace and drops empty / placeholder tag values.
    var cleanedTag: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else { return nil }
        return trimmed
    }
}

private extension UIImage {
    /// Cover art is often 3000×3000; store something the UI can actually use.
    func downscaled(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Artwork View
/// Shows embedded cover art, falling back to a generated gradient tile.
struct TrackArtworkView: View {
    let fileName: String
    var size: CGFloat
    var cornerRadius: CGFloat = 8
    var iconScale: CGFloat = 0.42

    @ObservedObject private var store = TrackTagStore.shared

    var body: some View {
        Group {
            if let image = store.artwork(for: fileName) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: Self.gradientColors(for: fileName),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: size * iconScale, weight: .light))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Stable per-track colours so a track always looks the same in the list.
    static func gradientColors(for fileName: String) -> [Color] {
        var hash: UInt64 = 5381
        for byte in fileName.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.62, brightness: 0.86),
            Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1.0), saturation: 0.78, brightness: 0.58)
        ]
    }
}
