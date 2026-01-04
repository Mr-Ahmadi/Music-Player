//
//  ShareViewController.swift
//  OfflineMusicPlayerShareExtension
//
//  Created by Share Extension Setup
//

import UIKit
import Social

class ShareViewController: UIViewController {
    
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    @IBOutlet weak var doneButton: UIBarButtonItem!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        statusLabel?.text = "Processing audio file..."
        activityIndicator?.startAnimating()
        doneButton?.isEnabled = false
        
        // Process the shared audio files
        processSharedFiles()
    }
    
    private func processSharedFiles() {
        guard let extensionContext = extensionContext else {
            completeWithError("No extension context available")
            return
        }
        
        let inputItems = extensionContext.inputItems
        
        guard !inputItems.isEmpty else {
            completeWithError("No files to process")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.handleInputItems(inputItems)
        }
    }
    
    private func handleInputItems(_ items: [Any]) {
        var successCount = 0
        var errorCount = 0
        
        for item in items {
            guard let provider = item as? NSItemProvider else { continue }
            
            // Check for audio files
            if provider.hasItemConformingToTypeIdentifier("com.apple.m4a-audio") ||
               provider.hasItemConformingToTypeIdentifier("public.mp3") ||
               provider.hasItemConformingToTypeIdentifier("public.wav") ||
               provider.hasItemConformingToTypeIdentifier("public.aiff-audio") ||
               provider.hasItemConformingToTypeIdentifier("com.flac") ||
               provider.hasItemConformingToTypeIdentifier("org.xiph.ogg") ||
               provider.hasItemConformingToTypeIdentifier("public.audio") ||
               provider.hasItemConformingToTypeIdentifier("public.mpeg-4-audio") {
                
                // Load the file
                provider.loadFileRepresentation(forTypeIdentifier: self.getPreferredTypeIdentifier(for: provider)) { url, error in
                    if let error = error {
                        print("Error loading file: \(error)")
                        errorCount += 1
                        self?.updateUI(successCount: successCount, errorCount: errorCount, totalCount: items.count)
                        return
                    }
                    
                    guard let url = url else {
                        print("No URL returned")
                        errorCount += 1
                        self?.updateUI(successCount: successCount, errorCount: errorCount, totalCount: items.count)
                        return
                    }
                    
                    // Copy file to app group container
                    if self?.copyFileToAppGroup(url: url) ?? false {
                        successCount += 1
                    } else {
                        errorCount += 1
                    }
                    
                    self?.updateUI(successCount: successCount, errorCount: errorCount, totalCount: items.count)
                }
            }
        }
    }
    
    private func getPreferredTypeIdentifier(for provider: NSItemProvider) -> String {
        let supportedTypes = [
            "public.mp3",
            "public.mpeg-4-audio",
            "com.apple.m4a-audio",
            "public.wav",
            "public.aiff-audio",
            "com.flac",
            "org.xiph.ogg",
            "public.audio"
        ]
        
        for type in supportedTypes {
            if provider.hasItemConformingToTypeIdentifier(type) {
                return type
            }
        }
        
        return "public.audio" // Fallback
    }
    
    private func copyFileToAppGroup(url: URL) -> Bool {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.offlinemusicplayer.shared") else {
            print("Failed to get app group container")
            return false
        }
        
        let importDir = containerURL.appendingPathComponent("ImportedAudio", isDirectory: true)
        
        do {
            try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create import directory: \(error)")
            return false
        }
        
        // Generate unique filename
        var destURL = importDir.appendingPathComponent(url.lastPathComponent)
        var counter = 1
        
        while FileManager.default.fileExists(atPath: destURL.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let newName = "\(base) - \(counter)\(ext.isEmpty ? "" : ".\(ext)")"
            destURL = importDir.appendingPathComponent(newName)
            counter += 1
        }
        
        do {
            try FileManager.default.copyItem(at: url, to: destURL)
            print("Successfully copied file to \(destURL.path)")
            
            // Notify main app of new shared file
            notifyMainApp()
            
            return true
        } catch {
            print("Failed to copy file: \(error)")
            return false
        }
    }
    
    private func notifyMainApp() {
        // Post a notification that the main app can listen for
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.offlinemusicplayer.shared") {
            let notificationFile = containerURL.appendingPathComponent(".notification")
            try? "1".write(to: notificationFile, atomically: true, encoding: .utf8)
        }
    }
    
    private func updateUI(successCount: Int, errorCount: Int, totalCount: Int) {
        let processed = successCount + errorCount
        
        DispatchQueue.main.async { [weak self] in
            if processed >= totalCount {
                if errorCount == 0 {
                    self?.statusLabel?.text = "Successfully imported \(successCount) audio file\(successCount == 1 ? "" : "s")!"
                } else if successCount == 0 {
                    self?.statusLabel?.text = "Failed to import \(errorCount) file\(errorCount == 1 ? "" : "s")"
                } else {
                    self?.statusLabel?.text = "Imported \(successCount) file\(successCount == 1 ? "" : "s"), \(errorCount) failed"
                }
                
                self?.activityIndicator?.stopAnimating()
                self?.doneButton?.isEnabled = true
            }
        }
    }
    
    private func completeWithError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusLabel?.text = message
            self?.activityIndicator?.stopAnimating()
            self?.doneButton?.isEnabled = true
        }
    }
    
    @IBAction func done() {
        let itemProvider = NSItemProvider(contentsOf: URL(fileURLWithPath: "/dev/null"))
        let extensionItem = NSExtensionItem()
        extensionItem.attachments = [itemProvider] as? [NSItemProvider]
        extensionContext?.completeRequest(returningItems: [extensionItem], completionHandler: nil)
    }
}
