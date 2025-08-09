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
            //return max(0.0, min(1.0, 1.0 - Double(distance)))
            return 1.0 / (1.0 + Double(distance))

        } catch {
            print("❌ Failed to compute distance: \(error)")
            return 0.0
        }
    }

    static func clusterFeatureObservations(_ embeddings: [ImageEmbedding], threshold: Double) -> [ImageComparisonResult] {

        @inline(__always)
        func sim(_ i: Int, _ j: Int) -> Double {
            similarityScore(embeddings[i].observation, embeddings[j].observation)
        }

        // Pick a stable, “best” reference inside a group.
        // 1) Prefer any exact-duplicate (≈1.0 similarity) pair.
        // 2) Otherwise pick the node with highest average similarity to others.
        func chooseReference(in indices: [Int]) -> Int {
            guard indices.count > 1 else { return indices.first! }

            // Prefer an exact pair if present.
            let exactEps = 0.9999
            for a in 0..<indices.count {
                for b in (a+1)..<indices.count {
                    if sim(indices[a], indices[b]) >= exactEps {
                        // deterministic choice for stability
                        let ia = indices[a], ib = indices[b]
                        let pa = embeddings[ia].url.path
                        let pb = embeddings[ib].url.path
                        return (pa <= pb) ? ia : ib
                    }
                }
            }

            // Fall back: highest average similarity to the group.
            var bestIdx = indices[0]
            var bestAvg = -Double.infinity
            for i in indices {
                var total = 0.0
                var count = 0.0
                for j in indices where j != i {
                    total += sim(i, j)
                    count += 1.0
                }
                let avg = total / max(1.0, count)
                if avg > bestAvg { bestAvg = avg; bestIdx = i }
            }
            return bestIdx
        }

        var used = Set<Int>()
        var results: [ImageComparisonResult] = []

        // Build groups greedily (as before)…
        for i in 0..<embeddings.count {
            guard !used.contains(i) else { continue }

            var members = [i]
            for j in (i + 1)..<embeddings.count where !used.contains(j) {
                if sim(i, j) >= threshold {
                    members.append(j)
                    used.insert(j)
                }
            }
            used.insert(i)

            guard members.count > 1 else { continue }

            // …then re-anchor the group to preserve exact matches.
            let refIdx = chooseReference(in: members)
            let refPath = embeddings[refIdx].url.path

            var pairs: [(path: String, percent: Double)] = []
            pairs.reserveCapacity(members.count)

            // Reference first at 1.0, then others sorted by similarity desc
            pairs.append((refPath, 1.0))
            var tail: [(path: String, percent: Double)] = []
            for idx in members where idx != refIdx {
                tail.append((embeddings[idx].url.path, sim(refIdx, idx)))
            }
            tail.sort { $0.percent > $1.percent }
            pairs.append(contentsOf: tail)

            results.append(ImageComparisonResult(reference: refPath, similars: pairs))
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

            var results: [ImageComparisonResult] = []

            // Process all subfolders AND root folders (if selected).
            let subdirs = Array(
                Set(roots.map(\.standardizedFileURL) + recursiveSubdirectoriesExcludingRoots(under: roots))
            ).sorted { $0.path < $1.path }
            
            if topLevelOnly {
                // A) Compare within each subfolder only
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

                    var embeddings: [ImageEmbedding] = []
                    embeddings.reserveCapacity(files.count)

                    for url in files {
                        if shouldCancel?() == true {
                            DispatchQueue.main.async {
                                completion([])
                            }
                            return
                        }
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

                var embeddings: [ImageEmbedding] = []
                embeddings.reserveCapacity(total)
                var processed = 0

                for url in imageFiles {
                    if shouldCancel?() == true {
                        DispatchQueue.main.async {
                            completion([])
                        }
                        return
                    }
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

            if shouldCancel?() == true {
                DispatchQueue.main.async {
                    completion([])
                }
                return
            }

            DispatchQueue.main.async {
                progressSink?.send(1.0)
                completion(results)
            }
        }
    }
}

