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

    var body: some View {
        Group {
            if vm.isProcessing { processingView }
            else { mainSplitView }
        }
        .frame(minWidth: 700, minHeight: 500)
        .toolbar {
            // LEFT: Open (folder picker), Reset (clear UI), Settings (popover)
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    selectFolders()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: [.command])
                
                Button {
                    clearAll()
                } label: {
                    Label("Clear Folders", systemImage: "arrow.counterclockwise")
                }
                .keyboardShortcut("l", modifiers: [.command])
                .disabled(vm.selectedParentFolders.isEmpty)
                .help("Clear all selected folders")
                
                Button {
                    showSettingsPopover = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettingsPopover) {
                    controlsPanelPopover
                }
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
                        vm.processImages(progress: { _ in })
                    } label: {
                        Label("Analyze", systemImage: "wand.and.stars")
                    }
                    .keyboardShortcut("a", modifiers: [.command])
                    .disabled(vm.activeLeafFolders.isEmpty)
                }
            }
        }
        // ADDED: Space bar to toggle deletion checkbox(es) - supports multi-row
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
    
    var mainSplitView: some View {
        VSplitView {
            topSplitView
            bottomSplitView
        }
    }
}

struct LeafFolderRow {
    let url: URL
}
