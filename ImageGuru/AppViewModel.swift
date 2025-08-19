import SwiftUI
import AppKit
import Combine
import ImageIO

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Core State (only what we actually need to store)
    @Published var selectedFolderURLs: [URL] = []
    @Published var similarityThreshold: Double = 0.7
    @Published var selectedAnalysisMode: AnalysisMode = .deepFeature
    @Published var scanTopLevelOnly: Bool = false
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double? = nil
    @Published var comparisonResults: [ImageComparisonResult] = []
    
    // Simple cancellation
    private var analysisTask: Task<Void, Never>?
    
    // MARK: - Computed Properties (replaces all the caching)
    
    var foldersToScanLabel: String {
        let leafs = findLeafFolders(from: selectedFolderURLs)
        return leafs.map { $0.lastPathComponent }.joined(separator: "\n")
    }
    
    var flattenedResults: [TableRow] {
        comparisonResults.flatMap { result in
            result.similars
                .filter { $0.path != result.reference }
                .map { TableRow(reference: result.reference, similar: $0.path, percent: $0.percent) }
        }
    }
    
    var folderDuplicateCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                counts[folder, default: 0] += 1
            }
        }
        return counts
    }
    
    var representativeImageByFolder: [String: String] {
        var representatives: [String: String] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                if representatives[folder] == nil {
                    representatives[folder] = path
                }
            }
        }
        return representatives
    }
    
    var folderClusters: [[String]] {
        // Build folder adjacency from duplicates
        var adjacency: [String: Set<String>] = [:]
        for result in comparisonResults {
            let folders = Set(([result.reference] + result.similars.map { $0.path }).map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().path
            })
            for folder in folders {
                var connections = adjacency[folder] ?? []
                for otherFolder in folders where otherFolder != folder {
                    connections.insert(otherFolder)
                }
                adjacency[folder] = connections
            }
        }
        
        // Find connected components
        var visited = Set<String>()
        var clusters: [[String]] = []
        
        for folder in adjacency.keys {
            if visited.contains(folder) { continue }
            
            var cluster: [String] = []
            var stack = [folder]
            visited.insert(folder)
            
            while let current = stack.popLast() {
                cluster.append(current)
                for neighbor in adjacency[current] ?? [] {
                    if !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        stack.append(neighbor)
                    }
                }
            }
            
            if cluster.count > 1 {
                clusters.append(cluster.sorted())
            }
        }
        
        return clusters
    }
    
    var allFoldersBeingProcessed: [URL] {
        let roots = selectedFolderURLs.map { $0.standardizedFileURL }
        let all = Set(roots + ImageAnalyzer.recursiveSubdirectoriesExcludingRoots(under: roots))
        return Array(all).sorted { $0.path < $1.path }
    }
    
    // MARK: - Actions
    
    func processImages(progress: @escaping @Sendable (Double) -> Void) {
        guard !isProcessing else { return }
        
        analysisTask?.cancel()
        isProcessing = true
        processingProgress = nil

        let roots = selectedFolderURLs
        let threshold = similarityThreshold
        let topOnly = scanTopLevelOnly

        let progressWrapper: @Sendable (Double) -> Void = { [weak self] p in
            Task { @MainActor in
                self?.processingProgress = p
            }
            DispatchQueue.main.async { progress(p) }
        }

        analysisTask = Task {
            let results: [ImageComparisonResult]
            
            switch selectedAnalysisMode {
            case .deepFeature:
                results = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        ImageAnalyzer.analyzeWithDeepFeatures(
                            inFolders: roots,
                            similarityThreshold: threshold,
                            topLevelOnly: topOnly,
                            progress: progressWrapper,
                            shouldCancel: { Task.isCancelled },
                            completion: { results in continuation.resume(returning: results) }
                        )
                    }
                } onCancel: {}
                
            case .perceptualHash:
                results = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        ImageAnalyzer.analyzeWithPerceptualHash(
                            inFolders: roots,
                            similarityThreshold: threshold,
                            topLevelOnly: topOnly,
                            progress: progressWrapper,
                            shouldCancel: { Task.isCancelled },
                            completion: { results in continuation.resume(returning: results) }
                        )
                    }
                } onCancel: {}
            }
            
            await MainActor.run {
                if !Task.isCancelled {
                    self.comparisonResults = results
                }
                self.processingProgress = nil
                self.isProcessing = false
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        isProcessing = false
        processingProgress = nil
    }

    func openFolderInFinder(_ folder: String) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    func deleteSelectedMatches(selectedMatches: [String]) {
        guard !selectedMatches.isEmpty else { return }
        selectedMatches.forEach(deleteFile)
    }
    
    func deleteFile(_ path: String) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        
        // Remove from results
        for (index, result) in comparisonResults.enumerated().reversed() {
            let filteredSimilars = result.similars.filter { $0.path != path }
            let nonReferenceSimilars = filteredSimilars.filter { $0.path != result.reference }
            
            if result.reference == path || nonReferenceSimilars.isEmpty {
                comparisonResults.remove(at: index)
            } else if filteredSimilars.count != result.similars.count {
                comparisonResults[index] = ImageComparisonResult(
                    reference: result.reference,
                    similars: filteredSimilars
                )
            }
        }
    }
    
    // MARK: - Helper
    private func findLeafFolders(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var leafFolders = [URL]()
        var seen = Set<URL>()

        func recurse(_ url: URL) {
            if let contents = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                let subfolders = contents.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                if subfolders.isEmpty {
                    if seen.insert(url).inserted {
                        leafFolders.append(url)
                    }
                } else {
                    subfolders.forEach(recurse)
                }
            }
        }

        urls.forEach(recurse)
        return leafFolders
    }
    
    func clearAll() {
        // Cancel any running analysis
        cancelAnalysis()
        
        // Clear selected folders
        selectedFolderURLs.removeAll()
        
        // Clear all analysis results
        comparisonResults.removeAll()
    }
    
}

// Background-safe thumbnailing
nonisolated
func downsampledCGImage(at url: URL, targetMaxDimension: CGFloat) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCache: false,
        kCGImageSourceThumbnailMaxPixelSize: Int(targetMaxDimension)
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
}
