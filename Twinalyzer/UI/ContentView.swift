/*
 
 ContentView.swift - Streamlined
 Twinalyzer
 
 George Babichev
 
 */


import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Quartz

// MARK: - QuickLookPreview Navigation Extension
extension ContentView.QuickLookPreview {
    func goPrevious() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        let prev = max(0, panel.currentPreviewItemIndex - 1)
        if prev != panel.currentPreviewItemIndex { panel.currentPreviewItemIndex = prev }
    }
    func goNext() {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        let next = panel.currentPreviewItemIndex + 1
        panel.currentPreviewItemIndex = next
    }
}

struct ContentView: View {
    
    // MARK: - Constant for building the Preview Layout
    let columnWidth: CGFloat = 800
    let viewportHeight: CGFloat = 400
    @State var atBottom = false
    @State var atTop = true
    
    // MARK: - Core State
    @EnvironmentObject var vm: AppViewModel
    @State var showSettingsPopover = false

    // MARK: - Tutorial State
    @State private var showTutorial = false

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
    
    // MARK: - Quick Look Navigation (without taking focus)
    private func quickLookGoPrevious() { QuickLookPreview.shared.goPrevious() }
    private func quickLookGoNext() { QuickLookPreview.shared.goNext() }

    // MARK: - Helper to refocus main window after Quick Look
    private func refocusPrimaryWindow() {
        // Bring a non-panel window back to key status so table keeps focus
        if let win = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible }) {
            win.makeKeyAndOrderFront(nil)
        }
        // Reassert SwiftUI table focus if applicable
        isTableFocused = true
    }
    
    @MainActor
    private func openPairInQuickLook(_ row: TableRow, referenceFirst: Bool = true) {
        let refURL = URL(fileURLWithPath: row.reference)
        let matchURL = URL(fileURLWithPath: row.similar)
        let fm = FileManager.default
        let hasRef = fm.fileExists(atPath: refURL.path)
        let hasMatch = fm.fileExists(atPath: matchURL.path)
        var urls: [URL] = []

        if referenceFirst {
            if hasRef { urls.append(refURL) }
            if hasMatch { urls.append(matchURL) }
        } else {
            if hasMatch { urls.append(matchURL) }
            if hasRef { urls.append(refURL) }
        }

        guard !urls.isEmpty else { return }
        QuickLookPreview.shared.show(urls: urls)
    }
    
    // MARK: - Main UI
    @ViewBuilder
    private var mainLayout: some View {
        if vm.isAnyOperationRunning {
            processingView
        } else {
            NavigationSplitView {
                sidebarContent
                    .navigationSplitViewColumnWidth(min: 100, ideal:200, max:300)
            } content: {
                tableView
                    .navigationSplitViewColumnWidth(min: 400, ideal:400)
                    .layoutPriority(1)
            } detail: {
                detailSplitView
                    .navigationSplitViewColumnWidth(min: 200, ideal:200)
            }
        }
    }

    @ViewBuilder
    private var contentWithTutorial: some View {
        ZStack {
            mainLayout

            // Tutorial overlay
            if showTutorial {
                TutorialView(isPresented: $showTutorial)
            }
        }
    }

    var body: some View {
        contentWithTutorial
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
                .disabled(vm.activeLeafFolders.isEmpty || vm.isAnyOperationRunning)
                .help("Clear all selected folders")
                
                Button {
                    showSettingsPopover = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .popover(isPresented: $showSettingsPopover) {
                    SettingsPanelPopover(vm: vm)
                }
                .disabled(vm.isAnyOperationRunning)
            }
            
            // CENTER: Title describing the app
            ToolbarItem(placement: .principal){
                Spacer()
            }
            
            // In the toolbar section, add this new ToolbarItem
            ToolbarItem(placement: .status) {
                if !vm.isProcessing && !vm.comparisonResults.isEmpty {
                    Text("Found \(displayedRows.count) duplicates")
                        .padding(.horizontal)
                }
            }
            
            // RIGHT: Primary actions
            ToolbarItemGroup(placement: .primaryAction) {
                // Combine both sides
                let pendingCount = vm.selectedMatchesForDeletion.count + vm.selectedReferencesForDeletion.count

                // Clear selection button
                if pendingCount > 0 {
                    Button {
                        // Prefer vm.clearSelection() if you updated it to clear both sets.
                        // If not, uncomment the 2 lines below:
                        // vm.selectedReferencesForDeletion.removeAll()
                        // vm.selectedMatchesForDeletion.removeAll()
                        vm.clearSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.badge.xmark")
                            Text("Clear selection")
                        }
                    }
                    .help("Clear selection (\(pendingCount) item\(pendingCount == 1 ? "" : "s"))")
                    .disabled(vm.isAnyOperationRunning)
                }

                // Delete selected button
                if pendingCount > 0 {
                    Button {
                        // If you added deletePendingSelections() use that:
                        // vm.deletePendingSelections()
                        //
                        // Otherwise, call what you have today (matches). References will be handled
                        // once the VM method exists:
                        vm.deletePendingSelections()
                        // If your VM already has deleteSelectedReferences(), call it too:
                        // vm.deleteSelectedReferences()
                    } label: {
                        HStack(spacing: 6) {
                            Label("Delete selected", systemImage: "trash")
                            Text("\(pendingCount)")
                                .font(.caption).fontWeight(.medium)
                        }
                    }
                    .help("Delete \(pendingCount) selected item\(pendingCount == 1 ? "" : "s")")
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
                    // Ready state (only show if no pending deletions)
                    if pendingCount == 0 {
                        Button {
                            // Clear selection states when starting new analysis
                            //tableSelection.removeAll()
                            //vm.clearSelection()
                            vm.processImages(progress: { _ in })
                        } label: {
                            Label("Analyze", systemImage: "sparkle")
                        }
                        .disabled(vm.activeLeafFolders.isEmpty)
                    }
                }
            }
        }
        // MARK: - Keyboard Shortcuts
        // MARK: - Keyboard Shortcuts - Fixed to respect popover state
        .onKeyPress(.leftArrow) {
            guard !showSettingsPopover else { return .ignored }
            quickLookGoPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard !showSettingsPopover else { return .ignored }
            quickLookGoNext()
            return .handled
        }
        .onKeyPress("z") {
            guard !showSettingsPopover else { return .ignored }
            let targets = !debouncedSelection.isEmpty ? debouncedSelection : tableSelection
            guard !targets.isEmpty else { return .handled }
            DispatchQueue.main.async {
                for id in targets {
                    if vm.selectedReferencesForDeletion.contains(id) {
                        vm.selectedReferencesForDeletion.remove(id)
                    } else {
                        vm.selectedReferencesForDeletion.insert(id)
                    }
                }
            }
            return .handled
        }
        .onKeyPress("x") {
            guard !showSettingsPopover else { return .ignored }
            let targets = !debouncedSelection.isEmpty ? debouncedSelection : tableSelection
            guard !targets.isEmpty else { return .handled }
            DispatchQueue.main.async {
                for id in targets {
                    if vm.selectedMatchesForDeletion.contains(id) {
                        vm.selectedMatchesForDeletion.remove(id)
                    } else {
                        vm.selectedMatchesForDeletion.insert(id)
                    }
                }
            }
            return .handled
        }
        .onKeyPress(.space) {
            guard !showSettingsPopover else { return .ignored }
            // Prefer the already-computed selectedRow to avoid extra lookup
            if let row = selectedRow {
                openPairInQuickLook(row, referenceFirst: true)
                refocusPrimaryWindow()
                return .handled
            }
            // Fallback to current selection and resolve within displayedRows
            let targets = !debouncedSelection.isEmpty ? debouncedSelection : tableSelection
            guard let id = targets.first,
                  let row = displayedRows.first(where: { $0.id == id })
            else { return .handled }
            openPairInQuickLook(row, referenceFirst: true)
            refocusPrimaryWindow()
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
            selectionDebounceTimer?.invalidate()
            selectionDebounceTimer = nil
            tableSelection = []
            debouncedSelection = []
            sortOrder = []
            vm.updateDisplayedRows(sortOrder: [])
        }
        .onChange(of: vm.activeSortedRows) { _, newRows in
            handleActiveRowsChange(newRows)
        }
        .onAppear {
            // Initialize display on first load
            vm.updateDisplayedRows(sortOrder: sortOrder)

            // Show tutorial on first launch
            if !UserDefaults.standard.bool(forKey: "hasSeenTutorial") {
                showTutorial = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
            showTutorial = true
        }
        .fileExporter(
            isPresented: $vm.isExportingCSV,
            document: vm.csvDocument,
            contentType: .commaSeparatedText,
            defaultFilename: vm.exportFilename
        ) { result in
            vm.handleCSVExportResult(result)
        }
        .alert("No Results Found", isPresented: $vm.showNoResultsAlert) {
            Button("OK") { }
            Button("Adjust Settings") {
                showSettingsPopover = true
            }
        } message: {
            Text(vm.noResultsAlertMessage)
        }
    }
}
