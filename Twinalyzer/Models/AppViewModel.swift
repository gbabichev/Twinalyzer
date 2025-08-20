/*
 
 AppViewModel.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
// MARK: - Main Application State Manager
/// Central view model managing all app state, analysis operations, and UI coordination
/// Implements ObservableObject for SwiftUI reactive updates
/// All operations must run on MainActor for thread safety
/// ENHANCED: Added memory pressure monitoring and batch size limiting to prevent beachballing
@MainActor
final class AppViewModel: ObservableObject {
    
    //MARK: - CSV
    @Published var isExportingCSV = false
    @Published var csvDocument: CSVDocument? = nil
    @Published var exportFilename: String = "Results"
    
    // MARK: - Configuration Constants
    private nonisolated static let maxDiscoveryBatchSize = 2000     // Limit folder discovery to prevent memory issues
    private nonisolated static let discoveryChunkSize = 100         // Process folders in chunks
    private nonisolated static let progressUpdateThrottle = 0.1     // Minimum time between progress updates
    
    // MARK: - Core Published State
    /// Only the essential state that needs to be stored and observed
    /// Other properties are computed from these core values for consistency
    
    @Published var selectedParentFolders: [URL] = []          // User-selected root directories
    @Published var excludedLeafFolders: Set<URL> = []         // Folders user has manually removed
    @Published var discoveredLeafFolders: [URL] = []          // CHANGED: Now stored property instead of computed
    @AppStorage("similarityThreshold") var similarityThreshold: Double = 0.7          // 0.0-1.0 similarity cutoff
    @AppStorage("selectedAnalysisMode") var selectedAnalysisMode: AnalysisMode = .deepFeature  // AI vs Hash analysis
    @AppStorage("scanTopLevelOnly") var scanTopLevelOnly: Bool = false // Limit to folder contents only
    @Published var isProcessing: Bool = false                 // Analysis in progress flag
    @Published var processingProgress: Double? = nil          // 0.0-1.0 or nil for indeterminate
    @Published var isDiscoveringFolders: Bool = false         // Folder discovery in progress flag (always indeterminate)
    @Published var comparisonResults: [ImageComparisonResult] = [] {  // Analysis results
        didSet {
            // PERFORMANCE OPTIMIZATION: Invalidate all cached values when results change
            // This prevents stale cached data while maintaining performance during UI interactions
            invalidateAllCaches()
        }
    }
    
    // MARK: - Performance Cache Storage
    /// Private cache variables to store expensive computations
    /// These are invalidated whenever comparisonResults changes but persist during UI interactions
    private var _flattenedResultsCache: [TableRow]?
    private var _folderDuplicateCountsCache: [String: Int]?
    private var _representativeImageByFolderCache: [String: String]?
    private var _folderClustersCache: [[String]]?
    private var _crossFolderDuplicateCountsCache: [String: Int]?
    private var _flattenedResultsSortedCache: [TableRow]?
    private var _sortedResultsCache: [String: [TableRow]] = [:]
    
    // MARK: - Enhanced Task Management
    /// Enhanced cancellation mechanism for long-running operations
    private var analysisTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var lastProgressUpdate: Date = .distantPast    // Throttle progress updates
    
    // MARK: - Computed Properties (Non-Cached - These are lightweight)
    /// These properties derive their values from simple state and remain uncached
    /// They don't cause performance issues during selection changes
    
    /// Folders that will actually be analyzed (after user exclusions)
    /// This is the final list passed to the analysis engine
    var activeLeafFolders: [URL] {
        discoveredLeafFolders.filter { !excludedLeafFolders.contains($0) }
    }
    
    /// Formatted string of folder names for display purposes
    var foldersToScanLabel: String {
        activeLeafFolders.map { $0.lastPathComponent }.joined(separator: "\n")
    }
    
    /// Computed property to check if any operation is running
    var isAnyOperationRunning: Bool {
        isProcessing || isDiscoveringFolders
    }
    
    /// Sorted list of folders currently being processed (for progress display)
    var allFoldersBeingProcessed: [URL] {
        if isDiscoveringFolders {
            // During discovery, show parent folders being scanned
            return selectedParentFolders.sorted { $0.path < $1.path }
        } else {
            // During analysis, show leaf folders being processed
            return activeLeafFolders.sorted { $0.path < $1.path }
        }
    }
    
    // MARK: - Cached Computed Properties (PERFORMANCE OPTIMIZED)
    /// These properties perform expensive computations and are cached to prevent
    /// recalculation during UI interactions like table row selection changes
    
    /// Flattens hierarchical results into table-friendly row format
    /// CACHED: This was causing major performance issues during selection changes
    var flattenedResults: [TableRow] {
        if let cached = _flattenedResultsCache {
            return cached
        }
        
        let result = comparisonResults.flatMap { result in
            result.similars
                .filter { $0.path != result.reference }
                .map { TableRow(reference: result.reference, similar: $0.path, percent: $0.percent) }
        }
        
        _flattenedResultsCache = result
        return result
    }
    
    /// Counts total duplicates found in each folder (including both references and matches)
    /// CACHED: Used for folder statistics and UI badges
    var folderDuplicateCounts: [String: Int] {
        if let cached = _folderDuplicateCountsCache {
            return cached
        }
        
        var counts: [String: Int] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                counts[folder, default: 0] += 1
            }
        }
        
        _folderDuplicateCountsCache = counts
        return counts
    }
    
    /// Maps each folder to a representative image for thumbnail display
    /// CACHED: Uses first discovered image as the folder's visual representative
    var representativeImageByFolder: [String: String] {
        if let cached = _representativeImageByFolderCache {
            return cached
        }
        
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
        
        _representativeImageByFolderCache = representatives
        return representatives
    }
    
    /// Groups folders that share duplicate images into relationship clusters
    /// CACHED: Each cluster represents folders containing the same or similar images
    var folderClusters: [[String]] {
        if let cached = _folderClustersCache {
            return cached
        }
        
        // Use flattened table data for accurate reference/match pairs
        var folderPairs: Set<[String]> = []
        
        for row in flattenedResults {
            let referenceFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            
            // Only include cross-folder duplicates (ignore within-folder matches)
            guard referenceFolder != matchFolder else { continue }
            
            // Create sorted pair to avoid duplicates (Folder1,Folder2 same as Folder2,Folder1)
            let sortedPair = [referenceFolder, matchFolder].sorted()
            folderPairs.insert(sortedPair)
        }
        
        // Return as array, sorted by first folder name for consistent display
        let result = Array(folderPairs).sorted { $0[0] < $1[0] }
        _folderClustersCache = result
        return result
    }

    /// Counts cross-folder duplicates per folder (excludes within-folder matches)
    /// CACHED: Used for displaying cross-folder duplicate badges in the UI
    var crossFolderDuplicateCounts: [String: Int] {
        if let cached = _crossFolderDuplicateCountsCache {
            return cached
        }
        
        var counts: [String: Int] = [:]
        
        for row in flattenedResults {
            let referenceFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            
            // Only count cross-folder duplicates
            guard referenceFolder != matchFolder else { continue }
            
            // Count the duplicate in both folders (bidirectional counting)
            counts[referenceFolder, default: 0] += 1
            counts[matchFolder, default: 0] += 1
        }
        
        _crossFolderDuplicateCountsCache = counts
        return counts
    }
    
    /// Flattened results pre-sorted by similarity percentage (highest first)
    /// CACHED: This ensures results always appear sorted without relying on Table sort state
    var flattenedResultsSorted: [TableRow] {
        if let cached = _flattenedResultsSortedCache {
            return cached
        }
        
        let result = flattenedResults.sorted { $0.percent > $1.percent }
        _flattenedResultsSortedCache = result
        return result
    }
    
    /// Generates a cache key for a given sort order
    private func sortCacheKey(for sortOrder: [KeyPathComparator<TableRow>]) -> String {
        if sortOrder.isEmpty {
            return "default"
        }
        
        // Create a unique key based on sort criteria
        return sortOrder.map { comparator in
            let keyPath = String(describing: comparator.keyPath)
            let order = comparator.order == .forward ? "asc" : "desc"
            return "\(keyPath)_\(order)"
        }.joined(separator: "|")
    }

    /// Enhanced sorted rows with caching for performance
    func getSortedRows(using sortOrder: [KeyPathComparator<TableRow>]) -> [TableRow] {
        let cacheKey = sortCacheKey(for: sortOrder)
        
        // Check cache first
        if let cached = _sortedResultsCache[cacheKey] {
            return cached
        }
        
        // Compute and cache the result
        let sorted: [TableRow]
        if sortOrder.isEmpty {
            sorted = flattenedResultsSorted // Use our pre-cached default sort
        } else {
            sorted = flattenedResults.sorted(using: sortOrder)
        }
        
        _sortedResultsCache[cacheKey] = sorted
        return sorted
    }

    /// Enhanced cache invalidation that also clears sort cache
    private func invalidateAllCaches() {
        _flattenedResultsCache = nil
        _folderDuplicateCountsCache = nil
        _representativeImageByFolderCache = nil
        _folderClustersCache = nil
        _crossFolderDuplicateCountsCache = nil
        _flattenedResultsSortedCache = nil
        
        // Clear sort cache when data changes
        _sortedResultsCache.removeAll()
    }
    
    // MARK: - User Actions
    
    /// Adds new parent folders while filtering and deduplicating
    /// Only directories are accepted, and duplicates are automatically excluded
    /// ENHANCED: Now triggers async folder discovery with batch limiting
    func addParentFolders(_ urls: [URL]) {
        let newParents = FileSystemHelpers.filterDirectories(from: urls)
        let uniqueNewParents = FileSystemHelpers.uniqueURLs(from: newParents, existingURLs: selectedParentFolders)
        
        // Only proceed if we have new unique folders
        guard !uniqueNewParents.isEmpty else { return }
        
        selectedParentFolders.append(contentsOf: uniqueNewParents)
        
        // Trigger async folder discovery using existing progress system
        discoverFoldersAsync()
    }
    
    /// ENHANCED: Async folder discovery with batch limiting and memory pressure monitoring
    private func discoverFoldersAsync() {
        guard !selectedParentFolders.isEmpty else { return }
        guard !isAnyOperationRunning else { return } // Don't start if already processing
        
        // Cancel any existing discovery
        discoveryTask?.cancel()
        
        // Use separate discovery state (always indeterminate)
        isDiscoveringFolders = true
        
        // Capture the folders on the main actor before going to background
        let foldersToScan = selectedParentFolders
        
        discoveryTask = Task {
            // Do the heavy work off the main thread with enhanced safety
            let discovered = await Task.detached(priority: .userInitiated) {
                await self.discoverFoldersWithLimits(from: foldersToScan)
            }.value
            
            // Update on main thread if not cancelled
            await MainActor.run {
                if !Task.isCancelled {
                    self.discoveredLeafFolders = discovered
                    
                    // Warn user if we hit limits
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
        
        for root in roots {
            // Check for cancellation
            if Task.isCancelled { break }
            
            // Check memory pressure
            if await isMemoryPressureHigh() {
                print("Warning: High memory pressure detected during folder discovery")
                break
            }
            
            // Process this root with chunking
            let rootFolders = await discoverSingleRootWithChunking(root)
            
            // Add to results but respect batch size limit
            for folder in rootFolders {
                if discovered.count >= Self.maxDiscoveryBatchSize {
                    break
                }
                discovered.append(folder)
            }
            
            if discovered.count >= Self.maxDiscoveryBatchSize {
                break
            }
            
            // Yield control after each root
            await Task.yield()
        }
        
        return discovered
    }
    
    /// Discover folders under a single root with chunked processing
    private func discoverSingleRootWithChunking(_ root: URL) async -> [URL] {
        let fm = FileManager.default
        var folders: [URL] = []
        
        // Check if root is a directory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        
        // Process directories in chunks to avoid blocking
        let (allURLs, maxBatchSize) = await Task.detached {
            let batchLimit = 2000 // Local constant to avoid actor isolation issues
            
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return ([URL](), batchLimit) }
            
            var urls: [URL] = []
            let allElements = Array(enumerator.compactMap { $0 as? URL })
            
            for url in allElements {
                if let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]),
                   (resourceValues.isDirectory ?? false),
                   !(resourceValues.isHidden ?? false) {
                    urls.append(url)
                }
                
                // Respect memory limits
                if urls.count >= batchLimit {
                    break
                }
            }
            return (urls, batchLimit)
        }.value
        
        // Process the URLs with yielding
        var count = 0
        for url in allURLs {
            // Check for cancellation every chunk
            if Task.isCancelled { break }
            
            // Yield control periodically
            count += 1
            if count % 100 == 0 { // Use literal instead of static property
                await Task.yield()
            }
            
            folders.append(url)
            
            // Respect memory limits
            if folders.count >= maxBatchSize {
                break
            }
        }
        
        return folders
    }
    
    /// Excludes a leaf folder from analysis without removing it from discovery
    /// Allows users to fine-tune which discovered folders are actually analyzed
    func removeLeafFolder(_ leafURL: URL) {
        excludedLeafFolders.insert(leafURL)
    }
    
    // MARK: - Enhanced Analysis Operations
    /// Starts image analysis using the selected method (deep feature or perceptual hash)
    /// Manages progress tracking, cancellation, and result processing
    /// ENHANCED: Added throttled progress updates and memory pressure monitoring
    func processImages(progress: @escaping @Sendable (Double) -> Void) {
        guard !isAnyOperationRunning else { return }
        
        // Cancel any existing operations and set up new operation
        cancelAllOperations()
        isProcessing = true
        processingProgress = 0.0  // Start at 0% for immediate progress bar

        // Capture current settings for the analysis task
        let leafFolders = activeLeafFolders
        let threshold = similarityThreshold
        let topOnly = scanTopLevelOnly

        // Enhanced progress wrapper with throttling
        let progressWrapper: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                // Throttle progress updates to prevent UI spam
                let now = Date()
                if let self = self, now.timeIntervalSince(self.lastProgressUpdate) >= Self.progressUpdateThrottle {
                    self.lastProgressUpdate = now
                    self.processingProgress = p
                }
            }
            DispatchQueue.main.async { progress(p) }
        }

        // Launch analysis task based on selected method
        analysisTask = Task {
            let results: [ImageComparisonResult]
            
            switch selectedAnalysisMode {
            case .deepFeature:
                // AI-based analysis using Vision framework
                results = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        ImageAnalyzer.analyzeWithDeepFeatures(
                            inFolders: leafFolders,
                            similarityThreshold: threshold,
                            topLevelOnly: topOnly,
                            progress: progressWrapper,
                            shouldCancel: { Task.isCancelled },
                            completion: { results in continuation.resume(returning: results) }
                        )
                    }
                } onCancel: {}
                
            case .perceptualHash:
                // Fast hash-based analysis for exact duplicates
                results = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        ImageAnalyzer.analyzeWithPerceptualHash(
                            inFolders: leafFolders,
                            similarityThreshold: threshold,
                            topLevelOnly: topOnly,
                            progress: progressWrapper,
                            shouldCancel: { Task.isCancelled },
                            completion: { results in continuation.resume(returning: results) }
                        )
                    }
                } onCancel: {}
            }
            
            // Update results on main thread if not cancelled
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

    /// Cancels the current analysis operation and resets processing state
    /// ENHANCED: Enhanced to handle both analysis and discovery cancellation
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
    /// Opens a folder in Finder for user inspection
    func openFolderInFinder(_ folder: String) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    /// Deletes currently selected matches (called from UI)
    func deleteSelectedMatches() {
        guard !selectedMatchesForDeletion.isEmpty else { return }
        
        let matchesToDelete = Array(selectedMatchesForDeletion)
        selectedMatchesForDeletion.removeAll()
        
        // Convert row IDs back to file paths for deletion
        let filePaths = matchesToDelete.compactMap { rowID -> String? in
            // Row ID format is "reference::similar" - we want to delete the "similar" file
            let components = rowID.components(separatedBy: "::")
            return components.count == 2 ? components[1] : nil
        }
        
        // Delete each file
        filePaths.forEach(deleteFile)
    }

    /// Deletes a single file and updates the results data structure
    /// Uses macOS trash for safety, then cleanly removes from analysis results
    func deleteFile(_ path: String) {
        // Move file to trash (safer than permanent deletion)
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            print("Failed to move file to trash: \(error.localizedDescription)")
            // Continue with data structure updates even if file deletion failed
        }
        
        // Update results data structure to reflect the deletion
        // Process in reverse order to avoid index shifting during removal
        for (index, result) in comparisonResults.enumerated().reversed() {
            let filteredSimilars = result.similars.filter { $0.path != path }
            let hasNonReferenceSimilars = filteredSimilars.contains { $0.path != result.reference }
            
            if result.reference == path || !hasNonReferenceSimilars {
                // Remove entire result if reference was deleted or no non-reference similars remain
                comparisonResults.remove(at: index)
            } else if filteredSimilars.count != result.similars.count {
                // Update result with filtered similars if some were removed
                comparisonResults[index] = ImageComparisonResult(
                    reference: result.reference,
                    similars: filteredSimilars
                )
            }
        }
    }
    
    
    
    // MARK: - Selection Management for Menu Commands
    /// Tracks selected matches for deletion (shared between ContentView and menu commands)
    @Published var selectedMatchesForDeletion: Set<String> = []
    
    /// Computed property to check if any matches are selected for deletion
    var hasSelectedMatches: Bool {
        !selectedMatchesForDeletion.isEmpty
    }
    
    /// Non-published method to handle selection toggle
    /// This prevents the "Publishing changes from within view updates" warning
    func toggleSelection(for rowIDs: Set<String>) {
        if rowIDs.count > 1 {
            // Check if all selected rows are already checked for deletion
            let allChecked = rowIDs.allSatisfy { selectedMatchesForDeletion.contains($0) }
            
            if allChecked {
                // If all are checked, uncheck all
                for rowID in rowIDs {
                    selectedMatchesForDeletion.remove(rowID)
                }
            } else {
                // If some/none are checked, check all
                for rowID in rowIDs {
                    selectedMatchesForDeletion.insert(rowID)
                }
            }
        } else if let focusedID = rowIDs.first {
            // Single row selection: simple toggle
            if selectedMatchesForDeletion.contains(focusedID) {
                selectedMatchesForDeletion.remove(focusedID)
            } else {
                selectedMatchesForDeletion.insert(focusedID)
            }
        }
    }
    
    /// Clears the current selection (called from menu command)
    func clearSelection() {
        selectedMatchesForDeletion.removeAll()
    }
    
    // MARK: - State Management
    /// Comprehensive reset of all application state
    /// Cancels ongoing operations and clears all user selections and results
    func clearAll() {
        // Cancel any running operations first
        cancelAllOperations()
        isProcessing = false
        isDiscoveringFolders = false
        processingProgress = nil
        
        // Clear selected folders and exclusions
        selectedParentFolders.removeAll()
        excludedLeafFolders.removeAll()
        
        // Clear discovered folders
        discoveredLeafFolders.removeAll()
        
        // Clear selection state
        selectedMatchesForDeletion.removeAll()
        
        // Clear all analysis results (this will automatically invalidate caches)
        comparisonResults.removeAll()
    }
    
    // MARK: - Memory Pressure Monitoring
    /// Checks if system is under memory pressure
    /// Returns true if available memory is low
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
                    // Use 512MB as threshold for high memory usage
                    let memoryThreshold: UInt64 = 512 * 1024 * 1024
                    let isHighMemory = info.resident_size > memoryThreshold
                    continuation.resume(returning: isHighMemory)
                } else {
                    // If we can't get memory info, assume we're fine
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    // MARK: - CSV Export (SwiftUI .fileExporter-backed)
    func triggerCSVExport() {
        // Don't export if no results or currently processing
        guard !comparisonResults.isEmpty, !isProcessing else { return }

        // Build CSV text from flattened & sorted rows to match the UI
        let header = "Reference,Match,Similarity,Cross-Folder,Reference Folder,Match Folder"
        var lines: [String] = [header]

        let rows = flattenedResultsSorted
        lines.reserveCapacity(rows.count + 1)

        for row in rows {
            let referenceFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
            let matchFolder     = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
            let isCrossFolder   = referenceFolder != matchFolder

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

        // Friendly default filename
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        exportFilename = "Twinalyzer_Results_\(df.string(from: Date()))"

        isExportingCSV = true
    }

    /// Handle the completion from .fileExporter
    func handleCSVExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            // Reveal in Finder as success feedback
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

    /// Properly escapes CSV fields (keep your existing version if already present)
    private static func escapeCSVField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return field
    }
    
}
