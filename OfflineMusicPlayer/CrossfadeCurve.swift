import Foundation

/// Crossfade transition curves for Apple Music-style crossfading
enum CrossfadeCurve: String, CaseIterable, Codable {
    case linear = "Linear"
    case easeInOut = "Ease In/Out"      // Apple Music default
    case constantPower = "Constant Power"
    
    var description: String {
        switch self {
        case .linear:
            return "Straight line fade"
        case .easeInOut:
            return "Smooth Apple-style transition"
        case .constantPower:
            return "DJ-style equal loudness"
        }
    }
    
    var icon: String {
        switch self {
        case .linear: return "chart.line.uptrend.xyaxis"
        case .easeInOut: return "waveform.path"
        case .constantPower: return "speaker.wave.3.fill"
        }
    }
}
