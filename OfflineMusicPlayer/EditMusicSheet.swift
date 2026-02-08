import SwiftUI

struct EditMusicSheet: View {
    @Binding var isPresented: Bool
    @StateObject private var metadataManager = MusicMetadataManager.shared
    
    let fileName: String
    let onUpdate: (String) -> Void
    
    @State private var displayName: String = ""
    @State private var selectedLabels: Set<String> = []
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Music Name")) {
                    TextField("Display name", text: $displayName)
                }
                
                Section(header: Text("Labels")) {
                    if metadataManager.labels.isEmpty {
                        Text("No labels available")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(metadataManager.labels) { label in
                            HStack {
                                Circle()
                                    .fill(label.swiftUIColor)
                                    .frame(width: 12, height: 12)
                                
                                Text(label.name)
                                
                                Spacer()
                                
                                if selectedLabels.contains(label.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selectedLabels.contains(label.id) {
                                    selectedLabels.remove(label.id)
                                } else {
                                    selectedLabels.insert(label.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit Music")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                let metadata = metadataManager.getMetadata(for: fileName)
                displayName = metadata.displayName
                selectedLabels = Set(metadata.labels)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        metadataManager.updateMusicName(fileName: fileName, newName: displayName)
                        
                        let metadata = metadataManager.getMetadata(for: fileName)
                        for labelId in metadata.labels {
                            if !selectedLabels.contains(labelId) {
                                metadataManager.removeLabel(labelId: labelId, from: fileName)
                            }
                        }
                        
                        for labelId in selectedLabels {
                            metadataManager.addLabel(labelId: labelId, to: fileName)
                        }
                        
                        onUpdate(displayName)
                        isPresented = false
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

#Preview {
    EditMusicSheet(
        isPresented: .constant(true),
        fileName: "song.mp3",
        onUpdate: { _ in }
    )
}
