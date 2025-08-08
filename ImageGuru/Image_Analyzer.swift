import AppKit
import AVFoundation
import Foundation
import Accelerate
import Vision
import CoreImage
import ImageIO

struct ImageComparisonResult: Identifiable {
    let id = UUID()
    let reference: String
    let similars: [(path: String, percent: Double)]
}

struct TableRow: Identifiable, Hashable {
    var id: String { reference + "::" + similar }
    let reference: String
    let similar: String
    let percent: Double
}

struct ImageAnalyzer {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "tiff", "gif", "heic", "heif", "webp"]

    // MARK: - File enumeration

    /// All image files (recursive) in a directory.
    static func allImageFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        if let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentTypeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    urls.append(fileURL)
                }
            }
        }
        return urls
    }

    /// Top-level image files (no recursion) in a directory.
    static func topLevelImageFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Recursively enumerates **subdirectories only** (excludes each root itself).
    static func recursiveSubdirectoriesExcludingRoots(under roots: [URL]) -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        dirs.reserveCapacity(256)

        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { continue }

            if let e = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in e {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        dirs.append(url)
                    }
                }
            }
        }

        // Unique + stable order
        return Array(Set(dirs.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
    }

    // MARK: - Downsample

    static func downsampledCGImage(from url: URL, to size: CGSize) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(size.width), Int(size.height)),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    // MARK: - Hashing

    static func subjectBlockHash(for imageURL: URL) -> UInt64? {
        return autoreleasepool {
            guard let cgImage = downsampledCGImage(from: imageURL, to: CGSize(width: 256, height: 256)) else {
                return nil
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNDetectHumanBodyPoseRequest()

            do {
                try handler.perform([request])
                let observations = request.results ?? []
                guard let observation = observations.first else {
                    return blockHash(for: cgImage)
                }

                let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                guard let recognizedPoints = try? observation.recognizedPoints(.all) else {
                    return blockHash(for: cgImage)
                }

                let validPoints = recognizedPoints.values.filter { $0.confidence > 0.3 }
                guard !validPoints.isEmpty else { return blockHash(for: cgImage) }

                let xs = validPoints.map { $0.x }
                let ys = validPoints.map { $0.y }
                guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
                      maxX > minX, maxY > minY else { return blockHash(for: cgImage) }

                let bb = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                let rect = CGRect(
                    x: bb.origin.x * imageSize.width,
                    y: (1.0 - bb.origin.y - bb.height) * imageSize.height,
                    width: bb.width * imageSize.width,
                    height: bb.height * imageSize.height
                ).integral

                if let cropped = cgImage.cropping(to: rect) {
                    return blockHash(for: cropped)
                } else {
                    return blockHash(for: cgImage)
                }
            } catch {
                return blockHash(for: cgImage)
            }
        }
    }

    static func blockHash(for cgImage: CGImage) -> UInt64? {
        let grid = 8
        guard let ctx = CGContext(
            data: nil,
            width: grid,
            height: grid,
            bitsPerComponent: 8,
            bytesPerRow: grid,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: grid, height: grid))

        guard let data = ctx.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: grid * grid)

        var sum = 0
        for i in 0..<(grid * grid) { sum += Int(ptr[i]) }
        let avg = sum / (grid * grid)

        var h: UInt64 = 0
        for i in 0..<(grid * grid) {
            if Int(ptr[i]) >= avg { h |= (1 << (63 - i)) }
        }
        return h
    }

    static func blockHash(for imageURL: URL) -> UInt64? {
        guard let cgImage = downsampledCGImage(from: imageURL, to: CGSize(width: 8, height: 8)) else { return nil }
        return blockHash(for: cgImage)
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - PROGRESS (thread-safe throttling)

    private final class ProgressThrottler {
        private var last: CFTimeInterval = 0
        private let minInterval: CFTimeInterval
        private let sink: (Double) -> Void

        init(minInterval: CFTimeInterval = 0.05, sink: @escaping (Double) -> Void) {
            self.minInterval = minInterval
            self.sink = sink
        }

        func send(_ value: Double) {
            let now = CACurrentMediaTime()
            if now - last >= minInterval || value == 0 || value >= 1 {
                last = now
                DispatchQueue.main.async { self.sink(value) }
            }
        }
    }

    // MARK: - Public API

    static func analyzeImages(
        inFolders roots: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        progress: ((Double) -> Void)? = nil,
        shouldCancel: (() -> Bool)? = nil,
        completion: @escaping ([ImageComparisonResult]) -> Void
    ) {
        let progressSink = progress.map { ProgressThrottler(sink: $0) }

        DispatchQueue.global(qos: .userInitiated).async {
            @inline(__always)
            func tick(_ done: Int, _ total: Int) {
                guard let progressSink, total > 0 else { return }
                progressSink.send(Double(done) / Double(total))
            }

            func analyzeHashes(_ hashes: [(url: URL, hash: UInt64)]) -> [ImageComparisonResult] {
                var groups: [[Int]] = []
                var used = Set<Int>()
                let maxDist = Int((1.0 - similarityThreshold) * 64.0)

                for i in 0..<hashes.count {
                    guard !used.contains(i) else { continue }
                    var group = [i]
                    for j in (i+1)..<hashes.count {
                        if hammingDistance(hashes[i].hash, hashes[j].hash) <= maxDist {
                            group.append(j)
                            used.insert(j)
                        }
                    }
                    used.insert(i)
                    if group.count > 1 { groups.append(group) }
                }

                var results: [ImageComparisonResult] = []
                results.reserveCapacity(groups.count)
                for group in groups {
                    let refIdx = group[0]
                    let refPath = hashes[refIdx].url.path
                    let refHash = hashes[refIdx].hash
                    var similars: [(path: String, percent: Double)] = []
                    similars.reserveCapacity(group.count)

                    for idx in group {
                        let path = hashes[idx].url.path
                        if idx == refIdx {
                            similars.append((path, 1.0))
                        } else {
                            let dist = hammingDistance(refHash, hashes[idx].hash)
                            let pct = 1.0 - Double(dist) / 64.0
                            similars.append((path, pct))
                        }
                    }
                    results.append(ImageComparisonResult(reference: refPath, similars: similars))
                }
                return results
            }

            var results: [ImageComparisonResult] = []

            // Process all subfolders AND root folders (if selected).
            let subdirs = Array(
                Set(roots.map(\.standardizedFileURL) + recursiveSubdirectoriesExcludingRoots(under: roots))
            ).sorted { $0.path < $1.path }
            
            if topLevelOnly {
                // A) Compare within each subfolder independently (no cross-folder matches)
                let totalImages = subdirs.reduce(0) { $0 + topLevelImageFiles(in: $1).count }
                var processed = 0

                for dir in subdirs {
                    if shouldCancel?() == true {
                        DispatchQueue.main.async {
                            completion([])
                        }
                        return
                    }

                    let files = topLevelImageFiles(in: dir)
                    guard !files.isEmpty else { continue }

                    var hashes: [(url: URL, hash: UInt64)] = []
                    hashes.reserveCapacity(files.count)

                    for url in files {
                        if shouldCancel?() == true {
                            DispatchQueue.main.async {
                                completion([])
                            }
                            return
                        }
                        autoreleasepool {
                            if let hash = subjectBlockHash(for: url) ?? blockHash(for: url) {
                                hashes.append((url, hash))
                            }
                            processed += 1
                            tick(processed, totalImages)
                        }
                    }

                    let folderResults = analyzeHashes(hashes)
                    if !folderResults.isEmpty { results.append(contentsOf: folderResults) }
                }
            } else {
                // B) Compare across ALL images from ALL subfolders combined (recursive)
                var imageFiles: [URL] = []
                for d in subdirs {
                    if shouldCancel?() == true {
                        DispatchQueue.main.async {
                            completion([])
                        }
                        return
                    }
                    imageFiles.append(contentsOf: allImageFiles(in: d))
                }

                let total = imageFiles.count
                if total == 0 {
                    DispatchQueue.main.async {
                        progressSink?.send(1.0)
                        completion([])
                    }
                    return
                }

                var hashes: [(url: URL, hash: UInt64)] = []
                hashes.reserveCapacity(total)
                var processed = 0

                for url in imageFiles {
                    if shouldCancel?() == true {
                        DispatchQueue.main.async {
                            completion([])
                        }
                        return
                    }
                    autoreleasepool {
                        if let hash = subjectBlockHash(for: url) ?? blockHash(for: url) {
                            hashes.append((url, hash))
                        }
                        processed += 1
                        tick(processed, total)
                    }
                }
                results = analyzeHashes(hashes)
            }

            DispatchQueue.main.async {
                progressSink?.send(1.0)
                completion(results)
            }
        }
    }
}
