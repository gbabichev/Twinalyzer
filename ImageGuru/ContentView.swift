import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    
    @State var showSettingsPopover = false
    
    // CHANGED: Multi-selection support instead of single selection
    @State var selectedRowIDs: Set<String> = []
    @State var sortOrder: [KeyPathComparator<TableRow>] = []

    var sortedRows: [TableRow] {
        let rows = vm.flattenedResults
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }

    // CHANGED: Use first selected row for preview
    var selectedRow: TableRow? {
        guard let firstID = selectedRowIDs.first else { return nil }
        return sortedRows.first(where: { $0.id == firstID })
    }
    
    // CHANGED: Get selected MATCH file paths for deletion (not references)
    var selectedMatchPaths: [String] {
        let selectedRows = sortedRows.filter { selectedRowIDs.contains($0.id) }
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
                // ADDED: Delete selected button
                if !selectedRowIDs.isEmpty {
                    Button {
                        vm.deleteSelectedMatches(selectedMatches: selectedMatchPaths)
                        selectedRowIDs.removeAll() // Clear selection after deletion
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("\(selectedRowIDs.count)")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("Delete \(selectedRowIDs.count) selected match\(selectedRowIDs.count == 1 ? "" : "es")")
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
        // ADDED: Space key support for selection
        .onKeyPress(.space) {
            // Toggle selection of currently focused row
            if let focusedRow = sortedRows.first(where: { selectedRowIDs.contains($0.id) }) {
                // If we have a selection, space toggles the first selected item
                if selectedRowIDs.contains(focusedRow.id) {
                    selectedRowIDs.remove(focusedRow.id)
                } else {
                    selectedRowIDs.insert(focusedRow.id)
                }
            } else if let firstRow = sortedRows.first {
                // If no selection, select the first row
                selectedRowIDs.insert(firstRow.id)
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
        
        // CHANGED: Clear multi-selection instead of single selection
        selectedRowIDs.removeAll()
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
