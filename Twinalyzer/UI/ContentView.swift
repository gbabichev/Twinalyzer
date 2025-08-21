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
    
    // MARK: - Scroll State Management
    @State var scrollOffset: CGFloat = 0
    @State var isScrollable: Bool = false
    @State var isScrolledToBottom: Bool = false
    @State var contentHeight: CGFloat = 0
    @State var visibleHeight: CGFloat = 200
    
    @EnvironmentObject var vm: AppViewModel
    @State var showSettingsPopover = false
    
    @State var debouncedSelection: Set<String> = []
    @State var selectionDebounceTimer: Timer?
    @FocusState var isTableFocused: Bool

    
    // MARK: - Selection State Management
    // The app maintains two separate selection systems:
    // 1. tableSelection: Tracks which rows are focused/highlighted in the table (for navigation and preview)
    // 2. selectedMatchesForDeletion: Now managed by the view model to enable menu bar commands
    @State var tableSelection: Set<String> = [] // For table focus/navigation and preview
    // selectedMatchesForDeletion is now managed by vm.selectedMatchesForDeletion
    
    // MARK: - Table Sorting
    @State var hasAutoSorted = false
    @State var sortOrder: [KeyPathComparator<TableRow>] = [] // User-configurable sort order for table columns
    
    /// Returns the table rows sorted according to user preferences
    /// If no sort order is specified, returns rows in their natural order from the view model
    var sortedRows: [TableRow] {
        return vm.getSortedRows(using: sortOrder)
    }
    
    /// Returns the currently focused/selected row for preview display
    /// Uses the first item from tableSelection (table focus) to determine which row to show in the detail view
    /// Returns nil if no row is selected or if the selection doesn't match any existing row
    var selectedRow: TableRow? {
        guard let firstID = debouncedSelection.first else { return nil }
        return sortedRows.first(where: { $0.id == firstID })
    }
    
    // Add debounced selection change handler
    private func handleSelectionChange() {
        // Cancel existing timer
        selectionDebounceTimer?.invalidate()
        
        // Reduce debounce delay to 50ms for better responsiveness
        selectionDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            DispatchQueue.main.async {
                self.debouncedSelection = self.tableSelection
            }
        }
    }
    
    //MARK: - Main UI
    var body: some View {
        Group {
            if vm.isAnyOperationRunning {
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
                .disabled(vm.isAnyOperationRunning) // Disable during processing
                
                Button {
                    clearAll()
                } label: {
                    Label("Clear Folders", systemImage: "arrow.counterclockwise")
                }
                .disabled(vm.selectedParentFolders.isEmpty || vm.isAnyOperationRunning) // Disable during processing
                .help("Clear all selected folders")
                
                Button {
                    showSettingsPopover = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettingsPopover) {
                    controlsPanelPopover
                }
                .disabled(vm.isAnyOperationRunning) // Disable during processing
            }
            
            // CENTER: Title describing the app
            ToolbarItem(placement: .principal){
                Spacer()
            }

            // RIGHT: Primary actions.
            ToolbarItemGroup(placement: .primaryAction) {
                // Clear selection button - only shows when items are selected for deletion
                if !vm.selectedMatchesForDeletion.isEmpty {
                    Button {
                        vm.clearSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.badge.xmark")
                            Text("Clear")
                                .font(.caption)
                        }
                    }
                    .help("Clear selection (\(vm.selectedMatchesForDeletion.count) item\(vm.selectedMatchesForDeletion.count == 1 ? "" : "s"))")
                    .disabled(vm.isAnyOperationRunning) // Disable during processing
                }
                
                // Delete selected button - shows count and allows batch deletion
                if !vm.selectedMatchesForDeletion.isEmpty {
                    Button {
                        vm.deleteSelectedMatches()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("\(vm.selectedMatchesForDeletion.count)")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                    .help("Delete \(vm.selectedMatchesForDeletion.count) selected match\(vm.selectedMatchesForDeletion.count == 1 ? "" : "es")")
                    .disabled(vm.isAnyOperationRunning) // Disable during processing
                }
                
                // Processing state: Show cancel button during analysis
                if vm.isProcessing {
                    Button {
                        vm.cancelAnalysis()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                } else {
                    // Ready state: Show analyze button when ready to process
                    Button {
                        // Clear both selection states when starting new analysis
                        // This prevents stale selections from previous results
                        tableSelection.removeAll()
                        vm.clearSelection()
                        vm.processImages(progress: { _ in })
                    } label: {
                        Label("Analyze", systemImage: "wand.and.stars")
                    }
                    .disabled(vm.activeLeafFolders.isEmpty)
                }
            }
        }
        // MARK: - Keyboard Shortcuts
        // Space bar toggles deletion checkbox for selected rows
        .onKeyPress(.space) {
            guard !tableSelection.isEmpty else { return .handled }
            
            // Defer the selection change to avoid "Publishing changes from within view updates"
            DispatchQueue.main.async {
                vm.toggleSelection(for: tableSelection)
            }
            
            return .handled
        }       // MARK: - Drag and Drop Support
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
        .onChange(of: tableSelection) { _, _ in
            handleSelectionChange()
        }
        .fileExporter(
            isPresented: $vm.isExportingCSV,
            document: vm.csvDocument,
            contentType: .commaSeparatedText,
            defaultFilename: vm.exportFilename
        ) { result in
            vm.handleCSVExportResult(result)
        }
    }
    
}
