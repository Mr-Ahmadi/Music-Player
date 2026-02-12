import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @State private var showingImporter = false
    @State private var searchText = ""
    @State private var shareURL: ShareableURLWrapper?
    @State private var selection = Set<URL>()
    @State private var isEditingSelection = false

    var filteredTracks: [URL] {
        if searchText.isEmpty {
            return player.tracks
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return player.tracks.filter { url in
            let fileName = url.lastPathComponent
            let meta = metadataManager.getMetadata(for: fileName)
            if meta.displayName.localizedCaseInsensitiveContains(query) { return true }
            if fileName.localizedCaseInsensitiveContains(query) { return true }
            let labelNames = meta.labels.compactMap { id in metadataManager.labels.first(where: { $0.id == id })?.name }
            return labelNames.contains { $0.localizedCaseInsensitiveContains(query) }
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

                ToolbarItemGroup(placement: .navigationBarLeading) {
                    if !selection.isEmpty {
                        HStack(spacing: 12) {
                            Button(action: {
                                let urls = Array(selection).compactMap { player.resolvedURL(for: $0) }
                                shareURL = ShareableURLWrapper(urls: urls)
                            }) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            
                            Button(action: {
                                selection.removeAll()
                            }) {
                                Text("\(selection.count) Selected")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.accentColor.opacity(0.2))
                                    .cornerRadius(6)
                            }
                        }
                    } else {
                        Button(action: {
                            isEditingSelection = !isEditingSelection
                        }) {
                            Image(systemName: isEditingSelection ? "checkmark" : "square.on.square")
                        }
                        .disabled(player.tracks.isEmpty)
                    }
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
            ShareSheet(items: wrapper.urls)
        }
    }
    
    private func presentShareSheet(for trackURL: URL) {
        guard let resolved = player.resolvedURL(for: trackURL) else { return }
        shareURL = ShareableURLWrapper(urls: [resolved])
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
        List(selection: $selection) {
            ForEach(filteredTracks, id: \.self) { url in
                TrackRow(
                    url: url,
                    isPlaying: player.currentURL == url,
                    isSelected: selection.contains(url),
                    onTap: { 
                        if isEditingSelection {
                            if selection.contains(url) {
                                selection.remove(url)
                            } else {
                                selection.insert(url)
                            }
                        } else {
                            player.play(url: url)
                        }
                    },
                    onShare: { presentShareSheet(for: url) }
                )
                .tag(url)
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
        .environment(\.editMode, .constant(isEditingSelection ? .active : .inactive))
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
    let urls: [URL]
}

// MARK: - TrackRow
struct TrackRow: View {
    let url: URL
    let isPlaying: Bool
    let isSelected: Bool
    let onTap: () -> Void
    var onShare: (() -> Void)?
    
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @State private var showEditSheet = false

    var body: some View {
        let fileName = url.lastPathComponent
        let metadata = metadataManager.getMetadata(for: fileName)
        let labels = metadataManager.labels.filter { metadata.labels.contains($0.id) }
        
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
                    Text(metadata.displayName)
                        .lineLimit(2)
                        .font(isPlaying ? .body.bold() : .body)
                        .foregroundColor(isPlaying ? .accentColor : .primary)

                    HStack(spacing: 4) {
                        Text(url.pathExtension.uppercased())
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if !labels.isEmpty {
                            ForEach(labels, id: \.id) { label in
                                HStack(spacing: 2) {
                                    Circle()
                                        .fill(label.swiftUIColor)
                                        .frame(width: 6, height: 6)
                                    Text(label.name)
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(label.swiftUIColor.opacity(0.15))
                                .cornerRadius(3)
                            }
                        }
                    }
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
                showEditSheet = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            
            Button {
                onShare?()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        .sheet(isPresented: $showEditSheet) {
            EditMusicSheet(
                isPresented: $showEditSheet,
                fileName: fileName,
                onUpdate: { _ in }
            )
        }
        .accessibilityLabel("\(metadata.displayName), \(isPlaying ? "now playing" : "tap to play")")
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
