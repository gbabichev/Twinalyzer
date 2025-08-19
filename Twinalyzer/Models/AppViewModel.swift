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
@MainActor
final class AppViewModel: ObservableObject {
    
    // MARK: - Core Published State
    /// Only the essential state that needs to be stored and observed
    /// Other properties are computed from these core values for consistency
    
    @Published var selectedParentFolders: [URL] = []          // User-selected root directories
    @Published var excludedLeafFolders: Set<URL> = []         // Folders user has manually removed
    @Published var similarityThreshold: Double = 0.7          // 0.0-1.0 similarity cutoff
    @Published var selectedAnalysisMode: AnalysisMode = .deepFeature  // AI vs Hash analysis
    @Published var scanTopLevelOnly: Bool = false             // Limit to folder contents only
    @Published var isProcessing: Bool = false                 // Analysis in progress flag
    @Published var processingProgress: Double? = nil          // 0.0-1.0 or nil for indeterminate
    @Published var comparisonResults: [ImageComparisonResult] = []  // Analysis results
    
    // MARK: - Task Management
    /// Simple cancellation mechanism for long-running analysis operations
    private var analysisTask: Task<Void, Never>?
    
    // MARK: - Computed Properties (Derived State)
    /// These properties derive their values from the core state above
    /// This approach ensures consistency and eliminates redundant storage
    
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
    
    /// Flattens hierarchical results into table-friendly row format
    /// Converts ImageComparisonResult (reference + similars) into individual TableRow pairs
    /// Excludes self-references to avoid showing "image similar to itself"
    var flattenedResults: [TableRow] {
        comparisonResults.flatMap { result in
            result.similars
                .filter { $0.path != result.reference }
                .map { TableRow(reference: result.reference, similar: $0.path, percent: $0.percent) }
        }
    }
    
    /// Counts total duplicates found in each folder (including both references and matches)
    /// Used for folder statistics and UI badges
    var folderDuplicateCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                counts[folder, default: 0] += 1
            }
        }
        return counts
    }
    
    /// Maps each folder to a representative image for thumbnail display
    /// Uses first discovered image as the folder's visual representative
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
    
    /// Groups folders that share duplicate images into relationship clusters
    /// Each cluster represents folders containing the same or similar images
    /// Used for cross-folder duplicate visualization in the UI
    var folderClusters: [[String]] {
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
        return Array(folderPairs).sorted { $0[0] < $1[0] }
    }

    /// Counts cross-folder duplicates per folder (excludes within-folder matches)
    /// Used for displaying cross-folder duplicate badges in the UI
    /// Each folder gets credit for both sending and receiving cross-folder duplicates
    var crossFolderDuplicateCounts: [String: Int] {
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
        
        return counts
    }
    
    /// Sorted list of folders currently being processed (for progress display)
    var allFoldersBeingProcessed: [URL] {
        activeLeafFolders.sorted { $0.path < $1.path }
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
        
        // Clear all analysis results
        comparisonResults.removeAll()
    }
}
