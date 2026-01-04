//
//  ContentView.swift
//  OfflineMusicPlayer
//
//  Created by Ali Ahmadi on 9/26/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var player = AudioPlayer()
    @State private var showingImporter = false

    var body: some View {
        NavigationView {
            VStack {
                if player.tracks.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .foregroundStyle(.tint)
                        Text("No tracks")
                            .font(.title2)
                        Text("Import audio files to play them offline.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        ForEach(player.tracks, id: \.self) { url in
                            Button(action: { player.play(url: url) }) {
                                HStack {
                                    Image(systemName: "music.note")
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .onDelete { indices in
                            player.remove(atOffsets: indices)
                        }
                    }
                }

                PlayerView()
                    .environmentObject(player)
            }
            .navigationTitle("Offline Music")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingImporter = true }) {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
        }
        .sheet(isPresented: $showingImporter) {
            DocumentPicker { urls in
                player.add(urls: urls)
                showingImporter = false
            }
        }
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
