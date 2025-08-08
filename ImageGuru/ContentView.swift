import SwiftUI
import AppKit
import ImageIO

enum AnalysisMode: String, CaseIterable, Identifiable {
    case perceptualHash = "Perceptual Hash"
    case deepFeature = "Deep Feature Embedding"
    var id: String { rawValue }
}

/// Root view. Heavy UI subviews and actions live in `Panels.swift` via `extension ContentView`.
struct ContentView: View {
    // MARK: - App State
    @State var selectedFolderURLs: [URL] = []
    @State var foldersToScanLabel: String = ""
    @State var similarityThreshold: Double = 0.7
    @State var comparisonResults: [ImageComparisonResult] = []
    @State var isProcessing: Bool = false
    @State var scanTopLevelOnly: Bool = false
    @State var processingProgress: Double? = nil
    @State var selectedAnalysisMode: AnalysisMode = .deepFeature

    // MARK: - Selection
    @State var selectedRowID: String? = nil
    @State var selectedRowIDs: Set<String> = []
    @State var toggleVersion = 0

    // MARK: - Cached derived data
    @State var cachedFlattened: [TableRow] = []
    @State var cachedFolderDuplicateCount: [String: Int] = [:]
    @State var cachedRepresentativeByFolder: [String: String] = [:]
    @State var cachedClusters: [[String]] = []

    // MARK: - Sorting
    @State var sortOrder: [KeyPathComparator<TableRow>] = [
        .init(\.percent, order: .reverse)
    ]

    // MARK: - Thumbnails
    @State var folderThumbs: [String: NSImage] = [:]

    // MARK: - Computed helpers
    var sortedRows: [TableRow] {
        var rows = cachedFlattened
        rows.sort(using: sortOrder)
        return rows
    }

    var selectedRow: TableRow? {
        sortedRows.first(where: { $0.id == selectedRowID })
    }

    var selectedMatches: [String] {
        cachedFlattened
            .filter { selectedRowIDs.contains($0.id) }
            .map { $0.similar }
    }

    // MARK: - Body
    var body: some View {
        Group {
            if isProcessing { processingView }
            else { mainSplitView }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { installSpacebarToggle() }
        .onChange(of: selectedFolderURLs) { urls in
            let leafs = findLeafFolders(from: urls)
            foldersToScanLabel = leafs.map { $0.lastPathComponent }.joined(separator: "\n")
        }
        .onChange(of: comparisonResults.count) { _ in
            recomputeDerived()
        }
    }

    // The main split view composition lives here; the panels are defined in Panels.swift
    var mainSplitView: some View {
        VSplitView {
            topSplitView
            bottomSplitView
        }
    }
}
