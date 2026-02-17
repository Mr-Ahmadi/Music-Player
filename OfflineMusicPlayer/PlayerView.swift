import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @ObservedObject private var jogSettings = JogEffectSettings.shared
    @State private var lastSeekProgress: Double = 0
    @State private var lastSeekTime: Date = .distantPast
    
    var body: some View {
        VStack(spacing: 12) {
            // Track info with artwork placeholder
            trackInfoView
            
            // Progress slider
            progressView
            
            // Playback controls
            controlsView
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
    
    // MARK: - Subviews
    private var trackInfoView: some View {
        Group {
            if let url = player.currentURL {
                HStack(spacing: 12) {
                    // Mini artwork
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(LinearGradient(
                                gradient: Gradient(colors: [Color(red: 0.07, green: 0.75, blue: 0.89), Color(red: 0.04, green: 0.52, blue: 0.82)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                        
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                    .frame(width: 50, height: 50)
                    
                    // Track info (use display name from metadata)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metadataManager.getMetadata(for: url.lastPathComponent).displayName)
                            .font(.headline)
                            .lineLimit(2)
                        
                        HStack {
                            Text(url.pathExtension.uppercased())
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if !player.labelFilterIds.isEmpty {
                                let queue = player.getPlayQueue()
                                if !queue.isEmpty {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text(player.currentPlayQueueIndex >= 0 ? "\(player.currentPlayQueueIndex + 1) of \(queue.count)" : "— of \(queue.count)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            } else if player.currentTrackIndex >= 0 {
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text("\(player.currentTrackIndex + 1) of \(player.tracks.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    
                    Spacer()
                }
            } else {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(UIColor.tertiarySystemGroupedBackground))
                        
                        Image(systemName: "music.note.list")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 50, height: 50)
                    
                    Text("No track selected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
            }
        }
    }
    
    private var progressView: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { player.progress },
                    set: { newValue in
                        player.seek(to: newValue)
                    }
                ),
                in: 0...max(1, player.duration),
                onEditingChanged: { editing in
                    if editing {
                        lastSeekProgress = player.progress
                        lastSeekTime = Date()
                        player.beginScrubbing()
                    } else {
                        player.endScrubbing(finalPosition: player.progress)
                    }
                }
            )
            .disabled(player.currentURL == nil)
            .accentColor(.accentColor)
            .tint(.accentColor)
            
            HStack {
                Text(timeString(player.progress))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                
                Spacer()
                
                Text(timeString(player.duration))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }
    
    private var controlsView: some View {
        HStack(spacing: 50) {
            // Previous button
            Button(action: { player.previousTrack() }) {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundColor(player.tracks.isEmpty ? .secondary.opacity(0.55) : .primary)
            }
            .disabled(player.tracks.isEmpty)
            .accessibilityLabel("Previous track")
            
            // Play/Pause button
            Button(action: { player.togglePlayPause() }) {
                ZStack {
                    Circle()
                        .fill(player.currentURL == nil ? Color.secondary.opacity(0.2) : Color.accentColor)
                        .frame(width: 64, height: 64)
                    
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .foregroundColor(.white)
                }
            }
            .disabled(player.currentURL == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            
            // Next button
            Button(action: { player.nextTrack() }) {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundColor(player.tracks.isEmpty ? .secondary.opacity(0.55) : .primary)
            }
            .disabled(player.tracks.isEmpty)
            .accessibilityLabel("Next track")
        }
    }
    
    // MARK: - Helper Methods
    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

// MARK: - Previews
#if DEBUG
struct PlayerView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PlayerView()
                .environmentObject(AudioPlayer())
                .previewDisplayName("Empty State")
            
            PlayerView()
                .environmentObject({
                    let player = AudioPlayer()
                    player.isPlaying = true
                    player.progress = 45.0
                    player.duration = 180.0
                    return player
                }())
                .previewDisplayName("Playing State")
        }
    }
}
#endif
