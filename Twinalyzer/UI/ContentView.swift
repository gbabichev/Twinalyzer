/*
 
 ContentView.swift - Updated for Simplified Table
 Twinalyzer
 
 */

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    
    
    
    // Constants
    let columnWidth: CGFloat = 1000
    let viewportHeight: CGFloat = 200
    
    @State var atBottom = false
    @State var atTop = true

    
    
    
    
    
    
    
    // MARK: - Scroll State Management
    @EnvironmentObject var vm: AppViewModel
    @State var showSettingsPopover = false
    
    @State var debouncedSelection: Set<String> = []
    @State var selectionDebounceTimer: Timer?
    @FocusState var isTableFocused: Bool

    // MARK: - SIMPLIFIED Selection State Management
    // Just one selection system now - table selection for navigation/preview
    @State var tableSelection: Set<String> = []
    // MARK: - SIMPLIFIED Table Sorting - Let SwiftUI handle it!
    typealias RowComparator = KeyPathComparator<TableRow>
    @State var sortOrder: [RowComparator] = []
    // View-only sorted copy; keep model data untouched
    @State private var displayedRows: [TableRow] = []
    // Off-main sort task so header clicks don't block the UI
    @State private var sortTask: Task<Void, Never>? = nil
    // Force table rebuild on resort to avoid diffing huge arrays
    @State private var tableReloadToken: Int = 0
    
    // Rows actually rendered by the Table (sorted view of vm.flattenedResults)
    
    /// SIMPLIFIED: Get the currently selected row for preview
    var selectedRow: TableRow? {
        guard let firstID = debouncedSelection.first else { return nil }
        return vm.flattenedResults.first(where: { $0.id == firstID })
    }

    private func recomputeDisplayedRows() {
        let base = vm.flattenedResults
        let order = sortOrder

        // Cancel any in-flight sort on rapid header clicks
        sortTask?.cancel()
        sortTask = Task.detached(priority: .userInitiated) {
            let result: [TableRow]
            if order.isEmpty {
                result = base
            } else {
                result = base.sorted(using: order)
            }
            await MainActor.run {
                self.displayedRows = result
                self.tableReloadToken &+= 1
            }
        }
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
                .onAppear { recomputeDisplayedRows() }
                .onChange(of: sortOrder) { _, _ in
                    recomputeDisplayedRows()
                }
                .onChange(of: vm.flattenedResults) { _, _ in
                    recomputeDisplayedRows()
                }
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
                        vm.ingestDroppedURLs(droppedURLs)
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
    
    var tableView: some View {
        let rows: [TableRow] = displayedRows
        let selection = $tableSelection
        let order = $sortOrder
        return ResultsTable(rows: rows, selection: selection, sortOrder: order)
            .environmentObject(vm)
            .id(tableReloadToken)
            .tableStyle(.automatic)
            .transaction { $0.disablesAnimations = true }
            .navigationTitle("Results")
            .focused($isTableFocused)
    }
    
    // MARK: - Preview Layout (simplified - no more complex display helpers)
    @ViewBuilder
    func renderPreview(for row: TableRow, size: CGSize) -> some View {
        // Calculate layout dimensions based on available space
        let spacing: CGFloat = 20
        let inset: CGFloat = 16
        let twoColumnWidth = max(0, size.width - spacing - inset * 2)
        let singleColumn = twoColumnWidth / 2
        let maxDim = max(80, min(singleColumn - 40, size.height - 120, 400))
        
        // Pre-compute paths to avoid URL processing during render
        let refDisplayPath = DisplayHelpers.shortDisplayPath(for: row.reference)
        let simDisplayPath = DisplayHelpers.shortDisplayPath(for: row.similar)
        let isCrossFolder = DisplayHelpers.isCrossFolder(row)
        
        HStack(alignment: .top, spacing: spacing) {
            // Left side: Reference image
            VStack(spacing: 8) {
                Text("Reference")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(refDisplayPath)
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
                
                Text(simDisplayPath)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isCrossFolder ? .red : .primary)
                
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

struct ResultsTable: View {
    let rows: [TableRow]
    @Binding var selection: Set<String>
    @Binding var sortOrder: [KeyPathComparator<TableRow>]
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            // Reference column with deletion checkbox
            TableColumn("Reference", value: \.referenceShortLower) { row in
                HStack(spacing: 8) {
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

            // Cross-folder column
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
    }
}
