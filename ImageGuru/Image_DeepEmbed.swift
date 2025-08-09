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

        // Choose a stable reference. Prefer any member that participates in a near‑exact pair.
        func chooseReference(in idxs: [Int]) -> Int {
            let exactEps = 0.9995
            var candidate: Int? = nil
            for a in 0..<idxs.count {
                for b in (a+1)..<idxs.count {
                    if sim(idxs[a], idxs[b]) >= exactEps {
                        // deterministic pick for stability
                        let ia = idxs[a], ib = idxs[b]
                        let pa = embeddings[ia].url.path
                        let pb = embeddings[ib].url.path
                        candidate = (pa <= pb) ? ia : ib
                        break
                    }
                }
                if candidate != nil { break }
            }
            return candidate ?? idxs.min { embeddings[$0].url.path < embeddings[$1].url.path }!
        }

        // Compute best-in-group similarity for each member (max vs any other).
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

        let exactEps = 0.9995
        var used = Set<Int>()
        var results: [ImageComparisonResult] = []

        for i in 0..<embeddings.count {
            guard !used.contains(i) else { continue }

            // Greedy build (same as before)
            var members = [i]
            for j in (i + 1)..<embeddings.count where !used.contains(j) {
                if sim(i, j) >= threshold {
                    members.append(j)
                    used.insert(j)
                }
            }
            used.insert(i)
            guard members.count > 1 else { continue }

            // Re-anchor to a good reference and compute best-in-group sims
            let refIdx = chooseReference(in: members)
            let refPath = embeddings[refIdx].url.path
            let best = bestSims(in: members)

            // Build output: reference first (1.0), then others sorted by displayed percent
            var rows: [(path: String, percent: Double)] = []
            rows.append((refPath, 1.0))
            var tail: [(path: String, percent: Double)] = []

            for idx in members where idx != refIdx {
                // Display the best similarity this item has with anyone in the group.
                var p = best[idx] ?? 0.0
                if p >= exactEps { p = 1.0 } // snap near-1.0 to 1.0
                tail.append((embeddings[idx].url.path, p))
            }
            tail.sort { $0.percent > $1.percent }
            rows.append(contentsOf: tail)

            results.append(ImageComparisonResult(reference: refPath, similars: rows))
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
            let subdirs = foldersToScan(from: roots)

            
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

