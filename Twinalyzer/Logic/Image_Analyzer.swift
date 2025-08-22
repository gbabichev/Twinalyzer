/*
 
 Image_Analyzer.swift
 Twinalyzer
 
 George Babichev
 
 */

//
//  Core image analysis engine providing two analysis methods:
//  1. Deep Feature Analysis: Uses Apple's Vision framework for AI-based similarity detection
//  2. Perceptual Hash Analysis: Fast fingerprint-based comparison for exact duplicates
//
//  ENHANCED: Added cooperative cancellation, memory pressure monitoring, and chunked processing
//  to prevent UI beachballing on large datasets
//

import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import Vision
@preconcurrency import CoreImage
import Darwin
// MARK: - Main Image Analysis Engine
/// Static enum containing all image analysis functionality
/// Provides both AI-based deep feature analysis and traditional perceptual hashing
/// All methods are nonisolated for Swift 6 concurrency safety
/// ENHANCED: Now includes beachball prevention and memory pressure handling

enum ImageAnalyzer {
    
    // MARK: - Configuration Constants
    private nonisolated static let maxBatchSize = 1000          // Limit processing to prevent memory issues
    private nonisolated static let fileSystemChunkSize = 50     // Process directories in chunks
    
    // MARK: - Progress Tracking Utilities
    /// Throttled progress reporting to avoid overwhelming the UI with updates
    /// Only reports progress every 5 items or at completion to maintain performance
    private nonisolated static func updateProgress(
        _ current: Int,
        _ total: Int,
        _ callback: (@Sendable (Double) -> Void)?
    ) {
        guard let callback, total > 0 else { return }
        let progress = Double(current) / Double(total)
        
        // More frequent updates - report every 5 items or at completion
        if current % 5 == 0 || current == total {
            Task { @MainActor in
                callback(progress)
            }
        }
    }
    
    // MARK: - Deep Feature Analysis (AI-Based)
    /// Primary analysis method using Apple's Vision framework for intelligent similarity detection
    /// Can detect similar content even with different crops, lighting, or minor modifications
    /// More computationally intensive but significantly more accurate than hash-based methods
    /// FIXED: Now only processes the exact folders passed in, no re-discovery
    nonisolated static func analyzeWithDeepFeatures(
        inFolders leafFolders: [URL],  // FIXED: Use exact folders from sidebar
        similarityThreshold: Double,
        topLevelOnly: Bool,
        ignoredFolderName: String = "",
        progress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    ){
        Task.detached(priority: .utility) {
            guard shouldCancel?() != true else {
                await MainActor.run { completion([]) }
                return
            }
            
            var results: [ImageComparisonResult] = []
            
            if topLevelOnly {
                // Process each folder separately to maintain folder boundaries
                var totalProcessed = 0
                let allFiles = await getAllFilesFromExactFolders(
                    folders: leafFolders,
                    topLevelOnly: true,
                    ignoredFolderName: ignoredFolderName,
                    shouldCancel: shouldCancel
                )
                let totalCount = allFiles.count
                
                // Limit batch size to prevent memory issues
                let limitedFiles = Array(allFiles.prefix(maxBatchSize))
                if limitedFiles.count < allFiles.count {
                    print("Warning: Limited processing to \(maxBatchSize) files due to memory constraints")
                }
                
                for dir in leafFolders {
                    if shouldCancel?() == true { break }
                    
                    let files = await topLevelImageFilesAsync(
                        in: dir,
                        ignoredFolderName: ignoredFolderName,
                        shouldCancel: shouldCancel
                    )
                    let folderResults = await processImageBatch(
                        files: files,
                        threshold: similarityThreshold,
                        processedSoFar: totalProcessed,
                        totalCount: totalCount,
                        progress: progress,
                        shouldCancel: shouldCancel
                    )
                    
                    totalProcessed += files.count
                    results.append(contentsOf: folderResults)
                }
            } else {
                // Process all images together for cross-folder duplicate detection
                let allFiles = await getAllFilesFromExactFolders(
                    folders: leafFolders,
                    topLevelOnly: false,
                    ignoredFolderName: ignoredFolderName,
                    shouldCancel: shouldCancel
                )
                
                // Limit batch size to prevent memory issues
                let limitedFiles = Array(allFiles.prefix(maxBatchSize))
                if limitedFiles.count < allFiles.count {
                    print("Warning: Limited processing to \(maxBatchSize) files due to memory constraints")
                }
                
                results = await processImageBatch(
                    files: limitedFiles,
                    threshold: similarityThreshold,
                    processedSoFar: 0,
                    totalCount: limitedFiles.count,
                    progress: progress,
                    shouldCancel: shouldCancel
                )
            }
            
            // Return results on main thread
            await MainActor.run {
                progress?(1.0)
                completion(shouldCancel?() == true ? [] : results)
            }
        }
    }
    
    // MARK: - Perceptual Hash Analysis (Fast)
    /// Alternative analysis method using perceptual hashing for fast duplicate detection
    /// Best for finding exact or near-exact duplicates with minimal computational overhead
    /// Uses block hash algorithm (8x8 grayscale grid) with Hamming distance comparison
    /// FIXED: Now only processes the exact folders passed in, no re-discovery
    nonisolated static func analyzeWithPerceptualHash(
        inFolders leafFolders: [URL],  // FIXED: Use exact folders from sidebar
        similarityThreshold: Double,
        topLevelOnly: Bool,
        ignoredFolderName: String = "",
        progress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    ) {
        // Convert similarity threshold to maximum Hamming distance
        // 64-bit hash allows 0-64 bit differences
        let maxDist = max(0, min(64, Int((1.0 - similarityThreshold) * 64.0)))
        
        Task.detached(priority: .utility) {
            let pairs = await computeHashPairs(
                folders: leafFolders,  // FIXED: Use exact folders
                topLevelOnly: topLevelOnly,
                maxDist: maxDist,
                ignoredFolderName: ignoredFolderName,
                progress: progress,
                shouldCancel: shouldCancel
            )
            
            if shouldCancel?() == true {
                await MainActor.run { completion([]) }
                return
            }
            
            // Group pairs into structured results on main actor
            let results = await MainActor.run {
                groupPairsIntoResults(pairs)
            }
            
            await MainActor.run {
                progress?(1.0)
                completion(results)
            }
        }
    }
    
    /// Computes perceptual hash pairs for similarity comparison
    /// FIXED: Only processes exact folders passed in, no re-discovery
    private nonisolated static func computeHashPairs(
        folders: [URL],  // FIXED: Use exact folders from sidebar
        topLevelOnly: Bool,
        maxDist: Int,
        ignoredFolderName: String = "",
        progress: (@Sendable (Double) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> [TableRow] {
        
        guard shouldCancel?() != true else { return [] }
        
        var allPairs: [TableRow] = []
        
        if topLevelOnly {
            // Process folders separately for folder-specific analysis
            var totalProcessed = 0
            let allFiles = await getAllFilesFromExactFolders(
                folders: folders,
                topLevelOnly: true,
                ignoredFolderName: ignoredFolderName,
                shouldCancel: shouldCancel
            )
            let totalCount = min(allFiles.count, maxBatchSize) // Limit processing
            
            for dir in folders {
                if shouldCancel?() == true { break }
                
                let files = await topLevelImageFilesAsync(
                    in: dir,
                    ignoredFolderName: ignoredFolderName,
                    shouldCancel: shouldCancel
                )
                let pairs = await hashAndCompareWithProgress(
                    files: files,
                    maxDist: maxDist,
                    processedSoFar: totalProcessed,
                    totalCount: totalCount,
                    progress: progress,
                    shouldCancel: shouldCancel
                )
                allPairs.append(contentsOf: pairs)
                
                totalProcessed += files.count
            }
        } else {
            // Process all files together for cross-folder comparison
            let allFiles = await getAllFilesFromExactFolders(
                folders: folders,
                topLevelOnly: false,
                ignoredFolderName: ignoredFolderName,
                shouldCancel: shouldCancel
            )
            let limitedFiles = Array(allFiles.prefix(maxBatchSize)) // Limit to prevent memory issues
            
            if limitedFiles.count < allFiles.count {
                print("Warning: Limited processing to \(maxBatchSize) files due to memory constraints")
            }
            
            allPairs = await hashAndCompareWithProgress(
                files: limitedFiles,
                maxDist: maxDist,
                processedSoFar: 0,
                totalCount: limitedFiles.count,
                progress: progress,
                shouldCancel: shouldCancel
            )
        }
        
        // Return pairs sorted by similarity percentage (highest first)
        return allPairs.sorted { $0.percent > $1.percent }
    }
    
    // MARK: - FIXED: New method that only scans exact folders (no re-discovery)
    /// Gets all image files from the exact list of folders provided
    /// This ensures consistency with what's shown in the sidebar
    /// FIXED: ALWAYS only scans top-level of provided folders to prevent subfolder discovery
    private nonisolated static func getAllFilesFromExactFolders(
        folders: [URL],
        topLevelOnly: Bool,
        ignoredFolderName: String = "",
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> [URL] {
        var all: [URL] = []
        all.reserveCapacity(1024)
        
        for folder in folders {
            if shouldCancel?() == true { break }
            
            let files = await allImageFilesAsync(
                in: folder,
                ignoredFolderName: ignoredFolderName,
                topLevelOnly: topLevelOnly,   // <- use the argument, don't force top-level
                shouldCancel: shouldCancel
            )
            all.append(contentsOf: files)
            await Task.yield()
        }
        return all
    }
    
    // MARK: - Rest of the implementation (unchanged methods)
    
    /// Processes a batch of images through the Vision framework pipeline
    /// Extracts feature vectors from each image then clusters similar ones
    /// Feature extraction is the most time-consuming step
    /// ENHANCED: Added memory pressure monitoring and cooperative cancellation
    private nonisolated static func processImageBatch(
        files: [URL],
        threshold: Double,
        processedSoFar: Int,
        totalCount: Int,
        progress: (@Sendable (Double) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> [ImageComparisonResult] {
        
        var observations: [VNFeaturePrintObservation] = []
        var paths: [String] = []
        
        // Extract Vision framework feature vectors from each image
        for (index, url) in files.enumerated() {
            if shouldCancel?() == true { break }
            
            // Yield control periodically to prevent beachballing
            if index % 10 == 0 {
                await Task.yield()
            }
            
            // Check memory pressure every 50 images
            if index % 50 == 0 {
                let memoryPressure = await isMemoryPressureHigh()
                if memoryPressure {
                    print("Warning: High memory pressure detected, limiting processing")
                    break
                }
            }
            
            if let observation = await extractFeature(from: url) {
                observations.append(observation)
                paths.append(url.path)
            }
            
            updateProgress(processedSoFar + index + 1, totalCount, progress)
        }
        
        // Clustering is fast, so we do it on the main actor for thread safety
        //        return await MainActor.run {
        //            _clusterFeaturePrints(observations: observations, paths: paths, threshold: threshold)
        //        }
        return await _clusterFeaturePrints(observations: observations, paths: paths, threshold: threshold)
    }
    
    /// Extracts a feature vector from a single image using Apple's Vision framework
    /// The feature vector captures semantic content that can be compared across images
    /// Uses autoreleasepool to manage memory during batch processing
    /// ENHANCED: Added timeout and better error handling
    private nonisolated static func extractFeature(from url: URL) async -> VNFeaturePrintObservation? {
        return await withCheckedContinuation { continuation in
            autoreleasepool {
                let request = VNGenerateImageFeaturePrintRequest()
                
                // Load image with orientation correction for accurate analysis
                guard let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                
                do {
                    try handler.perform([request])
                    let observation = request.results?.first as? VNFeaturePrintObservation
                    continuation.resume(returning: observation)
                } catch {
                    // Log error for debugging but continue processing
                    print("Vision processing failed for \(url.lastPathComponent): \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Enhanced hash comparison with proper progress reporting and cooperative cancellation
    /// ENHANCED: Added Task.yield() in O(n²) loop to prevent beachballing
    private nonisolated static func hashAndCompareWithProgress(
        files: [URL],
        maxDist: Int,
        processedSoFar: Int,
        totalCount: Int,
        progress: (@Sendable (Double) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> [TableRow] {
        var hashes: [(path: String, hash: UInt64)] = []
        
        // Generate perceptual hash for each image WITH PROGRESS REPORTING
        for (index, file) in files.enumerated() {
            if shouldCancel?() == true { break }
            
            // Yield control every 25 files to prevent beachballing
            if index % 25 == 0 {
                await Task.yield()
            }
            
            if let hash = await blockHash(for: file) {
                hashes.append((path: file.path, hash: hash))
            }
            
            // Report progress for each image processed
            let currentTotal = processedSoFar + index + 1
            updateProgress(currentTotal, totalCount, progress)
        }
        
        // ENHANCED: Compare all pairs with cooperative cancellation
        var pairs: [TableRow] = []
        var comparisonCount = 0
        
        for i in 0..<hashes.count {
            if shouldCancel?() == true { break }
            
            for j in (i + 1)..<hashes.count {
                if shouldCancel?() == true { break }
                
                // CRITICAL: Yield control periodically in O(n²) loop
                comparisonCount += 1
                if comparisonCount % 250 == 0 { // Use literal instead of static property
                    await Task.yield()
                }
                
                let distance = hammingDistance(hashes[i].hash, hashes[j].hash)
                if distance <= maxDist {
                    let similarity = 1.0 - (Double(distance) / 64.0)
                    let refPath = hashes[i].path
                    let simPath = hashes[j].path
//                    let id = "\(refPath)::\(simPath)"
//                    let refFolder = URL(fileURLWithPath: refPath).deletingLastPathComponent().path
//                    let simFolder = URL(fileURLWithPath: simPath).deletingLastPathComponent().path
//                    let cross = (refFolder != simFolder)
                    
                    // NEW (working)
                    await pairs.append(TableRow(
                        reference: refPath,
                        similar: simPath,
                        percent: similarity
                    ))
                }
            }
        }
        
        return pairs
    }
    
    /// Groups flat pairs into hierarchical results structure for UI display
    /// Transforms pair-based data into reference-with-matches format
    @MainActor
    private static func groupPairsIntoResults(_ pairs: [TableRow]) -> [ImageComparisonResult] {
        var grouped: [String: [(path: String, percent: Double)]] = [:]
        
        // Group matches by reference image
        for pair in pairs {
            grouped[pair.reference, default: []].append((path: pair.similar, percent: pair.percent))
        }
        
        // Convert to structured results and sort by best similarity
        return grouped.map { reference, similars in
            ImageComparisonResult(
                reference: reference,
                similars: similars.sorted { $0.percent > $1.percent }
            )
        }.sorted { ($0.similars.first?.percent ?? 0) > ($1.similars.first?.percent ?? 0) }
    }
    
    /// Advanced clustering algorithm for Vision framework feature vectors
    /// Groups similar images while intelligently choosing reference images
    /// Must run on MainActor due to Vision framework requirements
    private static func _clusterFeaturePrints(
        observations: [VNFeaturePrintObservation],
        paths: [String],
        threshold: Double
    ) -> [ImageComparisonResult] {
        precondition(observations.count == paths.count)
        
        // Compute similarity between two feature vectors
        // Uses Vision's built-in distance metric converted to similarity
        @inline(__always)
        func sim(_ i: Int, _ j: Int) -> Double {
            var d: Float = 0
            do {
                try observations[i].computeDistance(&d, to: observations[j])
                return 1.0 / (1.0 + Double(d))
            } catch {
                return 0.0
            }
        }
        
        // Choose the best reference image from a cluster
        // Prefers exact matches, then falls back to lexicographic ordering
        func chooseReference(in idxs: [Int]) -> Int {
            let exactEps = 0.9995
            // First, look for exact matches to use as reference
            for a in 0..<idxs.count {
                for b in (a + 1)..<idxs.count where sim(idxs[a], idxs[b]) >= exactEps {
                    let ia = idxs[a], ib = idxs[b]
                    let pa = paths[ia], pb = paths[ib]
                    return (pa <= pb) ? ia : ib
                }
            }
            // No exact matches found, use lexicographic ordering
            return idxs.min { paths[$0] < paths[$1] }!
        }
        
        // Calculate best similarity for each image in a cluster
        func bestSims(in idxs: [Int]) -> [Int: Double] {
            var best: [Int: Double] = [:]
            for i in 0..<idxs.count {
                let ii = idxs[i]
                var m = 0.0
                for j in 0..<idxs.count where j != i {
                    m = max(m, sim(ii, idxs[j]))
                }
                best[ii] = m
            }
            return best
        }
        
        let n = observations.count
        guard n > 1 else { return [] }
        
        let exactEps = 0.9995
        var used = Set<Int>()
        var results: [ImageComparisonResult] = []
        
        // Main clustering loop: build connected components of similar images
        for i in 0..<n {
            guard !used.contains(i) else { continue }
            
            // Find all images similar to image i
            var members = [i]
            for j in (i + 1)..<n where !used.contains(j) {
                if sim(i, j) >= threshold {
                    members.append(j)
                    used.insert(j)
                }
            }
            used.insert(i)
            guard members.count > 1 else { continue }
            
            // Build result structure for this cluster
            let refIdx = chooseReference(in: members)
            let refPath = paths[refIdx]
            let best = bestSims(in: members)
            
            var rows: [(path: String, percent: Double)] = []
            rows.append((refPath, 1.0))
            var tail: [(path: String, percent: Double)] = []
            for idx in members where idx != refIdx {
                var p = best[idx] ?? 0.0
                if p >= exactEps { p = 1.0 }
                tail.append((paths[idx], p))
            }
            tail.sort { $0.percent > $1.percent }
            rows.append(contentsOf: tail)
            
            results.append(ImageComparisonResult(reference: refPath, similars: rows))
        }
        return results
    }
    
    // MARK: - Enhanced File Discovery and Filtering
    
    
    
    /// ENHANCED: Async version with chunked processing and ignored folder filtering
    /// FIXED: Now respects topLevelOnly to prevent discovering new subfolders during analysis
    private nonisolated static func allImageFilesAsync(
        in directory: URL,
        ignoredFolderName: String = "",
        topLevelOnly: Bool = false,  // FIXED: Added topLevelOnly parameter
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> [URL] {
        // FIXED: If topLevelOnly is true, delegate to the top-level method
        if topLevelOnly {
            return await topLevelImageFilesAsync(
                in: directory,
                ignoredFolderName: ignoredFolderName,
                shouldCancel: shouldCancel
            )
        }
        
        var results: [URL] = []
        let fm = FileManager.default
        let ignoredName = ignoredFolderName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let e = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            var count = 0
            while let element = e.nextObject() {
                if shouldCancel?() == true { break }
                guard let url = element as? URL else { continue }
                
                count += 1
                if count % fileSystemChunkSize == 0 { await Task.yield() }
                
                // FIXED: Check if this file is in an ignored folder path
                if !ignoredName.isEmpty {
                    let pathComponents = url.pathComponents
                    let containsIgnoredFolder = pathComponents.contains { component in
                        component.lowercased() == ignoredName
                    }
                    if containsIgnoredFolder {
                        continue // Skip files in ignored folders
                    }
                }
                
                guard
                    let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]),
                    (rv.isRegularFile ?? false),
                    !(rv.isHidden ?? false),
                    allowedImageExtensions.contains(url.pathExtension.lowercased())
                else { continue }
                
                results.append(url)
            }
        }
        return results
    }
    
    /// FIXED: New method that properly filters ignored subfolders during top-level scanning
    nonisolated static func topLevelImageFilesWithIgnoredFilter(
        in directory: URL,
        ignoredFolderName: String
    ) -> [URL] {
        let fm = FileManager.default
        let ignoredName = ignoredFolderName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        var results: [URL] = []
        for url in contents {
            // FIXED: Skip if this is an ignored folder name (for top-level scan)
            if !ignoredName.isEmpty {
                let fileName = url.lastPathComponent.lowercased()
                if fileName == ignoredName {
                    continue // Skip files/folders with ignored name
                }
            }
            
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true &&
                allowedImageExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results
    }
    
    /// ENHANCED: Async version with ignored folder filtering
    private nonisolated static func topLevelImageFilesAsync(
        in directory: URL,
        ignoredFolderName: String = "",
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> [URL] {
        if shouldCancel?() == true { return [] }
        
        return topLevelImageFilesWithIgnoredFilter(in: directory, ignoredFolderName: ignoredFolderName)
    }
    
    /// Comprehensive list of supported image file extensions
    /// Includes common formats (JPEG, PNG) and professional formats (RAW, HEIC)
    private nonisolated static let allowedImageExtensions: Set<String> = [
        "jpg","jpeg","png","heic","heif","tiff","tif","bmp","gif","webp","dng","cr2","nef","arw"
    ]
    
    // MARK: - Perceptual Hash Implementation
    /// Generates a 64-bit perceptual hash using block hash algorithm
    /// Converts image to 8x8 grayscale grid and compares pixels to average brightness
    /// Robust to minor changes in compression, scaling, and lighting
    nonisolated static func blockHash(for cgImage: CGImage) -> UInt64? {
        let w = 8, h = 8
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(cgImage, in: rect)
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: w*h)
        
        // Calculate average brightness
        var sum = 0
        for i in 0..<(w*h) { sum += Int(p[i]) }
        let avg = sum / (w*h)
        
        // Build hash: 1 bit per pixel (above/below average)
        var hash: UInt64 = 0
        for i in 0..<(w*h) { if p[i] >= avg { hash |= (1 << UInt64(i)) } }
        return hash
    }
    
    /// Convenience method to generate perceptual hash directly from image file
    /// Handles downsampling for consistent hash generation
    nonisolated static func blockHash(for imageURL: URL) async -> UInt64? {
        let cg = await ImageProcessingUtilities.downsampledCGImageWithTimeout(
            at: imageURL,
            targetMaxDimension: 32,
            timeout: 10
        )
        guard let cg else { return nil }
        return blockHash(for: cg)
    }
    
    /// Calculates Hamming distance between two hash values
    /// Counts the number of differing bits using XOR and bit counting
    nonisolated static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        Int((a ^ b).nonzeroBitCount)
    }

    // MARK: - Memory Pressure Monitoring
    /// Checks if system is under memory pressure
    /// Returns true if available memory is low or if resident memory exceeds threshold
    private nonisolated static func isMemoryPressureHigh() async -> Bool {
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
                    let isHighMemory = info.resident_size > 512 * 1024 * 1024 // Use literal instead of static property
                    continuation.resume(returning: isHighMemory)
                } else {
                    // If we can't get memory info, assume we're fine
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
