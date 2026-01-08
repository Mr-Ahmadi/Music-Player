import SwiftUI

@main
struct OfflineMusicPlayerApp: App {
    @StateObject private var player = AudioPlayer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        // Handle shared audio files
        print("OfflineMusicPlayerApp: Received URL - \(url)")

        // Check if it's an audio file
        let supportedExtensions = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "ac3"]
        let fileExtension = url.pathExtension.lowercased()

        if supportedExtensions.contains(fileExtension) {
            // Use the correct method name from AudioPlayer
            player.importTracks(urls: [url])

            // Optionally, start playing immediately
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let lastTrack = player.tracks.last {
                    player.play(url: lastTrack)
                }
            }
        } else {
            print("OfflineMusicPlayerApp: Unsupported file type: \(fileExtension)")
        }
    }
}
