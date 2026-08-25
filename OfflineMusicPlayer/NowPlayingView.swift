import SwiftUI

/// Full-screen player: large cover art, scrubbing, and every playback control
/// that doesn't fit in the mini player.
struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @ObservedObject private var tagStore = TrackTagStore.shared
    @ObservedObject private var prefs = PlaybackPreferences.shared
    @ObservedObject private var sleepTimer = SleepTimer.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    @State private var showSpeedPicker = false
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0

    private var fileName: String? { player.currentURL?.lastPathComponent }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let artSize = min(geo.size.width - 64, geo.size.height * 0.42)

                VStack(spacing: 0) {
                    Spacer(minLength: 8)

                    artwork(size: artSize)

                    Spacer(minLength: 16)

                    titleBlock
                        .padding(.horizontal, 28)

                    Spacer(minLength: 12)

                    scrubber
                        .padding(.horizontal, 28)

                    Spacer(minLength: 8)

                    transportControls
                        .padding(.horizontal, 24)

                    Spacer(minLength: 12)

                    secondaryControls
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(backgroundGradient.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close player")
                }
                ToolbarItem(placement: .principal) {
                    if let text = sleepTimer.displayText {
                        Label(text, systemImage: "moon.zzz.fill")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.indigo)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showQueue = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Up next")
                }
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueView().environmentObject(player)
        }
    }

    // MARK: - Artwork
    private func artwork(size: CGFloat) -> some View {
        Group {
            if let fileName {
                TrackArtworkView(fileName: fileName, size: size, cornerRadius: 16, iconScale: 0.28)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.system(size: size * 0.2))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
        .scaleEffect(player.isPlaying ? 1.0 : 0.94)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: player.isPlaying)
    }

    // MARK: - Title
    private var titleBlock: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentTitle)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(currentSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let fileName {
                Button {
                    metadataManager.toggleFavorite(fileName: fileName)
                } label: {
                    Image(systemName: metadataManager.isFavorite(fileName: fileName) ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundColor(metadataManager.isFavorite(fileName: fileName) ? .pink : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(metadataManager.isFavorite(fileName: fileName) ? "Remove from favorites" : "Add to favorites")
            }
        }
    }

    private var currentTitle: String {
        guard let fileName else { return "Nothing playing" }
        return metadataManager.getMetadata(for: fileName).displayName
    }

    private var currentSubtitle: String {
        guard let fileName else { return "Pick a track from your library" }
        if let subtitle = tagStore.cachedTags(for: fileName)?.subtitle { return subtitle }
        let order = player.playbackOrder()
        if player.currentPlayQueueIndex >= 0 {
            return "\(player.currentPlayQueueIndex + 1) of \(order.count)"
        }
        return player.currentURL?.pathExtension.uppercased() ?? ""
    }

    // MARK: - Scrubber
    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : player.progress },
                    set: { newValue in
                        scrubPosition = newValue
                        player.seek(to: newValue)
                    }
                ),
                in: 0...max(1, player.duration),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        scrubPosition = player.progress
                        player.beginScrubbing()
                    } else {
                        player.endScrubbing(finalPosition: scrubPosition)
                    }
                }
            )
            .disabled(player.currentURL == nil)
            .tint(.accentColor)

            HStack {
                Text(timeString(isScrubbing ? scrubPosition : player.progress))
                Spacer()
                Text("-" + timeString(max(0, player.duration - (isScrubbing ? scrubPosition : player.progress))))
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Transport
    private var transportControls: some View {
        HStack {
            Button {
                player.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(prefs.shuffleEnabled ? .accentColor : .secondary)
            }
            .accessibilityLabel(prefs.shuffleEnabled ? "Shuffle on" : "Shuffle off")

            Spacer()

            Button { player.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 28))
            }
            .disabled(player.tracks.isEmpty)

            Spacer()

            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(player.currentURL == nil ? Color.secondary.opacity(0.25) : Color.accentColor)
                        .frame(width: 76, height: 76)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white)
                }
            }
            .disabled(player.currentURL == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Spacer()

            Button { player.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 28))
            }
            .disabled(player.tracks.isEmpty)

            Spacer()

            Button {
                player.cycleRepeatMode()
            } label: {
                Image(systemName: prefs.repeatMode.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(prefs.repeatMode == .off ? .secondary : .accentColor)
            }
            .accessibilityLabel(prefs.repeatMode.title)
        }
        .foregroundColor(.primary)
    }

    // MARK: - Secondary row
    private var secondaryControls: some View {
        HStack(spacing: 0) {
            pill(icon: "gobackward.\(prefs.skipInterval)", fallbackIcon: "gobackward", label: nil) {
                player.skipBackward()
            }
            .accessibilityLabel("Skip back \(prefs.skipInterval) seconds")

            Spacer()

            Menu {
                Picker("Speed", selection: $prefs.playbackRate) {
                    ForEach(PlaybackPreferences.speeds, id: \.self) { speed in
                        Text(PlaybackPreferences.label(for: speed)).tag(speed)
                    }
                }
            } label: {
                pillLabel(icon: "speedometer", label: prefs.rateLabel, highlighted: prefs.playbackRate != 1.0)
            }
            .accessibilityLabel("Playback speed \(prefs.rateLabel)")

            Spacer()

            NavigationLink {
                SleepTimerView()
            } label: {
                pillLabel(
                    icon: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz",
                    label: nil,
                    highlighted: sleepTimer.isActive
                )
            }
            .accessibilityLabel("Sleep timer")

            Spacer()

            NavigationLink {
                AudioEffectsView()
            } label: {
                pillLabel(
                    icon: "slider.vertical.3",
                    label: nil,
                    highlighted: EqualizerSettings.shared.isEnabled
                )
            }
            .accessibilityLabel("Equalizer")

            Spacer()

            pill(icon: "goforward.\(prefs.skipInterval)", fallbackIcon: "goforward", label: nil) {
                player.skipForward()
            }
            .accessibilityLabel("Skip forward \(prefs.skipInterval) seconds")
        }
    }

    private func pill(icon: String, fallbackIcon: String, label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Not every interval has a matching SF Symbol (e.g. gobackward.20).
            pillLabel(icon: UIImage(systemName: icon) != nil ? icon : fallbackIcon, label: label, highlighted: false)
        }
        .buttonStyle(.plain)
    }

    private func pillLabel(icon: String, label: String?, highlighted: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
            if let label {
                Text(label)
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .foregroundColor(highlighted ? .accentColor : .secondary)
        .frame(minWidth: 44, minHeight: 34)
        .contentShape(Rectangle())
    }

    // MARK: - Background
    private var backgroundGradient: some View {
        let colors: [Color] = fileName.map { TrackArtworkView.gradientColors(for: $0) } ?? [.gray, .black]
        return LinearGradient(
            colors: [
                colors[0].opacity(0.35),
                Color(UIColor.systemBackground),
                Color(UIColor.systemBackground)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

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
