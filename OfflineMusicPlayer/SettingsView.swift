import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var player: AudioPlayer
    @ObservedObject private var prefs = PlaybackPreferences.shared
    @ObservedObject private var eq = EqualizerSettings.shared
    @ObservedObject private var sleepTimer = SleepTimer.shared
    @ObservedObject private var crossfade = CrossfadeSettings.shared
    @StateObject private var metadataManager = MusicMetadataManager.shared

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Playback
                Section(header: Label("Playback", systemImage: "play.circle.fill")) {
                    Toggle(isOn: $prefs.shuffleEnabled) {
                        Label("Shuffle", systemImage: "shuffle")
                    }

                    Picker(selection: $prefs.repeatMode) {
                        ForEach(RepeatMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    } label: {
                        Label("Repeat", systemImage: "repeat")
                    }

                    Picker(selection: $prefs.playbackRate) {
                        ForEach(PlaybackPreferences.speeds, id: \.self) { speed in
                            Text(PlaybackPreferences.label(for: speed)).tag(speed)
                        }
                    } label: {
                        Label("Speed", systemImage: "speedometer")
                    }

                    Picker(selection: $prefs.skipInterval) {
                        ForEach(PlaybackPreferences.skipIntervals, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    } label: {
                        Label("Skip Interval", systemImage: "goforward")
                    }
                }

                // MARK: - Sound
                Section(header: Label("Sound", systemImage: "waveform")) {
                    NavigationLink(destination: AudioEffectsView()) {
                        settingRow(
                            title: "Equalizer",
                            detail: eq.summary,
                            systemImage: "slider.vertical.3",
                            color: .purple
                        )
                    }

                    NavigationLink(destination: CrossfadeSettingsView()) {
                        settingRow(
                            title: "Crossfade",
                            detail: crossfade.isEnabled
                                ? "\(String(format: "%.1f", crossfade.duration))s • \(crossfade.curve.rawValue)"
                                : "Off",
                            systemImage: "waveform.circle.fill",
                            color: .blue
                        )
                    }

                    NavigationLink(destination: SleepTimerView()) {
                        settingRow(
                            title: "Sleep Timer",
                            detail: sleepTimer.displayText ?? "Off",
                            systemImage: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz",
                            color: .indigo
                        )
                    }
                }

                // MARK: - Library
                Section(header: Label("Library", systemImage: "music.note.list")) {
                    NavigationLink(destination: LabelManagementView()) {
                        settingRow(title: "Manage Labels", detail: "\(metadataManager.labels.count)",
                                   systemImage: "tag.fill", color: .orange)
                    }

                    NavigationLink(destination: LabelPlaybackFilterView()) {
                        settingRow(
                            title: "Play by Labels",
                            detail: player.labelFilterIds.isEmpty ? "All tracks" : "\(player.labelFilterIds.count) active",
                            systemImage: "line.3.horizontal.decrease.circle.fill",
                            color: .green
                        )
                    }

                    Picker(selection: $prefs.librarySort) {
                        ForEach(LibrarySort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    } label: {
                        Label("Sort Library", systemImage: "arrow.up.arrow.down")
                    }
                }

                // MARK: - About
                Section(header: Label("About", systemImage: "info.circle")) {
                    LabeledContent {
                        Text("1.1.0").foregroundColor(.secondary)
                    } label: {
                        Label("Version", systemImage: "number.circle.fill")
                    }

                    LabeledContent {
                        Text("\(player.tracks.count)")
                            .font(.headline)
                            .foregroundColor(.accentColor)
                    } label: {
                        Label("Tracks", systemImage: "music.note")
                    }

                    LabeledContent {
                        Text("\(metadataManager.favoriteFileNames.count)")
                            .font(.headline)
                            .foregroundColor(.pink)
                    } label: {
                        Label("Favorites", systemImage: "heart.fill")
                    }

                    LabeledContent {
                        Text(librarySizeText).foregroundColor(.secondary)
                    } label: {
                        Label("Storage Used", systemImage: "internaldrive")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func settingRow(title: String, detail: String, systemImage: String, color: Color) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundColor(color)
        }
    }

    /// Total on-disk size of the imported audio files.
    private var librarySizeText: String {
        let bytes = player.tracks.reduce(Int64(0)) { total, url in
            guard let resolved = player.resolvedURL(for: url),
                  let values = try? resolved.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return total }
            return total + Int64(size)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AudioPlayer())
}
