import SwiftUI
import AppKit

extension ContentView {

var processingView: some View {
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

var topSplitView: some View {
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

var controlsPanel: some View {
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

var duplicateFoldersPanel: some View {
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

var bottomSplitView: some View {
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

var previewPanel: some View {
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

func recomputeDerived() {
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

func processImages() {
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

func selectFolders() {
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

func preloadAllFolderThumbnails() {
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

func installSpacebarToggle() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49, // space
               let tableView = NSApp.keyWindow?.firstResponder as? NSTableView {
                // Remember the exact table that had focus
                toggleSelectedRow()
                DispatchQueue.main.async {
                    NSApp.keyWindow?.makeFirstResponder(tableView)
                }
                return nil // consume
            }
            return event
        }
    }

func isCrossFolder(_ row: TableRow) -> Bool {
        let refFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent()
        let matchFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent()
        return refFolder != matchFolder
    }

func deleteSelectedMatches() {
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

func deleteFile(at path: String) {
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

func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let t = findTableView(in: sub) { return t }
        }
        return nil
    }

// MARK: - Helpers required by panels

func sliderLabel(for value: Double) -> String {
    return String(format: "%.0f%%", value * 100)
}

func openFolderInFinder(_ folder: String) {
    let url = URL(fileURLWithPath: folder, isDirectory: true)
    NSWorkspace.shared.open(url)
}

func toggleSelectedRow() {
    guard let id = selectedRowID else { return }
    if selectedRowIDs.contains(id) {
        selectedRowIDs.remove(id)
    } else {
        selectedRowIDs.insert(id)
    }
}

}
