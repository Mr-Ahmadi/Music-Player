import Foundation
import Combine

// MARK: - EQ Preset
/// A named set of gains, one per band of `EqualizerSettings.frequencies`.
struct EQPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let systemImage: String
    let gains: [Float]

    static let custom = EQPreset(id: "custom", name: "Custom", systemImage: "slider.vertical.3", gains: [])

    /// Built-in presets. Gains are in dB and follow the 10 ISO bands below.
    ///                                              32   64  125  250  500   1k   2k   4k   8k  16k
    static let builtIn: [EQPreset] = [
        EQPreset(id: "flat",       name: "Flat",        systemImage: "equal",
                 gains: [  0,   0,   0,   0,   0,   0,   0,   0,   0,   0]),
        EQPreset(id: "bass",       name: "Bass Boost",  systemImage: "speaker.wave.3.fill",
                 gains: [  8,   7,   5,   3,   1,   0,   0,   0,   1,   2]),
        EQPreset(id: "deepbass",   name: "Deep Bass",   systemImage: "waveform.path.ecg",
                 gains: [ 11,   9,   6,   2,  -1,  -2,   0,   1,   2,   3]),
        EQPreset(id: "bassreduce", name: "Bass Reducer",systemImage: "speaker.wave.1",
                 gains: [ -7,  -6,  -4,  -2,   0,   0,   0,   0,   0,   0]),
        EQPreset(id: "vocal",      name: "Vocal Boost", systemImage: "mic.fill",
                 gains: [ -3,  -2,  -1,   2,   4,   5,   4,   2,   0,  -1]),
        EQPreset(id: "treble",     name: "Treble Boost",systemImage: "sparkles",
                 gains: [  0,   0,   0,   0,   0,   1,   3,   5,   7,   8]),
        EQPreset(id: "rock",       name: "Rock",        systemImage: "guitars.fill",
                 gains: [  6,   5,   3,   1,  -1,  -1,   1,   3,   5,   6]),
        EQPreset(id: "pop",        name: "Pop",         systemImage: "star.fill",
                 gains: [ -2,  -1,   0,   3,   5,   4,   2,   0,  -1,  -2]),
        EQPreset(id: "electronic", name: "Electronic",  systemImage: "waveform",
                 gains: [  7,   6,   2,   0,  -2,   1,   2,   4,   6,   7]),
        EQPreset(id: "hiphop",     name: "Hip-Hop",     systemImage: "music.mic",
                 gains: [  9,   7,   3,   2,  -1,  -1,   1,   2,   3,   4]),
        EQPreset(id: "jazz",       name: "Jazz",        systemImage: "pianokeys",
                 gains: [  4,   3,   1,   2,  -1,  -1,   0,   2,   3,   4]),
        EQPreset(id: "classical",  name: "Classical",   systemImage: "music.quarternote.3",
                 gains: [  5,   4,   3,   2,  -1,  -1,   0,   2,   3,   4]),
        EQPreset(id: "podcast",    name: "Podcast",     systemImage: "waveform.and.mic",
                 gains: [ -6,  -4,   0,   3,   6,   6,   4,   1,  -2,  -4]),
        EQPreset(id: "lateNight",  name: "Late Night",  systemImage: "moon.stars.fill",
                 gains: [  3,   2,   1,   1,   2,   2,   1,   0,  -1,  -2]),
    ]

    static func preset(withId id: String) -> EQPreset? {
        builtIn.first { $0.id == id }
    }
}

// MARK: - Equalizer Settings
/// A 10-band parametric equalizer with a preamp, persisted across launches.
/// `AudioPlayer` observes this and applies changes to the live `AVAudioUnitEQ` in real time.
final class EqualizerSettings: ObservableObject {
    static let shared = EqualizerSettings()

    /// ISO standard 10-band centre frequencies (Hz).
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandCount = frequencies.count
    /// Maximum absolute gain per band, in dB.
    static let gainRange: ClosedRange<Float> = -12...12
    /// Preamp range, in dB.
    static let preampRange: ClosedRange<Float> = -12...12

    @Published var isEnabled: Bool = false {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }

    /// Per-band gain in dB, always `bandCount` entries long.
    @Published var gains: [Float] = Array(repeating: 0, count: EqualizerSettings.bandCount) {
        didSet {
            if gains.count != Self.bandCount {
                gains = Self.normalize(gains)
                return
            }
            defaults.set(gains, forKey: Keys.gains)
        }
    }

    /// Overall output gain in dB, applied before the bands.
    @Published var preamp: Float = 0 {
        didSet {
            let clamped = min(max(preamp, Self.preampRange.lowerBound), Self.preampRange.upperBound)
            if clamped != preamp {
                preamp = clamped
                return
            }
            defaults.set(preamp, forKey: Keys.preamp)
        }
    }

    /// Id of the currently selected preset, or `EQPreset.custom.id` when the
    /// user has nudged a band by hand.
    @Published private(set) var presetId: String = EQPreset.custom.id {
        didSet { defaults.set(presetId, forKey: Keys.preset) }
    }

    private enum Keys {
        static let enabled = "equalizerEnabled"
        static let gains = "equalizerGains"
        static let preamp = "equalizerPreamp"
        static let preset = "equalizerPresetId"
        static let migrated = "equalizerMigratedFromBassBoost"
    }

    private let defaults = UserDefaults.standard

    private init() {
        isEnabled = defaults.bool(forKey: Keys.enabled)

        if let saved = defaults.array(forKey: Keys.gains) as? [NSNumber] {
            gains = Self.normalize(saved.map { $0.floatValue })
        }

        preamp = defaults.float(forKey: Keys.preamp)
        presetId = defaults.string(forKey: Keys.preset) ?? EQPreset.custom.id

        migrateLegacyBassBoostIfNeeded()
    }

    // MARK: - Mutation
    func apply(preset: EQPreset) {
        guard !preset.gains.isEmpty else {
            presetId = EQPreset.custom.id
            return
        }
        gains = Self.normalize(preset.gains)
        presetId = preset.id
        if !isEnabled { isEnabled = true }
    }

    /// Updates a single band and marks the preset as custom.
    func setGain(_ value: Float, forBand index: Int) {
        guard gains.indices.contains(index) else { return }
        let clamped = min(max(value, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        guard gains[index] != clamped else { return }
        gains[index] = clamped
        if presetId != EQPreset.custom.id, !matchesCurrentPreset {
            presetId = EQPreset.custom.id
        }
    }

    func resetToFlat() {
        gains = Array(repeating: 0, count: Self.bandCount)
        preamp = 0
        presetId = "flat"
    }

    var currentPreset: EQPreset {
        EQPreset.preset(withId: presetId) ?? EQPreset.custom
    }

    private var matchesCurrentPreset: Bool {
        guard let preset = EQPreset.preset(withId: presetId) else { return false }
        return Self.normalize(preset.gains) == gains
    }

    /// A short summary for settings rows, e.g. "Rock • +3 dB preamp".
    var summary: String {
        guard isEnabled else { return "Off" }
        var parts = [currentPreset.name]
        if preamp != 0 {
            parts.append(String(format: "%+.0f dB preamp", preamp))
        }
        return parts.joined(separator: " • ")
    }

    // MARK: - Helpers
    static func label(forFrequency hz: Float) -> String {
        hz >= 1000 ? "\(Int(hz / 1000))k" : "\(Int(hz))"
    }

    private static func normalize(_ values: [Float]) -> [Float] {
        var result = Array(values.prefix(bandCount))
        if result.count < bandCount {
            result.append(contentsOf: Array(repeating: 0, count: bandCount - result.count))
        }
        return result.map { min(max($0, gainRange.lowerBound), gainRange.upperBound) }
    }

    /// Carries the old single-slider bass boost over to the new 10-band EQ once,
    /// so upgrading users keep the sound they had.
    private func migrateLegacyBassBoostIfNeeded() {
        guard !defaults.bool(forKey: Keys.migrated) else { return }
        defaults.set(true, forKey: Keys.migrated)

        guard defaults.bool(forKey: "bassBoostEnabled") else { return }
        let legacyLevel = defaults.float(forKey: "bassBoostLevel")
        let level = legacyLevel > 0 ? legacyLevel : 6.0
        // The old EQ was a 45 Hz shelf + 80 Hz peak at `level` dB, plus a fixed
        // 12 kHz clarity lift at level/3.
        let scale = min(max(level / 12.0, 0), 1)
        gains = Self.normalize([
            level, level * 0.85, level * 0.5, level * 0.2, 0, 0, 0, 0, 2 * scale, 3 * scale
        ])
        presetId = EQPreset.custom.id
        isEnabled = true
    }
}
