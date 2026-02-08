import SwiftUI

struct AudioEffectsView: View {
    @StateObject private var settings = AudioSettings.shared
    
    var body: some View {
        Form {
            Section(header: Text("Bass Boost"), footer: Text("Enhance low frequencies for deeper bass")) {
                Toggle("Enable Bass Boost", isOn: $settings.bassBoostEnabled)
                    .tint(.purple)
                
                if settings.bassBoostEnabled {
                    VStack(spacing: 16) {
                        // Visual meter
                        HStack(spacing: 4) {
                            ForEach(0..<12) { i in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(i < Int(settings.bassBoostLevel) ? 
                                          (i < 4 ? Color.green : (i < 8 ? Color.yellow : Color.red)) : 
                                          Color.gray.opacity(0.3))
                                    .frame(height: 24)
                            }
                        }
                        .animation(.easeInOut(duration: 0.1), value: settings.bassBoostLevel)
                        
                        HStack {
                            Image(systemName: "speaker.wave.1.fill")
                                .foregroundColor(.secondary)
                            
                            Slider(
                                value: $settings.bassBoostLevel,
                                in: 0...12,
                                step: 1
                            )
                            .tint(.purple)
                            
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.purple)
                        }
                        
                        Text("\(Int(settings.bassBoostLevel)) dB")
                            .font(.headline)
                            .foregroundColor(.purple)
                    }
                    .padding(.vertical, 8)
                }
            }
            
            Section(footer: Text("Bass boost amplifies frequencies below 100Hz for a fuller sound.")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("Recommended Settings")
                            .fontWeight(.semibold)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Normal listening: 3-6 dB", systemImage: "headphones")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Label("Party mode: 8-10 dB", systemImage: "music.note.house.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Label("Maximum impact: 12 dB", systemImage: "speaker.wave.3.fill")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Audio Effects")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        AudioEffectsView()
    }
}
