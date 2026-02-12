import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var player: AudioPlayer

    private var showKeepSharedTrackSheet: Bool {
        !player.pendingSharedTrackURLs.isEmpty
    }

    var body: some View {
        TabView {
            ContentView()
                .environmentObject(player)
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

            InsightsView()
                .environmentObject(player)
                .tabItem {
                    Label("Insights", systemImage: "chart.bar.doc.horizontal")
                }
            
            SettingsView()
                .environmentObject(player)
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .sheet(isPresented: Binding(
            get: { showKeepSharedTrackSheet },
            set: { if !$0 { self.player.clearPendingSharedTracks() } }
        )) {
            if !player.pendingSharedTrackURLs.isEmpty {
                KeepSharedTrackSheet(
                    fileNames: player.pendingSharedTrackURLs.map { $0.lastPathComponent },
                    onKeep: {
                        self.player.confirmKeepSharedTracks()
                    },
                    onDontKeep: {
                        self.player.clearPendingSharedTracks()
                    }
                )
            }
        }
    }
}

// MARK: - Keep shared track prompt (e.g. from Telegram)
struct KeepSharedTrackSheet: View {
    let fileNames: [String]
    let onKeep: () -> Void
    let onDontKeep: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 50))
                    .foregroundStyle(.tint)

                Text("Add to library?")
                    .font(.title2.bold())

                if fileNames.count == 1 {
                    Text(fileNames[0])
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("\(fileNames.count) audio files")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(fileNames.prefix(3).joined(separator: "\n") + (fileNames.count > 3 ? "\n...and \(fileNames.count - 3) more" : ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                Text("These files were shared to the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 16) {
                    Button("Don't Keep") {
                        onDontKeep()
                    }
                    .buttonStyle(.bordered)

                    Button("Keep All") {
                        onKeep()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Shared Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDontKeep()
                    }
                }
            }
        }
    }
}
