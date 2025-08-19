import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    
    @State var showSettingsPopover = false
    
    // CHANGED: Separate table focus from deletion selection
    @State var tableSelection: Set<String> = [] // For table focus/navigation
    @State var deletionSelection: Set<String> = [] // For actual deletion checkboxes
    @State var sortOrder: [KeyPathComparator<TableRow>] = []
    
    var sortedRows: [TableRow] {
        let rows = vm.flattenedResults
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }
    
    // CHANGED: Use table focused row for preview
    var selectedRow: TableRow? {
        guard let firstID = tableSelection.first else { return nil }
        return sortedRows.first(where: { $0.id == firstID })
    }
    
    // CHANGED: Get deletion selected MATCH file paths
    var selectedMatchPaths: [String] {
        let selectedRows = sortedRows.filter { deletionSelection.contains($0.id) }
        return selectedRows.map { $0.similar } // Only delete the matched photos, not references
    }
        
    var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selected Folders")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top)
            
            if !vm.discoveredLeafFolders.isEmpty {
                List {
                    ForEach(vm.activeLeafFolders, id: \.self) { leafURL in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(leafURL.lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                
                                Text(leafURL.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            
                            Spacer(minLength: 4)
                            
                            if !vm.isProcessing {
                                Button {
                                    vm.removeLeafFolder(leafURL)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red.opacity(0.7))
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .help("Remove this folder")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    
                    Text("Drop parent folders here to discover image folders.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Open Folder") {
                        selectFolders()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Folders")
        .frame(minWidth: 250, idealWidth: 300)
    }
    
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
    
    // SIMPLIFIED: Clean table view
    var tableView: some View {
        Table(sortedRows, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("Reference", value: \.reference) { row in
                HStack(spacing: 8) {
                    // Clickable deletion selection checkbox
                    Button(action: {
                        if deletionSelection.contains(row.id) {
                            deletionSelection.remove(row.id)
                        } else {
                            deletionSelection.insert(row.id)
                        }
                    }) {
                        Image(systemName: deletionSelection.contains(row.id) ? "checkmark.square.fill" : "square")
                            .foregroundColor(deletionSelection.contains(row.id) ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20)
                    
                    Text(DisplayHelpers.shortDisplayPath(for: row.reference))
                        .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 250)
            
            TableColumn("Match", value: \.similar) { row in
                Text(DisplayHelpers.shortDisplayPath(for: row.similar))
                    .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 200, ideal: 250)
            
            TableColumn("Similarity", value: \.percentSortKey) { row in
                Text(row.percentDisplay)
                    .font(.system(.body, design: .monospaced))
            }
            .width(80)
        }
        .tableStyle(.automatic)
        .navigationTitle("Results")
    }
    
    // SIMPLIFIED: Clean detail split
    var detailSplitView: some View {
        VSplitView {
            duplicatesFolderPanel
                .frame(minHeight: 150, idealHeight: 200)
            
            previewPanel
                .frame(minHeight: 200)
        }
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
                .navigationSplitViewStyle(.prominentDetail) // FIXES toolbar timing issue
            }
        }
        .frame(minWidth: 1000, minHeight: 600) // Standard minimum size
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
                // ADDED: Clear selection button
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
                
                // ADDED: Delete selected button
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
                
                if vm.isProcessing {
                    Button {
                        vm.cancelAnalysis()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .keyboardShortcut(.escape)
                } else {
                    Button {
                        // FIXED: Clear selections when starting new analysis
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
        .onKeyPress(.space) {
            guard !tableSelection.isEmpty else { return .handled }
            
            // If multiple rows are table-selected, toggle all of them
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
                // Single row - toggle as before
                guard let focusedID = tableSelection.first else { return .handled }
                
                if deletionSelection.contains(focusedID) {
                    deletionSelection.remove(focusedID)
                } else {
                    deletionSelection.insert(focusedID)
                }
            }
            return .handled
        }
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
    }
    
}
