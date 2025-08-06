import AppKit
import AVFoundation
import Foundation

// This file is needed by ContentView.swift and should be included in the main target.

struct ImageComparisonResult: Identifiable {
    let id = UUID()
    let type: ResultType
    enum ResultType {
        case duplicate(reference: String, duplicates: [(path: String, percent: Double)])
        case similar(reference: String, similars: [(path: String, percent: Double)])
    }
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

    static func averageHash(for imageURL: URL) -> UInt64? {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = CGSize(width: 8, height: 8)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 8 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let pixelData = context.data else { return nil }
        let ptr = pixelData.bindMemory(to: UInt8.self, capacity: 8*8*4)
        var total: UInt64 = 0
        var pixels: [UInt8] = []
        for i in 0..<64 {
            let offset = i * 4
            let r = ptr[offset]
            let g = ptr[offset+1]
            let b = ptr[offset+2]
            // Use luminance
            let lum = UInt8(0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b))
            pixels.append(lum)
            total += UInt64(lum)
        }
        let avg = total / 64
        var hash: UInt64 = 0
        for (i, p) in pixels.enumerated() {
            if p >= avg { hash |= (1 << UInt64(63-i)) }
        }
        return hash
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
        completion: @escaping ([ImageComparisonResult]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var imageFiles: [URL] = []
            for folderURL in folders {
                imageFiles.append(contentsOf: allImageFiles(in: folderURL))
            }
            var hashes: [(url: URL, hash: UInt64)] = []
            for url in imageFiles {
                if let hash = averageHash(for: url) {
                    hashes.append((url, hash))
                }
            }
            // Pairwise comparison
            var duplicates: [[Int]] = [] // Groups of indices into hashes
            var similars: [[Int]] = []
            var used = Set<Int>()
            let maxDist = Int((1.0 - similarityThreshold) * 64.0) // e.g., threshold 0.8 -> maxDist = 12
            for i in 0..<hashes.count {
                guard !used.contains(i) else { continue }
                var dupGroup: [Int] = [i]
                var simGroup: [Int] = []
                for j in (i+1)..<hashes.count {
                    let dist = hammingDistance(hashes[i].hash, hashes[j].hash)
                    if dist == 0 {
                        dupGroup.append(j)
                        used.insert(j)
                    } else if dist <= maxDist {
                        simGroup.append(j)
                    }
                }
                if dupGroup.count > 1 {
                    duplicates.append(dupGroup)
                } else if !simGroup.isEmpty {
                    similars.append([i] + simGroup)
                }
                used.insert(i)
            }
            var results: [ImageComparisonResult] = []
            // Duplicates
            for group in duplicates {
                let referenceIdx = group[0]
                let referencePath = hashes[referenceIdx].url.path
                let referenceHash = hashes[referenceIdx].hash
                var dups: [(path: String, percent: Double)] = []
                for dupIdx in group.dropFirst() {
                    let dupPath = hashes[dupIdx].url.path
                    let dupHash = hashes[dupIdx].hash
                    let dist = hammingDistance(referenceHash, dupHash)
                    // 100% match if identical, less if very close
                    let percent = 1.0 - Double(dist) / 64.0
                    dups.append((path: dupPath, percent: percent))
                }
                results.append(ImageComparisonResult(type: .duplicate(reference: referencePath, duplicates: dups)))
            }
            // Similars
            for group in similars {
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
                results.append(ImageComparisonResult(type: .similar(reference: referencePath, similars: similarsArray)))
            }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }
}

