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

    static func featurePrintObservation(for imageURL: URL) -> VNFeaturePrintObservation? {
        guard let ciImage = CIImage(contentsOf: imageURL) else { return nil }

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

    static func analyzeWithDeepFeatures(
        inFolders folders: [URL],
        similarityThreshold: Double, // normalized: 0.0 (loose) to 1.0 (strict)
        topLevelOnly: Bool,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping ([ImageComparisonResult]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let imageFiles = folders.flatMap {
                topLevelOnly ? topLevelImageFiles(in: $0) : allImageFiles(in: $0)
            }

            var embeddings: [ImageEmbedding] = []
            for (index, url) in imageFiles.enumerated() {
                if let obs = featurePrintObservation(for: url) {
                    embeddings.append(ImageEmbedding(url: url, observation: obs))
                }
                progress?(Double(index + 1) / Double(imageFiles.count))
            }

            let results = clusterFeatureObservations(embeddings, threshold: similarityThreshold)

            DispatchQueue.main.async {
                progress?(1.0)
                completion(results)
            }
        }
    }
}
