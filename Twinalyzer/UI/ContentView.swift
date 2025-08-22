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
    
    // Constants for processing view
    let columnWidth: CGFloat = 1000
    let viewportHeight: CGFloat = 200
    
    @State var atBottom = false
    @State var atTop = true
    
    // MARK: - Core State
    @EnvironmentObject var vm: AppViewModel
    @State var showSettingsPopover = false
    
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
    
    // MARK: - Helper Methods
    private func handleSelectionChange() {
        selectionDebounceTimer?.invalidate()
        selectionDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            DispatchQueue.main.async {
                self.debouncedSelection = self.tableSelection
            }
        }
    }
    
    private func handleSortOrderChange() {
        vm.updateDisplayedRows(sortOrder: sortOrder)
    }
    
    private func toggleRowDeletion(_ rowID: String) {
        if vm.selectedMatchesForDeletion.contains(rowID) {
            vm.selectedMatchesForDeletion.remove(rowID)
        } else {
            vm.selectedMatchesForDeletion.insert(rowID)
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
                } detail: {
                    detailSplitView
                        .navigationSplitViewColumnWidth(min: 200, ideal: 400)
                }
                .navigationSplitViewStyle(.prominentDetail)
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
                .disabled(vm.selectedParentFolders.isEmpty || vm.isAnyOperationRunning)
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
    
    // MARK: - Table View
    // Adds compatibiilty for macOS 15.
    // Padding for the table so it doesn't go under the toolbar.
    // Not an issue on macOS 26 liquid glass. 
    private var macOS15Padding: CGFloat {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 ? 1 : 0
    }
    
    var tableView: some View {
        Table(displayedRows, selection: $tableSelection, sortOrder: $sortOrder) {
            
            // Reference column with deletion checkbox
            TableColumn("Reference", value: \.referenceShortLower) { row in
                HStack(spacing: 8) {
                    // Deletion checkbox
                    Button(action: { toggleRowDeletion(row.id) }) {
                        Image(systemName: vm.selectedMatchesForDeletion.contains(row.id) ? "checkmark.square.fill" : "square")
                            .foregroundColor(vm.selectedMatchesForDeletion.contains(row.id) ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20)
                    
                    // Reference path
                    Text(row.referenceShort)
                        .foregroundStyle(row.isCrossFolder ? .red : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 250)
            
            // Match column
            TableColumn("Match", value: \.similarShortLower) { row in
                Text(row.similarShort)
                    .foregroundStyle(row.isCrossFolder ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 200, ideal: 250)
            
            // Cross-folder indicator column
            TableColumn("Cross-Folder", value: \.crossFolderText) { row in
                Text(row.crossFolderText)
                    .foregroundStyle(row.isCrossFolder ? .red : .secondary)
                    .font(.system(.body, design: .monospaced))
            }
            .width(90)
            
            // Similarity percentage column
            TableColumn("Similarity", value: \.percent) { row in
                Text(row.percentDisplay)
                    .font(.system(.body, design: .monospaced))
            }
            .width(80)
        }
        .navigationTitle("Results (\(displayedRows.count))")
        .focused($isTableFocused)
        .id(vm.tableReloadToken)  // Force reload on sort changes
        .transaction { $0.disablesAnimations = true }  // Prevent sort animations
        .padding(.top, macOS15Padding)
    }
    
    // MARK: - Preview Layout
    @ViewBuilder
    func renderPreview(for row: TableRow, size: CGSize) -> some View {
        // Calculate layout dimensions based on available space
        let spacing: CGFloat = 20
        let inset: CGFloat = 16
        let twoColumnWidth = max(0, size.width - spacing - inset * 2)
        let singleColumn = twoColumnWidth / 2
        let maxDim = max(80, min(singleColumn - 40, size.height - 120, 400))
        
        HStack(alignment: .top, spacing: spacing) {
            // Left side: Reference image
            VStack(spacing: 8) {
                Text("Reference")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(row.referenceShort)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                
                PreviewImage(path: row.reference, maxDimension: maxDim)
                    .frame(maxWidth: maxDim, maxHeight: maxDim)
                    .clipped()
                
                Button("Delete Reference") {
                    vm.deleteFile(row.reference)
                }
                .controlSize(.small)
                .disabled(vm.isProcessing)
            }
            .frame(maxWidth: max(100, singleColumn))
            
            // Right side: Match image
            VStack(spacing: 8) {
                Text("Match")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(row.similarShort)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(row.isCrossFolder ? .red : .primary)
                
                PreviewImage(path: row.similar, maxDimension: maxDim)
                    .frame(maxWidth: maxDim, maxHeight: maxDim)
                    .clipped()
                
                Button("Delete Match") {
                    vm.deleteFile(row.similar)
                }
                .controlSize(.small)
                .disabled(vm.isProcessing)
            }
            .frame(maxWidth: max(100, singleColumn))
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
