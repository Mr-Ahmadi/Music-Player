import SwiftUI

struct CrossfadeSettingsView: View {
    @StateObject private var crossfade = CrossfadeSettings.shared
    
    var body: some View {
        Form {
            Section(header: Text("Crossfade"), footer: Text("Smooth transition between tracks")) {
                Toggle("Enable Crossfade", isOn: $crossfade.isEnabled)
                    .tint(.blue)
            }
            
            if crossfade.isEnabled {
                Section(header: Text("Duration")) {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Fade Time")
                            Spacer()
                            Text("\(String(format: "%.1f", crossfade.duration))s")
                                .font(.headline)
                                .foregroundColor(.blue)
                        }
                        
                        Slider(
                            value: $crossfade.duration,
                            in: 1.0...12.0,
                            step: 0.5
                        )
                        .tint(.blue)
                        
                        HStack {
                            Text("1s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("12s")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Section(header: Text("Transition Style")) {
                    Picker("Curve", selection: $crossfade.curve) {
                        ForEach(CrossfadeCurve.allCases, id: \.self) { curve in
                            HStack {
                                Image(systemName: curve.icon)
                                Text(curve.rawValue)
                            }
                            .tag(curve)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    
                    // Curve description
                    HStack {
                        Image(systemName: crossfade.curve.icon)
                            .foregroundColor(.blue)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text(crossfade.curve.rawValue)
                                .font(.headline)
                            Text(crossfade.curve.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // Visual curve preview
                Section(header: Text("Preview")) {
                    CurvePreviewView(curve: crossfade.curve)
                        .frame(height: 100)
                        .padding(.vertical, 8)
                }
            }
            
            Section(footer: Text("Apple Music uses Ease In/Out for seamless transitions between songs.")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("How it works")
                            .font(.body.bold())
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Previous track fades out", systemImage: "speaker.wave.2.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Label("Next track fades in", systemImage: "speaker.wave.3.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Label("Smooth overlap transition", systemImage: "waveform.path.ecg")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Crossfade")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CurvePreviewView: View {
    let curve: CrossfadeCurve
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background grid
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    for i in 1..<4 {
                        let x = width * CGFloat(i) / 4
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: height))
                    }
                }
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                
                // Fade out curve (red)
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    path.move(to: CGPoint(x: 0, y: 0))
                    
                    for i in 0...100 {
                        let t = Float(i) / 100.0
                        let y = getCurveValue(t: t, fadeOut: true)
                        let x = CGFloat(i) / 100.0 * width
                        path.addLine(to: CGPoint(x: x, y: CGFloat(1 - y) * height))
                    }
                }
                .stroke(Color.red.opacity(0.8), lineWidth: 3)
                
                // Fade in curve (green)
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    path.move(to: CGPoint(x: 0, y: height))
                    
                    for i in 0...100 {
                        let t = Float(i) / 100.0
                        let y = getCurveValue(t: t, fadeOut: false)
                        let x = CGFloat(i) / 100.0 * width
                        path.addLine(to: CGPoint(x: x, y: CGFloat(1 - y) * height))
                    }
                }
                .stroke(Color.green.opacity(0.8), lineWidth: 3)
                
                // Labels
                VStack {
                    HStack {
                        Text("Out")
                            .font(.caption2)
                            .foregroundColor(.red)
                        Spacer()
                        Text("In")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
    
    private func getCurveValue(t: Float, fadeOut: Bool) -> Float {
        switch curve {
        case .linear:
            return fadeOut ? (1 - t) : t
        case .easeInOut:
            let x = max(0, min(1, t))
            let s = x * x * x * (x * (x * 6 - 15) + 10)
            return fadeOut ? (1 - s) : s
        case .constantPower:
            return fadeOut ? cos(t * .pi / 2) : sin(t * .pi / 2)
        }
    }
}

#Preview {
    NavigationView {
        CrossfadeSettingsView()
    }
}
