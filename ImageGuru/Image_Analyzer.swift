//
//  Image_Analyzer.swift
//  Swift 6–ready, deep embed merged (race-free)
//

import Foundation
import CoreGraphics
import ImageIO
@preconcurrency import Vision
@preconcurrency import CoreImage

// MARK: - Row Models

public struct TableRow: Identifiable, Hashable, Sendable {
    public var id: String { reference + "::" + similar }
    public let reference: String
    public let similar: String
    public let percent: Double
}

public struct ImageComparisonResult: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let reference: String
    public let similars: [(path: String, percent: Double)]

    public init(reference: String, similars: [(path: String, percent: Double)]) {
        self.id = UUID()
        self.reference = reference
        self.similars = similars
    }
    public static func == (lhs: ImageComparisonResult, rhs: ImageComparisonResult) -> Bool { lhs.id == rhs.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Throttle state (actor avoids captured-var races)

fileprivate actor ThrottleBox {
    private var lastSent: CFAbsoluteTime = 0
    private let minInterval: CFTimeInterval
    init(minInterval: CFTimeInterval) { self.minInterval = minInterval }

    func shouldEmit(_ value: Double) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastSent >= minInterval || value >= 0.9999 {
            lastSent = now
            return true
        }
        return false
    }
}

// MARK: - Analyzer

public enum ImageAnalyzer {

    // MARK: Progress helper (closure-based, @Sendable, race-free)
    /// Returns a throttled progress **emitter** you can call from any thread.
    /// It rate-limits emits (via an actor) and hops to the main actor before invoking the UI sink.
    public nonisolated static func makeProgressEmitter(
        _ progress: (@Sendable (Double) -> Void)?,
        minInterval: CFTimeInterval = 0.05
    ) -> (@Sendable (Double) -> Void)? {
        guard let progress else { return nil }
        let box = ThrottleBox(minInterval: minInterval)
        return { value in
            Task {
                if await box.shouldEmit(value) {
                    await MainActor.run {
                        progress(max(0, min(1, value)))
                    }
                }
            }
        }
    }

    // MARK: Public API (pHash table pairs)
    public static func analyzePerceptualHash(
        roots: [URL],
        scanTopLevelOnly: Bool,
        maxDist: Int = 5,
        progress: (@Sendable (Double) -> Void)? = nil
    ) -> [TableRow] {

        let emit = makeProgressEmitter(progress)

        let subdirs = foldersToScan(from: roots)

        if scanTopLevelOnly {
            let totalImages = subdirs.reduce(0) { $0 + topLevelImageFiles(in: $1).count }
            var processed = 0
            var rows: [TableRow] = []
            for dir in subdirs {
                let files = topLevelImageFiles(in: dir)
                let pairs = hashAndPair(urls: files, maxDist: maxDist) { done, total in
                    processed += done
                    tick(processed, max(totalImages, total), emit)
                }
                rows.append(contentsOf: pairs)
            }
            rows.sort { $0.percent > $1.percent }
            tick(totalImages, totalImages, emit)
            return rows
        } else {
            var allFiles: [URL] = []
            for d in subdirs { allFiles.append(contentsOf: topLevelImageFiles(in: d)) }
            let rows = hashAndPair(urls: allFiles, maxDist: maxDist) { done, total in
                tick(done, total, emit)
            }.sorted { $0.percent > $1.percent }
            tick(allFiles.count, allFiles.count, emit)
            return rows
        }
    }

    // MARK: Public API (Deep Features, merged, Swift 6-safe)
    /// Runs Vision work (feature prints + clustering) on the MainActor to satisfy Swift 6’s isolation.
    /// All FS work and progress throttling remain background-safe.
    public nonisolated static func analyzeWithDeepFeatures(
        inFolders roots: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        progress: (@Sendable (Double) -> Void)? = nil,
        shouldCancel: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable ([ImageComparisonResult]) -> Void
    ) {
        let emit = makeProgressEmitter(progress)

        Task.detached(priority: .userInitiated) {
            @inline(__always) func bump(_ done: Int, _ total: Int) {
                guard let emit, total > 0 else { return }
                emit(Double(done) / Double(total))
            }

            // plan scan roots on a background thread
            let subdirs = foldersToScan(from: roots)

            var results: [ImageComparisonResult] = []

            if topLevelOnly {
                let totalImages = subdirs.reduce(0) { $0 + topLevelImageFiles(in: $1).count }
                var processed = 0

                for dir in subdirs {
                    if shouldCancel?() == true { await MainActor.run { completion([]) }; return }

                    let files = topLevelImageFiles(in: dir)
                    guard !files.isEmpty else { continue }

                    // ➜ Vision extraction + clustering on MainActor
                    let folderBlock = await MainActor.run { () -> (res: [ImageComparisonResult], newProcessed: Int) in
                        var localProcessed = processed
                        let (obs, paths) = Self._makeFeaturePrints(for: files, progress: {
                            // This closure is NOT @Sendable and runs on MainActor synchronously.
                            localProcessed += 1
                            if let emit { emit(Double(localProcessed) / Double(max(totalImages, 1))) }
                        })
                        let res = Self._clusterFeaturePrints(observations: obs, paths: paths, threshold: similarityThreshold)
                        return (res, localProcessed)
                    }
                    processed = folderBlock.newProcessed
                    if !folderBlock.res.isEmpty { results.append(contentsOf: folderBlock.res) }
                }
            } else {
                // gather all images
                var imageFiles: [URL] = []
                for d in subdirs {
                    if shouldCancel?() == true { await MainActor.run { completion([]) }; return }
                    imageFiles.append(contentsOf: allImageFiles(in: d))
                }

                let total = imageFiles.count
                if total == 0 {
                    await MainActor.run {
                        emit?(1.0)
                        completion([])
                    }
                    return
                }

                // ➜ Vision extraction + clustering on MainActor
                results = await MainActor.run {
                    var localProcessed = 0
                    let (obs, paths) = Self._makeFeaturePrints(for: imageFiles, progress: {
                        localProcessed += 1
                        emit?(Double(localProcessed) / Double(total))
                    })
                    return Self._clusterFeaturePrints(observations: obs, paths: paths, threshold: similarityThreshold)
                }
            }

            if shouldCancel?() == true { await MainActor.run { completion([]) }; return }

            await MainActor.run {
                emit?(1.0)
                completion(results)
            }
        }
    }

    // MARK: Deep Features – MainActor section

    /// Build feature prints for URLs. Must be called on MainActor.
    /// Returns parallel arrays: observations[i] corresponds to paths[i].
    @MainActor
    private static func _makeFeaturePrints(
        for urls: [URL],
        progress: (() -> Void)?    // ⬅︎ not @Sendable; runs only on MainActor
    ) -> ([VNFeaturePrintObservation], [String]) {
        var observations: [VNFeaturePrintObservation] = []
        observations.reserveCapacity(urls.count)
        var paths: [String] = []
        paths.reserveCapacity(urls.count)

        let req = VNGenerateImageFeaturePrintRequest()

        for url in urls {
            autoreleasepool {
                if let ci = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
                    let h = VNImageRequestHandler(ciImage: ci, options: [:])
                    do {
                        try h.perform([req])
                        if let obs = req.results?.first as? VNFeaturePrintObservation {
                            observations.append(obs)
                            paths.append(url.path)
                        }
                    } catch {
                        // skip on error
                    }
                }
                progress?()  // runs synchronously on MainActor
            }
        }
        return (observations, paths)
    }

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

    // MARK: pHash plumbing (background-safe)

    private typealias PairProgress = (Int, Int) -> Void

    private static func hashAndPair(
        urls: [URL],
        maxDist: Int,
        progress: PairProgress
    ) -> [TableRow] {
        let total = max(urls.count, 1)
        var hashes = [(url: String, hash: UInt64)]()
        hashes.reserveCapacity(urls.count)

        var done = 0
        for url in urls {
            if let hash = subjectBlockHash(for: url) ?? blockHash(for: url) {
                hashes.append((url: url.path, hash: hash))
            }
            done += 1
            progress(done, total)
        }

        var rows: [TableRow] = []
        for i in 0..<hashes.count {
            for j in (i + 1)..<hashes.count {
                let d = hammingDistance(hashes[i].hash, hashes[j].hash)
                if d <= maxDist {
                    let percent = 1.0 - (Double(d) / 64.0)
                    rows.append(TableRow(reference: hashes[i].url, similar: hashes[j].url, percent: percent))
                }
            }
        }
        return rows
    }

    @inline(__always)
    private static func tick(_ done: Int, _ total: Int, _ emit: (@Sendable (Double) -> Void)?) {
        guard let emit, total > 0 else { return }
        emit(Double(done) / Double(total))
    }

    // MARK: Directory planning

    public nonisolated static func foldersToScan(from roots: [URL]) -> [URL] {
        recursiveSubdirectoriesExcludingRoots(under: roots)
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
                guard allowedImageExtensions.contains(url.pathExtension.lowercased()) else { continue }
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
        return contents.filter { allowedImageExtensions.contains($0.pathExtension.lowercased()) }
    }

    private nonisolated static let allowedImageExtensions: Set<String> = [
        "jpg","jpeg","png","heic","heif","tiff","tif","bmp","gif","webp"
    ]

    // MARK: Hashing

    public nonisolated static func subjectBlockHash(for imageURL: URL) -> UInt64? { nil }

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
        guard let cg = downsampledCGImage(from: imageURL, to: CGSize(width: 256, height: 256)) else { return nil }
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
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

