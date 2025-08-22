/*
 
 ContentView.swift - Streamlined
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    
    // MARK: - Constant for building the Preview Layout
    let columnWidth: CGFloat = 1000
    let viewportHeight: CGFloat = 200
    @State var atBottom = false
    @State var atTop = true
    
    // MARK: - Core State
    @EnvironmentObject var vm: AppViewModel
    @State var showSettingsPopover = false
    
    // MARK: - Inspector State
    @State private var showInspector = true
    
    @State var debouncedSelection: Set<String> = []
    @State var selectionDebounceTimer: Timer?
    @FocusState var isTableFocused: Bool

    // MARK: - Table State
    @State var tableSelection: Set<String> = []
    @State var sortOrder: [KeyPathComparator<TableRow>] = []
    
    // MARK: - Computed Properties
    /// Returns the currently displayed and sorted rows
    var displayedRows: [TableRow] {
        vm.activeSortedRows
    }
    
    /// Returns the currently selected row for preview
    var selectedRow: TableRow? {
        guard let firstID = debouncedSelection.first else { return nil }
        return displayedRows.first(where: { $0.id == firstID })
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
                } detail: {
                    tableView
                        .inspector(isPresented: $showInspector) {
                            detailSplitView
                        }
                }
                .navigationSplitViewStyle(.prominentDetail)
                .animation(.none, value: showInspector) // Disable entire split view animation during inspector transitions
            }
        }
        .frame(minWidth: 1200, minHeight: 600)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            // LEFT: Open (folder picker), Reset (clear UI), Settings (popover)
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    selectFolders()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .disabled(vm.isAnyOperationRunning)
                
                Button {
                    clearAll()
                } label: {
                    Label("Clear Folders", systemImage: "arrow.counterclockwise")
                }
                .disabled(vm.activeLeafFolders.isEmpty || vm.isAnyOperationRunning)
                .help("Clear all selected folders")
                
                Button {
                    showSettingsPopover = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettingsPopover) {
                    settingsPanelPopover
                }
                .disabled(vm.isAnyOperationRunning)
            }
            
            // CENTER: Title describing the app
            ToolbarItem(placement: .principal){
                Spacer()
            }

            // RIGHT: Primary actions
            ToolbarItemGroup(placement: .primaryAction) {
                // Inspector toggle button
                Button {
                    showInspector.toggle()
                } label: {
                    Label(showInspector ? "Hide Inspector" : "Show Inspector",
                          systemImage: showInspector ? "sidebar.trailing" : "sidebar.right")
                }
                .help(showInspector ? "Hide the inspector panel" : "Show the inspector panel")
                .keyboardShortcut("]", modifiers: [.command, .option])
                
                // Clear selection button
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
                    .disabled(vm.isAnyOperationRunning)
                }
                
                // Delete selected button
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
                    .disabled(vm.isAnyOperationRunning)
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
                        // Clear selection states when starting new analysis
                        //tableSelection.removeAll()
                        //vm.clearSelection()
                        vm.processImages(progress: { _ in })
                    } label: {
                        Label("Analyze", systemImage: "wand.and.stars")
                    }
                    .disabled(vm.activeLeafFolders.isEmpty)
                }
            }
        }
        // MARK: - Keyboard Shortcuts
        .onKeyPress(.space) {
            guard !tableSelection.isEmpty else { return .handled }
            DispatchQueue.main.async {
                vm.toggleSelection(for: tableSelection)
            }
            return .handled
        }
        // MARK: - Drag and Drop Support
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
                        // Silently ignore failed items
                    }
                }
                
                await MainActor.run {
                    if !droppedURLs.isEmpty {
                        vm.ingestDroppedURLs(droppedURLs)
                    }
                }
            }
            
            return true
        }
        // MARK: - Change Handlers
        .onChange(of: tableSelection) { _, _ in
            handleSelectionChange()
        }
        .onChange(of: sortOrder) { _, _ in
            handleSortOrderChange()
        }
        .onChange(of: vm.comparisonResults) { _, _ in
            // Reset sort when new results arrive
            sortOrder = []
            vm.updateDisplayedRows(sortOrder: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if !displayedRows.isEmpty {
                        tableSelection = [displayedRows.first!.id]
                        isTableFocused = true
                    }
                }
        }
        .onAppear {
            // Initialize display on first load
            vm.updateDisplayedRows(sortOrder: sortOrder)
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
