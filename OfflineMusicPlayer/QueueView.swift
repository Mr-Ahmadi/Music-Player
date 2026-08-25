import SwiftUI

/// "Up Next": the tracks the listener queued by hand, followed by what the
/// normal play order will reach on its own.
struct QueueView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @ObservedObject private var prefs = PlaybackPreferences.shared
    @Environment(\.dismiss) private var dismiss

    /// What plays after the manual queue drains, capped so the list stays useful.
    private var upcomingFromLibrary: [URL] {
        let order = player.playbackOrder()
        guard !order.isEmpty else { return [] }
        let start = player.currentPlayQueueIndex
        guard start >= 0 else { return Array(order.prefix(20)) }

        var result: [URL] = []
        var index = start + 1
        while result.count < 20 {
            if index >= order.count {
                guard prefs.repeatMode == .all else { break }
                index = 0
            }
            if index == start { break }
            result.append(order[index])
            index += 1
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentURL {
                    Section("Now Playing") {
                        QueueRow(url: current, isCurrent: true)
                    }
                }

                if !player.userQueue.isEmpty {
                    Section {
                        ForEach(player.userQueue, id: \.self) { url in
                            QueueRow(url: url, isCurrent: false)
                                .contentShape(Rectangle())
                                .onTapGesture { player.jumpToQueued(url) }
                        }
                        .onDelete { player.removeFromQueue(atOffsets: $0) }
                        .onMove { player.moveInQueue(from: $0, to: $1) }
                    } header: {
                        HStack {
                            Text("Queued by you")
                            Spacer()
                            Button("Clear") { player.clearQueue() }
                                .font(.caption)
                                .textCase(nil)
                        }
                    }
                }

                let upcoming = upcomingFromLibrary
                if !upcoming.isEmpty {
                    Section(prefs.shuffleEnabled ? "Next up (shuffled)" : "Next up") {
                        ForEach(upcoming, id: \.self) { url in
                            QueueRow(url: url, isCurrent: false)
                                .contentShape(Rectangle())
                                .onTapGesture { player.play(url: url) }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        player.playNext(url)
                                    } label: {
                                        Label("Play Next", systemImage: "text.insert")
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                }

                if player.currentURL == nil && player.userQueue.isEmpty && upcoming.isEmpty {
                    Section {
                        Text("Nothing queued yet.")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !player.userQueue.isEmpty { EditButton() }
                }
            }
        }
    }
}

private struct QueueRow: View {
    let url: URL
    let isCurrent: Bool

    @StateObject private var metadataManager = MusicMetadataManager.shared
    @ObservedObject private var tagStore = TrackTagStore.shared

    var body: some View {
        let fileName = url.lastPathComponent
        HStack(spacing: 12) {
            TrackArtworkView(fileName: fileName, size: 40, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(metadataManager.getMetadata(for: fileName).displayName)
                    .font(isCurrent ? .body.bold() : .body)
                    .lineLimit(1)
                if let subtitle = tagStore.cachedTags(for: fileName)?.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.accentColor)
                    .font(.caption)
            }
        }
    }
}
