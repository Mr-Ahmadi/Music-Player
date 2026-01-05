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
    @State private var searchText = ""

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
                    SearchBar(text: $searchText)
                    
                    if filteredTracks.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("No tracks found")
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    } else {
                        List {
                            ForEach(filteredTracks, id: \.self) { url in
                                Button(action: { player.play(url: url) }) {
                                    HStack {
                                        Image(systemName: "music.note")
                                        Text(url.lastPathComponent)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .onDelete { indices in
                                for index in indices.sorted(by: >) {
                                    if let trackIndex = player.tracks.firstIndex(of: filteredTracks[index]) {
                                        player.tracks.remove(at: trackIndex)
                                    }
                                }
                            }
                            .onMove { indices, destination in
                                player.tracks.move(fromOffsets: indices, toOffset: destination)
                            }
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

struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)

            TextField("Search tracks...", text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
