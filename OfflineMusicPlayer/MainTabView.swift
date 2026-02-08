import SwiftUI

struct MainTabView: View {
    @EnvironmentObject var player: AudioPlayer

    private var showKeepSharedTrackSheet: Bool {
        player.pendingSharedTrackURL != nil
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
            set: { if !$0 { player.clearPendingSharedTrack() } }
        )) {
            if let url = player.pendingSharedTrackURL {
                KeepSharedTrackSheet(
                    fileName: url.lastPathComponent,
                    onKeep: {
                        player.confirmKeepSharedTrack()
                    },
                    onDontKeep: {
                        player.clearPendingSharedTrack()
                    }
                )
            }
        }
    }
}

// MARK: - Keep shared track prompt (e.g. from Telegram)
struct KeepSharedTrackSheet: View {
    let fileName: String
    let onKeep: () -> Void
    let onDontKeep: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Image(systemName: "music.note")
                    .font(.system(size: 50))
                    .foregroundStyle(.tint)

                Text("Add to library?")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(fileName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Text("This file was shared to the app.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(spacing: 16) {
                    Button("Don't Keep") {
                        onDontKeep()
                    }
                    .buttonStyle(.bordered)

                    Button("Keep") {
                        onKeep()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)

                Spacer()
            }
            .padding(.top, 32)
            .navigationTitle("Shared track")
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
