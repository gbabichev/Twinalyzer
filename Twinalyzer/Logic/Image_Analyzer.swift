
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
import CryptoKit
import ImageIO
@preconcurrency import Vision

// MARK: - Main Image Analysis Engine
/// Static enum containing all image analysis functionality
/// Provides both AI-based deep feature analysis and traditional perceptual hashing
/// All methods are nonisolated for Swift 6 concurrency safety
/// ENHANCED: Now includes beachball prevention and memory pressure handling

enum ImageAnalyzer {

    // MARK: - Configuration Constants
    private nonisolated static let fileSystemChunkSize = 50     // Process directories in chunks
    private nonisolated static let featureTileSize = 256
    private nonisolated static let featurePrintRevision = VNGenerateImageFeaturePrintRequestRevision2
    nonisolated static let stepHashing = "Hashing"
    nonisolated static let stepComparing = "Comparing"

    // MARK: - Progress Tracking Utilities
    /// Step-based progress reporting to show distinct phases
    /// Reports progress every 5 items or at completion to maintain performance
    private nonisolated static func reportStepProgress(
        stepName: String,
        current: Int,
        total: Int,
        callback: (@Sendable (String, Double) -> Void)?
    ) {
        guard let callback, total > 0 else { return }
        let progress = Double(current) / Double(total)
        if current % 5 == 0 || current == total {
            Task { @MainActor in
                callback(stepName, progress)
            }
        }
    }

    // MARK: - Deep Feature Analysis (AI-Based) - FIXED VERSION
    /// Primary analysis method using Apple's Vision framework for intelligent similarity detection
    /// Can detect similar content even with different crops, lighting, or minor modifications
    /// More computationally intensive but significantly more accurate than hash-based methods
    /// FIXED: Two-phase approach - hash ALL first, then cluster ALL
    nonisolated static func analyzeWithDeepFeatures(
        inFolders leafFolders: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        ignoredFolderName: String = "",
        progress: (@Sendable (String, Double) -> Void)? = nil,
        reuseStatus: (@Sendable (EnhancedScanReuseStatus) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    ) {
        Task.detached(priority: .utility) {
            guard shouldCancel?() != true else {
                await MainActor.run { completion([]) }
                return
            }

            // Collect all files
            let allFiles = await getAllFilesFromExactFolders(
                folders: leafFolders,
                topLevelOnly: topLevelOnly,
                ignoredFolderName: ignoredFolderName,
                shouldCancel: shouldCancel
            )

            // Cross-folder enhanced scans use the persistent, exact tiled pipeline. Folder-local
            // scans retain the existing clustering behavior for now.
            if !topLevelOnly {
                let results = await analyzeCrossFolderWithPersistentCache(
                    files: allFiles,
                    threshold: similarityThreshold,
                    progress: progress,
                    reuseStatus: reuseStatus,
                    shouldCancel: shouldCancel
                )
                await MainActor.run {
                    progress?(stepComparing, 1.0)
                    completion(shouldCancel?() == true ? [] : results)
                }
                return
            }

            var results: [ImageComparisonResult] = []
            let totalCount = allFiles.count

            // STEP 1: Hash ALL images (smooth 0→100%)
            var observations: [VNFeaturePrintObservation] = []
            var paths: [String] = []
            observations.reserveCapacity(allFiles.count)
            paths.reserveCapacity(allFiles.count)

            for (index, url) in allFiles.enumerated() {
                if shouldCancel?() == true { break }
                if index % 10 == 0 { await Task.yield() }

                let observation = await extractFeature(from: url)
                if let observation = observation {
                    observations.append(observation)
                    paths.append(url.path)
                }

                reportStepProgress(stepName: stepHashing, current: index + 1, total: totalCount, callback: progress)
            }

            guard !Task.isCancelled, !observations.isEmpty else {
                await MainActor.run { completion([]) }
                return
            }

            // STEP 2: Per-folder clustering
            for dir in leafFolders {
                if shouldCancel?() == true { break }

                let files = await topLevelImageFilesAsync(
                    in: dir,
                    ignoredFolderName: ignoredFolderName,
                    shouldCancel: shouldCancel
                )
                let fileSet = Set(files.map { $0.path })

                let dirObs = zip(observations, paths).filter { _, p in fileSet.contains(p) }
                guard dirObs.count > 1 else {
                    await Task.yield()
                    continue
                }

                let obs = dirObs.map { $0.0 }
                let obsPaths = dirObs.map { $0.1 }

                let folderResults = await clusterFeaturePrintsOffMainActor(
                    observations: obs, paths: obsPaths,
                    threshold: similarityThreshold,
                    progress: progress
                )
                results.append(contentsOf: folderResults)
                await Task.yield()
            }

            await MainActor.run {
                progress?(stepComparing, 1.0)
                completion(shouldCancel?() == true ? [] : results)
            }
        }
    }

    /// Exhaustively compares every image pair while keeping only two bounded feature blocks in RAM.
    /// Vision feature generation and completed scan results are persisted between launches.
    private nonisolated static func analyzeCrossFolderWithPersistentCache(
        files: [URL],
        threshold: Double,
        progress: (@Sendable (String, Double) -> Void)?,
        reuseStatus: (@Sendable (EnhancedScanReuseStatus) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> [ImageComparisonResult] {
        guard !files.isEmpty, shouldCancel?() != true else { return [] }

        do {
            let cache = try EnhancedScanCache()
            let descriptors = files.compactMap(CachedImageDescriptor.init(url:)).sorted { $0.path < $1.path }
            guard !descriptors.isEmpty else { return [] }

            // Generate only missing or invalidated feature prints. Each new observation is
            // securely archived to SQLite and released before the next iteration.
            for (index, descriptor) in descriptors.enumerated() {
                if shouldCancel?() == true { return [] }
                let isCached = try cache.hasCachedFeature(
                    for: descriptor,
                    revision: featurePrintRevision
                )
                if !isCached {
                    let url = URL(fileURLWithPath: descriptor.path)
                    guard let observation = await extractFeature(from: url) else {
                        reportStepProgress(
                            stepName: stepHashing,
                            current: index + 1,
                            total: descriptors.count,
                            callback: progress
                        )
                        continue
                    }
                    try cache.storeFeature(
                        observation,
                        for: descriptor,
                        revision: featurePrintRevision
                    )
                }
                reportStepProgress(
                    stepName: stepHashing,
                    current: index + 1,
                    total: descriptors.count,
                    callback: progress
                )
                if index % 25 == 0 { await Task.yield() }
            }

            // Exclude files whose Vision request failed. A cache lookup also validates that an
            // archive can still be decoded by the current framework.
            var validDescriptors: [CachedImageDescriptor] = []
            validDescriptors.reserveCapacity(descriptors.count)
            for descriptor in descriptors {
                if shouldCancel?() == true { return [] }
                let isValid = try autoreleasepool {
                    try cache.cachedFeature(for: descriptor, revision: featurePrintRevision) != nil
                }
                if isValid {
                    validDescriptors.append(descriptor)
                }
            }
            guard validDescriptors.count > 1 else { return [] }

            try cache.prepareCurrentImageSet(validDescriptors)
            let signature = imageSetSignature(validDescriptors, revision: featurePrintRevision)
            if let reusable = try cache.reusableScan(
                signature: signature,
                requestedThreshold: threshold,
                revision: featurePrintRevision
            ) {
                try cache.recordCurrentImageSet(for: reusable.id)
                reportReuseStatus(
                    unchangedImages: validDescriptors.count,
                    newOrModifiedImages: 0,
                    requiredComparisons: 0,
                    callback: reuseStatus
                )
                progress?(stepComparing, 1.0)
                return try results(from: cache, scanID: reusable.id, threshold: threshold)
            }

            let priorCoverage = try cache.bestReusableCoverage(
                requestedThreshold: threshold,
                revision: featurePrintRevision
            )
            let reusablePaths = priorCoverage?.reusablePaths ?? []
            let reusedDescriptors = validDescriptors.filter { reusablePaths.contains($0.path) }
            let uncoveredDescriptors = validDescriptors.filter { !reusablePaths.contains($0.path) }

            let uncoveredCount = Int64(uncoveredDescriptors.count)
            let reusedCount = Int64(reusedDescriptors.count)
            let totalComparisons = uncoveredCount * (uncoveredCount - 1) / 2
                + uncoveredCount * reusedCount
            reportReuseStatus(
                unchangedImages: reusedDescriptors.count,
                newOrModifiedImages: uncoveredDescriptors.count,
                requiredComparisons: totalComparisons,
                callback: reuseStatus
            )

            let scanID = try cache.beginScan(
                signature: signature,
                threshold: threshold,
                revision: featurePrintRevision
            )
            do {
                try cache.beginWritingMatches(scanID: scanID)
                if let priorCoverage {
                    try cache.copyReusableMatches(
                        from: priorCoverage.scanID,
                        to: scanID,
                        threshold: threshold
                    )
                }

                var completedComparisons: Int64 = 0
                let progressInterval = max(Int64(10_000), totalComparisons / 10_000)
                let uncoveredBlockStarts = Array(
                    stride(from: 0, to: uncoveredDescriptors.count, by: featureTileSize)
                )

                // Compare every uncovered image with every other uncovered image.
                for (leftBlockIndex, leftStart) in uncoveredBlockStarts.enumerated() {
                    if shouldCancel?() == true { throw CancellationError() }
                    let leftEnd = min(leftStart + featureTileSize, uncoveredDescriptors.count)
                    let left = try cache.loadFeatureBlock(
                        uncoveredDescriptors[leftStart..<leftEnd],
                        revision: featurePrintRevision
                    )

                    for rightBlockIndex in leftBlockIndex..<uncoveredBlockStarts.count {
                        if shouldCancel?() == true { throw CancellationError() }
                        let rightStart = uncoveredBlockStarts[rightBlockIndex]
                        let rightEnd = min(rightStart + featureTileSize, uncoveredDescriptors.count)
                        let right = rightBlockIndex == leftBlockIndex
                            ? left
                            : try cache.loadFeatureBlock(
                                uncoveredDescriptors[rightStart..<rightEnd],
                                revision: featurePrintRevision
                            )
                        try compareFeatureBlocks(
                            left,
                            right,
                            diagonal: rightBlockIndex == leftBlockIndex,
                            cache: cache,
                            scanID: scanID,
                            threshold: threshold,
                            completedComparisons: &completedComparisons,
                            totalComparisons: totalComparisons,
                            progressInterval: progressInterval,
                            progress: progress,
                            shouldCancel: shouldCancel
                        )
                        await Task.yield()
                    }
                }

                // Prior coverage accounts for every reused↔reused pair. Only the cross product
                // between uncovered and reused images remains.
                let reusedBlockStarts = Array(
                    stride(from: 0, to: reusedDescriptors.count, by: featureTileSize)
                )
                for uncoveredStart in uncoveredBlockStarts {
                    if shouldCancel?() == true { throw CancellationError() }
                    let uncoveredEnd = min(
                        uncoveredStart + featureTileSize,
                        uncoveredDescriptors.count
                    )
                    let uncoveredBlock = try cache.loadFeatureBlock(
                        uncoveredDescriptors[uncoveredStart..<uncoveredEnd],
                        revision: featurePrintRevision
                    )
                    for reusedStart in reusedBlockStarts {
                        if shouldCancel?() == true { throw CancellationError() }
                        let reusedEnd = min(reusedStart + featureTileSize, reusedDescriptors.count)
                        let reusedBlock = try cache.loadFeatureBlock(
                            reusedDescriptors[reusedStart..<reusedEnd],
                            revision: featurePrintRevision
                        )
                        try compareFeatureBlocks(
                            uncoveredBlock,
                            reusedBlock,
                            diagonal: false,
                            cache: cache,
                            scanID: scanID,
                            threshold: threshold,
                            completedComparisons: &completedComparisons,
                            totalComparisons: totalComparisons,
                            progressInterval: progressInterval,
                            progress: progress,
                            shouldCancel: shouldCancel
                        )
                        await Task.yield()
                    }
                }

                if totalComparisons == 0 {
                    progress?(stepComparing, 1.0)
                }

                try cache.finishWritingMatches(scanID: scanID)
                return try results(from: cache, scanID: scanID, threshold: threshold)
            } catch {
                cache.abandonScan(scanID: scanID)
                throw error
            }
        } catch is CancellationError {
            return []
        } catch {
            print("Enhanced scan cache failed: \(error)")
            return []
        }
    }

    private nonisolated static func reportReuseStatus(
        unchangedImages: Int,
        newOrModifiedImages: Int,
        requiredComparisons: Int64,
        callback: (@Sendable (EnhancedScanReuseStatus) -> Void)?
    ) {
        let status = EnhancedScanReuseStatus(
            unchangedImages: unchangedImages,
            newOrModifiedImages: newOrModifiedImages,
            requiredComparisons: requiredComparisons
        )
        print(
            "Enhanced Scan cache: \(unchangedImages) unchanged images reused; "
                + "\(newOrModifiedImages) new or modified images; "
                + "\(requiredComparisons) new comparisons required"
        )
        callback?(status)
    }

    private nonisolated static func compareFeatureBlocks(
        _ left: [(descriptor: CachedImageDescriptor, observation: VNFeaturePrintObservation)],
        _ right: [(descriptor: CachedImageDescriptor, observation: VNFeaturePrintObservation)],
        diagonal: Bool,
        cache: EnhancedScanCache,
        scanID: Int64,
        threshold: Double,
        completedComparisons: inout Int64,
        totalComparisons: Int64,
        progressInterval: Int64,
        progress: (@Sendable (String, Double) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) throws {
        for leftIndex in left.indices {
            let firstRightIndex = diagonal ? leftIndex + 1 : 0
            guard firstRightIndex < right.count else { continue }
            for rightIndex in firstRightIndex..<right.count {
                if completedComparisons % 4_096 == 0, shouldCancel?() == true {
                    throw CancellationError()
                }
                var distance: Float = 0
                do {
                    try left[leftIndex].observation.computeDistance(
                        &distance,
                        to: right[rightIndex].observation
                    )
                    let similarity = 1.0 / (1.0 + Double(distance))
                    if similarity >= threshold {
                        let leftPath = left[leftIndex].descriptor.path
                        let rightPath = right[rightIndex].descriptor.path
                        try cache.appendMatch(
                            scanID: scanID,
                            reference: min(leftPath, rightPath),
                            similar: max(leftPath, rightPath),
                            similarity: similarity
                        )
                    }
                } catch let error as EnhancedScanCacheError {
                    throw error
                } catch {
                    print("Vision distance failed: \(error)")
                }

                completedComparisons += 1
                if completedComparisons % progressInterval == 0
                    || completedComparisons == totalComparisons {
                    let fraction = Double(completedComparisons) / Double(max(totalComparisons, 1))
                    progress?(stepComparing, fraction)
                }
            }
        }
    }

    private nonisolated static func imageSetSignature(
        _ descriptors: [CachedImageDescriptor],
        revision: Int
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("twinalyzer-feature-cache-v1\u{1f}\(revision)\n".utf8))
        for descriptor in descriptors {
            hasher.update(data: Data(descriptor.versionKey.utf8))
            hasher.update(data: Data([0x0A]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func results(
        from cache: EnhancedScanCache,
        scanID: Int64,
        threshold: Double
    ) throws -> [ImageComparisonResult] {
        var grouped: [String: [(path: String, percent: Double)]] = [:]
        try cache.forEachMatch(scanID: scanID, threshold: threshold) { match in
            grouped[match.reference, default: []].append((match.similar, match.similarity))
        }
        return grouped.map { reference, similars in
            ImageComparisonResult(
                reference: reference,
                similars: similars.sorted { $0.percent > $1.percent }
            )
        }.sorted { ($0.similars.first?.percent ?? 0) > ($1.similars.first?.percent ?? 0) }
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
        progress: (@Sendable (String, Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    )
    {
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
                progress?(stepComparing, 1.0)
                completion(results)
            }
        }
    }

    /// Computes perceptual hash pairs for similarity comparison
    private nonisolated static func computeHashPairs(
        folders: [URL],
        topLevelOnly: Bool,
        maxDist: Int,
        ignoredFolderName: String = "",
        progress: (@Sendable (String, Double) -> Void)?,
        shouldCancel: (@Sendable () -> Bool)?
    ) async -> [TableRow] {

        guard shouldCancel?() != true else { return [] }

        var allPairs: [TableRow] = []

        if topLevelOnly {
            // Process folders separately (no cross-folder comparison in this mode).
            var totalProcessed = 0
            let allFiles = await getAllFilesFromExactFolders(
                folders: folders,
                topLevelOnly: true,
                ignoredFolderName: ignoredFolderName,
                shouldCancel: shouldCancel
            )
            let totalCount = allFiles.count

            // Pre-count total comparisons across all folders for accurate progress reporting
            var totalComparisons = 0
            for dir in folders {
                if shouldCancel?() == true { break }
                let files = await topLevelImageFilesAsync(
                    in: dir,
                    ignoredFolderName: ignoredFolderName,
                    shouldCancel: shouldCancel
                )
                let n = files.count
                totalComparisons += n * (n - 1) / 2
            }
            var completedComparisons = 0

            for dir in folders {
                if shouldCancel?() == true { break }

                let files = await topLevelImageFilesAsync(
                    in: dir,
                    ignoredFolderName: ignoredFolderName,
                    shouldCancel: shouldCancel
                )

                // Compare the entire folder at once so pairs are not missed across chunks.
                let pairs = await hashAndCompareWithProgress(
                    files: files,
                    maxDist: maxDist,
                    processedSoFar: totalProcessed,
                    totalCount: totalCount,
                    totalComparisons: totalComparisons,
                    completedComparisons: completedComparisons,
                    progress: progress,
                    shouldCancel: shouldCancel
                )
                allPairs.append(contentsOf: pairs)

                let n = files.count
                completedComparisons += n * (n - 1) / 2
                totalProcessed += files.count

                await Task.yield()
            }
        } else {
            // Process all files together for full cross-folder comparison.
            let allFiles = await getAllFilesFromExactFolders(
                folders: folders,
                topLevelOnly: false,
                ignoredFolderName: ignoredFolderName,
                shouldCancel: shouldCancel
            )

            let totalComparisons = allFiles.count * (allFiles.count - 1) / 2

            let pairs = await hashAndCompareWithProgress(
                files: allFiles,
                maxDist: maxDist,
                processedSoFar: 0,
                totalCount: allFiles.count,
                totalComparisons: totalComparisons,
                completedComparisons: 0,
                progress: progress,
                shouldCancel: shouldCancel
            )
            allPairs.append(contentsOf: pairs)
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

    /// Extracts a feature vector from a single image using Apple's Vision framework
    /// The feature vector captures semantic content that can be compared across images
    /// Uses autoreleasepool to manage memory during batch processing
    /// ENHANCED: Added timeout, better error handling, and aggressive memory management
    private nonisolated static func extractFeature(from url: URL) async -> VNFeaturePrintObservation? {
        return await withCheckedContinuation { continuation in
            // Use autoreleasepool for the synchronous parts only
            autoreleasepool {
                let request = VNGenerateImageFeaturePrintRequest()
                request.revision = featurePrintRevision

                // Let Vision read from the file URL directly. This avoids retaining a lazily
                // decoded CIImage and its backing store beyond the request.
                let handler = VNImageRequestHandler(
                    url: url,
                    orientation: imageOrientation(at: url),
                    options: [:]
                )

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

    private nonisolated static func imageOrientation(at url: URL) -> CGImagePropertyOrientation {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawOrientation = properties[kCGImagePropertyOrientation] as? UInt32,
              let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) else {
            return .up
        }
        return orientation
    }

    /// Cluster feature prints on a background thread to avoid MainActor blocking
    private nonisolated static func clusterFeaturePrintsOffMainActor(
        observations: [VNFeaturePrintObservation],
        paths: [String],
        threshold: Double,
        progress: (@Sendable (String, Double) -> Void)?
    ) async -> [ImageComparisonResult] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results = _clusterFeaturePrints(
                    observations: observations, paths: paths,
                    threshold: threshold, progress: progress
                )
                continuation.resume(returning: results)
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
        totalComparisons: Int,
        completedComparisons: Int,
        progress: (@Sendable (String, Double) -> Void)?,
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
            reportStepProgress(stepName: stepHashing, current: processedSoFar + index + 1, total: totalCount, callback: progress)
        }

        // ENHANCED: Compare all pairs with cooperative cancellation
        // FIXED: Collect pair data first, then create TableRows on MainActor
        var pairData: [(reference: String, similar: String, percent: Double)] = []
        var comparisonCount = 0
        //_ = hashes.count * (hashes.count - 1) / 2

        for i in 0..<hashes.count {
            if shouldCancel?() == true { break }

            for j in (i + 1)..<hashes.count {
                if shouldCancel?() == true { break }

                // CRITICAL: Yield control periodically in O(n²) loop
                comparisonCount += 1
                if comparisonCount % 250 == 0 {
                    await Task.yield()

                    // Report progress during comparison phase
                    reportStepProgress(stepName: stepComparing, current: completedComparisons + comparisonCount, total: max(totalComparisons, 1), callback: progress)
                }

                let distance = hammingDistance(hashes[i].hash, hashes[j].hash)
                if distance <= maxDist {
                    let similarity = 1.0 - (Double(distance) / 64.0)
                    let refPath = hashes[i].path
                    let simPath = hashes[j].path

                    pairData.append((reference: refPath, similar: simPath, percent: similarity))
                }
            }
        }

        // Create TableRows on MainActor - FIXED
        let pairs = await MainActor.run {
            pairData.map { data in
                TableRow(
                    reference: data.reference,
                    similar: data.similar,
                    percent: data.percent
                )
            }
        }

        // Cleanup hashes array
        hashes.removeAll(keepingCapacity: false)

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
    /// Runs on background thread to avoid MainActor blocking
    private nonisolated static func _clusterFeaturePrints(
        observations: [VNFeaturePrintObservation],
        paths: [String],
        threshold: Double,
        progress: (@Sendable (String, Double) -> Void)?
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

        let totalComparisons = n * (n - 1) / 2
        let exactEps = 0.9995
        var used = Set<Int>()
        var results: [ImageComparisonResult] = []
        var comparisonCount = 0

        // Main clustering loop: build connected components of similar images
        for i in 0..<n {
            guard !used.contains(i) else { continue }

            // Find all images similar to image i
            var members = [i]
            for j in (i + 1)..<n where !used.contains(j) {
                comparisonCount += 1
                if sim(i, j) >= threshold {
                    members.append(j)
                    used.insert(j)
                }
                if comparisonCount % 250 == 0 {
                    reportStepProgress(stepName: stepComparing, current: comparisonCount, total: totalComparisons, callback: progress)
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
    private nonisolated static func allImageFilesAsync(
        in directory: URL,
        ignoredFolderName: String = "",
        topLevelOnly: Bool = false,
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

                // FIXED: Only check for ignored folder names in subfolders,
                // not in the root directory itself
                if !ignoredName.isEmpty {
                    let rootComponents = directory.pathComponents
                    let fileComponents = url.pathComponents

                    // Only check components that come after the root directory
                    if fileComponents.count > rootComponents.count {
                        let subdirComponents = Array(fileComponents[rootComponents.count...])
                        let containsIgnoredFolder = subdirComponents.contains { component in
                            component.lowercased() == ignoredName
                        }
                        if containsIgnoredFolder {
                            continue // Skip files in ignored subfolders
                        }
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
}
