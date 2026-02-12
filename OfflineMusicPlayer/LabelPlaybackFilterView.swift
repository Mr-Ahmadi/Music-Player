import SwiftUI

struct LabelPlaybackFilterView: View {
    @EnvironmentObject var player: AudioPlayer
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @State private var filterEnabled: Bool = false

    private var selectedIds: Set<String> {
        get { player.labelFilterIds }
        set { player.labelFilterIds = newValue }
    }

    var body: some View {
        List {
            Section(header: Text("Playback Filter"), footer: Text("When on, Next/Previous and automatic playback only use tracks that have at least one of the selected labels.")) {
                Toggle("Only play selected labels", isOn: $filterEnabled)
                    .onChange(of: filterEnabled) { on in
                        if !on { player.labelFilterIds = [] }
                    }

                if filterEnabled {
                    if metadataManager.labels.isEmpty {
                        Text("No labels yet. Add labels in Settings → Labels, then assign them to tracks.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(metadataManager.labels) { label in
                            Button {
                                var next = selectedIds
                                if next.contains(label.id) {
                                    next.remove(label.id)
                                } else {
                                    next.insert(label.id)
                                }
                                player.labelFilterIds = next
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(label.swiftUIColor)
                                        .frame(width: 14, height: 14)
                                    Text(label.name)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if selectedIds.contains(label.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if filterEnabled && !selectedIds.isEmpty {
                Section {
                    let count = player.getPlayQueue().count
                    HStack {
                        Text("Tracks in queue")
                        Spacer()
                        Text("\(count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Play by Labels")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            filterEnabled = !player.labelFilterIds.isEmpty
        }
        .onChange(of: player.labelFilterIds) { newValue in
            filterEnabled = !newValue.isEmpty
        }
    }
}

#Preview {
    NavigationView {
        LabelPlaybackFilterView()
            .environmentObject(AudioPlayer())
    }
}
