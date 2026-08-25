import SwiftUI

/// The compact player docked at the bottom of the library.
/// Tapping the artwork or title opens the full-screen `NowPlayingView`.
struct PlayerView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @ObservedObject private var tagStore = TrackTagStore.shared
    @ObservedObject private var prefs = PlaybackPreferences.shared
    @ObservedObject private var sleepTimer = SleepTimer.shared

    @State private var showNowPlaying = false
    @State private var showQueue = false

    var body: some View {
        VStack(spacing: 12) {
            trackInfoView
            progressView
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
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView().environmentObject(player)
        }
        .sheet(isPresented: $showQueue) {
            QueueView().environmentObject(player)
        }
    }

    // MARK: - Track info
    private var trackInfoView: some View {
        Group {
            if let url = player.currentURL {
                let fileName = url.lastPathComponent
                Button {
                    showNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        TrackArtworkView(fileName: fileName, size: 50)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(metadataManager.getMetadata(for: fileName).displayName)
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 5) {
                                if let subtitle = tagStore.cachedTags(for: fileName)?.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text(url.pathExtension.uppercased())
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                if let position = queuePositionText {
                                    Text("•").foregroundColor(.secondary)
                                    Text(position)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                if let sleep = sleepTimer.displayText {
                                    Image(systemName: "moon.zzz.fill")
                                        .font(.caption2)
                                        .foregroundColor(.indigo)
                                    Text(sleep)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.indigo)
                                }
                            }
                        }

                        Spacer(minLength: 4)

                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the full player")
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

    private var queuePositionText: String? {
        let order = player.playbackOrder()
        guard !order.isEmpty else { return nil }
        guard player.currentPlayQueueIndex >= 0 else { return "— of \(order.count)" }
        return "\(player.currentPlayQueueIndex + 1) of \(order.count)"
    }

    // MARK: - Progress
    private var progressView: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { player.progress },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(1, player.duration),
                onEditingChanged: { editing in
                    if editing {
                        player.beginScrubbing()
                    } else {
                        player.endScrubbing(finalPosition: player.progress)
                    }
                }
            )
            .disabled(player.currentURL == nil)
            .tint(.accentColor)

            HStack {
                Text(timeString(player.progress))
                Spacer()
                if prefs.playbackRate != 1.0 {
                    Text(prefs.rateLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .cornerRadius(4)
                    Spacer()
                }
                Text(timeString(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Controls
    private var controlsView: some View {
        HStack {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(prefs.shuffleEnabled ? .accentColor : .secondary)
            }
            .frame(width: 40, height: 40)
            .accessibilityLabel(prefs.shuffleEnabled ? "Shuffle on" : "Shuffle off")

            Spacer(minLength: 0)

            Button { player.previousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
                    .foregroundColor(player.tracks.isEmpty ? .secondary.opacity(0.55) : .primary)
            }
            .disabled(player.tracks.isEmpty)
            .accessibilityLabel("Previous track")

            Spacer(minLength: 0)

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(player.currentURL == nil ? Color.secondary.opacity(0.2) : Color.accentColor)
                        .frame(width: 58, height: 58)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }
            .disabled(player.currentURL == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer(minLength: 0)

            Button { player.nextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .foregroundColor(player.tracks.isEmpty ? .secondary.opacity(0.55) : .primary)
            }
            .disabled(player.tracks.isEmpty)
            .accessibilityLabel("Next track")

            Spacer(minLength: 0)

            Button {
                showQueue = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(player.userQueue.isEmpty ? .secondary : .accentColor)
                    if !player.userQueue.isEmpty {
                        Text("\(player.userQueue.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Circle().fill(Color.accentColor))
                            .offset(x: 9, y: -8)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .accessibilityLabel("Up next")
        }
    }

    // MARK: - Helpers
    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Previews
#if DEBUG
struct PlayerView_Previews: PreviewProvider {
    static var previews: some View {
        PlayerView()
            .environmentObject(AudioPlayer())
            .padding()
    }
}
#endif
