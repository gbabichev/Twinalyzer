import SwiftUI
import AppKit
import Combine

final class AppViewModel: ObservableObject {
    // App State
    @Published var selectedFolderURLs: [URL] = []
    @Published var foldersToScanLabel: String = ""
    @Published var similarityThreshold: Double = 0.7
    @Published var selectedAnalysisMode: AnalysisMode = .deepFeature
    @Published var scanTopLevelOnly: Bool = false
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double? = nil

    // Results + caches
    @Published var comparisonResults: [ImageComparisonResult] = []
    @Published var cachedFlattened: [TableRow] = []
    @Published var cachedFolderDuplicateCount: [String: Int] = [:]
    @Published var cachedRepresentativeByFolder: [String: String] = [:]
    @Published var cachedClusters: [[String]] = []
    @Published var folderThumbs: [String: NSImage] = [:]

    // MARK: - Derived recompute
    func recomputeDerived() {
        // Flatten rows (exclude reference=similar)
        let flat: [TableRow] = comparisonResults.flatMap { result in
            result.similars
                .filter { $0.path != result.reference }
                .map { TableRow(reference: result.reference, similar: $0.path, percent: $0.percent) }
        }
        cachedFlattened = flat

        // Folder counts + representative per folder
        var folderCount: [String: Int] = [:]
        var representative: [String: String] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                folderCount[folder, default: 0] += 1
                representative[folder] = representative[folder] ?? path
            }
        }
        cachedFolderDuplicateCount = folderCount
        cachedRepresentativeByFolder = representative

        // Clusters (folders connected via duplicates)
        var adj: [String: Set<String>] = [:]
        for result in comparisonResults {
            let folders = Set(([result.reference] + result.similars.map { $0.path }).map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().path
            })
            for f in folders {
                var row = adj[f] ?? []
                for g in folders where g != f { row.insert(g) }
                adj[f] = row
            }
        }

        // Connected components
        var seen = Set<String>()
        var clusters: [[String]] = []
        for node in adj.keys {
            if seen.contains(node) { continue }
            var stack = [node]
            var comp: [String] = []
            seen.insert(node)
            while let cur = stack.popLast() {
                comp.append(cur)
                for nxt in adj[cur] ?? [] {
                    if !seen.contains(nxt) {
                        seen.insert(nxt)
                        stack.append(nxt)
                    }
                }
            }
            if comp.count > 1 { clusters.append(comp.sorted()) }
        }
        cachedClusters = clusters
    }


    // MARK: - Thumbnails preload
    func preloadAllFolderThumbnails() {
        folderThumbs.removeAll()
        let folders = Array(cachedRepresentativeByFolder.keys)
        DispatchQueue.global(qos: .userInitiated).async {
            var newThumbs: [String: NSImage] = [:]
            newThumbs.reserveCapacity(folders.count)
            for folder in folders {
                if let path = self.cachedRepresentativeByFolder[folder],
                   let img = downsampledNSImage(at: URL(fileURLWithPath: path), targetMaxDimension: 64) {
                    newThumbs[folder] = img
                }
            }
            DispatchQueue.main.async { self.folderThumbs = newThumbs }
        }
    }

    // MARK: - Open folder
    func openFolderInFinder(_ folder: String) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Analysis entrypoint
    func processImages(progress: @escaping (Double) -> Void) {
        guard !isProcessing else { return }
        isProcessing = true
        processingProgress = nil

        let roots = selectedFolderURLs
        let threshold = similarityThreshold
        let topOnly = scanTopLevelOnly

        let progressSink: (Double) -> Void = { p in
            DispatchQueue.main.async {
                self.processingProgress = p
                progress(p)
            }
        }

        let finish: ([ImageComparisonResult]) -> Void = { results in
            DispatchQueue.main.async {
                self.comparisonResults = results
                self.processingProgress = nil
                self.isProcessing = false
                self.recomputeDerived()
                self.preloadAllFolderThumbnails()
            }
        }

        switch selectedAnalysisMode {
        case .deepFeature:
            ImageAnalyzer.analyzeWithDeepFeatures(
                inFolders: roots,
                similarityThreshold: threshold,
                topLevelOnly: topOnly,
                progress: progressSink,
                completion: finish
            )
        case .perceptualHash:
            ImageAnalyzer.analyzeImages(
                inFolders: roots,
                similarityThreshold: threshold,
                topLevelOnly: topOnly,
                progress: progressSink,
                completion: finish
            )
        }
    }


    // MARK: - Delete helpers
    func deleteSelectedMatches(selectedMatches: [String]) {
        // Remove selected similar paths from results; drop result if empty or if reference removed
        for (index, result) in comparisonResults.enumerated().reversed() {
            let filteredSimilars = result.similars.filter { !selectedMatches.contains($0.path) }
            let nonReferenceSimilars = filteredSimilars.filter { $0.path != result.reference }
            if selectedMatches.contains(result.reference) || nonReferenceSimilars.isEmpty {
                comparisonResults.remove(at: index)
            } else if filteredSimilars.count != result.similars.count {
                comparisonResults[index] = ImageComparisonResult(reference: result.reference, similars: filteredSimilars)
            }
        }
        // Recompute caches after modification
        recomputeDerived()
        preloadAllFolderThumbnails()
    }

    func deleteFile(_ path: String) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        for (index, result) in comparisonResults.enumerated().reversed() {
            let filteredSimilars = result.similars.filter { $0.path != path }
            let nonReferenceSimilars = filteredSimilars.filter { $0.path != result.reference }
            if result.reference == path || nonReferenceSimilars.isEmpty {
                comparisonResults.remove(at: index)
            } else if filteredSimilars.count != result.similars.count {
                comparisonResults[index] = ImageComparisonResult(reference: result.reference, similars: filteredSimilars)
            }
        }
        recomputeDerived()
        preloadAllFolderThumbnails()
    }

}
