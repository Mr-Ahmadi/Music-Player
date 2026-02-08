import Foundation

final class CrossfadeSettings: NSObject, ObservableObject {
    static let shared = CrossfadeSettings()
    
    @Published var isEnabled: Bool = false {
        didSet { saveToDisk() }
    }
    
    @Published var duration: Double = 4.0 {  // Default 4s like Apple Music
        didSet { saveToDisk() }
    }
    
    @Published var curve: CrossfadeCurve = .easeInOut {
        didSet { saveToDisk() }
    }
    
    private let isEnabledKey = "crossfadeEnabled"
    private let durationKey = "crossfadeDuration"
    private let curveKey = "crossfadeCurve"
    
    private override init() {
        super.init()
        loadFromDisk()
    }
    
    private func saveToDisk() {
        UserDefaults.standard.set(isEnabled, forKey: isEnabledKey)
        UserDefaults.standard.set(duration, forKey: durationKey)
        UserDefaults.standard.set(curve.rawValue, forKey: curveKey)
    }
    
    private func loadFromDisk() {
        isEnabled = UserDefaults.standard.bool(forKey: isEnabledKey)
        let savedDuration = UserDefaults.standard.double(forKey: durationKey)
        duration = savedDuration > 0 ? savedDuration : 4.0
        if let savedCurve = UserDefaults.standard.string(forKey: curveKey),
           let curve = CrossfadeCurve(rawValue: savedCurve) {
            self.curve = curve
        }
    }
}
