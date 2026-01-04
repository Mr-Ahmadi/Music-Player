import SwiftUI

#if canImport(UIKit)
import UniformTypeIdentifiers
import UIKit

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [UTType.audio]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}

#elseif canImport(AppKit)
import AppKit
import UniformTypeIdentifiers

struct DocumentPicker: NSViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeNSViewController(context: Context) -> NSViewController {
        let vc = NSViewController()
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [UTType.mp3, UTType.m4a, UTType.wav, UTType.aac, UTType.flac]
            if panel.runModal() == .OK {
                onPick(panel.urls)
            } else {
                onPick([])
            }
        }
        return vc
    }

    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

#else
struct DocumentPicker: View {
    var onPick: ([URL]) -> Void
    var body: some View { Text("Document picker not supported on this platform") }
}
#endif
