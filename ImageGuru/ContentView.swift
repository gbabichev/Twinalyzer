import SwiftUI
import AppKit

enum AnalysisMode: String, CaseIterable, Identifiable {
    case perceptualHash = "Perceptual Hash"
    case deepFeature = "Deep Feature Embedding"

    var id: String { rawValue }
}

struct ContentView: View {
    @State private var selectedFolderURLs: [URL] = []
    @State private var similarityThreshold: Double = 0.2
    @State private var comparisonResults: [ImageComparisonResult] = []
    @State private var isProcessing: Bool = false
    @State private var scanTopLevelOnly: Bool = false
    @State private var processingProgress: Double? = nil
    @State private var selectedAnalysisMode: AnalysisMode = .deepFeature
    @State private var selectedRowID: String? = nil
    @State private var selectedRowIDs: Set<String> = []
    @State private var toggleVersion = 0
    @State private var sortByPercentDescending: Bool = true

    struct TableRow: Identifiable, Hashable {
        var id: String { reference + "::" + similar }
        let reference: String
        let similar: String
        let percent: Double
    }

    private var flattenedResults: [TableRow] {
        let rows = comparisonResults.flatMap { result in
            result.similars.filter { $0.path != result.reference }.map { item in
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

    var body: some View {
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
                let foldersToDisplay: [URL] = findLeafFolders(from: selectedFolderURLs)
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
            }

            if !comparisonResults.isEmpty {
                Text("Number of matches found: \(flattenedResults.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !comparisonResults.isEmpty {
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

            if !comparisonResults.isEmpty {
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
                        if let row = selectedRow {
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
                            Text("Select a row to preview")
                        }
                        Spacer()
                    }
                }
            }

            Spacer()
        }
        .padding()
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

        comparisonResults.removeAll { result in
            result.similars.contains(where: { selectedMatches.contains($0.path) })
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

        let folders = findLeafFolders(from: selectedFolderURLs)
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
        comparisonResults.removeAll { $0.reference == path || $0.similars.contains(where: { $0.path == path }) }
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
}

