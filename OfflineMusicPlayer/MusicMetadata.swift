import Foundation
import SwiftUI
import UIKit

// MARK: - Music Label
struct MusicLabel: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var color: String // Hex color representation
    
    init(id: String = UUID().uuidString, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }
    
    var swiftUIColor: Color {
        Color(hex: color)
    }
}

// MARK: - Music Metadata
struct MusicMetadata: Codable, Identifiable {
    let id: String  // File name (unique identifier)
    var displayName: String
    var labels: [String]  // Label IDs
    
    init(id: String, displayName: String, labels: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.labels = labels
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgbValue: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgbValue)
        
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
    
    func toHex() -> String {
        let uiColor = UIColor(self)
        guard let components = uiColor.cgColor.components else { return "#000000" }
        
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

// MARK: - Predefined Label Colors
struct LabelTheme {
    static let colors: [String] = [
        "#FF6B6B",  // Red
        "#4ECDC4",  // Teal
        "#45B7D1",  // Blue
        "#FFA07A",  // Light Salmon
        "#98D8C8",  // Mint
        "#F7DC6F",  // Yellow
        "#BB8FCE",  // Purple
        "#85C1E2",  // Sky Blue
        "#F8B4D4",  // Pink
        "#A8E6CF",  // Light Green
        "#FFD3B6",  // Peach
        "#FF8A80",  // Deep Orange
    ]
}

// MARK: - Default Labels
extension MusicLabel {
    static let defaultLabels: [MusicLabel] = [
        MusicLabel(name: "Dance", color: LabelTheme.colors[0]),
        MusicLabel(name: "Sad", color: LabelTheme.colors[6]),
        MusicLabel(name: "Hot", color: LabelTheme.colors[5]),
    ]
}
