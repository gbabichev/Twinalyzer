
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Foundation

public enum DisplayHelpers {
    
    /// Returns a shortened path showing only the last two components
    public static func shortDisplayPath(for fullPath: String) -> String {
        let url = URL(fileURLWithPath: fullPath)
        let components = url.pathComponents
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        } else {
            return url.lastPathComponent
        }
    }
    
    /// Formats a similarity threshold as a percentage label
    public static func formatSimilarityThreshold(_ value: Double) -> String {
        "\(Int(round(value * 100)))%"
    }
    
    /// Determines if a table row represents a cross-folder match
    public static func isCrossFolder(_ row: TableRow) -> Bool {
        let refFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
        let simFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
        return refFolder != simFolder
    }
    
    /// Formats a folder path for display, showing parent/folder structure
    public static func formatFolderDisplayName(for url: URL) -> String {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? name : "\(parent)/\(name)"
    }
    
    /// Creates a summary string for processing progress
    public static func formatProcessingProgress(_ progress: Double?) -> String {
        if let progress = progress {
            return "\(Int(progress * 100))%"
        } else {
            return "Preparing..."
        }
    }
}

extension ContentView {
    func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select Parent Folders to Scan"
        
        if panel.runModal() == .OK {
            vm.addParentFolders(panel.urls)
        }
    }

    func clearAll() {
        vm.clearAll()
        
        // CHANGED: Clear both selections
        tableSelection.removeAll()
        deletionSelection.removeAll()
        sortOrder.removeAll()
    }

}

