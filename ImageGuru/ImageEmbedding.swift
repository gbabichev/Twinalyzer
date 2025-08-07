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

    /// Extracts the Vision feature print observation for an image
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

    /// Computes the distance between two Vision feature prints
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
            return distance
        } catch {
            print("❌ Failed to compute distance: \(error)")
            return Float.greatestFiniteMagnitude
        }
    }

    /**
     Clusters the given image embeddings based on their Vision feature print observations.

     - Parameters:
       - embeddings: Array of ImageEmbedding instances.
       - threshold: Distance threshold below which images are considered similar.

     - Returns: An array of ImageComparisonResult, each containing a reference image path and an array of similar image paths with similarity scores.
    */
    static func clusterFeatureObservations(_ embeddings: [ImageEmbedding], threshold: Float) -> [ImageComparisonResult] {
        var clusters: [[ImageEmbedding]] = []

        for embedding in embeddings {
            var found = false
            for i in 0..<clusters.count {
                if let rep = clusters[i].first, distance(rep.observation, embedding.observation) < threshold {
                    clusters[i].append(embedding)
                    found = true
                    break
                }
            }
            if !found {
                clusters.append([embedding])
            }
        }

        var results: [ImageComparisonResult] = []
        for group in clusters where group.count > 1 {
            let reference = group[0]
            let similars = group.map {
                let dist = distance(reference.observation, $0.observation)
                let score = 1.0 - Double(dist)
                return (path: $0.url.path, percent: score)
            }
            results.append(ImageComparisonResult(reference: reference.url.path, similars: similars))
        }
        return results
    }

    /// Alternate analysis path using Vision deep features instead of perceptual hashes
    static func analyzeWithDeepFeatures(
        inFolders folders: [URL],
        threshold: Float = 0.10,
        topLevelOnly: Bool,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping ([ImageComparisonResult]) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let imageFiles: [URL] = folders.flatMap {
                topLevelOnly ? topLevelImageFiles(in: $0) : allImageFiles(in: $0)
            }
            let total = imageFiles.count
            var embeddings: [ImageEmbedding] = []
            for (index, url) in imageFiles.enumerated() {
                if let obs = featurePrintObservation(for: url) {
                    embeddings.append(ImageEmbedding(url: url, observation: obs))
                }
                progress?(Double(index + 1) / Double(total))
            }
            let results = clusterFeatureObservations(embeddings, threshold: threshold)
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }
}
