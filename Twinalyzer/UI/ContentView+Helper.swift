/*
 
 ContentView+Helper.swift - Streamlined
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Foundation

// MARK: - Display Utilities
enum DisplayHelpers {

    /// Returns a shortened path showing only the last two components
    /// Example: "/Users/john/Photos/Vacation/beach.jpg" becomes "Vacation/beach.jpg"
    nonisolated static func shortDisplayPath(for fullPath: String) -> String {
        let url = URL(fileURLWithPath: fullPath)
        let components = url.pathComponents
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        } else {
            return url.lastPathComponent
        }
    }
    
    /// Formats a similarity threshold as a percentage label
    /// Example: 0.75 becomes "75%"
    nonisolated static func formatSimilarityThreshold(_ value: Double) -> String {
        "\(Int(round(value * 100)))%"
    }
    
    
    /// Formats a folder path for display, showing parent/folder structure
    /// Creates a hierarchical display like "Photos/Vacation" for better folder identification
    nonisolated static func formatFolderDisplayName(for url: URL) -> String {
        let folderName = url.lastPathComponent
        let parentName = url.deletingLastPathComponent().lastPathComponent
        
        // If parent is empty, root, or same as folder, just show folder name
        if parentName.isEmpty || parentName == "/" || parentName == folderName {
            return folderName
        }
        
        return "\(parentName)/\(folderName)"
    }
    
    /// Creates a summary string for processing progress
    nonisolated static func formatProcessingProgress(_ progress: Double?) -> String {
        if let progress = progress {
            let percentage = Int(progress * 100)
            // Show "Finalizing..." when at 99% or higher (the list-building phase)
            if percentage >= 99 {
                return "99% - Finalizing..."
            }
            return "\(percentage)%"
        } else {
            return "Preparing..."
        }
    }
}

// MARK: - Enhanced TableRow Model
/// Streamlined table row that works perfectly with SwiftUI's native Table sorting
/// All expensive computations are done once during initialization
struct TableRow: Identifiable, Hashable {
    // Core data
    let id: String
    let reference: String
    let similar: String
    let percent: Double
    let isCrossFolder: Bool
    
    // Pre-computed display strings (cached for sorting performance)
    let referenceShort: String
    let similarShort: String
    let referenceShortLower: String
    let similarShortLower: String
    
    // Computed display properties
    var crossFolderText: String {
        isCrossFolder ? "YES" : ""
    }
    
    var percentDisplay: String {
        let clamped = max(0.0, min(1.0, percent))
        return String(format: "%.1f%%", clamped * 100)
    }
    
    // MARK: - Initializer
    nonisolated init(reference: String, similar: String, percent: Double) {
        self.id = "\(reference)::\(similar)"
        self.reference = reference
        self.similar = similar
        self.percent = percent
        
        // Pre-compute cross-folder status (expensive operation done once)
        let refFolder = URL(fileURLWithPath: reference).deletingLastPathComponent().path
        let simFolder = URL(fileURLWithPath: similar).deletingLastPathComponent().path
        self.isCrossFolder = (refFolder != simFolder)
        
        // Pre-compute display strings for sorting performance
        let refShort = DisplayHelpers.shortDisplayPath(for: reference)
        let simShort = DisplayHelpers.shortDisplayPath(for: similar)
        self.referenceShort = refShort
        self.similarShort = simShort
        self.referenceShortLower = refShort.lowercased()
        self.similarShortLower = simShort.lowercased()
    }
}

// MARK: - ContentView Helper Extensions
extension ContentView {
    
    // MARK: - Folder Selection Dialog
    /// Presents a native macOS folder picker for selecting parent directories
    func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select Parent Folders to Scan"
        
        if panel.runModal() == .OK {
            vm.ingestDroppedURLs(panel.urls)
        }
    }
    
    // MARK: - State Reset
    /// Comprehensive reset of all app state including view model and UI selections
    func clearAll() {
        vm.clearAll()
        
        // Clear table focus/navigation selection
        tableSelection.removeAll()
        sortOrder.removeAll()
    }
    
    
    
    // MARK: - Helper Methods
    func handleSelectionChange() {
        selectionDebounceTimer?.invalidate()
        selectionDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            DispatchQueue.main.async {
                self.debouncedSelection = self.tableSelection
            }
        }
    }
    
    func handleSortOrderChange() {
        vm.updateDisplayedRows(sortOrder: sortOrder)
    }
    
    func toggleRowDeletion(_ rowID: String) {
        if vm.selectedMatchesForDeletion.contains(rowID) {
            vm.selectedMatchesForDeletion.remove(rowID)
        } else {
            vm.selectedMatchesForDeletion.insert(rowID)
        }
    }
    
    func handleActiveRowsChange(_ newRows: [TableRow]) {
        selectionDebounceTimer?.invalidate()
        selectionDebounceTimer = nil
        
        let validIDs = Set(newRows.map { $0.id })
        let currentSelection = tableSelection
        let currentDebounced = debouncedSelection
        let firstID = newRows.first?.id
        
        DispatchQueue.main.async {
            let prunedSelection = currentSelection.intersection(validIDs)
            if prunedSelection != tableSelection {
                tableSelection = prunedSelection
            }
            
            let prunedDebounced = currentDebounced.intersection(validIDs)
            if prunedDebounced != debouncedSelection {
                debouncedSelection = prunedDebounced
            }
            
            guard let firstID, tableSelection.isEmpty else {
                if !newRows.isEmpty {
                    isTableFocused = true
                }
                return
            }
            
            tableSelection = [firstID]
            debouncedSelection = [firstID]
            isTableFocused = true
        }
    }
    
    
    
    
    
    
    
}
