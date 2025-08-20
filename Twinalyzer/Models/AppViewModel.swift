/*
 
 AppViewModel.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import Combine
import ImageIO

// MARK: - Main Application State Manager
/// Central view model managing all app state, analysis operations, and UI coordination
/// Implements ObservableObject for SwiftUI reactive updates
/// All operations must run on MainActor for thread safety
/// OPTIMIZED VERSION: Caches expensive computations to prevent recalculation on selection changes
@MainActor
final class AppViewModel: ObservableObject {
    
    // MARK: - Core Published State
    /// Only the essential state that needs to be stored and observed
    /// Other properties are computed from these core values for consistency
    
    @Published var selectedParentFolders: [URL] = []          // User-selected root directories
    @Published var excludedLeafFolders: Set<URL> = []         // Folders user has manually removed
    @AppStorage("similarityThreshold") var similarityThreshold: Double = 0.7          // 0.0-1.0 similarity cutoff
    @AppStorage("selectedAnalysisMode") var selectedAnalysisMode: AnalysisMode = .deepFeature  // AI vs Hash analysis
    @AppStorage("scanTopLevelOnly") var scanTopLevelOnly: Bool = false // Limit to folder contents only
    @Published var isProcessing: Bool = false                 // Analysis in progress flag
    @Published var processingProgress: Double? = nil          // 0.0-1.0 or nil for indeterminate
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
    
    /// Invalidates all cached computations - called when source data changes
    private func invalidateAllCaches() {
        _flattenedResultsCache = nil
        _folderDuplicateCountsCache = nil
        _representativeImageByFolderCache = nil
        _folderClustersCache = nil
        _crossFolderDuplicateCountsCache = nil
        _flattenedResultsSortedCache = nil
    }
    
    // MARK: - Task Management
    /// Simple cancellation mechanism for long-running analysis operations
    private var analysisTask: Task<Void, Never>?
    
    // MARK: - Computed Properties (Non-Cached - These are lightweight)
    /// These properties derive their values from simple state and remain uncached
    /// They don't cause performance issues during selection changes
    
    /// All leaf folders discovered from parent selections (matches analysis engine behavior)
    /// Uses same logic as ImageAnalyzer.foldersToScan for consistency
    var discoveredLeafFolders: [URL] {
        ImageAnalyzer.foldersToScan(from: selectedParentFolders)
    }
    
    /// Folders that will actually be analyzed (after user exclusions)
    /// This is the final list passed to the analysis engine
    var activeLeafFolders: [URL] {
        discoveredLeafFolders.filter { !excludedLeafFolders.contains($0) }
    }
    
    /// Formatted string of folder names for display purposes
    var foldersToScanLabel: String {
        activeLeafFolders.map { $0.lastPathComponent }.joined(separator: "\n")
    }
    
    /// Sorted list of folders currently being processed (for progress display)
    var allFoldersBeingProcessed: [URL] {
        activeLeafFolders.sorted { $0.path < $1.path }
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
    
    // MARK: - User Actions
    
    /// Adds new parent folders while filtering and deduplicating
    /// Only directories are accepted, and duplicates are automatically excluded
    func addParentFolders(_ urls: [URL]) {
        let newParents = FileSystemHelpers.filterDirectories(from: urls)
        let uniqueNewParents = FileSystemHelpers.uniqueURLs(from: newParents, existingURLs: selectedParentFolders)
        selectedParentFolders.append(contentsOf: uniqueNewParents)
    }
    
    /// Excludes a leaf folder from analysis without removing it from discovery
    /// Allows users to fine-tune which discovered folders are actually analyzed
    func removeLeafFolder(_ leafURL: URL) {
        excludedLeafFolders.insert(leafURL)
    }
    
    // MARK: - Analysis Operations
    /// Starts image analysis using the selected method (deep feature or perceptual hash)
    /// Manages progress tracking, cancellation, and result processing
    /// Prevents multiple concurrent analyses and provides progress callbacks
    func processImages(progress: @escaping @Sendable (Double) -> Void) {
        guard !isProcessing else { return }
        
        // Cancel any existing analysis and set up new operation
        analysisTask?.cancel()
        isProcessing = true
        processingProgress = nil

        // Capture current settings for the analysis task
        let leafFolders = activeLeafFolders
        let threshold = similarityThreshold
        let topOnly = scanTopLevelOnly

        // Progress wrapper that updates both internal state and external callback
        let progressWrapper: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.processingProgress = p
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
            }
        }
    }

    /// Cancels the current analysis operation and resets processing state
    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        isProcessing = false
        processingProgress = nil
    }

    // MARK: - File System Operations
    /// Opens a folder in Finder for user inspection
    func openFolderInFinder(_ folder: String) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    /// Batch delete operation for selected match files
    /// Delegates to individual deleteFile for each selected item
    func deleteSelectedMatches(selectedMatches: [String]) {
        guard !selectedMatches.isEmpty else { return }
        selectedMatches.forEach(deleteFile)
    }
    
    /// Deletes a single file and updates the results data structure
    /// Uses macOS trash for safety, then cleanly removes from analysis results
    /// Maintains data consistency by removing empty result groups
    func deleteFile(_ path: String) {
        // Move file to trash (safer than permanent deletion)
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        
        // Update results data structure to reflect the deletion
        // Process in reverse order to avoid index shifting during removal
        for (index, result) in comparisonResults.enumerated().reversed() {
            let filteredSimilars = result.similars.filter { $0.path != path }
            let nonReferenceSimilars = filteredSimilars.filter { $0.path != result.reference }
            
            if result.reference == path || nonReferenceSimilars.isEmpty {
                // Remove entire result if reference was deleted or no matches remain
                comparisonResults.remove(at: index)
            } else if filteredSimilars.count != result.similars.count {
                // Update result with filtered similars if some were removed
                comparisonResults[index] = ImageComparisonResult(
                    reference: result.reference,
                    similars: filteredSimilars
                )
            }
        }
        
        // Note: Cache invalidation happens automatically via comparisonResults didSet
    }
    
    // MARK: - Selection Management for Menu Commands
    /// Tracks selected matches for deletion (shared between ContentView and menu commands)
    @Published var selectedMatchesForDeletion: Set<String> = []
    
    /// Computed property to check if any matches are selected for deletion
    var hasSelectedMatches: Bool {
        !selectedMatchesForDeletion.isEmpty
    }
    
    /// Deletes currently selected matches (called from menu command)
    func deleteSelectedMatches() {
        let matchesToDelete = Array(selectedMatchesForDeletion)
        deleteSelectedMatches(selectedMatches: matchesToDelete)
        selectedMatchesForDeletion.removeAll()
    }
    
    /// Clears the current selection (called from menu command)
    func clearSelection() {
        selectedMatchesForDeletion.removeAll()
    }
    
    // MARK: - State Management
    /// Comprehensive reset of all application state
    /// Cancels ongoing operations and clears all user selections and results
    func clearAll() {
        // Cancel any running analysis first
        cancelAnalysis()
        
        // Clear selected folders and exclusions
        selectedParentFolders.removeAll()
        excludedLeafFolders.removeAll()
        
        // Clear selection state
        selectedMatchesForDeletion.removeAll()
        
        // Clear all analysis results (this will automatically invalidate caches)
        comparisonResults.removeAll()
    }
}
