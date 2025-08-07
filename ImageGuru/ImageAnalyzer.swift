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

struct ImageAnalyzer {
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "bmp", "tiff", "gif"]

    static func allImageFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    urls.append(fileURL)
                }
            }
        }
        return urls
    }

    static func topLevelImageFiles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
    }

    static func downsampledCGImage(from url: URL, to size: CGSize) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(size.width), Int(size.height)),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return nil
        }
        return cgImage
    }

    static func subjectBlockHash(for imageURL: URL) -> UInt64? {
        guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              //let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
              let cgImage = downsampledCGImage(from: imageURL, to: CGSize(width: 256, height: 256)) else {
            return nil
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNDetectHumanBodyPoseRequest()

        do {
            try handler.perform([request])
            let observations = request.results ?? []
            guard let observation = observations.first else {
                return blockHash(for: imageURL)
            }

            let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
            guard let recognizedPoints = try? observation.recognizedPoints(.all) else {
                return blockHash(for: imageURL)
            }

            let validPoints = recognizedPoints.values.filter { $0.confidence > 0.3 }
            guard !validPoints.isEmpty else {
                return blockHash(for: imageURL)
            }

            let xs = validPoints.map { $0.x }
            let ys = validPoints.map { $0.y }

            let minX = xs.min() ?? 0
            let maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0
            let maxY = ys.max() ?? 0

            let boundingBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let rect = CGRect(
                x: boundingBox.origin.x * imageSize.width,
                y: (1.0 - boundingBox.origin.y - boundingBox.height) * imageSize.height,
                width: boundingBox.width * imageSize.width,
                height: boundingBox.height * imageSize.height
            ).integral

            guard let cropped = cgImage.cropping(to: rect) else {
                return blockHash(for: cgImage)
            }

            return blockHash(for: cropped)

        } catch {
            print("Vision request failed: \(error)")
            return blockHash(for: imageURL)
        }
    }

    static func blockHash(for cgImage: CGImage) -> UInt64? {
        let gridSize = 8
        let width = gridSize
        let height = gridSize

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(origin: .zero, size: CGSize(width: width, height: height)))

        guard let pixelBuffer = context.data else { return nil }
        let bufferPointer = pixelBuffer.bindMemory(to: UInt8.self, capacity: width * height)
        let pixels = (0..<(width * height)).map { bufferPointer[$0] }

        let total = pixels.reduce(0) { $0 + Int($1) }
        let avg = total / pixels.count

        var hash: UInt64 = 0
        for (i, pixel) in pixels.enumerated() {
            if Int(pixel) >= avg {
                hash |= (1 << (63 - i))
            }
        }

        return hash
    }

    static func blockHash(for imageURL: URL) -> UInt64? {
        guard let cgImage = downsampledCGImage(from: imageURL, to: CGSize(width: 8, height: 8)) else {
            return nil
        }
        return blockHash(for: cgImage)
    }

    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    static func loadThumbnail(for path: String, size: CGFloat = 48) -> NSImage {
        guard let image = NSImage(contentsOfFile: path) else {
            let placeholder = NSImage(size: NSSize(width: size, height: size))
            placeholder.lockFocus()
            NSColor.gray.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
            placeholder.unlockFocus()
            return placeholder
        }
        let thumbnail = NSImage(size: NSSize(width: size, height: size))
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .low
        let targetRect = AVMakeRect(aspectRatio: image.size, insideRect: NSRect(x: 0, y: 0, width: size, height: size))
        image.draw(in: targetRect, from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        thumbnail.unlockFocus()
        return thumbnail
    }

    static func analyzeImages(
        inFolders folders: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping ([ImageComparisonResult]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {

            func analyzeHashes(_ hashes: [(url: URL, hash: UInt64)]) -> [ImageComparisonResult] {
                var groups: [[Int]] = []
                var used = Set<Int>()
                let maxDist = Int((1.0 - similarityThreshold) * 64.0)

                for i in 0..<hashes.count {
                    guard !used.contains(i) else { continue }
                    var group: [Int] = [i]
                    for j in (i+1)..<hashes.count {
                        let dist = hammingDistance(hashes[i].hash, hashes[j].hash)
                        if dist <= maxDist {
                            group.append(j)
                            used.insert(j)
                        }
                    }
                    used.insert(i)
                    if group.count > 1 {
                        groups.append(group)
                    }
                }

                var results: [ImageComparisonResult] = []
                for group in groups {
                    let referenceIdx = group[0]
                    let referencePath = hashes[referenceIdx].url.path
                    let referenceHash = hashes[referenceIdx].hash
                    var similarsArray: [(path: String, percent: Double)] = []
                    for idx in group {
                        let path = hashes[idx].url.path
                        let percent: Double
                        if idx == referenceIdx {
                            percent = 1.0
                        } else {
                            let dist = hammingDistance(referenceHash, hashes[idx].hash)
                            percent = 1.0 - Double(dist) / 64.0
                        }
                        similarsArray.append((path: path, percent: percent))
                    }
                    results.append(ImageComparisonResult(reference: referencePath, similars: similarsArray))
                }
                return results
            }

            var results: [ImageComparisonResult] = []

            if topLevelOnly {
                let allImageFiles = folders.flatMap { topLevelImageFiles(in: $0) }
                let totalImages = allImageFiles.count
                var imagesProcessed = 0

                for folderURL in folders {
                    let imageFiles = topLevelImageFiles(in: folderURL)
                    var hashes: [(url: URL, hash: UInt64)] = []
                    for url in imageFiles {
                        if let hash = subjectBlockHash(for: url) {
                            hashes.append((url: url, hash: hash))
                        }
                        imagesProcessed += 1
                        progress?(Double(imagesProcessed) / Double(totalImages))
                    }
                    let folderResults = analyzeHashes(hashes)
                    results.append(contentsOf: folderResults)
                }
            } else {
                var imageFiles: [URL] = []
                for folderURL in folders {
                    imageFiles.append(contentsOf: allImageFiles(in: folderURL))
                }
                var hashes: [(url: URL, hash: UInt64)] = []
                let total = imageFiles.count
                var processed = 0
                for url in imageFiles {
                    if let hash = subjectBlockHash(for: url) {
                        hashes.append((url: url, hash: hash))
                    }
                    processed += 1
                    progress?(Double(processed) / Double(total))
                }
                results = analyzeHashes(hashes)
            }

            DispatchQueue.main.async {
                progress?(1.0)
                completion(results)
            }
        }
    }
}

