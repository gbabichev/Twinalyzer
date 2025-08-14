import SwiftUI
import AppKit
import Combine
import ImageIO

@MainActor
final class AppViewModel: ObservableObject {
    // App State
    @Published var selectedFolderURLs: [URL] = []
    @Published var foldersToScanLabel: String = ""
    @Published var similarityThreshold: Double = 0.7
    @Published var selectedAnalysisMode: AnalysisMode = .deepFeature
    @Published var scanTopLevelOnly: Bool = false
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double? = nil
    @Published var analysisCancelled: Bool = false

    // Results + caches
    @Published var comparisonResults: [ImageComparisonResult] = []
    @Published var cachedFlattened: [TableRow] = []
    @Published var cachedFolderDuplicateCount: [String: Int] = [:]
    @Published var cachedRepresentativeByFolder: [String: String] = [:]
    @Published var cachedClusters: [[String]] = []
    @Published var folderThumbs: [String: NSImage] = [:]
    private var cancelBoxRef: CancelBox?
    /// All folders that will be processed (selected roots + all subdirectories, unique, sorted)
    var allFoldersBeingProcessed: [URL] {
        let roots = selectedFolderURLs.map { $0.standardizedFileURL }
        let all = Set(roots + ImageAnalyzer.recursiveSubdirectoriesExcludingRoots(under: roots))
        return Array(all).sorted { $0.path < $1.path }
    }

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
        // Clear on main
        folderThumbs.removeAll()

        // Snapshot on main; never touch `self` off-main
        let reps = cachedRepresentativeByFolder
        let folders = Array(reps.keys)

        DispatchQueue.global(qos: .userInitiated).async {
            for folder in folders {
                guard let path = reps[folder] else { continue }
                let url = URL(fileURLWithPath: path)

                // Decode CGImage off-main
                guard let cg = downsampledCGImage(at: url, targetMaxDimension: 64) else { continue }

                // Hop to main to create NSImage and publish a single entry.
                DispatchQueue.main.async {
                    let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    // Update just the one key; no shared mutable dict between threads.
                    self.folderThumbs[folder] = ns
                }
            }
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
        analysisCancelled = false
        isProcessing = true
        processingProgress = nil

        let roots = selectedFolderURLs
        let threshold = similarityThreshold
        let topOnly = scanTopLevelOnly

        // Wrap non-Sendable progress so analyzer can take a @Sendable closure.
        let progressBox = ProgressBox(progress)
        let progressSink: @Sendable (Double) -> Void = { [weak self, progressBox] p in
            // self.touch must be on main
            DispatchQueue.main.async {
                self?.processingProgress = p
            }
            // external callback (also on main)
            progressBox.call(p)
        }

        // Use a Sendable cancel flag instead of reading main-actor state off-main.
        // Use a MainActor box and read it synchronously from any thread.
        let cancelBox = CancelBox()
        cancelBox.set(false)
        self.cancelBoxRef = cancelBox

        let shouldCancel: @Sendable () -> Bool = { [weak cancelBox] in
            var v = false
            // sync hop to main to read the @MainActor value
            DispatchQueue.main.sync {
                v = cancelBox?.value ?? false
            }
            return v
        }


        //self.cancelBoxRef = cancelBox


        let finish: @Sendable ([ImageComparisonResult]) -> Void = { [weak self] results in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if cancelBox.value {
                    self.processingProgress = nil
                    self.isProcessing = false
                    return
                }
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
                shouldCancel: shouldCancel,
                completion: finish
            )
        case .perceptualHash:
            ImageAnalyzer.analyzeWithPerceptualHash(
                inFolders: roots,
                similarityThreshold: threshold,
                topLevelOnly: topOnly,
                progress: progressSink,
                shouldCancel: shouldCancel,
                completion: finish
            )
        }

        // Keep the box in sync if you also toggle via UI
        // (your existing cancelAnalysis() below flips it)
        // Store it in a property if you need to reference it later.
    }

    // MARK: - Cancel analysis
    func cancelAnalysis() {
        analysisCancelled = true
        cancelBoxRef?.set(true)
        isProcessing = false
        processingProgress = nil
    }

    // MARK: - Delete helpers
    func deleteSelectedMatches(selectedMatches: [String]) {
        guard !selectedMatches.isEmpty else { return }
        for path in selectedMatches {
            deleteFile(path)
        }
    }
    
    // MARK: - Moves files to trash
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

//// ---- Compatibility shim (remove once callers are updated) ----
// ---- Compatibility shim: keep call-sites compiling; swap to real pHash when ready.
extension ImageAnalyzer {
    static func analyzeWithPerceptualHash(
        inFolders: [URL],
        similarityThreshold: Double,
        topLevelOnly: Bool,
        progress: @Sendable @escaping (Double) -> Void,
        shouldCancel: @Sendable @escaping () -> Bool,
        completion: @Sendable @escaping ([ImageComparisonResult]) -> Void
    ) {
        // TEMP: forward to deep-features so signatures match.
        analyzeWithDeepFeatures(
            inFolders: inFolders,
            similarityThreshold: similarityThreshold,
            topLevelOnly: topLevelOnly,
            progress: progress,
            shouldCancel: shouldCancel,
            completion: completion
        )
    }
}


// Background-safe thumbnailing using CGImageSource; NOT @MainActor.
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


// Sendable wrappers used to cross thread boundaries safely.
final class ProgressBox: @unchecked Sendable {
    private let f: (Double) -> Void
    init(_ f: @escaping (Double) -> Void) { self.f = f }

    nonisolated
    func call(_ p: Double) {
        // Ensure the UI callback runs on the main thread.
        DispatchQueue.main.async { self.f(p) }
    }
}

public final class CancelBox {
    private var _value: Bool = false
    public init() {}

    public var value: Bool { _value }
    public func set(_ newValue: Bool) { _value = newValue }
}
