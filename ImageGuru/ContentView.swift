import SwiftUI
import AppKit

enum AnalysisMode: String, CaseIterable, Identifiable {
    case perceptualHash = "Perceptual Hash"
    case deepFeature = "Deep Feature Embedding"

    var id: String { rawValue }
}

struct ContentView: View {
    @State private var selectedFolderURLs: [URL] = []
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

    struct TableRow: Identifiable, Hashable {
        var id: String { reference + "::" + similar }
        let reference: String
        let similar: String
        let percent: Double
    }

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

    private var duplicateFolderCounts: [String: Int] {
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

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: - Matches Tab
            VSplitView {
                // TOP: Controls (capped height so results are always visible)
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
                            let foldersToDisplay: [URL] = findLeafFolders(from: selectedFolderURLs, topLevelOnly: scanTopLevelOnly)
                            Text("Folders to Scan: " + foldersToDisplay.map { $0.lastPathComponent }.joined(separator: ", "))
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
                            if isProcessing {
                                if let progress = processingProgress {
                                    HStack {
                                        ProgressView(value: progress)
                                        Text(" \(Int(progress * 100))%")
                                    }
                                } else {
                                    ProgressView()
                                }
                            } else {
                                Text("Analyze Images")
                            }
                        }
                        .disabled(selectedFolderURLs.isEmpty || isProcessing)

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
                .frame(minHeight: 180, idealHeight: 260, maxHeight: 320) // <-- important cap

                // BOTTOM: Results (reserve space even before results exist)
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
                .frame(minHeight: 320) // <-- forces table area to exist
            }
            .animation(.default, value: comparisonResults.count)
            .tabItem {
                Label("Matches", systemImage: "rectangle.grid.2x2")
            }
            .tag(0)

            // MARK: - Duplicate Folders Tab
            VStack(alignment: .leading, spacing: 16) {
                Text("Folders With Duplicates")
                    .font(.headline)
                if duplicateFolderCounts.isEmpty {
                    Text("No folders with duplicate images found.")
                        .foregroundStyle(.secondary)
                } else {
                    List(Array(duplicateFolderCounts.keys), id: \.self) { folder in
                        Button(action: { openFolderInFinder(folder) }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder)
                                }
                                Spacer()
                                Text("\(duplicateFolderCounts[folder, default: 0]) duplicates")
                                    .foregroundColor(.secondary)
                                    .font(.footnote)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(folder)
                    }
                    .frame(minHeight: 200)
                }
                Spacer()
            }
            .padding()
            .tabItem {
                Label("Duplicate Folders", systemImage: "folder.badge.minus")
            }
            .tag(1)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 49, // space
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
    }

    // MARK: - Helpers

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
        print("After multi-delete, comparisonResults count: \(comparisonResults.count)")
        for result in comparisonResults {
            print("Reference: \(result.reference), Similars: \(result.similars.map { $0.path })")
        }
    }

    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select Folders of Images"
        if panel.runModal() == .OK {
            selectedFolderURLs = panel.urls
            comparisonResults = []
            selectedRowIDs = []
        }
    }

    private func processImages() {
        guard !selectedFolderURLs.isEmpty else { return }
        isProcessing = true
        processingProgress = 0
        comparisonResults = []
        selectedRowIDs = []

        let folders = findLeafFolders(from: selectedFolderURLs, topLevelOnly: scanTopLevelOnly)
        let similarityScoreThreshold = similarityThreshold

        let onComplete: ([ImageComparisonResult]) -> Void = { results in
            DispatchQueue.main.async {
                self.comparisonResults = results
                self.processingProgress = nil
                self.isProcessing = false
            }
        }

        switch selectedAnalysisMode {
        case .perceptualHash:
            ImageAnalyzer.analyzeImages(
                inFolders: folders,
                similarityThreshold: similarityScoreThreshold,
                topLevelOnly: scanTopLevelOnly,
                progress: { self.processingProgress = $0 },
                completion: onComplete
            )

        case .deepFeature:
            ImageAnalyzer.analyzeWithDeepFeatures(
                inFolders: folders,
                similarityThreshold: similarityScoreThreshold,
                topLevelOnly: scanTopLevelOnly,
                progress: { self.processingProgress = $0 },
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
        for result in comparisonResults {
            print("Reference: \(result.reference), Similars: \(result.similars.map { $0.path })")
        }
    }

    private func sliderLabel(for value: Double) -> String {
        switch value {
        case ..<0.3: return "Loose"
        case ..<0.6: return "Moderate"
        case ..<0.85: return "Strict"
        default: return "Exact"
        }
    }

    // MARK: - Local utilities so this compiles standalone

    /// Finds "leaf" folders from the given roots. If `topLevelOnly` is true, returns the roots as-is.
    private func findLeafFolders(from roots: [URL], topLevelOnly: Bool) -> [URL] {
        guard !topLevelOnly else { return roots }
        var folders: [URL] = []
        let fm = FileManager.default

        for root in roots {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in enumerator {
                        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            folders.append(url)
                        }
                    }
                }
                folders.append(root)
            }
        }

        let folderSet = Set(folders.map(\.standardizedFileURL))
        let isParentOfAnother: (URL) -> Bool = { folder in
            for other in folderSet where other != folder {
                if other.path.hasPrefix(folder.path + "/") { return true }
            }
            return false
        }
        let leafs = folders.filter { !isParentOfAnother($0.standardizedFileURL) }
        return Array(Set(leafs))
    }

    /// Walks the view hierarchy to find the first NSTableView (used for restoring first responder).
    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews {
            if let t = findTableView(in: sub) { return t }
        }
        return nil
    }
}

