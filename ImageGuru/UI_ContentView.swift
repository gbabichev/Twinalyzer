import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AnalysisMode: String, CaseIterable, Identifiable {
    case perceptualHash = "Perceptual Hash"
    case deepFeature = "Deep Feature Embedding"
    var id: String { rawValue }
}

/// Root view using a lightweight state and a dedicated AppViewModel for data/logic.

struct FolderRow: Identifiable {
    let id: Int
    let index: Int
    let url: URL
    
    init(index: Int, url: URL) {
        self.id = index
        self.index = index
        self.url = url
    }
}

struct LeafFolder: Identifiable, Comparable, Sendable {
    let id = UUID()
    let url: URL
    
    var displayName: String {
        url.lastPathComponent
    }
    
    static func < (lhs: LeafFolder, rhs: LeafFolder) -> Bool {
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
    
    static func == (lhs: LeafFolder, rhs: LeafFolder) -> Bool {
        lhs.url == rhs.url
    }
}

struct ContentView: View {

    @StateObject var vm = AppViewModel()

    @State var showSettingsPopover = false
    
 
    
    @State var selectedLeafIDs: Set<UUID> = []
    @State var leafSortOrder: [KeyPathComparator<LeafFolder>] = []

    // Add this computed property to ContentView
    var sortedLeafFolders: [LeafFolder] {
        guard !vm.selectedFolderURLs.isEmpty else { return [] }
        
        // Find all leaf folders from the selected parent folders
        let foundLeafs = findLeafFolders(from: vm.selectedFolderURLs)
        let folders = foundLeafs.map { LeafFolder(url: $0) }
        
        // Apply sorting based on current sort order or default
        if leafSortOrder.isEmpty {
            return folders.sorted { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }
        } else {
            return folders.sorted(using: leafSortOrder)
        }
    }

    
    
    



    
    // Selection + sorting remains in the view for keyboard focus reasons
    @State var selectedRowID: String? = nil
    @State var selectedRowIDs: Set<String> = []
    @State var toggleVersion = 0
    @State var sortOrder: [KeyPathComparator<TableRow>] = []

    var sortedRows: [TableRow] {
        let rows = vm.flattenedResults  // Changed from vm.cachedFlattened
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }

    var selectedRow: TableRow? {
        sortedRows.first(where: { $0.id == selectedRowID })
    }

    var selectedMatches: [String] {
        vm.flattenedResults.filter { selectedRowIDs.contains($0.id) }.map { $0.similar }  // Changed from vm.cachedFlattened
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
        .onAppear { installSpacebarToggle() }
        .toolbar {
            // LEFT: Open (folder picker), Reset (clear UI), Settings (popover)
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    selectFoldersAndLeafs()
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
                
//                Button {
//                    clearAll()
//                } label: {
//                    Label("Clear View", systemImage: "arrow.counterclockwise")
//                }
//                .help("Clear selections and logs (does not delete files).")
                
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
                        addFolders(droppedURLs)
                    }
                }
            }
            
            return true
        }
    }

    
// ----
    
    
    func removeLeaf(_ leaf: LeafFolder) {
            // Remove this specific leaf folder
            // Since we're working with computed leafFolders, we need to update the parent selection
            // This is tricky - we might need to track which parent contributed this leaf
            // For now, let's just refresh the selection
            selectedLeafIDs.remove(leaf.id)
        }
    
    func removeLeafs(withIDs ids: Set<UUID>) {
        selectedLeafIDs.subtract(ids)
    }
    
    func removeSelectedLeafs() {
        selectedLeafIDs.removeAll()
    }
        
    func addFolders(_ urls: [URL]) {
        // Same logic as selectFoldersAndLeafs but without the file picker
        let newFolders = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        
        let existingFolders = Set(vm.selectedFolderURLs.map { $0.standardizedFileURL })
        
        // Filter out duplicates and add new folders
        let uniqueNewFolders = newFolders.filter { !existingFolders.contains($0.standardizedFileURL) }
        vm.selectedFolderURLs.append(contentsOf: uniqueNewFolders)
        
        // Auto-select all discovered leaf folders (both existing and new)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            selectedLeafIDs = Set(sortedLeafFolders.map(\.id))
        }
    }

    // Update selectFoldersAndLeafs to use the new helper:
    func selectFoldersAndLeafs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select Parent Folders to Scan"

        if panel.runModal() == .OK {
            addFolders(panel.urls)
        }
    }
    
    func clearAllFolders() {
        vm.selectedFolderURLs.removeAll()
        selectedLeafIDs.removeAll()
    }
    
    func clearAll() {
        // Cancel any running analysis
        vm.cancelAnalysis()
        
        // Clear selected folders and leaf selections
        vm.selectedFolderURLs.removeAll()
        selectedLeafIDs.removeAll()
        
        // Clear all analysis results (this clears matches, duplicate groups, etc.)
        vm.comparisonResults.removeAll()
        
        // Clear table selections and sorting
        selectedRowID = nil
        selectedRowIDs.removeAll()
        sortOrder.removeAll()
        leafSortOrder.removeAll()
        
        // Reset toggle version (if this affects any UI state)
        toggleVersion = 0
    }
    
    
// ------
    var mainSplitView: some View {
        VSplitView {
            topSplitView
            bottomSplitView
        }
    }
}
