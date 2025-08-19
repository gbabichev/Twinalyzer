import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    
    @State var showSettingsPopover = false
    
    // Selection + sorting remains in the view for keyboard focus reasons
    @State var selectedRowID: String? = nil
    @State var sortOrder: [KeyPathComparator<TableRow>] = []

    var sortedRows: [TableRow] {
        let rows = vm.flattenedResults
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }

    var selectedRow: TableRow? {
        sortedRows.first(where: { $0.id == selectedRowID })
    }

//    private var settingsPopoverContent: some View {
//        return VStack(alignment: .leading, spacing: 16) {
//            Text("Global Settings").font(.headline)
//            Divider()
//            controlsPanelPopover
//        }
//        .padding(20)
//        .frame(width: 350)
//    }
    
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
        
        // Clear table selections and sorting
        selectedRowID = nil
        //selectedRowIDs.removeAll()
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
