/*

 AppViewModel.swift - Streamlined
 Twinalyzer

 George Babichev

 */

import SwiftUI
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

// MARK: - Main Application State Manager
@MainActor
final class AppViewModel: ObservableObject {
    
    // MARK: - CSV Export
    @Published var isExportingCSV = false
    @Published var csvDocument: CSVDocument? = nil
    @Published var exportFilename: String = "Results"
    
    // MARK: - Configuration Constants
    private nonisolated static let maxDiscoveryBatchSize = 2000
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
    @Published var comparisonResults: [ImageComparisonResult] = [] {
        didSet { invalidateAllCaches() }
    }
    
    // MARK: - Table State Management
    @Published var activeSortedRows: [TableRow] = []
    @Published var tableReloadToken: Int = 0  // Force table reload on sort changes
    private var sortComputeTask: Task<[TableRow], Never>? = nil
    private var _sortCache: [String: [TableRow]] = [:]  // Cache sorted results
    
    // MARK: - Static Snapshot (frozen after analysis)
    /// These drive the "Cross-Folder Duplicates" panel and remain static until next analysis
    @Published var folderClustersStatic: [[String]] = []
    @Published var representativeImageByFolderStatic: [String: String] = [:]
    @Published var crossFolderDuplicateCountsStatic: [String: Int] = [:]
    @Published var folderDisplayNamesStatic: [String: String] = [:]

    // Ordered cross-folder pairs following table reference→match direction
    struct OrderedFolderPair: Identifiable, Hashable {
        let id = UUID()
        let reference: String
        let match: String
        let count: Int
    }
    @Published var orderedCrossFolderPairsStatic: [OrderedFolderPair] = []

    
    // MARK: - Performance Cache Storage
    private var _tableRowsCache: [TableRow]?
    //private var _sortCache: [String: [TableRow]] = [:]  // Cache sorted results
    
    // MARK: - Task Management
    private var analysisTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var lastProgressUpdate: Date = .distantPast
    
    // MARK: - Computed Properties (lightweight)
    var activeLeafFolders: [URL] {
        discoveredLeafFolders.filter { !excludedLeafFolders.contains($0) }
    }

    var isAnyOperationRunning: Bool {
        isProcessing || isDiscoveringFolders
    }
    
    var allFoldersBeingProcessed: [URL] {
        if isDiscoveringFolders {
            return selectedParentFolders.sorted { $0.path < $1.path }
        } else {
            return activeLeafFolders.sorted { $0.path < $1.path }
        }
    }
    
    // MARK: - Table Data Management
    
    /// Generates TableRow objects from comparison results (cached)
    var tableRows: [TableRow] {
        if let cached = _tableRowsCache { return cached }
        
        let result = comparisonResults.flatMap { result in
            result.similars
                .filter { $0.path != result.reference }
                .map { similar in
                    TableRow(
                        reference: result.reference,
                        similar: similar.path,
                        percent: similar.percent
                    )
                }
        }
        
        _tableRowsCache = result
        return result
    }
    
    /// Updates the displayed rows with the given sort order
    /// FIXED: Proper off-main-thread sorting with caching to prevent beachballing
    func updateDisplayedRows(sortOrder: [KeyPathComparator<TableRow>]) {
        let cacheKey = sortCacheKey(for: sortOrder)
        
        // 1) Check cache first for immediate response
        if let cached = _sortCache[cacheKey] {
            activeSortedRows = cached
            tableReloadToken &+= 1  // Force table reload
            return
        }
        
        // 2) Cancel any in-flight sort to avoid race conditions
        sortComputeTask?.cancel()
        
        // 3) Snapshot the base data on main thread (value copy)
        let baseRows = tableRows
        
        // 4) Sort off-main-thread to prevent beachballing
        sortComputeTask = Task.detached(priority: .userInitiated) {
            let sortedRows: [TableRow]
            if sortOrder.isEmpty {
                // Default sort by similarity (highest first)
                sortedRows = baseRows.sorted { $0.percent > $1.percent }
            } else {
                sortedRows = baseRows.sorted(using: sortOrder)
            }
            return sortedRows
        }
        
        // 5) Update on main thread when complete
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if let rows = await self.sortComputeTask?.value {
                // Cache the result for future use
                self._sortCache[cacheKey] = rows
                self.activeSortedRows = rows
                self.tableReloadToken &+= 1  // Force table reload
                self.sortComputeTask = nil
            }
        }
    }
    
    /// Creates a cache key for the sort order to enable fast lookup
    private func sortCacheKey(for sortOrder: [KeyPathComparator<TableRow>]) -> String {
        guard !sortOrder.isEmpty else { return "default" }
        
        return sortOrder.map { comparator in
            let keyPath = String(describing: comparator.keyPath)
            let order = comparator.order == .forward ? "asc" : "desc"
            return "\(keyPath)_\(order)"
        }.joined(separator: "|")
    }
    
    private func invalidateAllCaches() {
        _tableRowsCache = nil
        _sortCache.removeAll()  // Clear sort cache
        
        // Clear the active sorted rows so they get recomputed
        activeSortedRows = []
        tableReloadToken &+= 1  // Force table reload
    }
    
    // MARK: - User Actions
    
    private func isDescendant(_ child: URL, of ancestor: URL) -> Bool {
        let a = ancestor.standardizedFileURL.pathComponents
        let c = child.standardizedFileURL.pathComponents
        return c.starts(with: a)
    }
    
    private func removeExclusions(under parents: [URL]) {
        guard !parents.isEmpty else { return }
        let parentsStd = parents.map { $0.standardizedFileURL }
        excludedLeafFolders = excludedLeafFolders.filter { leaf in
            !parentsStd.contains { parent in isDescendant(leaf, of: parent) }
        }
    }
    
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

    /// Unified entry point for .onDrop
    @MainActor
    func ingestDroppedURLs(_ urls: [URL]) {
        let dirs = FileSystemHelpers.filterDirectories(from: urls).map { $0.standardizedFileURL }
        guard !dirs.isEmpty else { return }

        var leaves: [URL] = []
        var parents: [URL] = []
        let ignored = ignoredFolderName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        for dir in dirs {
            if directoryContainsImageFiles(dir, ignoredName: ignored) {
                leaves.append(dir)
            } else {
                parents.append(dir)
            }
        }

        if !leaves.isEmpty { addLeafFolders(leaves) }
        if !parents.isEmpty { addParentFolders(parents) }
    }

    /// Adds leaf folders directly
    @MainActor
    private func addLeafFolders(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let dropped = urls.map { $0.standardizedFileURL }
        let droppedSet = Set(dropped)

        var changed = false

        // Un-exclude these leaves
        let beforeExCount = excludedLeafFolders.count
        excludedLeafFolders = excludedLeafFolders.filter { ex in
            !droppedSet.contains(ex.standardizedFileURL)
        }
        if excludedLeafFolders.count != beforeExCount { changed = true }

        // Append new leaves
        var seen = Set(discoveredLeafFolders.map { $0.standardizedFileURL })
        for s in dropped {
            if !seen.contains(s) {
                discoveredLeafFolders.append(s)
                seen.insert(s)
                changed = true
            }
        }

        if changed {
            reconcileExclusionsWithDiscovered()
        }
    }
    
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
                self.discoveredLeafFolders.removeAll { leaf in
                    parentsStd.contains { self.isDescendant(leaf, of: $0) }
                }
                var seen = Set(self.discoveredLeafFolders.map { $0.standardizedFileURL })
                for leaf in freshlyDiscovered {
                    let s = leaf.standardizedFileURL
                    if !seen.contains(s) {
                        self.discoveredLeafFolders.append(s)
                        seen.insert(s)
                    }
                }
                self.excludedLeafFolders = self.excludedLeafFolders.filter { ex in
                    !parentsStd.contains { self.isDescendant(ex, of: $0) }
                }
                self.reconcileExclusionsWithDiscovered()
                self.isDiscoveringFolders = false
                self.discoveryTask = nil
            }
        }
    }
    
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
                if discovered.count >= Self.maxDiscoveryBatchSize { break }
                discovered.append(folder)
            }
            if discovered.count >= Self.maxDiscoveryBatchSize { break }
            await Task.yield()
        }
        return discovered
    }
    
    /// Quick heuristic: a directory is a "leaf" if it directly contains image files
    private func directoryContainsImageFiles(_ directory: URL, ignoredName: String) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        let imageExtensions: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","bmp","gif","webp","dng","cr2","nef","arw"]
        for item in contents {
            if let rv = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) {
                if rv.isDirectory == true {
                    let subfolderName = item.lastPathComponent.lowercased()
                    if !ignoredName.isEmpty && subfolderName == ignoredName { continue }
                } else if rv.isRegularFile == true {
                    if imageExtensions.contains(item.pathExtension.lowercased()) { return true }
                }
            }
        }
        return false
    }

    private func findLeafFoldersWithIgnoreFilter(root: URL, ignoredName: String) async -> [URL] {
        return await Task.detached {
            let fm = FileManager.default
            var leafFolders: [URL] = []
            func findLeafFolders(in directory: URL) {
                let folderName = directory.lastPathComponent.lowercased()
                if !ignoredName.isEmpty && folderName == ignoredName { return }
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
                            if imageExtensions.contains(ext) { hasImageFiles = true }
                        }
                    }
                }
                if hasImageFiles { leafFolders.append(directory) }
                if !subdirectories.isEmpty {
                    for subdir in subdirectories { findLeafFolders(in: subdir) }
                }
            }
            findLeafFolders(in: root)
            return leafFolders
        }.value
    }
    
    func removeLeafFolder(_ leafURL: URL) {
        excludedLeafFolders.insert(leafURL.standardizedFileURL)
    }
    
    // MARK: - Analysis Operations
    func processImages(progress: @escaping @Sendable (Double) -> Void) {
        guard !isAnyOperationRunning else { return }
        
        // Clear the static snapshot up front
        folderClustersStatic.removeAll()
        representativeImageByFolderStatic.removeAll()
        crossFolderDuplicateCountsStatic.removeAll()
        folderDisplayNamesStatic.removeAll()
        
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
                }
            }
            DispatchQueue.main.async { progress(p) }
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
                    self.updateDisplayedRows(sortOrder: [])
                    // Build the static snapshot once per run
                    self.buildFolderDuplicatesSnapshot()
                }
                self.processingProgress = nil
                self.isProcessing = false
                self.analysisTask = nil
            }
        }
    }
    
    /// Builds the frozen snapshot from the current comparison results
    
private func buildFolderDuplicatesSnapshot() {
        let rows = tableRows

        // Representative image per folder
        var reps: [String: String] = [:]
        // Display names cache
        var displayNames: [String: String] = [:]

        for row in rows {
            let refFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path

            if reps[refFolder] == nil { reps[refFolder] = row.reference }
            if reps[matchFolder] == nil { reps[matchFolder] = row.similar }

            // Cache display names
            if displayNames[refFolder] == nil {
                displayNames[refFolder] = DisplayHelpers.formatFolderDisplayName(for: URL(fileURLWithPath: refFolder))
            }
            if displayNames[matchFolder] == nil {
                displayNames[matchFolder] = DisplayHelpers.formatFolderDisplayName(for: URL(fileURLWithPath: matchFolder))
            }
        }

        // Cross-folder counts (per folder, bidirectional)
        var folderHitCounts: [String: Int] = [:]
        for row in rows {
            let ref = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let match = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            guard ref != match else { continue }
            folderHitCounts[ref, default: 0] += 1
            folderHitCounts[match, default: 0] += 1
        }

        // Folder relationship clusters (unordered unique pairs)
        var folderPairs: Set<[String]> = []
        for row in rows {
            let a = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let b = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            guard a != b else { continue }
            folderPairs.insert([a, b].sorted())
        }
        let clusters = Array(folderPairs).sorted { $0[0] < $1[0] }

        // Directional majority (reference → match) to mirror table direction
        struct DirKey: Hashable { let ref: String; let match: String }
        struct UnKey: Hashable { let a: String; let b: String }
        var directional: [DirKey: Int] = [:]
        for row in rows {
            let rf = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let mf = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            guard rf != mf else { continue }
            directional[DirKey(ref: rf, match: mf), default: 0] += 1
        }

        var totals: [UnKey: (ab: Int, ba: Int)] = [:]
        for (k, c) in directional {
            if k.ref <= k.match {
                let u = UnKey(a: k.ref, b: k.match)
                var t = totals[u] ?? (ab: 0, ba: 0)
                t.ab += c
                totals[u] = t
            } else {
                let u = UnKey(a: k.match, b: k.ref)
                var t = totals[u] ?? (ab: 0, ba: 0)
                t.ba += c
                totals[u] = t
            }
        }

        var orderedPairs: [OrderedFolderPair] = []
        orderedPairs.reserveCapacity(totals.count)
        for (u, t) in totals {
            if t.ab > t.ba {
                orderedPairs.append(.init(reference: u.a, match: u.b, count: t.ab))
            } else if t.ba > t.ab {
                orderedPairs.append(.init(reference: u.b, match: u.a, count: t.ba))
            } else {
                // tie → deterministic
                orderedPairs.append(.init(reference: u.a, match: u.b, count: t.ab))
            }
        }
        orderedPairs.sort {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.reference != $1.reference { return $0.reference < $1.reference }
            return $0.match < $1.match
        }

        // Commit the snapshot
        self.representativeImageByFolderStatic = reps
        self.crossFolderDuplicateCountsStatic = folderHitCounts
        self.folderClustersStatic = clusters
        self.folderDisplayNamesStatic = displayNames
        self.orderedCrossFolderPairsStatic = orderedPairs
    }

    
    func cancelAnalysis() {
        cancelAllOperations()
        isProcessing = false
        isDiscoveringFolders = false
        processingProgress = nil
    }
    
    private func cancelAllOperations() {
        analysisTask?.cancel(); analysisTask = nil
        discoveryTask?.cancel(); discoveryTask = nil
        sortComputeTask?.cancel(); sortComputeTask = nil
    }
    
    // MARK: - File System Operations
    func openFolderInFinder(_ folder: String) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        NSWorkspace.shared.open(url)
    }
    
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
    var hasSelectedMatches: Bool { !selectedMatchesForDeletion.isEmpty }
    
    func toggleSelection(for rowIDs: Set<String>) {
        if rowIDs.count > 1 {
            let allChecked = rowIDs.allSatisfy { selectedMatchesForDeletion.contains($0) }
            if allChecked {
                for rowID in rowIDs { selectedMatchesForDeletion.remove(rowID) }
            } else {
                for rowID in rowIDs { selectedMatchesForDeletion.insert(rowID) }
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
        activeSortedRows.removeAll()
        
        // Clear the static snapshot
        folderClustersStatic.removeAll()
        representativeImageByFolderStatic.removeAll()
        crossFolderDuplicateCountsStatic.removeAll()
        folderDisplayNamesStatic.removeAll()
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
        let rows = activeSortedRows.isEmpty ? tableRows.sorted { $0.percent > $1.percent } : activeSortedRows
        lines.reserveCapacity(rows.count + 1)
        for row in rows {
            let referenceFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            let isCrossFolder = referenceFolder != matchFolder
            let line = [
                Self.escapeCSVField(row.reference),
                Self.escapeCSVField(row.similar),
                String(format: "%.1f%%", row.percent * 100),
                isCrossFolder ? "Yes" : "No",
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
    
    // MARK: - Exclusion Reconciliation
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

