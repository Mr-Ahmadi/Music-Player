import SwiftUI

@main
struct OfflineMusicPlayerApp: App {
    @StateObject private var player = AudioPlayer()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(player)
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        // Handle shared audio files (e.g. from Telegram: Share → Open in Offline Music Player)
        print("OfflineMusicPlayerApp: Received URL - \(url)")

        let supportedExtensions = ["mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff", "ac3"]
        let fileExtension = url.pathExtension.lowercased()

        if supportedExtensions.contains(fileExtension) {
            // Ask user whether to keep the track instead of auto-importing
            player.pendingSharedTrackURL = url
        } else {
            print("OfflineMusicPlayerApp: Unsupported file type: \(fileExtension)")
        }
    }
}
