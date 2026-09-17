import SwiftUI

/// Full-screen lyrics for the playing track. Synced lyrics follow the music,
/// highlighting and centring the current line; tap a line to jump to it.
struct LyricsView: View {
    @EnvironmentObject var player: AudioPlayer
    @ObservedObject private var store = LyricsStore.shared
    @ObservedObject private var metadataManager = MusicMetadataManager.shared
    @ObservedObject private var tagStore = TrackTagStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showTimingControls = false

    private var fileName: String? { player.currentURL?.lastPathComponent }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) {
                    if showTimingControls, let fileName, isSynced {
                        TimingControls(fileName: fileName) {
                            withAnimation(.spring(response: 0.35)) { showTimingControls = false }
                        }
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .task(id: fileName) { load() }
    }

    // MARK: - Content
    /// The store's state, unless it still describes the previous track.
    private var state: LyricsStore.State {
        store.fileName == fileName ? store.state : .loading
    }

    @ViewBuilder
    private var content: some View {
        if fileName == nil {
            ContentUnavailableView("Nothing Playing", systemImage: "music.note",
                                   description: Text("Play a song to see its lyrics."))
        } else {
            stateContent
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Finding lyrics…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .loaded(.synced(let lines)):
            SyncedLyricsView(lines: lines, offset: fileName.map(store.offset(for:)) ?? 0)
        case .loaded(.plain(let text)):
            PlainLyricsView(text: text)
        case .loaded(.instrumental):
            ContentUnavailableView("Instrumental", systemImage: "pianokeys",
                                   description: Text("This song has no lyrics. Just enjoy the music."))
        case .notFound:
            ContentUnavailableView {
                Label("No Lyrics Found", systemImage: "quote.bubble")
            } description: {
                Text("LRCLIB doesn't have lyrics for \u{201C}\(currentTitle)\u{201D}. Check the song's title and artist, then try again.")
            } actions: {
                Button("Try Again") { load(forceRefresh: true) }
                    .buttonStyle(.bordered)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Lyrics", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { load(forceRefresh: true) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private var isSynced: Bool {
        if case .loaded(.synced) = state { return true }
        return false
    }

    private func load(forceRefresh: Bool = false) {
        guard let url = player.currentURL else { return }
        store.load(
            fileName: url.lastPathComponent,
            url: player.resolvedURL(for: url),
            duration: player.duration,
            forceRefresh: forceRefresh
        )
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.body.weight(.semibold))
            }
            .accessibilityLabel("Close lyrics")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(currentTitle)
                    .font(.subheadline.weight(.semibold))
                if let subtitle = fileName.flatMap({ tagStore.cachedTags(for: $0)?.artist }) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if isSynced {
                    Button {
                        withAnimation(.spring(response: 0.35)) { showTimingControls.toggle() }
                    } label: {
                        Label("Adjust Timing", systemImage: "timer")
                    }
                }
                Button {
                    load(forceRefresh: true)
                } label: {
                    Label("Search Again", systemImage: "arrow.clockwise")
                }
                .disabled(state == .loading || fileName == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Lyrics options")
        }
    }

    private var currentTitle: String {
        guard let fileName else { return "Lyrics" }
        return tagStore.cachedTags(for: fileName)?.title
            ?? metadataManager.getMetadata(for: fileName).displayName
    }

    private var background: some View {
        let colors = fileName.map { TrackArtworkView.gradientColors(for: $0) } ?? [.gray, .black]
        return LinearGradient(
            colors: [colors[0].opacity(0.45), colors[1].opacity(0.25), Color(UIColor.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Synced Lyrics
private struct SyncedLyricsView: View {
    @EnvironmentObject var player: AudioPlayer
    let lines: [LyricLine]
    let offset: Double

    var body: some View {
        // Sample the clock ~10×/s while playing; freeze while paused (seeks still
        // re-render through the player's published progress).
        TimelineView(.animation(minimumInterval: 0.1, paused: !player.isPlaying)) { _ in
            LyricsScroller(
                lines: lines,
                activeIndex: lines.activeIndex(at: player.currentTime - offset)
            ) { line in
                // A hair past the timestamp so frame rounding can't land on the previous line.
                player.seek(to: line.time + offset + 0.05)
            }
        }
    }
}

private struct LyricsScroller: View {
    let lines: [LyricLine]
    let activeIndex: Int?
    let onSelect: (LyricLine) -> Void

    /// While the user is browsing, stop following the song for a few seconds.
    @State private var lastManualScroll: Date = .distantPast
    private let followResumeDelay: TimeInterval = 3
    /// Where the current line sits vertically — a bit above centre reads naturally.
    private let focusAnchor = UnitPoint(x: 0.5, y: 0.35)

    private var isFollowing: Bool {
        Date().timeIntervalSince(lastManualScroll) > followResumeDelay
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(lines) { line in
                            row(for: line)
                                .id(line.id)
                        }

                        Text("Lyrics provided by LRCLIB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, geo.size.height * 0.3)
                    .padding(.bottom, geo.size.height * 0.6)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10).onChanged { _ in lastManualScroll = Date() }
                )
                .onAppear { scroll(proxy, animated: false) }
                .onChange(of: activeIndex) { scroll(proxy, animated: true) }
            }
        }
    }

    private func row(for line: LyricLine) -> some View {
        let distance = activeIndex.map { line.id - $0 } ?? line.id + 1
        let isActive = distance == 0

        return Group {
            if line.isGap {
                Image(systemName: "ellipsis")
                    .font(.system(size: 30, weight: .bold))
                    .symbolEffect(.pulse, isActive: isActive)
            } else {
                Text(line.text)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.primary)
        .opacity(isActive ? 1 : (distance < 0 ? 0.28 : 0.4))
        .scaleEffect(isActive ? 1 : 0.95, anchor: .leading)
        .blur(radius: isActive || !isFollowing ? 0 : min(Double(abs(distance)) * 0.35, 1.8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            lastManualScroll = .distantPast
            onSelect(line)
        }
        .animation(.easeOut(duration: 0.35), value: isActive)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard isFollowing, let target = activeIndex ?? lines.first?.id else { return }
        if animated {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.9)) {
                proxy.scrollTo(target, anchor: focusAnchor)
            }
        } else {
            proxy.scrollTo(target, anchor: focusAnchor)
        }
    }
}

// MARK: - Plain Lyrics
private struct PlainLyricsView: View {
    let text: String

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                Label("These lyrics aren't time-synced", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(text)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .lineSpacing(10)
                    .textSelection(.enabled)

                Text("Lyrics provided by LRCLIB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
    }
}

// MARK: - Timing Controls
/// Nudges lyrics earlier or later when a synced file doesn't quite match the recording.
private struct TimingControls: View {
    @ObservedObject private var store = LyricsStore.shared
    let fileName: String
    let onDone: () -> Void

    private let step = 0.5

    var body: some View {
        let offset = store.offset(for: fileName)

        HStack(spacing: 4) {
            Button { store.setOffset(offset - step, for: fileName) } label: {
                Image(systemName: "minus").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Show lyrics earlier")

            Button { store.setOffset(0, for: fileName) } label: {
                VStack(spacing: 0) {
                    Text(offset == 0 ? "In Sync" : String(format: "%+.1fs", offset))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(offset == 0 ? "Timing" : "Tap to reset")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 96)
            }
            .disabled(offset == 0)

            Button { store.setOffset(offset + step, for: fileName) } label: {
                Image(systemName: "plus").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Show lyrics later")

            Divider().frame(height: 24).padding(.horizontal, 4)

            Button("Done", action: onDone)
                .font(.subheadline.weight(.semibold))
                .padding(.trailing, 12)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
