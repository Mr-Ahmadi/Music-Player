import SwiftUI

struct ContentView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @ObservedObject private var prefs = PlaybackPreferences.shared
    @ObservedObject private var analytics = PlaybackAnalytics.shared
    @ObservedObject private var tagStore = TrackTagStore.shared

    @State private var showingImporter = false
    @State private var searchText = ""
    @State private var shareURL: ShareableURLWrapper?
    @State private var selection = Set<URL>()
    @State private var isEditingSelection = false
    @State private var bulkLabelTarget: BulkLabelRequest?
    @State private var toast: String?

    private let pageBackground = Color(UIColor.systemGroupedBackground)

    // MARK: - Filtering & sorting
    /// Search, then the favourites toggle, then the chosen sort order.
    var filteredTracks: [URL] {
        var result = player.tracks

        if prefs.showFavoritesOnly {
            let favorites = metadataManager.favoriteFileNames
            result = result.filter { favorites.contains($0.lastPathComponent) }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { matches(url: $0, query: query) }
        }

        return sorted(result)
    }

    private func matches(url: URL, query: String) -> Bool {
        let fileName = url.lastPathComponent
        let meta = metadataManager.getMetadata(for: fileName)
        if meta.displayName.localizedCaseInsensitiveContains(query) { return true }
        if fileName.localizedCaseInsensitiveContains(query) { return true }

        // Embedded tags are searchable too, so "beatles" finds tracks whose
        // file name says nothing useful.
        if let tags = tagStore.cachedTags(for: fileName) {
            for field in [tags.artist, tags.album, tags.albumArtist, tags.genre, tags.title] {
                if field?.localizedCaseInsensitiveContains(query) == true { return true }
            }
        }

        let labelNames = meta.labels.compactMap { id in metadataManager.labels.first(where: { $0.id == id })?.name }
        return labelNames.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    private func sorted(_ urls: [URL]) -> [URL] {
        switch prefs.librarySort {
        case .custom:
            return urls
        case .title:
            return urls.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
        case .titleDescending:
            return urls.sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedDescending }
        case .mostPlayed:
            return urls.sorted {
                let a = analytics.trackStats(for: $0.lastPathComponent).playCount
                let b = analytics.trackStats(for: $1.lastPathComponent).playCount
                if a == b { return displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
                return a > b
            }
        case .recentlyPlayed:
            return urls.sorted {
                let a = analytics.trackStats(for: $0.lastPathComponent).lastPlayed ?? .distantPast
                let b = analytics.trackStats(for: $1.lastPathComponent).lastPlayed ?? .distantPast
                return a > b
            }
        case .longest:
            return urls.sorted {
                let a = tagStore.cachedTags(for: $0.lastPathComponent)?.duration ?? 0
                let b = tagStore.cachedTags(for: $1.lastPathComponent)?.duration ?? 0
                return a > b
            }
        }
    }

    private func displayName(_ url: URL) -> String {
        metadataManager.getMetadata(for: url.lastPathComponent).displayName
    }

    // MARK: - Body
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if player.tracks.isEmpty {
                    emptyStateView
                } else {
                    SearchBar(text: $searchText)
                    filterBar

                    if filteredTracks.isEmpty {
                        noResultsView
                    } else {
                        trackListView
                    }
                }

                PlayerView()
                    .environmentObject(player)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(pageBackground)
            }
            .background(pageBackground.ignoresSafeArea())
            .navigationTitle("Library")
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(pageBackground, for: .navigationBar)
            .toolbar { toolbarContent }
            .overlay(alignment: .bottom) { toastView }
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
        .sheet(item: $bulkLabelTarget) { request in
            BulkLabelSheet(fileNames: request.fileNames) {
                selection.removeAll()
                isEditingSelection = false
            }
        }
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if selection.isEmpty {
                Menu {
                    Picker("Sort by", selection: $prefs.librarySort) {
                        ForEach(LibrarySort.allCases) { sort in
                            Label(sort.title, systemImage: sort.systemImage).tag(sort)
                        }
                    }

                    Divider()

                    Toggle(isOn: $prefs.showFavoritesOnly) {
                        Label("Favorites Only", systemImage: "heart")
                    }

                    Divider()

                    Button {
                        player.shuffleAll()
                    } label: {
                        Label("Shuffle All", systemImage: "shuffle")
                    }
                    .disabled(player.tracks.isEmpty)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Sort and filter")
            }

            Button {
                showingImporter = true
            } label: {
                Label("Import", systemImage: "plus")
            }
        }

        ToolbarItemGroup(placement: .navigationBarLeading) {
            if !selection.isEmpty {
                Menu {
                    Button {
                        let urls = Array(selection).compactMap { player.resolvedURL(for: $0) }
                        shareURL = ShareableURLWrapper(urls: urls)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        for url in orderedSelection() { player.addToQueue(url) }
                        showToast("Added \(selection.count) to queue")
                        selection.removeAll()
                    } label: {
                        Label("Add to Queue", systemImage: "text.append")
                    }

                    Button {
                        bulkLabelTarget = BulkLabelRequest(fileNames: orderedSelection().map { $0.lastPathComponent })
                    } label: {
                        Label("Add Label…", systemImage: "tag")
                    }

                    Button {
                        for url in orderedSelection() {
                            metadataManager.toggleFavorite(fileName: url.lastPathComponent)
                        }
                        selection.removeAll()
                    } label: {
                        Label("Toggle Favorite", systemImage: "heart")
                    }

                    Divider()

                    Button(role: .destructive) {
                        deleteSelected()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Text("\(selection.count) Selected")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.16))
                        .cornerRadius(8)
                }

                Button("Done") {
                    selection.removeAll()
                    isEditingSelection = false
                }
                .font(.caption)
            } else {
                Button {
                    isEditingSelection.toggle()
                } label: {
                    Image(systemName: isEditingSelection ? "checkmark.circle.fill" : "checklist")
                }
                .disabled(player.tracks.isEmpty)
            }
        }
    }

    /// Selection is a Set, so restore the on-screen order before acting on it.
    private func orderedSelection() -> [URL] {
        filteredTracks.filter { selection.contains($0) }
    }

    // MARK: - Filter bar
    private var filterBar: some View {
        HStack(spacing: 8) {
            Button {
                player.shuffleAll()
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            Button {
                prefs.showFavoritesOnly.toggle()
            } label: {
                Label("Favorites", systemImage: prefs.showFavoritesOnly ? "heart.fill" : "heart")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(prefs.showFavoritesOnly ? Color.pink.opacity(0.2) : Color.secondary.opacity(0.12)))
                    .foregroundColor(prefs.showFavoritesOnly ? .pink : .secondary)
            }
            .buttonStyle(.plain)

            if prefs.librarySort != .custom {
                Label(prefs.librarySort.title, systemImage: prefs.librarySort.systemImage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("\(filteredTracks.count)")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    // MARK: - Subviews
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(UIColor.secondarySystemGroupedBackground))
                    .frame(width: 128, height: 128)
                Image(systemName: "music.note.list")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(.tint)
            }

            Text("No Tracks")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Import audio files to start listening.\n\nTip: Share music from Telegram, Files, or other apps—tap \"Open in Offline Music Player\". You’ll be asked whether to keep each track in your library.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: { showingImporter = true }) {
                Label("Import Audio Files", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top)

            Spacer()
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: prefs.showFavoritesOnly && searchText.isEmpty ? "heart.slash" : "magnifyingglass")
                .font(.system(size: 50))
                .foregroundColor(.secondary)

            Text(prefs.showFavoritesOnly && searchText.isEmpty ? "No Favorites Yet" : "No Tracks Found")
                .font(.headline)

            Text(prefs.showFavoritesOnly && searchText.isEmpty
                 ? "Tap the heart on a track to add it here."
                 : "Try adjusting your search")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if prefs.showFavoritesOnly {
                Button("Show All Tracks") { prefs.showFavoritesOnly = false }
                    .buttonStyle(.bordered)
            }

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
                    isQueued: player.userQueue.contains(url),
                    onTap: {
                        if isEditingSelection {
                            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
                        } else {
                            player.play(url: url)
                        }
                    },
                    onShare: { presentShareSheet(for: url) },
                    onPlayNext: {
                        player.playNext(url)
                        showToast("Playing next")
                    },
                    onAddToQueue: {
                        player.addToQueue(url)
                        showToast("Added to queue")
                    }
                )
                .tag(url)
            }
            .onDelete { deleteItems(at: $0) }
            .onMove { indices, destination in
                // Manual ordering only makes sense while the list is unsorted.
                guard prefs.librarySort == .custom else { return }
                moveItemsInFilteredList(from: indices, to: destination)
            }
        }
        .listStyle(PlainListStyle())
        .environment(\.editMode, .constant(isEditingSelection ? .active : .inactive))
        .scrollContentBackground(.hidden)
        .background(pageBackground)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.footnote.weight(.medium))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.black.opacity(0.8)))
                .padding(.bottom, 190)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Helper Methods
    private func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeIn(duration: 0.25)) {
                if toast == message { toast = nil }
            }
        }
    }

    private func presentShareSheet(for trackURL: URL) {
        guard let resolved = player.resolvedURL(for: trackURL) else { return }
        shareURL = ShareableURLWrapper(urls: [resolved])
    }

    private func deleteItems(at offsets: IndexSet) {
        // Convert filtered indices to actual track indices
        let visible = filteredTracks
        let tracksToDelete = offsets.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        remove(tracks: tracksToDelete)
    }

    private func deleteSelected() {
        remove(tracks: orderedSelection())
    }

    private func remove(tracks tracksToDelete: [URL]) {
        guard !tracksToDelete.isEmpty else { return }
        let actualIndices = IndexSet(tracksToDelete.compactMap { player.tracks.firstIndex(of: $0) })
        selection.subtract(tracksToDelete)
        player.remove(atOffsets: actualIndices)
    }

    private func moveItemsInFilteredList(from indices: IndexSet, to destination: Int) {
        let visible = filteredTracks
        let movingTracks = indices.map { visible[$0] }
        let filteredWithoutMoving = visible.enumerated()
            .filter { !indices.contains($0.offset) }
            .map(\.element)
        let destinationInFiltered = min(destination, filteredWithoutMoving.count)

        var reorderedFiltered = filteredWithoutMoving
        reorderedFiltered.insert(contentsOf: movingTracks, at: destinationInFiltered)

        let filteredSet = Set(visible)
        let nonFiltered = player.tracks.filter { !filteredSet.contains($0) }
        var filteredIterator = reorderedFiltered.makeIterator()
        var nonFilteredIterator = nonFiltered.makeIterator()

        var merged: [URL] = []
        merged.reserveCapacity(player.tracks.count)

        for original in player.tracks {
            if filteredSet.contains(original), let next = filteredIterator.next() {
                merged.append(next)
            } else if let next = nonFilteredIterator.next() {
                merged.append(next)
            }
        }

        player.tracks = merged
    }
}

// MARK: - Shareable URL Wrapper (for sheet binding)
struct ShareableURLWrapper: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct BulkLabelRequest: Identifiable {
    let id = UUID()
    let fileNames: [String]
}

// MARK: - TrackRow
struct TrackRow: View {
    let url: URL
    let isPlaying: Bool
    let isQueued: Bool
    let onTap: () -> Void
    var onShare: (() -> Void)?
    var onPlayNext: (() -> Void)?
    var onAddToQueue: (() -> Void)?

    @StateObject private var metadataManager = MusicMetadataManager.shared
    @ObservedObject private var tagStore = TrackTagStore.shared
    @State private var showEditSheet = false

    var body: some View {
        let fileName = url.lastPathComponent
        let metadata = metadataManager.getMetadata(for: fileName)
        let labels = metadataManager.labels.filter { metadata.labels.contains($0.id) }
        let tags = tagStore.cachedTags(for: fileName)

        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    TrackArtworkView(fileName: fileName, size: 46, cornerRadius: 8)

                    if isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.accentColor))
                            .offset(x: 4, y: 4)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(metadata.displayName)
                            .lineLimit(1)
                            .font(isPlaying ? .body.bold() : .body)

                        if metadata.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.pink)
                        }
                    }

                    HStack(spacing: 4) {
                        if let subtitle = tags?.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else {
                            Text(url.pathExtension.uppercased())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if let duration = tags?.duration {
                            Text("• \(Self.durationText(duration))")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }

                    if !labels.isEmpty {
                        HStack(spacing: 4) {
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

                Spacer(minLength: 4)

                if isQueued {
                    Image(systemName: "text.append")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }

                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "chevron.right")
                    .font(.caption)
                    .foregroundColor(isPlaying ? .accentColor : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isPlaying ? Color.accentColor.opacity(0.14) : Color(UIColor.secondarySystemGroupedBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                metadataManager.toggleFavorite(fileName: fileName)
            } label: {
                Label(metadata.isFavorite ? "Unfavorite" : "Favorite",
                      systemImage: metadata.isFavorite ? "heart.slash.fill" : "heart.fill")
            }
            .tint(.pink)

            Button {
                onPlayNext?()
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                onPlayNext?()
            } label: {
                Label("Play Next", systemImage: "text.insert")
            }

            Button {
                onAddToQueue?()
            } label: {
                Label("Add to Queue", systemImage: "text.append")
            }

            Button {
                metadataManager.toggleFavorite(fileName: fileName)
            } label: {
                Label(metadata.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: metadata.isFavorite ? "heart.slash" : "heart")
            }

            Divider()

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

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Bulk label sheet
/// Applies one label to every selected track in a single step.
struct BulkLabelSheet: View {
    let fileNames: [String]
    let onDone: () -> Void

    @StateObject private var metadataManager = MusicMetadataManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if metadataManager.labels.isEmpty {
                    Text("No labels yet. Create one in Settings → Manage Labels.")
                        .foregroundColor(.secondary)
                } else {
                    Section("Add label to \(fileNames.count) track\(fileNames.count == 1 ? "" : "s")") {
                        ForEach(metadataManager.labels) { label in
                            Button {
                                for fileName in fileNames {
                                    metadataManager.addLabel(labelId: label.id, to: fileName)
                                }
                                onDone()
                                dismiss()
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(label.swiftUIColor)
                                        .frame(width: 12, height: 12)
                                    Text(label.name)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
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

                TextField("Search title, artist, album, label…", text: $text)
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
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
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
