import Foundation

extension AudioPlayer {
    // MARK: - Shared Track Management
    func clearPendingSharedTracks() {
        pendingSharedTrackURLs.removeAll()
    }

    func confirmKeepSharedTracks() {
        guard !pendingSharedTrackURLs.isEmpty else { return }
        
        // Import all pending tracks
        importTracks(urls: pendingSharedTrackURLs)
        
        // Clear pending
        clearPendingSharedTracks()
        
        // Reset state
        pendingSharedTrackURLs = []
    }
}
