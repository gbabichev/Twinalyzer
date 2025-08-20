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
public enum DisplayHelpers {
    
    /// Returns a shortened path showing only the last two components
    /// Example: "/Users/john/Photos/Vacation/beach.jpg" becomes "Vacation/beach.jpg"
    /// This keeps file paths readable in table cells and UI labels while maintaining context
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
    /// Converts decimal values (0.0-1.0) to user-friendly percentage strings
    /// Example: 0.75 becomes "75%"
    public static func formatSimilarityThreshold(_ value: Double) -> String {
        "\(Int(round(value * 100)))%"
    }
    
    /// Determines if a table row represents a cross-folder match
    /// Cross-folder matches are visually highlighted in red throughout the UI
    /// This helps users identify duplicates that span different directories
    public static func isCrossFolder(_ row: TableRow) -> Bool {
        let refFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
        let simFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
        return refFolder != simFolder
    }
    
    /// Formats a folder path for display, showing parent/folder structure
    /// Creates a hierarchical display like "Photos/Vacation" for better folder identification
    /// Falls back to just the folder name if no parent context is available
    public static func formatFolderDisplayName(for url: URL) -> String {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? name : "\(parent)/\(name)"
    }
    
    /// Creates a summary string for processing progress
    /// Handles both determinate progress (with percentage) and indeterminate states
    /// Used in the processing overlay to show analysis status
    public static func formatProcessingProgress(_ progress: Double?) -> String {
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
            vm.addParentFolders(panel.urls)
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

    // MARK: - Scroll State Updates
    func updateScrollableState(availableHeight: CGFloat) {
        visibleHeight = availableHeight
        
        // Simple heuristic: estimate content height based on folder count
        // Each text row is roughly 20px (font + spacing), plus 16px padding
        let estimatedContentHeight = CGFloat(vm.allFoldersBeingProcessed.count) * 22 + 16
        
        let wasScrollable = isScrollable
        isScrollable = estimatedContentHeight > availableHeight
        
        // IMPORTANT: Update bottom state when scrollable state changes
        if wasScrollable != isScrollable {
            updateScrolledToBottomState()
        }
    }
    
    func updateScrolledToBottomState() {
        // More accurate bottom detection
        if isScrollable {
            // Calculate how much we can actually scroll
            let maxScrollDistance = max(0, contentHeight - visibleHeight)
            // We're "at bottom" when we've scrolled at least 80% of the way down
            let scrolledDistance = abs(scrollOffset)
            isScrolledToBottom = scrolledDistance >= (maxScrollDistance * 0.8)
        } else {
            isScrolledToBottom = true // Non-scrollable content is considered "at bottom"
        }
    }    
}
