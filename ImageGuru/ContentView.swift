import SwiftUI
import AppKit
import ImageIO

enum AnalysisMode: String, CaseIterable, Identifiable {
    case perceptualHash = "Perceptual Hash"
    case deepFeature = "Deep Feature Embedding"
    var id: String { rawValue }
}

// MARK: - Image cache for previews
final class ImageCache {
    static let shared = NSCache<NSString, NSImage>()
    private init() {}
}

// MARK: - Preview image view with bucketed downsampling
struct PreviewImage: View {
    let path: String
    let maxDimension: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .border(Color.gray.opacity(0.4))
            } else {
                ProgressView().frame(width: 32, height: 32)
            }
        }
        .task(id: cacheKey) {
            await load()
        }
        .accessibilityLabel(Text((path as NSString).lastPathComponent))
    }

    private var cacheKey: String {
        let bucket = Self.bucket(for: maxDimension)
        return "\(path)::\(bucket)"
    }

    private static func bucket(for dim: CGFloat) -> Int {
        if dim <= 320 { return 320 }
        if dim <= 640 { return 640 }
        if dim <= 1024 { return 1024 }
        if dim <= 1600 { return 1600 }
        return 2048
    }

    @MainActor private func setImage(_ img: NSImage?) { self.image = img }

    private func load() async {
        let key = cacheKey as NSString
        if let cached = ImageCache.shared.object(forKey: key) {
            await setImage(cached)
            return
        }
        let bucket = Self.bucket(for: maxDimension)
        let url = URL(fileURLWithPath: path)

        let ns: NSImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let ns = downsampledNSImage(at: url, targetMaxDimension: CGFloat(bucket))
                cont.resume(returning: ns)
            }
        }

        if let ns { ImageCache.shared.setObject(ns, forKey: key) }
        await setImage(ns)
    }
}

private func downsampledNSImage(at url: URL, targetMaxDimension: CGFloat) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [NSString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(targetMaxDimension)
    ]
    guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
    let size = NSSize(width: cgThumb.width, height: cgThumb.height)
    return NSImage(cgImage: cgThumb, size: size)
}

// MARK: - ContentView
struct ContentView: View {
    @State private var selectedFolderURLs: [URL] = []
    @State private var foldersToScanLabel: String = ""
    @State private var similarityThreshold: Double = 0.7
    @State private var comparisonResults: [ImageComparisonResult] = []
    @State private var isProcessing: Bool = false
    @State private var scanTopLevelOnly: Bool = false
    @State private var processingProgress: Double? = nil
    @State private var selectedAnalysisMode: AnalysisMode = .deepFeature
    @State private var selectedRowID: String? = nil
    @State private var selectedRowIDs: Set<String> = []
    @State private var toggleVersion = 0

    // Cached derived data
    @State private var cachedFlattened: [TableRow] = []
    @State private var cachedFolderDuplicateCount: [String: Int] = [:]
    @State private var cachedRepresentativeByFolder: [String: String] = [:]
    @State private var cachedClusters: [[String]] = []

    // Sort
    @State private var sortOrder: [KeyPathComparator<TableRow>] = [
        .init(\.percent, order: .reverse)
    ]

    // Thumbs
    @State private var folderThumbs: [String: NSImage] = [:]

    struct TableRow: Identifiable, Hashable {
        var id: String { reference + "::" + similar }
        let reference: String
        let similar: String
        let percent: Double
    }

    private var sortedRows: [TableRow] {
        var rows = cachedFlattened
        rows.sort(using: sortOrder)
        return rows
    }

    private var selectedRow: TableRow? {
        sortedRows.first(where: { $0.id == selectedRowID })
    }

    private var selectedMatches: [String] {
        cachedFlattened
            .filter { selectedRowIDs.contains($0.id) }
            .map { $0.similar }
    }

    // MARK: Body broken up to help the type checker
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

    // MARK: - Subviews

    private var processingView: some View {
        VStack(spacing: 16) {
            if let p = processingProgress {
                ProgressView(value: p).frame(width: 320)
                Text("\(Int(p * 100))%").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 320)
                Text("Preparing…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mainSplitView: some View {
        VSplitView {
            topSplitView
            bottomSplitView
        }
    }

    private var topSplitView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                controlsPanel
                    .frame(width: max(geometry.size.width * 0.3, 320))
                Divider()
                duplicateFoldersPanel
                    .frame(minWidth: 220)
                    .frame(width: geometry.size.width * 0.7)
                    .padding()
            }
        }
        .frame(minHeight: 320)
    }

    private var controlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button("Select Folders") { selectFolders() }
                    Button("Analyze", action: processImages)
                        .disabled(selectedFolderURLs.isEmpty)
                }

                Toggle("Limit scan to selected folders only", isOn: $scanTopLevelOnly)

                Picker("", selection: $selectedAnalysisMode) {
                    ForEach(AnalysisMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                VStack {
                    Text("Similarity Threshold")
                    Slider(value: $similarityThreshold, in: 0.1...1.0, step: 0.1)
                    Text(String(format: "%.0f%% (%@)", similarityThreshold * 100, sliderLabel(for: similarityThreshold)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !selectedMatches.isEmpty {
                    Button(role: .destructive) {
                        deleteSelectedMatches()
                    } label: {
                        Label("Delete Selected Matches (\(selectedMatches.count))", systemImage: "trash")
                    }
                }

                Divider()

                if cachedFlattened.isEmpty {
                    Text("No matches yet.").foregroundStyle(.secondary)
                } else {
                    Text("Number of matches found: \(cachedFlattened.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if selectedFolderURLs.isEmpty {
                    Text("No folders selected.").foregroundStyle(.secondary)
                } else {
                    Text("Selected Folders:\n" + foldersToScanLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var duplicateFoldersPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duplicate Folder Groups").font(.headline)

            if cachedClusters.isEmpty {
                Text("No cross-folder duplicate relationships found.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(Array(cachedClusters.enumerated()), id: \.offset) { index, cluster in
                        Section {
                            ForEach(cluster, id: \.self) { folder in
                                Button(action: { openFolderInFinder(folder) }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(folder)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                        HStack(spacing: 8) {
                                            if let img = folderThumbs[folder] {
                                                Image(nsImage: img)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 36, height: 36)
                                                    .clipped()
                                                    .cornerRadius(4)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 4)
                                                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                                                    )
                                            }
                                            Text("\(cachedFolderDuplicateCount[folder, default: 0]) duplicates")
                                                .foregroundColor(.secondary)
                                                .font(.footnote)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(folder)
                            }
                        } header: {
                            HStack {
                                Text("Group \(index + 1)")
                                Spacer()
                                Text("\(cluster.count) folder\(cluster.count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(minHeight: 240)
            }
            Spacer()
        }
    }

    private var bottomSplitView: some View {
        GeometryReader { geometry in
            HSplitView {
                Table(sortedRows, selection: $selectedRowID, sortOrder: $sortOrder) {
                    TableColumn("") { row in
                        Toggle("", isOn: Binding(
                            get: { selectedRowIDs.contains(row.id) },
                            set: { isSelected in
                                if isSelected { selectedRowIDs.insert(row.id) }
                                else { selectedRowIDs.remove(row.id) }
                                toggleVersion += 1
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                    .width(30)

                    TableColumn("Reference", value: \.reference) { row in
                        Text(row.reference)
                            .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                    }

                    TableColumn("Match", value: \.similar) { row in
                        Text(row.similar)
                            .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                    }

                    TableColumn("Percent", value: \.percent) { row in
                        Text("\(Int(row.percent * 100))%")
                    }
                    .width(70)
                }
                .frame(width: geometry.size.width * 0.5)

                previewPanel
            }
        }
        .frame(minHeight: 320)
    }

    private var previewPanel: some View {
        VStack {
            if let row = selectedRow, !cachedFlattened.isEmpty {
                GeometryReader { geo in
                    let maxDim = max(300, min(max(geo.size.width, geo.size.height), 1600))
                    HStack(alignment: .top, spacing: 20) {
                        VStack {
                            Text("Reference")
                            PreviewImage(path: row.reference, maxDimension: maxDim)
                            Button("Delete Reference") { deleteFile(at: row.reference) }
                        }
                        VStack {
                            Text("Match")
                            PreviewImage(path: row.similar, maxDimension: maxDim)
                            Button("Delete Match") { deleteFile(at: row.similar) }
                        }
                    }
                }
            } else {
                ZStack {
                    VStack(spacing: 8) {
                        Text(comparisonResults.isEmpty ? "Run an analysis to see results here." : "Select a row to preview")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

    // MARK: - Actions

    private func installSpacebarToggle() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49,
               NSApp.keyWindow?.firstResponder is NSTableView {
                toggleSelectedRow()
                DispatchQueue.main.async {
                    if let contentView = NSApp.keyWindow?.contentView,
                       let tableView = findTableView(in: contentView) {
                        NSApp.keyWindow?.makeFirstResponder(tableView)
                    }
                }
                return nil
            }
            return event
        }
    }

    private func openFolderInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    private func isCrossFolder(_ row: TableRow) -> Bool {
        let refFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent()
        let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent()
        return refFolder != matchFolder
    }

    private func deleteSelectedMatches() {
        for path in selectedMatches {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
        for (index, var result) in comparisonResults.enumerated().reversed() {
            let filteredSimilars = result.similars.filter { !selectedMatches.contains($0.path) }
            let nonReferenceSimilars = filteredSimilars.filter { $0.path != result.reference }
            if selectedMatches.contains(result.reference) || nonReferenceSimilars.isEmpty {
                comparisonResults.remove(at: index)
            } else if filteredSimilars.count != result.similars.count {
                comparisonResults[index] = ImageComparisonResult(reference: result.reference, similars: filteredSimilars)
            }
        }
        selectedRowIDs.removeAll()
        toggleVersion += 1
        recomputeDerived()
        preloadAllFolderThumbnails()
    }

    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select Folders of Images"
        if panel.runModal() == .OK {
            selectedFolderURLs = panel.urls
            let leafs = findLeafFolders(from: panel.urls)
            foldersToScanLabel = leafs.map { $0.lastPathComponent }.joined(separator: "\n")
            comparisonResults = []
            selectedRowIDs = []
            folderThumbs.removeAll()
            cachedFlattened = []
            cachedFolderDuplicateCount = [:]
            cachedRepresentativeByFolder = [:]
            cachedClusters = []
        }
    }

    private func processImages() {
        guard !selectedFolderURLs.isEmpty else { return }
        isProcessing = true
        processingProgress = 0
        comparisonResults = []
        selectedRowIDs = []
        folderThumbs.removeAll()
        cachedFlattened = []
        cachedFolderDuplicateCount = [:]
        cachedRepresentativeByFolder = [:]
        cachedClusters = []

        let roots = selectedFolderURLs
        let similarityScoreThreshold = similarityThreshold
        let topOnly = scanTopLevelOnly

        let onComplete: ([ImageComparisonResult]) -> Void = { results in
            DispatchQueue.main.async {
                self.comparisonResults = results
                self.processingProgress = nil
                self.isProcessing = false
                self.recomputeDerived()
                self.preloadAllFolderThumbnails()
            }
        }

        switch selectedAnalysisMode {
        case .perceptualHash:
            ImageAnalyzer.analyzeImages(
                inFolders: roots,
                similarityThreshold: similarityScoreThreshold,
                topLevelOnly: topOnly,
                progress: { self.processingProgress = $0 },
                completion: onComplete
            )
        case .deepFeature:
            ImageAnalyzer.analyzeWithDeepFeatures(
                inFolders: roots,
                similarityThreshold: similarityScoreThreshold,
                topLevelOnly: topOnly,
                progress: { self.processingProgress = $0 },
                completion: onComplete
            )
        }
    }

    private func toggleSelectedRow() {
        guard NSApp.keyWindow?.firstResponder is NSTableView else { return }
        guard let id = selectedRowID else { return }
        if selectedRowIDs.contains(id) { selectedRowIDs.remove(id) }
        else { selectedRowIDs.insert(id) }
        toggleVersion += 1
    }

    private func deleteFile(at path: String) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        for (index, var result) in comparisonResults.enumerated().reversed() {
            let filteredSimilars = result.similars.filter { $0.path != path }
            let nonReferenceSimilars = filteredSimilars.filter { $0.path != result.reference }
            if result.reference == path || nonReferenceSimilars.isEmpty {
                comparisonResults.remove(at: index)
            } else if filteredSimilars.count != result.similars.count {
                comparisonResults[index] = ImageComparisonResult(reference: result.reference, similars: filteredSimilars)
            }
        }
        selectedRowIDs.remove(path)
        toggleVersion += 1
        recomputeDerived()
        preloadAllFolderThumbnails()
    }

    private func sliderLabel(for value: Double) -> String {
        switch value {
        case ..<0.3: return "Loose"
        case ..<0.6: return "Moderate"
        case ..<0.85: return "Strict"
        default: return "Exact"
        }
    }

    // MARK: - Derived + thumbs

    private func recomputeDerived() {
        let flat: [TableRow] = comparisonResults.flatMap { result in
            result.similars
                .filter { $0.path != result.reference }
                .map { TableRow(reference: result.reference, similar: $0.path, percent: $0.percent) }
        }
        cachedFlattened = flat

        var folderCount: [String: Int] = [:]
        var rep: [String: String] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                folderCount[folder, default: 0] += 1
                if rep[folder] == nil { rep[folder] = path }
            }
        }
        let filteredCount = folderCount.filter { $0.value > 1 }
        cachedFolderDuplicateCount = filteredCount
        cachedRepresentativeByFolder = rep.filter { filteredCount[$0.key] != nil }

        var graph: [String: Set<String>] = [:]
        for result in comparisonResults {
            var foldersInResult = Set<String>()
            foldersInResult.insert(URL(fileURLWithPath: result.reference).deletingLastPathComponent().path)
            for s in result.similars {
                foldersInResult.insert(URL(fileURLWithPath: s.path).deletingLastPathComponent().path)
            }
            let list = Array(foldersInResult)
            for i in 0..<list.count {
                for j in (i+1)..<list.count {
                    graph[list[i], default: []].insert(list[j])
                    graph[list[j], default: []].insert(list[i])
                }
            }
        }
        if graph.isEmpty {
            cachedClusters = []
        } else {
            var visited = Set<String>(), clusters: [[String]] = []
            for node in graph.keys.sorted() where !visited.contains(node) {
                var stack = [node], comp: [String] = []
                visited.insert(node)
                while let v = stack.popLast() {
                    comp.append(v)
                    for n in graph[v, default: []] where !visited.contains(n) {
                        visited.insert(n); stack.append(n)
                    }
                }
                let pruned = comp.filter { cachedFolderDuplicateCount[$0, default: 0] > 1 }.sorted()
                if !pruned.isEmpty { clusters.append(pruned) }
            }
            clusters.sort { $0.count != $1.count ? $0.count > $1.count : ($0.first ?? "") < ($1.first ?? "") }
            cachedClusters = clusters
        }
    }

    private func preloadAllFolderThumbnails() {
        folderThumbs.removeAll()
        let folders = Array(cachedRepresentativeByFolder.keys)

        DispatchQueue.global(qos: .userInitiated).async {
            var newThumbs: [String: NSImage] = [:]
            newThumbs.reserveCapacity(folders.count)
            for folder in folders {
                if let path = cachedRepresentativeByFolder[folder],
                   let img = downsampledNSImage(at: URL(fileURLWithPath: path), targetMaxDimension: 64) {
                    newThumbs[folder] = img
                }
            }
            DispatchQueue.main.async { folderThumbs = newThumbs }
        }
    }

    // MARK: - Helpers

    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let t = findTableView(in: sub) { return t }
        }
        return nil
    }
}

