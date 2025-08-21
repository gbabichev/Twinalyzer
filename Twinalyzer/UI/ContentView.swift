/*
 
 ContentView.swift - Updated for Simplified Table
 Twinalyzer
 
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

    // MARK: - SIMPLIFIED Selection State Management
    // Just one selection system now - table selection for navigation/preview
    @State var tableSelection: Set<String> = []
    
    // MARK: - SIMPLIFIED Table Sorting - Let SwiftUI handle it!
    @State var sortOrder: [KeyPathComparator<TableRow>] = []
    
    /// SIMPLIFIED: Get the currently selected row for preview
    var selectedRow: TableRow? {
        guard let firstID = debouncedSelection.first else { return nil }
        return sortedResults.first(where: { $0.id == firstID })
    }
    
    // Debounced selection change handler
    private func handleSelectionChange() {
        selectionDebounceTimer?.invalidate()
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
                        .navigationSplitViewColumnWidth(min: 500, ideal: 600) // Wider for new column
                } detail: {
                    detailSplitView
                        .navigationSplitViewColumnWidth(min: 200, ideal: 400)
                }
                .navigationSplitViewStyle(.prominentDetail)
            }
        }
        .frame(minWidth: 1200, minHeight: 600) // Slightly wider for new column
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
                    controlsPanelPopover
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
    
    // MARK: - SIMPLIFIED Results Table with Native Sorting
    /// Apply the sortOrder to get native column header sorting
    var sortedResults: [TableRow] {
        if sortOrder.isEmpty {
            return vm.flattenedResults
        } else {
            return vm.flattenedResults.sorted(using: sortOrder)
        }
    }
    
    var tableView: some View {
        Table(sortedResults, selection: $tableSelection, sortOrder: $sortOrder) {
            // Reference column with deletion checkbox
            TableColumn("Reference", value: \.reference) { row in
                HStack(spacing: 8) {
                    // Deletion checkbox
                    Button(action: {
                        if vm.selectedMatchesForDeletion.contains(row.id) {
                            vm.selectedMatchesForDeletion.remove(row.id)
                        } else {
                            vm.selectedMatchesForDeletion.insert(row.id)
                        }
                    }) {
                        Image(systemName: vm.selectedMatchesForDeletion.contains(row.id) ? "checkmark.square.fill" : "square")
                            .foregroundColor(vm.selectedMatchesForDeletion.contains(row.id) ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20)
                    
                    // Reference path with cross-folder highlighting
                    Text(row.referenceShort)
                        .foregroundStyle(row.isCrossFolder ? .red : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 250)
            
            // Match column
            TableColumn("Match", value: \.similar) { row in
                Text(row.similarShort)
                    .foregroundStyle(row.isCrossFolder ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 200, ideal: 250)
            
            // NEW: Cross-folder column
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
        .tableStyle(.automatic)
        .navigationTitle("Results")
        .focused($isTableFocused)
        .onAppear {
            // Ensure focus when table appears with data
            if !sortedResults.isEmpty && tableSelection.isEmpty {
                if let firstRow = sortedResults.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        tableSelection = [firstRow.id]
                        isTableFocused = true
                    }
                }
            }
        }
    }
    
    // MARK: - Preview Panel (simplified)
    var previewPanel: some View {
        GeometryReader { geometry in
            VStack {
                if let row = selectedRow, !sortedResults.isEmpty {
                    previewLayout(for: row, in: geometry.size)
                } else {
                    VStack(spacing: 8) {
                        if vm.selectedMatchesForDeletion.count > 1 {
                            Text("\(vm.selectedMatchesForDeletion.count) matches selected")
                                .foregroundStyle(.secondary)
                            Text("Press Delete or use toolbar button to delete selected matches")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                        } else {
                            Text(vm.comparisonResults.isEmpty ? "Run an analysis to see results here." : "Select a row to preview")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
    
    // MARK: - Preview Layout (simplified - no more complex display helpers)
    @ViewBuilder
    private func previewLayout(for row: TableRow, in size: CGSize) -> some View {
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
                
                PreviewImage(path: row.reference, maxDimension: maxDim, priority: .userInitiated)
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
                
                PreviewImage(path: row.similar, maxDimension: maxDim, priority: .utility)
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
