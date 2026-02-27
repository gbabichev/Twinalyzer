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
import UserNotifications

// MARK: - Main Application State Manager
@MainActor
final class AppViewModel: ObservableObject {
    
    // MARK: - No Results Popup
    @Published var showNoResultsAlert = false
    @Published var noResultsAlertMessage = ""
    
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
    private var sortRequestGeneration: UInt64 = 0
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

        // 1) Cancel prior sort and advance generation so stale completions are ignored.
        sortComputeTask?.cancel()
        sortComputeTask = nil
        sortRequestGeneration &+= 1
        let generation = sortRequestGeneration

        // 2) Check cache first for immediate response
        if let cached = _sortCache[cacheKey] {
            activeSortedRows = cached
            tableReloadToken &+= 1  // Force table reload
            return
        }

        // 3) Snapshot the base data on main thread (value copy)
        let baseRows = tableRows

        // 4) Sort off-main-thread to prevent beachballing
        let sortTask = Task.detached(priority: .userInitiated) {
            let sortedRows: [TableRow]
            if sortOrder.isEmpty {
                // Default sort by similarity (highest first)
                sortedRows = baseRows.sorted { $0.percent > $1.percent }
            } else {
                sortedRows = baseRows.sorted(using: sortOrder)
            }
            return sortedRows
        }

        sortComputeTask = sortTask

        // 5) Update on main thread when complete
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let rows = await sortTask.value

            // Ignore stale results from superseded sort requests.
            guard self.sortRequestGeneration == generation else { return }

            // Cache the result for future use
            self._sortCache[cacheKey] = rows
            self.activeSortedRows = rows
            self.tableReloadToken &+= 1  // Force table reload
            if self.sortRequestGeneration == generation {
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
        sortComputeTask?.cancel()
        sortComputeTask = nil
        sortRequestGeneration &+= 1
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
                    // Only ignore subdirectories with the ignored name, not the directory being checked itself
                    let subfolderName = item.lastPathComponent.lowercased()
                    if !ignoredName.isEmpty && subfolderName == ignoredName {
                        continue // Skip this subdirectory
                    }
                } else if rv.isRegularFile == true {
                    if imageExtensions.contains(item.pathExtension.lowercased()) {
                        return true
                    }
                }
            }
        }
        return false
    }
    
    private func findLeafFoldersWithIgnoreFilter(root: URL, ignoredName: String) async -> [URL] {
        return await Task.detached {
            let fm = FileManager.default
            var leafFolders: [URL] = []
            
            func findLeafFolders(in directory: URL, isRootLevel: Bool = false) {
                // Only apply ignored folder filter to non-root directories
                if !isRootLevel {
                    let folderName = directory.lastPathComponent.lowercased()
                    if !ignoredName.isEmpty && folderName == ignoredName {
                        return // Skip this directory entirely
                    }
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
                            // Apply ignore filter to subdirectories
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
                        findLeafFolders(in: subdir, isRootLevel: false)
                    }
                }
            }
            
            // Start the search at root level (don't apply ignore filter to root)
            findLeafFolders(in: root, isRootLevel: true)
            return leafFolders
        }.value
    }
    
    func removeLeafFolder(_ leafURL: URL) {
        excludedLeafFolders.insert(leafURL.standardizedFileURL)
    }
    
    // MARK: - Analysis Operations
    func processImages(progress: @escaping @Sendable (Double) -> Void) {
        guard !isAnyOperationRunning else { return }
        
        // Ask for notification permission (once). Safe if called repeatedly.
        ensureNotificationAuthorization()
        
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
            
            // Process results off the main thread first to avoid blocking UI
            let tableRowsData = await Task.detached(priority: .userInitiated) {
                // Build TableRow objects off the main thread
                return results.flatMap { result in
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
            }.value

            let didApplyResults = await MainActor.run { () -> Bool in
                guard !Task.isCancelled else { return false }

                // Store results and pre-computed table rows
                self.comparisonResults = results
                self._tableRowsCache = tableRowsData  // Directly set the cache to avoid recomputation

                self.processingProgress = nil
                self.isProcessing = false
                self.analysisTask = nil

                // Check if no results were found and show alert
                let matches = tableRowsData.count
                if matches == 0 {
                    self.showNoResultsAlert = true
                    self.noResultsAlertMessage = "No similar images were found with the current similarity threshold (\(Int(self.similarityThreshold * 100))%). Try lowering the threshold or selecting different folders."
                }

                self.postProcessingDoneNotification(matches: matches)

                // Trigger sorting in background
                self.updateDisplayedRows(sortOrder: [])
                return true
            }

            // Build folder duplicates snapshot off the main thread to prevent beachballing
            if didApplyResults && !Task.isCancelled {
                await self.buildFolderDuplicatesSnapshotAsync()
            }
        }
    }
    
    /// Async version that performs heavy computation off the main thread
    /// Prevents beachballing by building the folder duplicates snapshot on a background thread
    private func buildFolderDuplicatesSnapshotAsync() async {
        if Task.isCancelled { return }

        // Snapshot rows on main thread (quick copy)
        let rows = await MainActor.run { tableRows }
        if Task.isCancelled { return }

        // Perform ALL heavy computation off the main thread
        let snapshotData = await Task.detached(priority: .userInitiated) {
            // Helper function for formatting folder display names (inline to avoid MainActor issues)
            func formatFolderDisplayName(for url: URL) -> String {
                let folderName = url.lastPathComponent
                let parentName = url.deletingLastPathComponent().lastPathComponent

                if parentName.isEmpty || parentName == "/" || parentName == folderName {
                    return folderName
                }

                return "\(parentName)/\(folderName)"
            }

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
                    displayNames[refFolder] = formatFolderDisplayName(for: URL(fileURLWithPath: refFolder))
                }
                if displayNames[matchFolder] == nil {
                    displayNames[matchFolder] = formatFolderDisplayName(for: URL(fileURLWithPath: matchFolder))
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

            return (reps: reps, hitCounts: folderHitCounts, clusters: clusters, displayNames: displayNames, orderedPairs: orderedPairs)
        }.value
        if Task.isCancelled { return }

        // Commit the snapshot on main thread (quick assignment)
        await MainActor.run {
            guard !Task.isCancelled else { return }
            self.representativeImageByFolderStatic = snapshotData.reps
            self.crossFolderDuplicateCountsStatic = snapshotData.hitCounts
            self.folderClustersStatic = snapshotData.clusters
            self.folderDisplayNamesStatic = snapshotData.displayNames
            self.orderedCrossFolderPairsStatic = snapshotData.orderedPairs
        }
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
        sortRequestGeneration &+= 1
    }
    
    // MARK: - File System Operations
    func openFolderInFinder(_ folder: String) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        NSWorkspace.shared.open(url)
    }
    
    private func decodeRowID(_ rowID: String) -> (ref: String, match: String)? {
        let components = rowID.components(separatedBy: "::")
        guard components.count == 2 else { return nil }
        return (ref: components[0], match: components[1])
    }

    private func rowIDsSharingReference(with rowID: String) -> Set<String> {
        guard let refPath = decodeRowID(rowID)?.ref else { return [rowID] }
        let ids = Set(tableRows.lazy.filter { $0.reference == refPath }.map(\.id))
        return ids.isEmpty ? [rowID] : ids
    }

    private var pendingReferenceDeletionSelection: Set<String>? = nil
    private var isReferenceDeletionFlushScheduled = false

    private func currentReferenceDeletionSelection() -> Set<String> {
        pendingReferenceDeletionSelection ?? selectedReferencesForDeletion
    }

    private func queueReferenceDeletionSelection(_ newSelection: Set<String>) {
        pendingReferenceDeletionSelection = newSelection
        guard !isReferenceDeletionFlushScheduled else { return }
        isReferenceDeletionFlushScheduled = true

        DispatchQueue.main.async { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isReferenceDeletionFlushScheduled = false
                guard let pending = self.pendingReferenceDeletionSelection else { return }
                self.pendingReferenceDeletionSelection = nil
                if pending != self.selectedReferencesForDeletion {
                    self.selectedReferencesForDeletion = pending
                }
            }
        }
    }

    func selectReferenceDeletionSelection(forRowID rowID: String) {
        let groupedIDs = rowIDsSharingReference(with: rowID)
        let currentSelection = currentReferenceDeletionSelection()
        guard !groupedIDs.isSubset(of: currentSelection) else { return }
        var nextSelection = currentSelection
        nextSelection.formUnion(groupedIDs)
        queueReferenceDeletionSelection(nextSelection)
    }

    func toggleReferenceDeletionSelection(forRowID rowID: String) {
        toggleReferenceDeletionSelection(forRowIDs: [rowID])
    }

    func toggleReferenceDeletionSelection(forRowIDs rowIDs: Set<String>) {
        guard !rowIDs.isEmpty else { return }

        let allRows = tableRows
        var referencesToToggle: Set<String> = []
        var fallbackRowIDs: Set<String> = []
        var nextSelection = currentReferenceDeletionSelection()

        for rowID in rowIDs {
            if let ref = decodeRowID(rowID)?.ref {
                referencesToToggle.insert(ref)
            } else {
                fallbackRowIDs.insert(rowID)
            }
        }

        for refPath in referencesToToggle {
            let groupedIDs = Set(allRows.lazy.filter { $0.reference == refPath }.map(\.id))
            guard !groupedIDs.isEmpty else { continue }

            // If all variants are already selected, unselect all; otherwise select all.
            if groupedIDs.isSubset(of: nextSelection) {
                nextSelection.subtract(groupedIDs)
            } else {
                nextSelection.formUnion(groupedIDs)
            }
        }

        for rowID in fallbackRowIDs {
            if nextSelection.contains(rowID) {
                nextSelection.remove(rowID)
            } else {
                nextSelection.insert(rowID)
            }
        }

        if nextSelection != currentReferenceDeletionSelection() {
            queueReferenceDeletionSelection(nextSelection)
        }
    }

    func deletePendingSelections() {
        var paths: Set<String> = []
        let referenceSelections = currentReferenceDeletionSelection()
        for id in referenceSelections { if let ref = decodeRowID(id)?.ref { paths.insert(ref) } }
        for id in selectedMatchesForDeletion   { if let match = decodeRowID(id)?.match { paths.insert(match) } }
        pendingReferenceDeletionSelection = nil
        selectedReferencesForDeletion.removeAll()
        selectedMatchesForDeletion.removeAll()
        if !paths.isEmpty { paths.forEach(deleteFile) }
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

    func deleteFolder(_ folderPath: String) {
        do {
            let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
            try FileManager.default.trashItem(at: folderURL, resultingItemURL: nil)
            print("Moved folder to trash: \(folderPath)")

            // Remove the deleted folder from discovered leaf folders and exclusions
            let deletedURL = folderURL.standardizedFileURL
            discoveredLeafFolders.removeAll { $0.standardizedFileURL == deletedURL }
            excludedLeafFolders = excludedLeafFolders.filter { $0.standardizedFileURL != deletedURL }

            // Remove all comparison results involving this folder
            comparisonResults = comparisonResults.compactMap { result in
                let refFolder = URL(fileURLWithPath: result.reference).deletingLastPathComponent().path
                let similarsInFolder = result.similars.filter { similar in
                    let simFolder = URL(fileURLWithPath: similar.path).deletingLastPathComponent().path
                    return simFolder != folderPath
                }

                // Remove the entire result if reference is in deleted folder or no similars remain
                if refFolder == folderPath || similarsInFolder.count <= 1 {
                    return nil
                }

                return ImageComparisonResult(reference: result.reference, similars: similarsInFolder)
            }

            // Rebuild the table and snapshots
            invalidateAllCaches()
            updateDisplayedRows(sortOrder: [])

        } catch {
            print("Failed to move folder to trash: \(error.localizedDescription)")
        }
    }

    func deleteMatchedFolders() {
        // Collect all "match" folders from cross-folder duplicate pairs
        let foldersToDelete = Set(orderedCrossFolderPairsStatic.map { $0.match })

        guard !foldersToDelete.isEmpty else { return }

        // Delete each folder
        for folderPath in foldersToDelete {
            do {
                let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
                try FileManager.default.trashItem(at: folderURL, resultingItemURL: nil)
                print("Moved folder to trash: \(folderPath)")
            } catch {
                print("Failed to move folder to trash: \(error.localizedDescription)")
            }
        }

        // Remove the deleted folders from discovered leaf folders and exclusions
        let deletedURLs = Set(foldersToDelete.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL })
        discoveredLeafFolders.removeAll { deletedURLs.contains($0.standardizedFileURL) }
        excludedLeafFolders = excludedLeafFolders.filter { !deletedURLs.contains($0.standardizedFileURL) }

        // Clear comparison results since we've modified the folder structure
        comparisonResults.removeAll()
        activeSortedRows.removeAll()

        // Clear static snapshots
        folderClustersStatic.removeAll()
        representativeImageByFolderStatic.removeAll()
        crossFolderDuplicateCountsStatic.removeAll()
        folderDisplayNamesStatic.removeAll()
        orderedCrossFolderPairsStatic.removeAll()
    }
    
    
    // MARK: - Selection Management
    @Published var selectedReferencesForDeletion: Set<String> = []
    @Published var selectedMatchesForDeletion: Set<String> = []
    var hasSelectedMatches: Bool {
        !selectedMatchesForDeletion.isEmpty || !selectedReferencesForDeletion.isEmpty
    }

    func clearSelection() {
        pendingReferenceDeletionSelection = nil
        selectedReferencesForDeletion.removeAll()
        selectedMatchesForDeletion.removeAll()
    }
    
    // MARK: - State Management
    func clearAll() {
        // 1. Cancel everything first
        cancelAllOperations()
        
        // 2. Reset state immediately
        isProcessing = false
        isDiscoveringFolders = false
        processingProgress = nil
        
        // 3. Clear data structures once, aggressively
        selectedParentFolders.removeAll(keepingCapacity: false)
        excludedLeafFolders.removeAll()
        discoveredLeafFolders.removeAll(keepingCapacity: false)
        selectedMatchesForDeletion.removeAll(keepingCapacity: false)
        pendingReferenceDeletionSelection = nil
        selectedReferencesForDeletion.removeAll(keepingCapacity: false)
        comparisonResults.removeAll(keepingCapacity: false)
        activeSortedRows.removeAll(keepingCapacity: false)
        
        // Clear static snapshots
        folderClustersStatic.removeAll(keepingCapacity: false)
        representativeImageByFolderStatic.removeAll(keepingCapacity: false)
        crossFolderDuplicateCountsStatic.removeAll(keepingCapacity: false)
        folderDisplayNamesStatic.removeAll(keepingCapacity: false)
        orderedCrossFolderPairsStatic.removeAll(keepingCapacity: false)
        
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
    
    // MARK: - Notifications / Badge
    
    // Ask for notification permission (once). Safe to call repeatedly.
    func ensureNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            // Use async API to avoid capturing a non‑Sendable value.
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }
    
    /// Post a banner and set a Dock badge only if app is NOT frontmost. Safe to call from any thread.
    func postProcessingDoneNotification(matches: Int) {
        // Check foreground state on the main thread; if the app is frontmost, do nothing.
        DispatchQueue.main.async {
            // Treat the app as "in focus" if it is the active (frontmost) app.
            // (Optionally, also consider key/main window status.)
            let appIsFrontmost = NSApp.isActive
            if appIsFrontmost {
                // App is in focus: don't post a notification and don't set a Dock badge.
                return
            }
            
            // App is NOT frontmost → post a banner + set Dock badge
            let content = UNMutableNotificationContent()
            content.title = "Analysis complete"
            content.body = matches > 0 ? "Found \(matches) similar pairs." : "No similar pairs found."
            content.sound = .default
            content.badge = NSNumber(value: 1)
            content.threadIdentifier = "twinalyzer.analysis"
            
            let req = UNNotificationRequest(
                identifier: "analysis-complete-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            
            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
            
            NSApp.dockTile.badgeLabel = "1"
        }
    }
    
    // Clear Dock badge + remove our delivered/pending notifications + reset badge count.
    func clearDockBadge() {
        // 1) Dock badge
        DispatchQueue.main.async {
            NSApp.dockTile.badgeLabel = nil
        }
        
        // 2) Delivered notifications (only ours)
        UNUserNotificationCenter.current().getDeliveredNotifications { notes in
            let ids = notes
                .filter { $0.request.content.threadIdentifier == "twinalyzer.analysis" }
                .map { $0.request.identifier }
            
            if !ids.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
            }
            
            // Pending in same thread
            UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
                let pendingIDs = reqs
                    .filter { $0.content.threadIdentifier == "twinalyzer.analysis" }
                    .map { $0.identifier }
                
                if !pendingIDs.isEmpty {
                    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: pendingIDs)
                }
            }
        }
        
        // 3) Reset the system badge (macOS 13+)
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }
}
