import Foundation

/// Audio settings for EQ and effects
final class AudioSettings: NSObject, ObservableObject {
    static let shared = AudioSettings()
    
    @Published var bassBoostEnabled: Bool = false {
        didSet { saveToDisk() }
    }
    
    /// Bass boost level in dB (0-12)
    @Published var bassBoostLevel: Float = 6.0 {
        didSet { saveToDisk() }
    }
    
    private let bassEnabledKey = "bassBoostEnabled"
    private let bassLevelKey = "bassBoostLevel"
    
    private override init() {
        super.init()
        loadFromDisk()
    }
    
    private func saveToDisk() {
        UserDefaults.standard.set(bassBoostEnabled, forKey: bassEnabledKey)
        UserDefaults.standard.set(bassBoostLevel, forKey: bassLevelKey)
    }
    
    private func loadFromDisk() {
        bassBoostEnabled = UserDefaults.standard.bool(forKey: bassEnabledKey)
        let savedLevel = UserDefaults.standard.float(forKey: bassLevelKey)
        bassBoostLevel = savedLevel > 0 ? savedLevel : 6.0
    }
}
