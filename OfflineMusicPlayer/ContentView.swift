import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: AudioPlayer
    @State private var showingImporter = false
    @State private var searchText = ""
    @State private var shareURL: ShareableURLWrapper?

    var filteredTracks: [URL] {
        if searchText.isEmpty {
            return player.tracks
        } else {
            return player.tracks.filter {
                $0.lastPathComponent.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if player.tracks.isEmpty {
                    emptyStateView
                } else {
                    SearchBar(text: $searchText)

                    if filteredTracks.isEmpty {
                        noResultsView
                    } else {
                        trackListView
                    }
                }

                Divider()

                PlayerView()
                    .environmentObject(player)
                    .background(Color(UIColor.secondarySystemBackground))
            }
            .navigationTitle("Offline Music")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingImporter = true }) {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                        .disabled(player.tracks.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showingImporter) {
            DocumentPicker { urls in
                player.importTracks(urls: urls)
                showingImporter = false
            }
        }
        .sheet(item: $shareURL) { wrapper in
            ShareSheet(items: [wrapper.url])
        }
    }
    
    private func presentShareSheet(for trackURL: URL) {
        guard let resolved = player.resolvedURL(for: trackURL) else { return }
        shareURL = ShareableURLWrapper(url: resolved)
    }

    // MARK: - Subviews
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "music.note.list")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .foregroundStyle(.tint)
                .padding()

            Text("No Tracks")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Import audio files to start listening.\n\nTip: Share music from Telegram, Files, or other apps—tap \"Open in Offline Music Player\". You’ll be asked whether to keep each track in your library.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: { showingImporter = true }) {
                Label("Import Audio Files", systemImage: "square.and.arrow.down")
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .padding(.top)

            Spacer()
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 50))
                .foregroundColor(.secondary)

            Text("No Tracks Found")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Try adjusting your search")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }

    private var trackListView: some View {
        List {
            ForEach(filteredTracks, id: \.self) { url in
                TrackRow(
                    url: url,
                    isPlaying: player.currentURL == url,
                    onTap: { player.play(url: url) },
                    onShare: { presentShareSheet(for: url) }
                )
            }
            .onDelete { indices in
                deleteItems(at: indices)
            }
            .onMove { indices, destination in
                // Find actual indices in the full track list
                let tracksToMove = indices.map { filteredTracks[$0] }
                var newTracks = player.tracks

                // Remove tracks from current positions
                newTracks.removeAll { tracksToMove.contains($0) }

                // Insert at new position
                let insertIndex = min(destination, newTracks.count)
                newTracks.insert(contentsOf: tracksToMove, at: insertIndex)

                player.tracks = newTracks
            }
        }
        .listStyle(PlainListStyle())
    }

    // MARK: - Helper Methods
    private func deleteItems(at offsets: IndexSet) {
        // Convert filtered indices to actual track indices
        let tracksToDelete = offsets.map { filteredTracks[$0] }
        let actualIndices = IndexSet(tracksToDelete.compactMap { player.tracks.firstIndex(of: $0) })
        player.remove(atOffsets: actualIndices)
    }
}

// MARK: - Shareable URL Wrapper (for sheet binding)
struct ShareableURLWrapper: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - TrackRow
struct TrackRow: View {
    let url: URL
    let isPlaying: Bool
    let onTap: () -> Void
    var onShare: (() -> Void)?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Playing indicator
                if isPlaying {
                    Image(systemName: "waveform")
                        .foregroundColor(.accentColor)
                        .imageScale(.medium)
                        .frame(width: 24)
                } else {
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .imageScale(.medium)
                        .frame(width: 24)
                }

                // Track info
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .lineLimit(2)
                        .fontWeight(isPlaying ? .semibold : .regular)
                        .foregroundColor(isPlaying ? .accentColor : .primary)

                    Text(url.pathExtension.uppercased())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button {
                onShare?()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .accessibilityLabel("\(url.deletingPathExtension().lastPathComponent), \(isPlaying ? "now playing" : "tap to play")")
    }
}

// MARK: - SearchBar
struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search tracks...", text: $text)
                    .textFieldStyle(PlainTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(8)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Previews
#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AudioPlayer())
    }
}
#endif
