import SwiftUI

struct LabelManagementView: View {
    @StateObject private var metadataManager = MusicMetadataManager.shared
    @State private var showingAddLabel = false
    @State private var editingLabel: MusicLabel?
    @State private var newLabelName = ""
    @State private var selectedColor = LabelTheme.colors[0]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if metadataManager.labels.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "tag")
                            .font(.system(size: 50))
                            .foregroundColor(.secondary)
                        Text("No Labels")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Create labels to organize your music")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    List {
                        ForEach(metadataManager.labels) { label in
                            Button(action: { editingLabel = label }) {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(label.swiftUIColor)
                                        .frame(width: 16, height: 16)
                                    
                                    Text(label.name)
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        .onDelete { indices in
                            for index in indices {
                                let labelId = metadataManager.labels[index].id
                                metadataManager.removeLabel(id: labelId)
                            }
                        }
                    }
                }
                
                Divider()
                
                Button(action: { 
                    newLabelName = ""
                    selectedColor = LabelTheme.colors[0]
                    showingAddLabel = true 
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Label")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .cornerRadius(8)
                }
                .padding()
            }
            .navigationTitle("Labels")
            .background(Color(UIColor.systemGroupedBackground))
        }
        .sheet(isPresented: $showingAddLabel) {
            AddLabelSheet(
                isPresented: $showingAddLabel,
                onAdd: { name, color in
                    let label = MusicLabel(name: name, color: color)
                    metadataManager.addLabel(label)
                    showingAddLabel = false
                }
            )
        }
        .sheet(item: $editingLabel) { label in
            EditLabelSheet(
                isPresented: Binding(
                    get: { editingLabel != nil },
                    set: { if !$0 { editingLabel = nil } }
                ),
                label: label,
                onUpdate: { newName, newColor in
                    metadataManager.updateLabel(id: label.id, name: newName, color: newColor)
                    editingLabel = nil
                },
                onDelete: {
                    metadataManager.removeLabel(id: label.id)
                    editingLabel = nil
                }
            )
        }
    }
}

// MARK: - Add Label Sheet
struct AddLabelSheet: View {
    @Binding var isPresented: Bool
    var onAdd: (String, String) -> Void
    
    @State private var labelName = ""
    @State private var selectedColor = LabelTheme.colors[0]
    
    var isValid: Bool {
        !labelName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Label Details")) {
                    TextField("Label name", text: $labelName)
                }
                
                Section(header: Text("Color")) {
                    VStack(spacing: 12) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                            ForEach(LabelTheme.colors, id: \.self) { color in
                                Button(action: { selectedColor = color }) {
                                    Circle()
                                        .fill(Color(hex: color))
                                        .frame(height: 44)
                                        .overlay(
                                            selectedColor == color ?
                                            Circle()
                                                .stroke(Color.black, lineWidth: 2)
                                            : nil
                                        )
                                }
                            }
                        }
                        .padding(.vertical)
                        
                        HStack {
                            Text("Preview:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Circle()
                                .fill(Color(hex: selectedColor))
                                .frame(width: 20, height: 20)
                            Text(labelName.isEmpty ? "Label name" : labelName)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(hex: selectedColor).opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            }
            .navigationTitle("New Label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Add") {
                        onAdd(labelName, selectedColor)
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}

// MARK: - Edit Label Sheet
struct EditLabelSheet: View {
    @Binding var isPresented: Bool
    let label: MusicLabel
    var onUpdate: (String, String) -> Void
    var onDelete: () -> Void
    
    @State private var labelName: String = ""
    @State private var selectedColor: String = ""
    @State private var showDeleteConfirm = false
    
    var isValid: Bool {
        !labelName.trimmingCharacters(in: .whitespaces).isEmpty
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Label Details")) {
                    TextField("Label name", text: $labelName)
                }
                
                Section(header: Text("Color")) {
                    VStack(spacing: 12) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 8) {
                            ForEach(LabelTheme.colors, id: \.self) { color in
                                Button(action: { selectedColor = color }) {
                                    Circle()
                                        .fill(Color(hex: color))
                                        .frame(height: 44)
                                        .overlay(
                                            selectedColor == color ?
                                            Circle()
                                                .stroke(Color.black, lineWidth: 2)
                                            : nil
                                        )
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                }
                
                Section {
                    Button(action: { showDeleteConfirm = true }) {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Delete Label")
                        }
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Label")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                labelName = label.name
                selectedColor = label.color
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        onUpdate(labelName, selectedColor)
                    }
                    .disabled(!isValid)
                }
            }
        }
        .alert("Delete Label?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                onDelete()
                isPresented = false
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This label will be removed from all songs.")
        }
    }
}

#Preview {
    LabelManagementView()
}
