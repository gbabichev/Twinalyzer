/*
 
 AppViewModel.swift - Simplified Version
 Twinalyzer
 
 */

import SwiftUI
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    
    // MARK: - CSV Export
    @Published var isExportingCSV = false
    @Published var csvDocument: CSVDocument? = nil
    @Published var exportFilename: String = "Results"
    
    // MARK: - Configuration Constants
    private nonisolated static let maxDiscoveryBatchSize = 2000
    private nonisolated static let discoveryChunkSize = 100
    private nonisolated static let progressUpdateThrottle = 0.1
    
    // MARK: - Core Published State
    @Published var selectedParentFolders: [URL] = []
    @Published var excludedLeafFolders: Set<URL> = []
    @Published var discoveredLeafFolders: [URL] = []
    @AppStorage("similarityThreshold") var similarityThreshold: Double = 0.7
    @AppStorage("selectedAnalysisMode") var selectedAnalysisMode: AnalysisMode = .deepFeature
    @AppStorage("scanTopLevelOnly") var scanTopLevelOnly: Bool = false
    @AppStorage("ignoredFolderName") var ignoredFolderName: String = "thumb"
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double? = nil
    @Published var isDiscoveringFolders: Bool = false
    @Published var comparisonResults: [ImageComparisonResult] = []
    
    // MARK: - Enhanced Task Management
    private var analysisTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var lastProgressUpdate: Date = .distantPast
    
    // MARK: - Simple Computed Properties (No Caching!)
    
    /// Folders that will actually be analyzed (after user exclusions)
    var activeLeafFolders: [URL] {
        discoveredLeafFolders.filter { !excludedLeafFolders.contains($0) }
    }
    
    /// Computed property to check if any operation is running
    var isAnyOperationRunning: Bool {
        isProcessing || isDiscoveringFolders
    }
    
    /// Sorted list of folders currently being processed (for progress display)
    var allFoldersBeingProcessed: [URL] {
        if isDiscoveringFolders {
            return selectedParentFolders.sorted { $0.path < $1.path }
        } else {
            return activeLeafFolders.sorted { $0.path < $1.path }
        }
    }
    
    // MARK: - SIMPLIFIED: Just flatten the results, no caching!
    /// Simple flattening - let SwiftUI handle the sorting natively
    var flattenedResults: [TableRow] {
        comparisonResults.flatMap { result in
            result.similars
                .filter { $0.path != result.reference }
                .map { TableRow(reference: result.reference, similar: $0.path, percent: $0.percent) }
        }
    }
    
    // MARK: - Minimal Folder Statistics (for cross-folder panel only)
    /// Simple folder grouping for the cross-folder panel
    var folderClusters: [[String]] {
        var folderPairs: Set<[String]> = []
        
        for row in flattenedResults where row.isCrossFolder {
            let referenceFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            let sortedPair = [referenceFolder, matchFolder].sorted()
            folderPairs.insert(sortedPair)
        }
        
        return Array(folderPairs).sorted { $0[0] < $1[0] }
    }
    
    /// Simple cross-folder duplicate counts
    var crossFolderDuplicateCounts: [String: Int] {
        var counts: [String: Int] = [:]
        
        for row in flattenedResults where row.isCrossFolder {
            let referenceFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            counts[referenceFolder, default: 0] += 1
            counts[matchFolder, default: 0] += 1
        }
        
        return counts
    }
    
    /// Simple representative image mapping
    var representativeImageByFolder: [String: String] {
        var representatives: [String: String] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                if representatives[folder] == nil {
                    representatives[folder] = path
                }
            }
        }
        return representatives
    }
    
    // MARK: - User Actions
    
    // Descendant check used by exclusion cleanup
    private func isDescendant(_ child: URL, of ancestor: URL) -> Bool {
        let a = ancestor.standardizedFileURL.pathComponents
        let c = child.standardizedFileURL.pathComponents
        return c.starts(with: a)
    }

    // Clear exclusions that live under the specified parents
    private func removeExclusions(under parents: [URL]) {
        guard !parents.isEmpty else { return }
        let parentsStd = parents.map { $0.standardizedFileURL }
        excludedLeafFolders = excludedLeafFolders.filter { leaf in
            !parentsStd.contains { parent in isDescendant(leaf, of: parent) }
        }
    }

    /// Adds parent folders; re-adding an existing parent triggers a targeted rescan
    @MainActor
    func addParentFolders(_ urls: [URL]) {
        let dirs = FileSystemHelpers.filterDirectories(from: urls)
        guard !dirs.isEmpty else { return }

        let existing = Set(selectedParentFolders.map { $0.standardizedFileURL })
        var toRescan: [URL] = []
        var toAppend: [URL] = []

        for u in dirs {
            let s = u.standardizedFileURL
            if existing.contains(s) {
                toRescan.append(s)
            } else {
                toAppend.append(s)
            }
        }

        if !toAppend.isEmpty {
            selectedParentFolders.append(contentsOf: toAppend)
            removeExclusions(under: toAppend)
            discoverFoldersAsync()
        }

        if !toRescan.isEmpty {
            rescanSelectedParents(toRescan)
        }
    }

    // MARK: - Targeted rescan (no UI)
    @MainActor
    private func rescanSelectedParents(_ parents: [URL]) {
        guard !parents.isEmpty else { return }
        guard !isAnyOperationRunning else { return }

        isDiscoveringFolders = true
        let parentsStd = parents.map { $0.standardizedFileURL }

        discoveryTask?.cancel()
        discoveryTask = Task {
            let ignored = self.ignoredFolderName
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let freshlyDiscovered: [URL] = await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return [] }
                var out: [URL] = []
                for p in parentsStd {
                    if Task.isCancelled { break }
                    let leaves = await self.findLeafFoldersWithIgnoreFilter(root: p, ignoredName: ignored)
                    out.append(contentsOf: leaves)
                }
                return out
            }.value

            guard !Task.isCancelled else {
                await MainActor.run {
                    self.isDiscoveringFolders = false
                    self.discoveryTask = nil
                }
                return
            }

            await MainActor.run {
                // Remove previously discovered leafs that live under these parents
                self.discoveredLeafFolders.removeAll { leaf in
                    parentsStd.contains { self.isDescendant(leaf, of: $0) }
                }

                // Merge freshly discovered leafs (dedupe)
                var seen = Set(self.discoveredLeafFolders.map { $0.standardizedFileURL })
                for leaf in freshlyDiscovered {
                    let s = leaf.standardizedFileURL
                    if !seen.contains(s) {
                        self.discoveredLeafFolders.append(s)
                        seen.insert(s)
                    }
                }

                // Clear exclusions that live under these parents
                self.excludedLeafFolders = self.excludedLeafFolders.filter { ex in
                    !parentsStd.contains { self.isDescendant(ex, of: $0) }
                }

                // Global pruning: keep exclusions only if that leaf still exists
                self.reconcileExclusionsWithDiscovered()

                self.isDiscoveringFolders = false
                self.discoveryTask = nil
            }
        }
    }

    /// Enhanced folder discovery
    private func discoverFoldersAsync() {
        guard !selectedParentFolders.isEmpty else { return }
        guard !isAnyOperationRunning else { return }
        
        discoveryTask?.cancel()
        isDiscoveringFolders = true
        
        let foldersToScan = selectedParentFolders
        
        discoveryTask = Task {
            let discovered = await Task.detached(priority: .userInitiated) {
                await self.discoverFoldersWithLimits(from: foldersToScan)
            }.value
            
            await MainActor.run {
                if !Task.isCancelled {
                    self.discoveredLeafFolders = discovered
                    self.reconcileExclusionsWithDiscovered()

                    if discovered.count >= Self.maxDiscoveryBatchSize {
                        print("Warning: Discovery limited to \(Self.maxDiscoveryBatchSize) folders to prevent memory issues")
                    }
                }
                self.isDiscoveringFolders = false
                self.discoveryTask = nil
            }
        }
    }
    
    /// Enhanced folder discovery with memory pressure monitoring and batch limiting
    private func discoverFoldersWithLimits(from roots: [URL]) async -> [URL] {
        var discovered: [URL] = []
        discovered.reserveCapacity(Self.maxDiscoveryBatchSize)
        
        let ignoredName = ignoredFolderName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        for root in roots {
            if Task.isCancelled { break }
            
            if await isMemoryPressureHigh() {
                print("Warning: High memory pressure detected during folder discovery")
                break
            }
            
            let leafFolders = await findLeafFoldersWithIgnoreFilter(root: root, ignoredName: ignoredName)
            
            for folder in leafFolders {
                if discovered.count >= Self.maxDiscoveryBatchSize {
                    break
                }
                discovered.append(folder)
            }
            
            if discovered.count >= Self.maxDiscoveryBatchSize {
                break
            }
            
            await Task.yield()
        }
        
        return discovered
    }
    
    /// Find leaf folders while filtering ignored folders
    private func findLeafFoldersWithIgnoreFilter(root: URL, ignoredName: String) async -> [URL] {
        return await Task.detached {
            let fm = FileManager.default
            var leafFolders: [URL] = []
            
            func findLeafFolders(in directory: URL) {
                let folderName = directory.lastPathComponent.lowercased()
                if !ignoredName.isEmpty && folderName == ignoredName {
                    return
                }
                
                guard let contents = try? fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return }
                
                var subdirectories: [URL] = []
                var hasImageFiles = false
                
                for item in contents {
                    if let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) {
                        if resourceValues.isDirectory == true {
                            let subfolderName = item.lastPathComponent.lowercased()
                            if ignoredName.isEmpty || subfolderName != ignoredName {
                                subdirectories.append(item)
                            }
                        } else if resourceValues.isRegularFile == true {
                            let ext = item.pathExtension.lowercased()
                            let imageExtensions: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","bmp","gif","webp","dng","cr2","nef","arw"]
                            if imageExtensions.contains(ext) {
                                hasImageFiles = true
                            }
                        }
                    }
                }
                
                if hasImageFiles {
                    leafFolders.append(directory)
                }

                if !subdirectories.isEmpty {
                    for subdir in subdirectories {
                        findLeafFolders(in: subdir)
                    }
                }
            }
            
            findLeafFolders(in: root)
            return leafFolders
        }.value
    }
    
    /// Excludes a leaf folder from analysis
    func removeLeafFolder(_ leafURL: URL) {
        excludedLeafFolders.insert(leafURL.standardizedFileURL)
    }
    
    // MARK: - Enhanced Analysis Operations

    /// Starts image analysis
    func processImages(progress: @escaping @Sendable (Double) -> Void) {
        guard !isAnyOperationRunning else { return }
        
        cancelAllOperations()
        isProcessing = true
        processingProgress = 0.0

        let leafFolders = activeLeafFolders
        let threshold = similarityThreshold
        let topOnly = scanTopLevelOnly
        let ignoredFolder = ignoredFolderName

        let progressWrapper: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                let now = Date()
                if let self = self, now.timeIntervalSince(self.lastProgressUpdate) >= Self.progressUpdateThrottle {
                    self.lastProgressUpdate = now
                    self.processingProgress = p
                    progress(p)
                }
            }
        }

        analysisTask = Task {
            let results: [ImageComparisonResult]
            
            switch selectedAnalysisMode {
            case .deepFeature:
                results = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        ImageAnalyzer.analyzeWithDeepFeatures(
                            inFolders: leafFolders,
                            similarityThreshold: threshold,
                            topLevelOnly: topOnly,
                            ignoredFolderName: ignoredFolder,
                            progress: progressWrapper,
                            shouldCancel: { Task.isCancelled },
                            completion: { results in continuation.resume(returning: results) }
                        )
                    }
                } onCancel: {}
                
            case .perceptualHash:
                results = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        ImageAnalyzer.analyzeWithPerceptualHash(
                            inFolders: leafFolders,
                            similarityThreshold: threshold,
                            topLevelOnly: topOnly,
                            ignoredFolderName: ignoredFolder,
                            progress: progressWrapper,
                            shouldCancel: { Task.isCancelled },
                            completion: { results in continuation.resume(returning: results) }
                        )
                    }
                } onCancel: {}
            }
            
            await MainActor.run {
                if !Task.isCancelled {
                    self.comparisonResults = results
                }
                self.processingProgress = nil
                self.isProcessing = false
                self.analysisTask = nil
            }
        }
    }

    /// Cancels the current analysis operation
    func cancelAnalysis() {
        cancelAllOperations()
        isProcessing = false
        isDiscoveringFolders = false
        processingProgress = nil
    }
    
    /// Cancel all background operations
    private func cancelAllOperations() {
        analysisTask?.cancel()
        analysisTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    // MARK: - File System Operations
    /// Opens a folder in Finder
    func openFolderInFinder(_ folder: String) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    /// Deletes currently selected matches
    func deleteSelectedMatches() {
        guard !selectedMatchesForDeletion.isEmpty else { return }
        
        let matchesToDelete = Array(selectedMatchesForDeletion)
        selectedMatchesForDeletion.removeAll()
        
        let filePaths = matchesToDelete.compactMap { rowID -> String? in
            let components = rowID.components(separatedBy: "::")
            return components.count == 2 ? components[1] : nil
        }
        
        filePaths.forEach(deleteFile)
    }

    /// Deletes a single file and updates the results data structure
    func deleteFile(_ path: String) {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            print("Failed to move file to trash: \(error.localizedDescription)")
        }
        
        for (index, result) in comparisonResults.enumerated().reversed() {
            let filteredSimilars = result.similars.filter { $0.path != path }
            let hasNonReferenceSimilars = filteredSimilars.contains { $0.path != result.reference }
            
            if result.reference == path || !hasNonReferenceSimilars {
                comparisonResults.remove(at: index)
            } else if filteredSimilars.count != result.similars.count {
                comparisonResults[index] = ImageComparisonResult(
                    reference: result.reference,
                    similars: filteredSimilars
                )
            }
        }
    }
    
    // MARK: - Selection Management
    @Published var selectedMatchesForDeletion: Set<String> = []
    
    var hasSelectedMatches: Bool {
        !selectedMatchesForDeletion.isEmpty
    }
    
    func toggleSelection(for rowIDs: Set<String>) {
        if rowIDs.count > 1 {
            let allChecked = rowIDs.allSatisfy { selectedMatchesForDeletion.contains($0) }
            
            if allChecked {
                for rowID in rowIDs {
                    selectedMatchesForDeletion.remove(rowID)
                }
            } else {
                for rowID in rowIDs {
                    selectedMatchesForDeletion.insert(rowID)
                }
            }
        } else if let focusedID = rowIDs.first {
            if selectedMatchesForDeletion.contains(focusedID) {
                selectedMatchesForDeletion.remove(focusedID)
            } else {
                selectedMatchesForDeletion.insert(focusedID)
            }
        }
    }
    
    func clearSelection() {
        selectedMatchesForDeletion.removeAll()
    }
    
    // MARK: - State Management
    func clearAll() {
        cancelAllOperations()
        isProcessing = false
        isDiscoveringFolders = false
        processingProgress = nil
        
        selectedParentFolders.removeAll()
        excludedLeafFolders.removeAll()
        discoveredLeafFolders.removeAll()
        selectedMatchesForDeletion.removeAll()
        comparisonResults.removeAll()
    }
    
    // MARK: - Memory Pressure Monitoring
    private func isMemoryPressureHigh() async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
                let kerr = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }
                
                if kerr == KERN_SUCCESS {
                    let memoryThreshold: UInt64 = 512 * 1024 * 1024
                    let isHighMemory = info.resident_size > memoryThreshold
                    continuation.resume(returning: isHighMemory)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    // MARK: - CSV Export
    func triggerCSVExport() {
        guard !comparisonResults.isEmpty, !isProcessing else { return }

        let header = "Reference,Match,Similarity,Cross-Folder,Reference Folder,Match Folder"
        var lines: [String] = [header]

        // Use simple flattened results, sorted by percent descending
        let rows = flattenedResults.sorted { $0.percent > $1.percent }
        lines.reserveCapacity(rows.count + 1)

        for row in rows {
            let referenceFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path

            let line = [
                Self.escapeCSVField(row.reference),
                Self.escapeCSVField(row.similar),
                String(format: "%.1f%%", row.percent * 100),
                row.crossFolderText,
                Self.escapeCSVField(referenceFolder),
                Self.escapeCSVField(matchFolder)
            ].joined(separator: ",")

            lines.append(line)
        }

        let csvText = lines.joined(separator: "\n") + "\n"
        csvDocument = CSVDocument(data: Data(csvText.utf8))

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        exportFilename = "Twinalyzer_Results_\(df.string(from: Date()))"

        isExportingCSV = true
    }

    func handleCSVExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }

    // MARK: - Exclusion reconciliation
    @MainActor
    private func reconcileExclusionsWithDiscovered() {
        let discoveredSet = Set(discoveredLeafFolders.map { $0.standardizedFileURL })
        excludedLeafFolders = Set(
            excludedLeafFolders
                .map { $0.standardizedFileURL }
                .filter { discoveredSet.contains($0) }
        )
    }
}
