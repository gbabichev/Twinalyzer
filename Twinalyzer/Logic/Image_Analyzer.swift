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

import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import Vision
@preconcurrency import CoreImage

// MARK: - Main Image Analysis Engine
/// Static enum containing all image analysis functionality
/// Provides both AI-based deep feature analysis and traditional perceptual hashing
/// All methods are nonisolated for Swift 6 concurrency safety
public enum ImageAnalyzer {

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
    public nonisolated static func analyzeWithDeepFeatures(
        inFolders roots: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        progress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            // Determine which folders to scan based on user preferences
            let subdirs = foldersToScan(from: roots)
            var results: [ImageComparisonResult] = []
            
            if topLevelOnly {
                // Process each folder separately to maintain folder boundaries
                var totalProcessed = 0
                let allFiles = subdirs.flatMap { topLevelImageFiles(in: $0) }
                let totalCount = allFiles.count
                
                for dir in subdirs {
                    if shouldCancel?() == true { break }
                    
                    let files = topLevelImageFiles(in: dir)
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
                let allFiles = subdirs.flatMap { allImageFiles(in: $0) }
                results = await processImageBatch(
                    files: allFiles,
                    threshold: similarityThreshold,
                    processedSoFar: 0,
                    totalCount: allFiles.count,
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
    
    /// Processes a batch of images through the Vision framework pipeline
    /// Extracts feature vectors from each image then clusters similar ones
    /// Feature extraction is the most time-consuming step
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
            
            if let observation = await extractFeature(from: url) {
                observations.append(observation)
                paths.append(url.path)
            }
            
            updateProgress(processedSoFar + index + 1, totalCount, progress)
        }
        
        // Clustering is fast, so we do it on the main actor for thread safety
        return await MainActor.run {
            _clusterFeaturePrints(observations: observations, paths: paths, threshold: threshold)
        }
    }
    
    /// Extracts a feature vector from a single image using Apple's Vision framework
    /// The feature vector captures semantic content that can be compared across images
    /// Uses autoreleasepool to manage memory during batch processing
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
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Perceptual Hash Analysis (Fast)
    /// Alternative analysis method using perceptual hashing for fast duplicate detection
    /// Best for finding exact or near-exact duplicates with minimal computational overhead
    /// Uses block hash algorithm (8x8 grayscale grid) with Hamming distance comparison
    public nonisolated static func analyzeWithPerceptualHash(
        inFolders roots: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        progress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    ) {
        // Convert similarity threshold to maximum Hamming distance
        // 64-bit hash allows 0-64 bit differences
        let maxDist = max(0, min(64, Int((1.0 - similarityThreshold) * 64.0)))
        
        Task.detached(priority: .userInitiated) {
            let pairs = computeHashPairs(
                roots: roots,
                topLevelOnly: topLevelOnly,
                maxDist: maxDist,
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
    /// Generates hash for each image then compares all pairs within distance threshold
    /// ENHANCED: Now includes proper progress reporting at the image level
    private nonisolated static func computeHashPairs(
        roots: [URL],
        topLevelOnly: Bool,
        maxDist: Int,
        progress: (@Sendable (Double) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> [TableRow] {
        
        let subdirs = foldersToScan(from: roots)
        var allPairs: [TableRow] = []
        
        if topLevelOnly {
            // Process folders separately for folder-specific analysis
            var totalProcessed = 0
            let allFiles = subdirs.flatMap { topLevelImageFiles(in: $0) }
            let totalCount = allFiles.count
            
            for dir in subdirs {
                if shouldCancel?() == true { break }
                
                let files = topLevelImageFiles(in: dir)
                let pairs = hashAndCompareWithProgress(
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
            let allFiles = subdirs.flatMap { allImageFiles(in: $0) }
            allPairs = hashAndCompareWithProgress(
                files: allFiles,
                maxDist: maxDist,
                processedSoFar: 0,
                totalCount: allFiles.count,
                progress: progress,
                shouldCancel: shouldCancel
            )
        }
        
        // Return pairs sorted by similarity percentage (highest first)
        return allPairs.sorted { $0.percent > $1.percent }
    }
    
    /// Enhanced hash comparison with proper progress reporting
    /// ENHANCED: Now reports progress for each image processed, not just at the end
    private nonisolated static func hashAndCompareWithProgress(
        files: [URL],
        maxDist: Int,
        processedSoFar: Int,
        totalCount: Int,
        progress: (@Sendable (Double) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> [TableRow] {
        var hashes: [(path: String, hash: UInt64)] = []
        
        // Generate perceptual hash for each image WITH PROGRESS REPORTING
        for (index, file) in files.enumerated() {
            if shouldCancel?() == true { break }
            
            if let hash = blockHash(for: file) {
                hashes.append((path: file.path, hash: hash))
            }
            
            // Report progress for each image processed
            let currentTotal = processedSoFar + index + 1
            updateProgress(currentTotal, totalCount, progress)
        }
        
        // Compare all pairs and find those within distance threshold
        var pairs: [TableRow] = []
        for i in 0..<hashes.count {
            for j in (i + 1)..<hashes.count {
                let distance = hammingDistance(hashes[i].hash, hashes[j].hash)
                if distance <= maxDist {
                    let similarity = 1.0 - (Double(distance) / 64.0)
                    pairs.append(TableRow(
                        reference: hashes[i].path,
                        similar: hashes[j].path,
                        percent: similarity
                    ))
                }
            }
        }
        return pairs
    }
    
    /// Core hash comparison algorithm using block hash and Hamming distance
    /// O(n²) comparison of all image pairs - efficient for perceptual hashes
    /// Legacy wrapper for backward compatibility
    private nonisolated static func hashAndCompare(files: [URL], maxDist: Int) -> [TableRow] {
        return hashAndCompareWithProgress(
            files: files,
            maxDist: maxDist,
            processedSoFar: 0,
            totalCount: files.count,
            progress: nil,
            shouldCancel: nil
        )
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

    // MARK: - Deep Feature Clustering Algorithm
    /// Advanced clustering algorithm for Vision framework feature vectors
    /// Groups similar images while intelligently choosing reference images
    /// Must run on MainActor due to Vision framework requirements
    @MainActor
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

    // MARK: - Directory Discovery and Planning
    /// Determines which folders should be scanned based on user selections
    /// Handles both leaf folders (no subdirectories) and parent folders with children
    /// Deduplicates results while preserving selection order
    public nonisolated static func foldersToScan(from roots: [URL]) -> [URL] {
        var out: [URL] = []
        out.reserveCapacity(roots.count * 4)

        for root in roots {
            // Get subdirectories under this root
            let subs = recursiveSubdirectoriesExcludingRoots(under: [root])
            if subs.isEmpty {
                // Leaf root (no subdirs) -> include the root itself
                out.append(root)
            } else {
                // Non-leaf root -> include only the subdirs (preserves old behavior)
                out.append(contentsOf: subs)
            }
        }

        // Deduplicate while preserving order
        var seen = Set<URL>()
        return out.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    /// Recursively discovers all subdirectories within given root directories
    /// Excludes hidden files and package contents for cleaner results
    /// Returns flattened list of all discovered subdirectories
    public nonisolated static func recursiveSubdirectoriesExcludingRoots(under roots: [URL]) -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        dirs.reserveCapacity(256)
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let e = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in e {
                    if let r = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey]),
                       (r.isDirectory ?? false), !(r.isHidden ?? false) {
                        dirs.append(url)
                    }
                }
            }
        }
        return dirs
    }

    // MARK: - File Discovery and Filtering
    /// Recursively finds all image files within a directory tree
    /// Filters by supported image extensions and excludes hidden files
    public nonisolated static func allImageFiles(in directory: URL) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        if let e = fm.enumerator(at: directory,
                                 includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in e {
                guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey]),
                      (rv.isRegularFile ?? false),
                      !(rv.isHidden ?? false),
                      allowedImageExtensions.contains(url.pathExtension.lowercased())
                else { continue }
                results.append(url)
            }
        }
        return results
    }

    /// Finds image files only in the top level of a directory (non-recursive)
    /// Used when user wants to limit scanning to specific folder levels
    public nonisolated static func topLevelImageFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: [.isRegularFileKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true &&
            allowedImageExtensions.contains($0.pathExtension.lowercased())
        }
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
    public nonisolated static func blockHash(for cgImage: CGImage) -> UInt64? {
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
    public nonisolated static func blockHash(for imageURL: URL) -> UInt64? {
        guard let cg = downsampledCGImage(from: imageURL, to: CGSize(width: 32, height: 32)) else { return nil }
        return blockHash(for: cg)
    }

    /// Calculates Hamming distance between two hash values
    /// Counts the number of differing bits using XOR and bit counting
    public nonisolated static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        Int((a ^ b).nonzeroBitCount)
    }

    // MARK: - Image Processing Utilities
    /// Creates a downsampled CGImage from a file URL for consistent processing
    /// Uses ImageIO for efficient thumbnail generation with orientation handling
    /// Essential for memory management when processing large image collections
    public nonisolated static func downsampledCGImage(from url: URL, to size: CGSize) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxDimension = Int(max(size.width, size.height))
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
