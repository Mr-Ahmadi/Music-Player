import Foundation
import Combine
import SwiftUI

// MARK: - Repeat Mode
enum RepeatMode: String, Codable, CaseIterable, Identifiable {
    case off
    case all
    case one

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Repeat Off"
        case .all: return "Repeat All"
        case .one: return "Repeat One"
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    /// Cycles off -> all -> one -> off
    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

// MARK: - Library Sort
enum LibrarySort: String, Codable, CaseIterable, Identifiable {
    case custom
    case title
    case titleDescending
    case mostPlayed
    case recentlyPlayed
    case longest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .custom: return "My Order"
        case .title: return "Title (A–Z)"
        case .titleDescending: return "Title (Z–A)"
        case .mostPlayed: return "Most Played"
        case .recentlyPlayed: return "Recently Played"
        case .longest: return "Longest First"
        }
    }

    var systemImage: String {
        switch self {
        case .custom: return "line.3.horizontal"
        case .title: return "textformat.abc"
        case .titleDescending: return "textformat.abc"
        case .mostPlayed: return "flame"
        case .recentlyPlayed: return "clock.arrow.circlepath"
        case .longest: return "hourglass"
        }
    }
}

// MARK: - Playback Preferences
/// User-facing playback behaviour: shuffle, repeat, speed and skip interval.
/// Persisted in UserDefaults so the player restores exactly how it was left.
final class PlaybackPreferences: ObservableObject {
    static let shared = PlaybackPreferences()

    /// Available playback speeds, in the order shown in the UI.
    static let speeds: [Float] = [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]
    /// Available skip intervals in seconds for the lock screen / player skip buttons.
    static let skipIntervals: [Int] = [5, 10, 15, 30, 45, 60]

    @Published var shuffleEnabled: Bool = false {
        didSet { defaults.set(shuffleEnabled, forKey: Keys.shuffle) }
    }

    @Published var repeatMode: RepeatMode = .all {
        didSet { defaults.set(repeatMode.rawValue, forKey: Keys.repeatMode) }
    }

    /// Playback rate. 1.0 is normal speed; pitch is preserved at every rate.
    @Published var playbackRate: Float = 1.0 {
        didSet {
            let clamped = min(max(playbackRate, 0.5), 2.0)
            if clamped != playbackRate {
                playbackRate = clamped
                return
            }
            defaults.set(playbackRate, forKey: Keys.rate)
        }
    }

    @Published var skipInterval: Int = 15 {
        didSet { defaults.set(skipInterval, forKey: Keys.skipInterval) }
    }

    /// Sort order applied to the library list.
    @Published var librarySort: LibrarySort = .custom {
        didSet { defaults.set(librarySort.rawValue, forKey: Keys.librarySort) }
    }

    /// When true the library only shows favourited tracks.
    @Published var showFavoritesOnly: Bool = false {
        didSet { defaults.set(showFavoritesOnly, forKey: Keys.favoritesOnly) }
    }

    private enum Keys {
        static let shuffle = "playbackShuffleEnabled"
        static let repeatMode = "playbackRepeatMode"
        static let rate = "playbackRate"
        static let skipInterval = "playbackSkipInterval"
        static let librarySort = "librarySortOrder"
        static let favoritesOnly = "libraryFavoritesOnly"
    }

    private let defaults = UserDefaults.standard

    private init() {
        shuffleEnabled = defaults.bool(forKey: Keys.shuffle)

        if let raw = defaults.string(forKey: Keys.repeatMode), let mode = RepeatMode(rawValue: raw) {
            repeatMode = mode
        }

        let savedRate = defaults.float(forKey: Keys.rate)
        playbackRate = savedRate > 0 ? min(max(savedRate, 0.5), 2.0) : 1.0

        let savedSkip = defaults.integer(forKey: Keys.skipInterval)
        skipInterval = Self.skipIntervals.contains(savedSkip) ? savedSkip : 15

        if let raw = defaults.string(forKey: Keys.librarySort), let sort = LibrarySort(rawValue: raw) {
            librarySort = sort
        }

        showFavoritesOnly = defaults.bool(forKey: Keys.favoritesOnly)
    }

    /// Formatted speed label, e.g. "1×" or "1.25×".
    var rateLabel: String { Self.label(for: playbackRate) }

    static func label(for rate: Float) -> String {
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        return String(format: "%g×", rate)
    }
}
