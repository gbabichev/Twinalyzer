import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @StateObject var folderVM: FolderSelectionViewModel
    
    @State var showSettingsPopover = false
    
    // Selection + sorting remains in the view for keyboard focus reasons
    @State var selectedRowID: String? = nil
    @State var selectedRowIDs: Set<String> = []
    @State var toggleVersion = 0
    @State var sortOrder: [KeyPathComparator<TableRow>] = []

    // Custom initializer to properly connect the ViewModels
    init() {
        // We'll get the AppViewModel from the environment, but we need to create the folder VM
        // This is a bit tricky with @EnvironmentObject, so we'll use a placeholder for now
        // and properly initialize it in onAppear
        _folderVM = StateObject(wrappedValue: FolderSelectionViewModel(appViewModel: nil))
    }

    var sortedRows: [TableRow] {
        let rows = vm.flattenedResults
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }

    var selectedRow: TableRow? {
        sortedRows.first(where: { $0.id == selectedRowID })
    }

    var selectedMatches: [String] {
        vm.flattenedResults.filter { selectedRowIDs.contains($0.id) }.map { $0.similar }
    }

    private var settingsPopoverContent: some View {
        return VStack(alignment: .leading, spacing: 16) {
            Text("Global Settings").font(.headline)
            Divider()
            controlsPanelPopover
        }
        .padding(20)
        .frame(width: 350)
    }
    
    var body: some View {
        Group {
            if vm.isProcessing { processingView }
            else { mainSplitView }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            // Initialize the folder VM with the actual app VM
            folderVM.setAppViewModel(vm)
        }
        .toolbar {
            // LEFT: Open (folder picker), Reset (clear UI), Settings (popover)
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    folderVM.selectFoldersAndLeafs()
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
                .disabled(vm.selectedFolderURLs.isEmpty)
                .help("Clear all selected folders")
                
                Button {
                    showSettingsPopover = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettingsPopover) {
                    settingsPopoverContent
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
                    .disabled(vm.selectedFolderURLs.isEmpty)
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
                        folderVM.addFolders(droppedURLs)
                    }
                }
            }
            
            return true
        }
    }
    
    func clearAll() {
        // Cancel any running analysis
        vm.cancelAnalysis()
        
        // Clear folders via folderVM
        folderVM.clearAllFolders()
        
        // Clear all analysis results (this clears matches, duplicate groups, etc.)
        vm.comparisonResults.removeAll()
        
        // Clear table selections and sorting
        selectedRowID = nil
        selectedRowIDs.removeAll()
        sortOrder.removeAll()
        
        // Reset toggle version (if this affects any UI state)
        toggleVersion = 0
    }
    
    var mainSplitView: some View {
        VSplitView {
            topSplitView
            bottomSplitView
        }
    }
}
