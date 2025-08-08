//
//  ImageEmbedding.swift
//  ImageGuru
//
//  Created by George Babichev on 8/7/25.
//

import AppKit
import AVFoundation
import Foundation
import Accelerate
import Vision
import CoreImage

struct ImageEmbedding {
    let url: URL
    let observation: VNFeaturePrintObservation
}

extension ImageAnalyzer {

    // MARK: - Vision helpers

    static func featurePrintObservation(for imageURL: URL) -> VNFeaturePrintObservation? {
        // Respect orientation; keep memory footprint small
        guard let ciImage = CIImage(contentsOf: imageURL, options: [.applyOrientationProperty: true]) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            print("❌ Feature print extraction failed: \(error)")
            return nil
        }
    }

    static func similarityScore(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Double {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
            // Normalize to [0,1] where 1 means identical
            return max(0.0, min(1.0, 1.0 - Double(distance)))
        } catch {
            print("❌ Failed to compute distance: \(error)")
            return 0.0
        }
    }

    static func clusterFeatureObservations(_ embeddings: [ImageEmbedding], threshold: Double) -> [ImageComparisonResult] {
        var used = Set<Int>()
        var results: [ImageComparisonResult] = []

        for i in 0..<embeddings.count {
            guard !used.contains(i) else { continue }
            let reference = embeddings[i]
            var group: [(path: String, percent: Double)] = [(reference.url.path, 1.0)]

            for j in (i + 1)..<embeddings.count where !used.contains(j) {
                let similarity = similarityScore(reference.observation, embeddings[j].observation)
                if similarity >= threshold {
                    group.append((embeddings[j].url.path, similarity))
                    used.insert(j)
                }
            }

            if group.count > 1 {
                results.append(ImageComparisonResult(reference: reference.url.path, similars: group))
                used.insert(i)
            }
        }
        return results
    }

    // MARK: - Throttled progress (local to this file)

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

    // MARK: - Public Deep Features with proper toggle semantics

    static func analyzeWithDeepFeatures(
        inFolders roots: [URL],
        similarityThreshold: Double, // 0...1
        topLevelOnly: Bool,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping ([ImageComparisonResult]) -> Void
    ) {
        let progressSink = progress.map { ProgressThrottler(sink: $0) }

        DispatchQueue.global(qos: .userInitiated).async {
            @inline(__always)
            func tick(_ done: Int, _ total: Int) {
                guard let progressSink, total > 0 else { return }
                progressSink.send(Double(done) / Double(total))
            }

            var results: [ImageComparisonResult] = []

            // === IMPORTANT: Always discard roots; only process subfolders ===
            let subdirs = recursiveSubdirectoriesExcludingRoots(under: roots)

            if topLevelOnly {
                // A) Compare within each subfolder only
                let totalImages = subdirs.reduce(0) { $0 + topLevelImageFiles(in: $1).count }
                var processed = 0

                for dir in subdirs {
                    let files = topLevelImageFiles(in: dir)
                    guard !files.isEmpty else { continue }

                    var embeddings: [ImageEmbedding] = []
                    embeddings.reserveCapacity(files.count)

                    for url in files {
                        autoreleasepool {
                            if let obs = featurePrintObservation(for: url) {
                                embeddings.append(ImageEmbedding(url: url, observation: obs))
                            }
                            processed += 1
                            tick(processed, totalImages)
                        }
                    }

                    let folderResults = clusterFeatureObservations(embeddings, threshold: similarityThreshold)
                    if !folderResults.isEmpty { results.append(contentsOf: folderResults) }
                }
            } else {
                // B) Compare across ALL subfolders combined (recursive)
                var imageFiles: [URL] = []
                for d in subdirs { imageFiles.append(contentsOf: allImageFiles(in: d)) }

                let total = imageFiles.count
                if total == 0 {
                    DispatchQueue.main.async {
                        progressSink?.send(1.0)
                        completion([])
                    }
                    return
                }

                var embeddings: [ImageEmbedding] = []
                embeddings.reserveCapacity(total)
                var processed = 0

                for url in imageFiles {
                    autoreleasepool {
                        if let obs = featurePrintObservation(for: url) {
                            embeddings.append(ImageEmbedding(url: url, observation: obs))
                        }
                        processed += 1
                        tick(processed, total)
                    }
                }

                results = clusterFeatureObservations(embeddings, threshold: similarityThreshold)
            }

            DispatchQueue.main.async {
                progressSink?.send(1.0)
                completion(results)
            }
        }
    }
}

