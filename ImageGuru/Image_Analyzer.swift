//
//  Image_Analyzer.swift
//  Swift 6 ready, simplified progress tracking
//

import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import Vision
@preconcurrency import CoreImage


// MARK: - Analyzer

public enum ImageAnalyzer {

    // MARK: - Simple Progress Helper
    private nonisolated static func updateProgress(
        _ current: Int, 
        _ total: Int, 
        _ callback: (@Sendable (Double) -> Void)?
    ) {
        guard let callback, total > 0 else { return }
        let progress = Double(current) / Double(total)
        
        // Simple throttling - only update every 10 items or at 100%
        if current % 10 == 0 || current == total {
            Task { @MainActor in
                callback(progress)
            }
        }
    }

    // MARK: Public API (Deep Features, simplified)
    public nonisolated static func analyzeWithDeepFeatures(
        inFolders roots: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        progress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    ) {
        Task.detached(priority: .userInitiated) {
            let subdirs = foldersToScan(from: roots)
            var results: [ImageComparisonResult] = []
            
            if topLevelOnly {
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
            
            await MainActor.run {
                progress?(1.0)
                completion(shouldCancel?() == true ? [] : results)
            }
        }
    }
    
    /// Process a batch of images and extract features
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
        
        // Extract features with simple progress tracking
        for (index, url) in files.enumerated() {
            if shouldCancel?() == true { break }
            
            if let observation = await extractFeature(from: url) {
                observations.append(observation)
                paths.append(url.path)
            }
            
            updateProgress(processedSoFar + index + 1, totalCount, progress)
        }
        
        // Cluster on main actor (it's fast)
        return await MainActor.run {
            _clusterFeaturePrints(observations: observations, paths: paths, threshold: threshold)
        }
    }
    
    /// Extract feature from single image
    private nonisolated static func extractFeature(from url: URL) async -> VNFeaturePrintObservation? {
        return await withCheckedContinuation { continuation in
            autoreleasepool {
                let request = VNGenerateImageFeaturePrintRequest()
                
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

    // MARK: Public API (Perceptual Hash, simplified)
    public nonisolated static func analyzeWithPerceptualHash(
        inFolders roots: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        progress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    ) {
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
            
            // Group pairs into results on main actor
            let results = await MainActor.run {
                groupPairsIntoResults(pairs)
            }
            
            await MainActor.run {
                progress?(1.0)
                completion(results)
            }
        }
    }
    
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
            var totalProcessed = 0
            let allFiles = subdirs.flatMap { topLevelImageFiles(in: $0) }
            let totalCount = allFiles.count
            
            for dir in subdirs {
                if shouldCancel?() == true { break }
                
                let files = topLevelImageFiles(in: dir)
                let pairs = hashAndCompare(files: files, maxDist: maxDist)
                allPairs.append(contentsOf: pairs)
                
                totalProcessed += files.count
                updateProgress(totalProcessed, totalCount, progress)
            }
        } else {
            let allFiles = subdirs.flatMap { allImageFiles(in: $0) }
            allPairs = hashAndCompare(files: allFiles, maxDist: maxDist)
            updateProgress(allFiles.count, allFiles.count, progress)
        }
        
        return allPairs.sorted { $0.percent > $1.percent }
    }
    
    private nonisolated static func hashAndCompare(files: [URL], maxDist: Int) -> [TableRow] {
        var hashes: [(path: String, hash: UInt64)] = []
        
        for file in files {
            if let hash = blockHash(for: file) {
                hashes.append((path: file.path, hash: hash))
            }
        }
        
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
    
    @MainActor
    private static func groupPairsIntoResults(_ pairs: [TableRow]) -> [ImageComparisonResult] {
        var grouped: [String: [(path: String, percent: Double)]] = [:]
        
        for pair in pairs {
            grouped[pair.reference, default: []].append((path: pair.similar, percent: pair.percent))
        }
        
        return grouped.map { reference, similars in
            ImageComparisonResult(
                reference: reference,
                similars: similars.sorted { $0.percent > $1.percent }
            )
        }.sorted { ($0.similars.first?.percent ?? 0) > ($1.similars.first?.percent ?? 0) }
    }

    // MARK: Public API (pHash table pairs) - kept for compatibility

    /// Cluster Vision observations at a given threshold. Must be called on MainActor.
    @MainActor
    private static func _clusterFeaturePrints(
        observations: [VNFeaturePrintObservation],
        paths: [String],
        threshold: Double
    ) -> [ImageComparisonResult] {
        precondition(observations.count == paths.count)

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

        func chooseReference(in idxs: [Int]) -> Int {
            let exactEps = 0.9995
            for a in 0..<idxs.count {
                for b in (a + 1)..<idxs.count where sim(idxs[a], idxs[b]) >= exactEps {
                    let ia = idxs[a], ib = idxs[b]
                    let pa = paths[ia], pb = paths[ib]
                    return (pa <= pb) ? ia : ib
                }
            }
            return idxs.min { paths[$0] < paths[$1] }!
        }

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

        for i in 0..<n {
            guard !used.contains(i) else { continue }

            var members = [i]
            for j in (i + 1)..<n where !used.contains(j) {
                if sim(i, j) >= threshold {
                    members.append(j)
                    used.insert(j)
                }
            }
            used.insert(i)
            guard members.count > 1 else { continue }

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

    // MARK: Directory planning

    public nonisolated static func foldersToScan(from roots: [URL]) -> [URL] {
        var out: [URL] = []
        out.reserveCapacity(roots.count * 4)

        for root in roots {
            // Get subdirectories under *this* root
            let subs = recursiveSubdirectoriesExcludingRoots(under: [root])
            if subs.isEmpty {
                // Leaf root (no subdirs) -> include the root itself
                out.append(root)
            } else {
                // Non-leaf root -> include only the subdirs (old behavior)
                out.append(contentsOf: subs)
            }
        }

        // Deduplicate while preserving order
        var seen = Set<URL>()
        return out.filter { seen.insert($0.standardizedFileURL).inserted }
    }

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

    // MARK: File enumeration

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

    private nonisolated static let allowedImageExtensions: Set<String> = [
        "jpg","jpeg","png","heic","heif","tiff","tif","bmp","gif","webp","dng","cr2","nef","arw"
    ]

    // MARK: Hashing
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
        var sum = 0
        for i in 0..<(w*h) { sum += Int(p[i]) }
        let avg = sum / (w*h)
        var hash: UInt64 = 0
        for i in 0..<(w*h) { if p[i] >= avg { hash |= (1 << UInt64(i)) } }
        return hash
    }

    public nonisolated static func blockHash(for imageURL: URL) -> UInt64? {
        guard let cg = downsampledCGImage(from: imageURL, to: CGSize(width: 32, height: 32)) else { return nil }
        return blockHash(for: cg)
    }

    public nonisolated static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        Int((a ^ b).nonzeroBitCount)
    }

    // MARK: Downsampling

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
