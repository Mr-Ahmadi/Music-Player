import Foundation
import Combine

final class MusicMetadataManager: ObservableObject {
    static let shared = MusicMetadataManager()
    
    @Published var labels: [MusicLabel] = []
    @Published var metadata: [String: MusicMetadata] = [:]  // File name -> Metadata
    
    private let labelsKey = "musicLabels"
    private let metadataKey = "musicMetadata"
    
    private init() {
        loadLabels()
        loadMetadata()
        
        // Initialize with default labels if empty
        if labels.isEmpty {
            labels = MusicLabel.defaultLabels
            saveLabels()
        }
    }
    
    // MARK: - Label Management
    func addLabel(_ label: MusicLabel) {
        DispatchQueue.main.async {
            if !self.labels.contains(where: { $0.id == label.id }) {
                self.labels.append(label)
                self.saveLabels()
            }
        }
    }
    
    func removeLabel(id: String) {
        DispatchQueue.main.async {
            self.labels.removeAll { $0.id == id }
            
            // Remove from all metadata
            for key in self.metadata.keys {
                self.metadata[key]?.labels.removeAll { $0 == id }
            }
            
            self.saveLabels()
            self.saveMetadata()
        }
    }
    
    func updateLabel(id: String, name: String, color: String) {
        DispatchQueue.main.async {
            if let index = self.labels.firstIndex(where: { $0.id == id }) {
                self.labels[index].name = name
                self.labels[index].color = color
                self.saveLabels()
            }
        }
    }
    
    // MARK: - Music Metadata Management
    func getMetadata(for fileName: String) -> MusicMetadata {
        if let existing = metadata[fileName] {
            return existing
        }
        
        // Create new metadata with display name from file
        let displayName = fileName
            .replacingOccurrences(of: "_", with: " ")
            .removingExtension()
        
        let newMetadata = MusicMetadata(id: fileName, displayName: displayName)
        
        // Schedule update asynchronously to avoid "Publishing changes from within view updates"
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Check again in case it was added in the meantime
            if self.metadata[fileName] == nil {
                self.metadata[fileName] = newMetadata
                self.saveMetadata()
            }
        }
        
        return newMetadata
    }
    
    func updateMusicName(fileName: String, newName: String) {
        DispatchQueue.main.async {
            var trackMetadata = self.getMetadata(for: fileName)
            trackMetadata.displayName = newName
            self.metadata[fileName] = trackMetadata
            // History/analytics key by fileName (trackId); display name is UI-only, so no change needed there.
            self.saveMetadata()
        }
    }
    
    func addLabel(labelId: String, to fileName: String) {
        DispatchQueue.main.async {
            var trackMetadata = self.getMetadata(for: fileName)
            if !trackMetadata.labels.contains(labelId) {
                trackMetadata.labels.append(labelId)
                self.metadata[fileName] = trackMetadata
                self.saveMetadata()
            }
        }
    }
    
    func removeLabel(labelId: String, from fileName: String) {
        DispatchQueue.main.async {
            if var trackMetadata = self.metadata[fileName] {
                trackMetadata.labels.removeAll { $0 == labelId }
                self.metadata[fileName] = trackMetadata
                self.saveMetadata()
            }
        }
    }
    
    func toggleFavorite(fileName: String) {
        DispatchQueue.main.async {
            var trackMetadata = self.getMetadata(for: fileName)
            trackMetadata.isFavorite.toggle()
            self.metadata[fileName] = trackMetadata
            self.saveMetadata()
        }
    }

    func isFavorite(fileName: String) -> Bool {
        metadata[fileName]?.isFavorite ?? false
    }

    func setRating(_ rating: Int, for fileName: String) {
        DispatchQueue.main.async {
            var trackMetadata = self.getMetadata(for: fileName)
            trackMetadata.rating = min(max(rating, 0), 5)
            self.metadata[fileName] = trackMetadata
            self.saveMetadata()
        }
    }

    /// Remembers where playback stopped so long tracks can be resumed later.
    /// Positions near the start or the very end are cleared rather than stored.
    func setResumePosition(_ position: TimeInterval, duration: TimeInterval, for fileName: String) {
        let worthResuming = duration > 300 && position > 60 && position < duration - 30
        let value = worthResuming ? position : 0
        DispatchQueue.main.async {
            var trackMetadata = self.getMetadata(for: fileName)
            guard abs(trackMetadata.resumePosition - value) > 1 else { return }
            trackMetadata.resumePosition = value
            self.metadata[fileName] = trackMetadata
            self.saveMetadata()
        }
    }

    func resumePosition(for fileName: String) -> TimeInterval {
        metadata[fileName]?.resumePosition ?? 0
    }

    var favoriteFileNames: Set<String> {
        Set(metadata.filter { $0.value.isFavorite }.keys)
    }

    func removeMusicMetadata(fileName: String) {
        DispatchQueue.main.async {
            self.metadata.removeValue(forKey: fileName)
            self.saveMetadata()
        }
    }
    
    // MARK: - Filtering
    func tracksByLabel(labelId: String) -> [String] {
        metadata.filter { $0.value.labels.contains(labelId) }.map { $0.key }
    }
    
    // MARK: - Persistence
    private func saveLabels() {
        guard let data = try? JSONEncoder().encode(labels) else { return }
        UserDefaults.standard.set(data, forKey: labelsKey)
    }
    
    private func loadLabels() {
        guard let data = UserDefaults.standard.data(forKey: labelsKey),
              let decoded = try? JSONDecoder().decode([MusicLabel].self, from: data) else {
            return
        }
        labels = decoded
    }
    
    private func saveMetadata() {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        UserDefaults.standard.set(data, forKey: metadataKey)
    }
    
    private func loadMetadata() {
        guard let data = UserDefaults.standard.data(forKey: metadataKey),
              let decoded = try? JSONDecoder().decode([String: MusicMetadata].self, from: data) else {
            return
        }
        metadata = decoded
    }
    
    // MARK: - Sync Support (Removed)
}

// MARK: - String Helper
extension String {
    func removingExtension() -> String {
        if let lastDot = lastIndex(of: ".") {
            return String(self[..<lastDot])
        }
        return self
    }
}
