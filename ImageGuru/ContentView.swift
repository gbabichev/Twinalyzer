import SwiftUI
import AppKit

enum AnalysisMode: String, CaseIterable, Identifiable {
    case perceptualHash = "Perceptual Hash"
    case deepFeature = "Deep Feature Embedding"

    var id: String { rawValue }
}

struct ContentView: View {
    @State private var selectedFolderURLs: [URL] = []
    @State private var foldersToScanLabel: String = ""   // cheap cached label (no enumeration)
    @State private var similarityThreshold: Double = 0.7
    @State private var comparisonResults: [ImageComparisonResult] = []
    @State private var isProcessing: Bool = false
    @State private var scanTopLevelOnly: Bool = false
    @State private var processingProgress: Double? = nil
    @State private var selectedAnalysisMode: AnalysisMode = .deepFeature
    @State private var selectedRowID: String? = nil
    @State private var selectedRowIDs: Set<String> = []
    @State private var toggleVersion = 0
    @State private var sortByPercentDescending: Bool = true
    @State private var selectedTab: Int = 0

    // Thumbnail cache for Duplicate Folders list
    @State private var folderThumbs: [String: NSImage] = [:]

    struct TableRow: Identifiable, Hashable {
        var id: String { reference + "::" + similar }
        let reference: String
        let similar: String
        let percent: Double
    }

    // === Derived data ONLY used when isProcessing == false ===

    private var flattenedResults: [TableRow] {
        let rows = comparisonResults.flatMap { result in
            result.similars
                .filter { $0.path != result.reference }
                .map { item in
                    TableRow(reference: result.reference, similar: item.path, percent: item.percent)
                }
        }
        return rows.sorted { sortByPercentDescending ? $0.percent > $1.percent : $0.percent < $1.percent }
    }

    private var selectedRow: TableRow? {
        flattenedResults.first(where: { $0.id == selectedRowID })
    }

    private var selectedMatches: [String] {
        flattenedResults
            .filter { selectedRowIDs.contains($0.id) }
            .map { $0.similar }
    }

    private var folderDuplicateCount: [String: Int] {
        var folderCount: [String: Int] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                folderCount[folder, default: 0] += 1
            }
        }
        return folderCount.filter { $0.value > 1 }
    }

    private var representativeDuplicateByFolder: [String: String] {
        var rep: [String: String] = [:]
        for result in comparisonResults {
            let allPaths = [result.reference] + result.similars.map { $0.path }
            for path in allPaths {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                if rep[folder] == nil {
                    rep[folder] = path
                }
            }
        }
        return rep.filter { folderDuplicateCount[$0.key, default: 0] > 1 }
    }

    private var duplicateFolderClusters: [[String]] {
        var graph: [String: Set<String>] = [:]
        func addEdge(_ a: String, _ b: String) {
            guard a != b else { return }
            graph[a, default: []].insert(b)
            graph[b, default: []].insert(a)
        }
        for result in comparisonResults {
            var foldersInResult = Set<String>()
            foldersInResult.insert(URL(fileURLWithPath: result.reference).deletingLastPathComponent().path)
            for s in result.similars {
                foldersInResult.insert(URL(fileURLWithPath: s.path).deletingLastPathComponent().path)
            }
            for f in foldersInResult { _ = graph[f, default: []] }
            let list = Array(foldersInResult)
            for i in 0..<list.count {
                for j in (i+1)..<list.count { addEdge(list[i], list[j]) }
            }
        }
        if graph.isEmpty { return [] }
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
            let pruned = comp.filter { folderDuplicateCount[$0, default: 0] > 1 }.sorted()
            if !pruned.isEmpty { clusters.append(pruned) }
        }
        clusters.sort { $0.count != $1.count ? $0.count > $1.count : ($0.first ?? "") < ($1.first ?? "") }
        return clusters
    }

    var body: some View {
        Group {
            if isProcessing {
                // === Processing-only UI ===
                VStack(spacing: 16) {
                    if let p = processingProgress {
                        ProgressView(value: p)
                            .frame(width: 320)
                        Text("\(Int(p * 100))%")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .frame(width: 320)
                        Text("Preparing…")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // === Full UI only when NOT processing ===
                TabView(selection: $selectedTab) {
                    // MARK: Matches tab
                    VSplitView {
                        // Controls
                        ScrollView {
                            VStack(alignment: .leading, spacing: 20) {
                                Button("Select Folders of Images") {
                                    selectFolders()
                                }
                                .padding(.top, 20)

                                Toggle("Limit scan to selected folders only", isOn: $scanTopLevelOnly)

                                if selectedFolderURLs.isEmpty {
                                    Text("No folders selected.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Folders to Scan: " + foldersToScanLabel)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                Picker("Analysis Mode", selection: $selectedAnalysisMode) {
                                    ForEach(AnalysisMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)

                                HStack {
                                    Text("Similarity Threshold")
                                    Slider(value: $similarityThreshold, in: 0.1...1.0, step: 0.01)
                                    Text(String(format: "%.0f%% (%@)", similarityThreshold * 100, sliderLabel(for: similarityThreshold)))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Button(action: processImages) {
                                    Text("Analyze Images")
                                }
                                .disabled(selectedFolderURLs.isEmpty)

                                if !selectedMatches.isEmpty {
                                    Button(role: .destructive) {
                                        deleteSelectedMatches()
                                    } label: {
                                        Label("Delete Selected Matches (\(selectedMatches.count))", systemImage: "trash")
                                    }
                                }

                                Divider()

                                if comparisonResults.isEmpty {
                                    Text("No results yet.")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Number of matches found: \(flattenedResults.count)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)

                                    HStack(spacing: 8) {
                                        Spacer()
                                        Button(action: { sortByPercentDescending.toggle() }) {
                                            HStack(spacing: 2) {
                                                Text("Sort by Percent")
                                                Image(systemName: sortByPercentDescending ? "arrow.down" : "arrow.up")
                                                    .font(.system(size: 10, weight: .bold))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .font(.footnote)
                                    }
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(minHeight: 180, idealHeight: 260, maxHeight: 320)

                        // Results
                        Group {
                            HSplitView {
                                Table(flattenedResults, selection: $selectedRowID) {
                                    TableColumn("") { row in
                                        Toggle("", isOn: Binding(
                                            get: { selectedRowIDs.contains(row.id) },
                                            set: { isSelected in
                                                if isSelected {
                                                    selectedRowIDs.insert(row.id)
                                                } else {
                                                    selectedRowIDs.remove(row.id)
                                                }
                                                toggleVersion += 1
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()
                                    }
                                    .width(30)

                                    TableColumn("Reference") { row in
                                        Text(row.reference)
                                            .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                                    }
                                    TableColumn("Similar") { row in
                                        Text(row.similar)
                                            .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                                    }

                                    TableColumn("Percent") { row in
                                        Text("\(Int(row.percent * 100))%")
                                    }
                                    .width(70)
                                }
                                .frame(minWidth: 50)

                                VStack {
                                    if let row = selectedRow, !flattenedResults.isEmpty {
                                        HStack(alignment: .top, spacing: 20) {
                                            VStack {
                                                Text("Reference")
                                                loadPreview(for: row.reference)
                                                Button("Delete Reference") {
                                                    deleteFile(at: row.reference)
                                                }
                                            }

                                            VStack {
                                                Text("Match")
                                                loadPreview(for: row.similar)
                                                Button("Delete Match") {
                                                    deleteFile(at: row.similar)
                                                }
                                            }
                                        }
                                    } else {
                                        VStack(spacing: 8) {
                                            Text(comparisonResults.isEmpty ? "Run an analysis to see results here." : "Select a row to preview")
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }
                                        .padding(.top, 8)
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 320)
                    }
                    .animation(.default, value: comparisonResults.count)
                    .tabItem {
                        Label("Matches", systemImage: "rectangle.grid.2x2")
                    }
                    .tag(0)

                    // MARK: Duplicate Folders tab
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Duplicate Folder Groups")
                            .font(.headline)

                        if duplicateFolderClusters.isEmpty {
                            Text("No cross-folder duplicate relationships found.")
                                .foregroundStyle(.secondary)
                        } else {
                            List {
                                ForEach(Array(duplicateFolderClusters.enumerated()), id: \.offset) { index, cluster in
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
                                                        Text("\(folderDuplicateCount[folder, default: 0]) duplicates")
                                                            .foregroundColor(.secondary)
                                                            .font(.footnote)
                                                    }
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .help(folder)
                                            .onAppear { ensureFolderThumbnail(folder) }
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
                    .padding()
                    .tabItem {
                        Label("Duplicate Folders", systemImage: "folder.badge.minus")
                    }
                    .tag(1)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
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
        .onChange(of: selectedFolderURLs) { urls in
            // Expand root folders into leaf subfolders for display
            let leafs = findLeafFolders(from: urls)
            foldersToScanLabel = leafs.map { $0.lastPathComponent }.joined(separator: ", ")
        }

    }

    // MARK: - Actions

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
            foldersToScanLabel = leafs.map { $0.lastPathComponent }.joined(separator: ", ")
            comparisonResults = []
            selectedRowIDs = []
            folderThumbs.removeAll()
        }
    }


    private func processImages() {
        guard !selectedFolderURLs.isEmpty else { return }
        // Lock UI to progress-only view
        isProcessing = true
        processingProgress = 0
        comparisonResults = []
        selectedRowIDs = []
        folderThumbs.removeAll()

        let roots = selectedFolderURLs
        let similarityScoreThreshold = similarityThreshold
        let topOnly = scanTopLevelOnly

        let onComplete: ([ImageComparisonResult]) -> Void = { results in
            DispatchQueue.main.async {
                self.comparisonResults = results
                self.processingProgress = nil
                self.isProcessing = false   // swap full UI back in one shot
            }
        }

        switch selectedAnalysisMode {
        case .perceptualHash:
            ImageAnalyzer.analyzeImages(
                inFolders: roots,
                similarityThreshold: similarityScoreThreshold,
                topLevelOnly: topOnly,
                progress: { self.processingProgress = $0 },   // only thing that updates during run
                completion: onComplete
            )
        case .deepFeature:
            ImageAnalyzer.analyzeWithDeepFeatures(
                inFolders: roots,
                similarityThreshold: similarityScoreThreshold,
                topLevelOnly: topOnly,
                progress: { self.processingProgress = $0 },   // only thing that updates during run
                completion: onComplete
            )
        }
    }

    private func toggleSelectedRow() {
        guard NSApp.keyWindow?.firstResponder is NSTableView else { return }
        guard let id = selectedRowID else { return }
        if selectedRowIDs.contains(id) {
            selectedRowIDs.remove(id)
        } else {
            selectedRowIDs.insert(id)
        }
        toggleVersion += 1
    }

    private func loadPreview(for path: String) -> some View {
        if let image = NSImage(contentsOfFile: path) {
            return AnyView(
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    .border(Color.gray)
            )
        } else {
            return AnyView(
                Image(systemName: "questionmark.square")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 100, height: 100)
                    .foregroundColor(.secondary)
            )
        }
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
    }

    private func sliderLabel(for value: Double) -> String {
        switch value {
        case ..<0.3: return "Loose"
        case ..<0.6: return "Moderate"
        case ..<0.85: return "Strict"
        default: return "Exact"
        }
    }

    // MARK: - Thumbs + helpers

    private func ensureFolderThumbnail(_ folder: String) {
        guard folderThumbs[folder] == nil,
              let path = representativeDuplicateByFolder[folder] else { return }
        if let img = downsampledNSImage(at: URL(fileURLWithPath: path), targetMaxDimension: 64) {
            folderThumbs[folder] = img
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
        let ns = NSImage(size: size)
        ns.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .low
        NSImage(cgImage: cgThumb, size: size).draw(in: NSRect(origin: .zero, size: size))
        ns.unlockFocus()
        return ns
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let t = findTableView(in: sub) { return t }
        }
        return nil
    }
}

