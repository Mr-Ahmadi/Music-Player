import Foundation

/// When enabled, scrubbing the progress bar applies a DJ jog-wheel style pitch/speed effect.
final class JogEffectSettings: NSObject, ObservableObject {
    static let shared = JogEffectSettings()

    @Published var isEnabled: Bool = false {
        didSet { saveToDisk() }
    }

    private let isEnabledKey = "jogEffectEnabled"

    private override init() {
        super.init()
        loadFromDisk()
    }

    private func saveToDisk() {
        UserDefaults.standard.set(isEnabled, forKey: isEnabledKey)
    }

    private func loadFromDisk() {
        isEnabled = UserDefaults.standard.bool(forKey: isEnabledKey)
    }
}
