//
//  FolderSelectionViewModel.swift
//  ImageGuru
//
//  Handles folder selection and leaf folder management
//

import SwiftUI
import AppKit
import Combine

@MainActor
final class FolderSelectionViewModel: ObservableObject {
    
    // MARK: - Published State
    @Published var selectedLeafIDs: Set<UUID> = []
    @Published var leafSortOrder: [KeyPathComparator<LeafFolder>] = []
    
    // MARK: - Dependencies
    private weak var appViewModel: AppViewModel?
    
    init(appViewModel: AppViewModel?) {
        self.appViewModel = appViewModel
    }
    
    // Method to set the app view model (for cases where it's not available during init)
    func setAppViewModel(_ appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
    }
    
    // MARK: - Computed Properties
    
    var sortedLeafFolders: [LeafFolder] {
        guard let appViewModel = appViewModel else { return [] }
        guard !appViewModel.selectedFolderURLs.isEmpty else { return [] }
        
        // Find all leaf folders from the selected parent folders
        let foundLeafs = FileSystemHelpers.findLeafFolders(from: appViewModel.selectedFolderURLs)
        let folders = foundLeafs.map { LeafFolder(url: $0) }
        
        // Apply sorting based on current sort order or default
        if leafSortOrder.isEmpty {
            return folders.sorted { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }
        } else {
            return folders.sorted(using: leafSortOrder)
        }
    }
    
    var hasSelectedFolders: Bool {
        appViewModel?.selectedFolderURLs.isEmpty == false
    }
    
    var selectedLeafCount: Int {
        selectedLeafIDs.count
    }
    
    var totalLeafCount: Int {
        sortedLeafFolders.count
    }
    
    // MARK: - Actions
    
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
    
    func addFolders(_ urls: [URL]) {
        guard let appViewModel = appViewModel else { return }
        
        // Filter to only include directories
        let newFolders = FileSystemHelpers.filterDirectories(from: urls)
        
        // Filter out duplicates and add new folders
        let uniqueNewFolders = FileSystemHelpers.uniqueURLs(from: newFolders, existingURLs: appViewModel.selectedFolderURLs)
        appViewModel.selectedFolderURLs.append(contentsOf: uniqueNewFolders)
        
        // Auto-select all discovered leaf folders (both existing and new)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.selectedLeafIDs = Set(self.sortedLeafFolders.map(\.id))
        }
    }
    
    func removeLeaf(_ leaf: LeafFolder) {
        selectedLeafIDs.remove(leaf.id)
        // Note: We don't remove from parent folders since one parent might contribute multiple leafs
        // This maintains the current behavior from ContentView
    }
    
    func removeLeafs(withIDs ids: Set<UUID>) {
        selectedLeafIDs.subtract(ids)
    }
    
    func removeSelectedLeafs() {
        selectedLeafIDs.removeAll()
    }
    
    func selectAllLeafs() {
        selectedLeafIDs = Set(sortedLeafFolders.map(\.id))
    }
    
    func deselectAllLeafs() {
        selectedLeafIDs.removeAll()
    }
    
    func clearAllFolders() {
        appViewModel?.selectedFolderURLs.removeAll()
        selectedLeafIDs.removeAll()
    }
    
    // MARK: - Helper Properties for UI
    
    var canRemoveSelected: Bool {
        !selectedLeafIDs.isEmpty && !(appViewModel?.isProcessing ?? true)
    }
    
    var canSelectAll: Bool {
        selectedLeafIDs.count < sortedLeafFolders.count
    }
    
    var canDeselectAll: Bool {
        !selectedLeafIDs.isEmpty
    }
    
    var selectionSummary: String {
        if sortedLeafFolders.isEmpty {
            return "No folders selected"
        } else if selectedLeafIDs.isEmpty {
            return "0 of \(totalLeafCount) folders selected"
        } else {
            return "\(selectedLeafCount) of \(totalLeafCount) folders selected"
        }
    }
}
