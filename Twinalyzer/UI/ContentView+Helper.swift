/*
 
 ContentView+Helper.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Foundation

// MARK: - Display Utilities
/// Static helper functions for formatting and displaying various UI elements
/// These utilities handle path formatting, progress display, and visual distinction
/// of cross-folder duplicates throughout the app
enum DisplayHelpers {
    
    /// Returns a shortened path showing only the last two components
    /// Example: "/Users/john/Photos/Vacation/beach.jpg" becomes "Vacation/beach.jpg"
    /// This keeps file paths readable in table cells and UI labels while maintaining context
    static func shortDisplayPath(for fullPath: String) -> String {
        let url = URL(fileURLWithPath: fullPath)
        let components = url.pathComponents
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        } else {
            return url.lastPathComponent
        }
    }
    
    /// Formats a similarity threshold as a percentage label
    /// Converts decimal values (0.0-1.0) to user-friendly percentage strings
    /// Example: 0.75 becomes "75%"
    static func formatSimilarityThreshold(_ value: Double) -> String {
        "\(Int(round(value * 100)))%"
    }
    
    /// Determines if a table row represents a cross-folder match
    /// Cross-folder matches are visually highlighted in red throughout the UI
    /// This helps users identify duplicates that span different directories
    static func isCrossFolder(_ row: TableRow) -> Bool {
        let refFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
        let simFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
        return refFolder != simFolder
    }
    
    /// Formats a folder path for display, showing parent/folder structure
    /// Creates a hierarchical display like "Photos/Vacation" for better folder identification
    /// Falls back to just the folder name if no parent context is available
    static func formatFolderDisplayName(for url: URL) -> String {
        let folderName = url.lastPathComponent
        let parentName = url.deletingLastPathComponent().lastPathComponent
        
        // If parent is empty, root, or same as folder, just show folder name
        if parentName.isEmpty || parentName == "/" || parentName == folderName {
            return folderName
        }
        
        return "\(parentName)/\(folderName)"
    }
    
    /// Creates a summary string for processing progress
    /// Handles both determinate progress (with percentage) and indeterminate states
    /// Used in the processing overlay to show analysis status
    static func formatProcessingProgress(_ progress: Double?) -> String {
        if let progress = progress {
            return "\(Int(progress * 100))%"
        } else {
            return "Preparing..."
        }
    }
}


// MARK: - ContentView Helper Extensions
extension ContentView {
    
    // MARK: - Folder Selection Dialog
    /// Presents a native macOS folder picker for selecting parent directories
    /// Configured to allow multiple directory selection for batch processing
    /// Automatically adds selected folders to the view model for analysis
    func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select Parent Folders to Scan"
        
        if panel.runModal() == .OK {
            vm.ingestDroppedURLs(panel.urls)
            //vm.addParentFolders(panel.urls)
        }
    }

    // MARK: - State Reset
    /// Comprehensive reset of all app state including view model and UI selections
    /// Clears folder selections, analysis results, and all UI selection states
    /// Ensures clean slate for new analysis sessions
    func clearAll() {
        vm.clearAll()
        
        // Clear table focus/navigation selection
        tableSelection.removeAll()
        sortOrder.removeAll()         // Table column sorting preferences
    }

}
// MARK: - Simplified TableRow with Native Sorting Support
/// Simplified table row that works perfectly with SwiftUI's native Table sorting
/// All computed properties are lightweight and work great with KeyPath-based sorting
struct TableRow: Identifiable, Hashable {
    public let id: String
    let reference: String
    let similar: String
    let percent: Double
    let isCrossFolder: Bool

    // Cached short strings (computed once to keep sorting cheap)
    let referenceShort: String
    let similarShort: String
    // Lowercased caches in case you later need case-insensitive compares
    let referenceShortLower: String
    let similarShortLower: String

    var crossFolderText: String { isCrossFolder ? "YES" : "" }
    var percentDisplay: String {
        let clamped = max(0.0, min(1.0, percent))
        return String(format: "%.1f%%", clamped * 100)
    }
    init(id: String, reference: String, similar: String, percent: Double, isCrossFolder: Bool) {
        self.id = id
        self.reference = reference
        self.similar = similar
        self.percent = percent
        self.isCrossFolder = isCrossFolder

        // Compute short strings ONCE (avoid recomputation during sort)
        let refShort = DisplayHelpers.shortDisplayPath(for: reference)
        let simShort = DisplayHelpers.shortDisplayPath(for: similar)
        self.referenceShort = refShort
        self.similarShort = simShort
        self.referenceShortLower = refShort.lowercased()
        self.similarShortLower = simShort.lowercased()
    }
}
