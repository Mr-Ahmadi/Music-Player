import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var player: AudioPlayer
    @ObservedObject private var jogSettings = JogEffectSettings.shared
    @ObservedObject private var audioSettings = AudioSettings.shared

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Playback Section
                Section(header: Label("Playback", systemImage: "play.circle.fill")) {
                    Toggle(isOn: $jogSettings.isEnabled) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DJ Scrubbing")
                                Text("Vinyl scratch effect when seeking")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } icon: {
                            Image(systemName: "dial.medium.fill")
                                .foregroundColor(.orange)
                        }
                    }
                    .tint(.orange)
                    
                    NavigationLink(destination: CrossfadeSettingsView()) {
                        Label {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Crossfade")
                                    if CrossfadeSettings.shared.isEnabled {
                                        Text("\(String(format: "%.1f", CrossfadeSettings.shared.duration))s • \(CrossfadeSettings.shared.curve.rawValue)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        } icon: {
                            Image(systemName: "waveform.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                }
                
                // MARK: - Audio Effects Section
                Section(header: Label("Audio Effects", systemImage: "slider.horizontal.3")) {
                    NavigationLink(destination: AudioEffectsView()) {
                        Label {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Bass Boost")
                                    if audioSettings.bassBoostEnabled {
                                        Text("+\(Int(audioSettings.bassBoostLevel)) dB")
                                            .font(.caption)
                                            .foregroundColor(.purple)
                                    } else {
                                        Text("Off")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        } icon: {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundColor(.purple)
                        }
                    }
                }
                
                // MARK: - Music Organization Section
                Section(header: Label("Library", systemImage: "music.note.list")) {
                    NavigationLink(destination: LabelManagementView()) {
                        Label("Manage Labels", systemImage: "tag.fill")
                            .foregroundColor(.primary)
                    }
                    .tint(.orange)
                    
                    NavigationLink(destination: LabelPlaybackFilterView()) {
                        Label {
                            HStack {
                                Text("Play by Labels")
                                Spacer()
                                if !player.labelFilterIds.isEmpty {
                                    Text("\(player.labelFilterIds.count) active")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.15))
                                        .cornerRadius(8)
                                }
                            }
                        } icon: {
                            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                
                // MARK: - About Section
                Section(header: Label("About", systemImage: "info.circle")) {
                    HStack {
                        Label("Version", systemImage: "number.circle.fill")
                            .foregroundColor(.primary)
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Label("Tracks", systemImage: "music.note")
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(player.tracks.count)")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AudioPlayer())
}

