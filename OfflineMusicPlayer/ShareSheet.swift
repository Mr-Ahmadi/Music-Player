import SwiftUI

#if canImport(UIKit)
import UIKit

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif canImport(AppKit)
import AppKit

struct ShareSheet: NSViewControllerRepresentable {
    let items: [Any]
    
    func makeNSViewController(context: Context) -> NSViewController {
        let vc = NSViewController()
        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: .zero, of: vc.view, preferredEdge: .minY)
        return vc
    }
    
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}
#endif
