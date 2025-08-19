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
            if vm.isProcessing {
                processingView
            } else {
                // IMPROVED: Better responsive layout with GeometryReader
                GeometryReader { geometry in
                    adaptiveLayout(for: geometry.size)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500) // REDUCED: More reasonable minimum size
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
    
    // IMPROVED: Adaptive layout that responds to window size
    @ViewBuilder
    private func adaptiveLayout(for size: CGSize) -> some View {
        let isCompact = size.width < 1200
        let isVeryCompact = size.width < 900
        
        if isVeryCompact {
            // Very compact: Stack vertically with tabs
            VStack(spacing: 0) {
                compactTabView
                Divider()
                tableView
                    .frame(height: max(200, size.height * 0.6))
                Divider()
                previewPanel
                    .frame(maxHeight: .infinity)
            }
        } else if isCompact {
            // Compact: Simplified two-column layout
            NavigationSplitView {
                compactSidebarContent
            } detail: {
                VStack(spacing: 0) {
                    tableView
                        .frame(height: max(250, size.height * 0.55))
                    Divider()
                    previewPanel
                        .frame(maxHeight: .infinity)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } else {
            // Standard: Three-column layout
            NavigationSplitView {
                sidebarContent
            } content: {
                tableView
                    .navigationSplitViewColumnWidth(min: 400, ideal: 500)
            } detail: {
                detailSplitView
                    .navigationSplitViewColumnWidth(min: 400, ideal: 600)
            }
            .navigationSplitViewStyle(.balanced)
        }
    }
    
    // IMPROVED: Compact tab view for very small windows
    private var compactTabView: some View {
        HStack(spacing: 12) {
            Text("Folders: \(vm.activeLeafFolders.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            if !vm.folderClusters.isEmpty {
                Text("Groups: \(vm.folderClusters.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // IMPROVED: Compact sidebar for smaller windows
    private var compactSidebarContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Folders section (more compact)
            Text("Folders")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            
            if !vm.discoveredLeafFolders.isEmpty {
                List {
                    ForEach(vm.activeLeafFolders, id: \.self) { leafURL in
                        compactFolderRow(leafURL)
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 6) {
                    Text("Drop folders here")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    
                    Button("Open") {
                        selectFolders()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(8)
            }
            
            // Groups section (compact)
            if !vm.folderClusters.isEmpty {
                Divider()
                
                Text("Groups")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 12)
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.folderClusters.indices, id: \.self) { i in
                            compactGroupRow(i)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
        .navigationTitle("Folders")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    // IMPROVED: Compact folder row
    private func compactFolderRow(_ leafURL: URL) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(leafURL.lastPathComponent)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                Text(leafURL.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer(minLength: 0)
            
            if !vm.isProcessing {
                Button {
                    vm.removeLeafFolder(leafURL)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red.opacity(0.7))
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 1)
    }
    
    // IMPROVED: Compact group row
    private func compactGroupRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Group \(index + 1)")
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            ForEach(vm.folderClusters[index].prefix(3), id: \.self) { folder in
                Button(action: { vm.openFolderInFinder(folder) }) {
                    HStack(spacing: 4) {
                        Text(URL(fileURLWithPath: folder).lastPathComponent)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer(minLength: 0)
                        
                        Text("\(vm.folderDuplicateCounts[folder, default: 0])")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            
            if vm.folderClusters[index].count > 3 {
                Text("+ \(vm.folderClusters[index].count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(4)
    }
    
    // IMPROVED: Original sidebar content with better sizing
    var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                VStack(spacing: 8) {
                    Text("Drop parent folders here to discover image folders.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    
                    Button("Open Folder") {
                        selectFolders()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Folders")
        .frame(minWidth: 220, idealWidth: 280) // IMPROVED: Better responsive widths
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
    
    // IMPROVED: Table view with better column sizing
    var tableView: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width - 100 // Account for padding and percent column
            let checkboxWidth: CGFloat = 40
            let percentWidth: CGFloat = 70
            let pathWidth = (availableWidth - checkboxWidth - percentWidth) / 2
            
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
                .width(min: 150, ideal: pathWidth, max: .infinity)
                
                TableColumn("Match", value: \.similar) { row in
                    Text(DisplayHelpers.shortDisplayPath(for: row.similar))
                        .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .width(min: 150, ideal: pathWidth, max: .infinity)
                
                TableColumn("Percent", value: \.percentSortKey) { row in
                    Text(row.percentDisplay)
                        .font(.system(.body, design: .monospaced))
                }
                .width(percentWidth)
            }
            .tableStyle(.automatic)
        }
        .navigationTitle("Results")
    }
    
    // IMPROVED: Detail split with better sizing
    var detailSplitView: some View {
        GeometryReader { geometry in
            let totalHeight = geometry.size.height
            let duplicatesHeight = min(max(150, totalHeight * 0.4), totalHeight - 200)
            
            VSplitView {
                duplicatesFolderPanel
                    .frame(height: duplicatesHeight)
                previewPanel
                    .frame(minHeight: 150)
            }
        }
    }
}
