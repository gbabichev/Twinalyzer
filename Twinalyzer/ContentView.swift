/*
 
 ContentView.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    
    @EnvironmentObject var vm: AppViewModel
    @State var showSettingsPopover = false
    
    // MARK: - Selection State Management
    // The app maintains two separate selection systems:
    // 1. tableSelection: Tracks which rows are focused/highlighted in the table (for navigation and preview)
    // 2. deletionSelection: Tracks which rows are marked for deletion via checkboxes (for batch operations)
    @State var tableSelection: Set<String> = [] // For table focus/navigation and preview
    @State var deletionSelection: Set<String> = [] // For actual deletion checkboxes and bulk operations
    
    // MARK: - Table Sorting
    @State var sortOrder: [KeyPathComparator<TableRow>] = [] // User-configurable sort order for table columns
    
    /// Returns the table rows sorted according to user preferences
    /// If no sort order is specified, returns rows in their natural order from the view model
    var sortedRows: [TableRow] {
        let rows = vm.flattenedResults
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }
    
    /// Returns the currently focused/selected row for preview display
    /// Uses the first item from tableSelection (table focus) to determine which row to show in the detail view
    /// Returns nil if no row is selected or if the selection doesn't match any existing row
    var selectedRow: TableRow? {
        guard let firstID = tableSelection.first else { return nil }
        return sortedRows.first(where: { $0.id == firstID })
    }
    
    //MARK: - Main UI
    var body: some View {
        Group {
            if vm.isProcessing {
                processingView
            } else {
                NavigationSplitView {
                    sidebarContent
                        .navigationSplitViewColumnWidth(min: 100, ideal:200, max:300)
                } content: {
                    tableView
                        .navigationSplitViewColumnWidth(min: 400, ideal: 500)
                } detail: {
                    detailSplitView
                        .navigationSplitViewColumnWidth(min: 200, ideal: 400)
                }
                .navigationSplitViewStyle(.prominentDetail)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .toolbar {
            // LEFT: Open (folder picker), Reset (clear UI), Settings (popover)
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    selectFolders()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(vm.isProcessing) // Disable during processing
                
                Button {
                    clearAll()
                } label: {
                    Label("Clear Folders", systemImage: "arrow.counterclockwise")
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(vm.selectedParentFolders.isEmpty || vm.isProcessing) // Disable during processing
                .help("Clear all selected folders")
                
                Button {
                    showSettingsPopover = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettingsPopover) {
                    controlsPanelPopover
                }
                .disabled(vm.isProcessing) // Disable during processing
            }
            
            // CENTER: Title describing the app
            ToolbarItem(placement: .principal){
                Spacer()
            }

            // RIGHT: Primary actions.
            ToolbarItemGroup(placement: .primaryAction) {
                // Clear selection button - only shows when items are selected for deletion
                if !deletionSelection.isEmpty {
                    Button {
                        deletionSelection.removeAll()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                            Text("Clear")
                                .font(.caption)
                        }
                    }
                    .help("Clear selection (\(deletionSelection.count) item\(deletionSelection.count == 1 ? "" : "s"))")
                    .disabled(vm.isProcessing) // Disable during processing
                }
                
                // Delete selected button - shows count and allows batch deletion
                if !deletionSelection.isEmpty {
                    Button {
                        vm.deleteSelectedMatches(selectedMatches: selectedMatchPaths)
                        deletionSelection.removeAll() // Clear selection after deletion
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("\(deletionSelection.count)")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("Delete \(deletionSelection.count) selected match\(deletionSelection.count == 1 ? "" : "es")")
                    .disabled(vm.isProcessing) // Disable during processing
                }
                
                // Processing state: Show cancel button during analysis
                if vm.isProcessing {
                    Button {
                        vm.cancelAnalysis()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .keyboardShortcut(.escape)
                } else {
                    // Ready state: Show analyze button when ready to process
                    Button {
                        // Clear both selection states when starting new analysis
                        // This prevents stale selections from previous results
                        tableSelection.removeAll()
                        deletionSelection.removeAll()
                        vm.processImages(progress: { _ in })
                    } label: {
                        Label("Analyze", systemImage: "wand.and.stars")
                    }
                    .keyboardShortcut("a", modifiers: [.command])
                    .disabled(vm.activeLeafFolders.isEmpty)
                }
            }
        }
        // MARK: - Keyboard Shortcuts
        // Space bar toggles deletion checkbox for selected rows
        .onKeyPress(.space) {
            guard !tableSelection.isEmpty else { return .handled }
            
            // Handle multiple row selection: toggle all selected rows consistently
            if tableSelection.count > 1 {
                // Check if all selected rows are already checked for deletion
                let allChecked = tableSelection.allSatisfy { deletionSelection.contains($0) }
                
                if allChecked {
                    // If all are checked, uncheck all
                    for rowID in tableSelection {
                        deletionSelection.remove(rowID)
                    }
                } else {
                    // If some/none are checked, check all
                    for rowID in tableSelection {
                        deletionSelection.insert(rowID)
                    }
                }
            } else {
                // Single row selection: simple toggle
                guard let focusedID = tableSelection.first else { return .handled }
                
                if deletionSelection.contains(focusedID) {
                    deletionSelection.remove(focusedID)
                } else {
                    deletionSelection.insert(focusedID)
                }
            }
            return .handled
        }
        // MARK: - Drag and Drop Support
        // Allow users to drag folders directly onto the app window
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task {
                var droppedURLs: [URL] = []
                
                for provider in providers {
                    do {
                        let item = try await provider.loadItem(forTypeIdentifier: "public.file-url")
                        if let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            droppedURLs.append(url)
                        }
                    } catch {
                        // Silently ignore failed items - don't interrupt the drag operation
                    }
                }
                
                await MainActor.run {
                    if !droppedURLs.isEmpty {
                        vm.addParentFolders(droppedURLs)
                    }
                }
            }
            
            return true
        }
    }
    
}
