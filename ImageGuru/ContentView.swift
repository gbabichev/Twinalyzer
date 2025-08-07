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
    @State private var selectedAnalysisMode: AnalysisMode = .perceptualHash

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Folder selection
            Button("Select Folders of Images") {
                selectFolders()
            }
            .padding(.top, 20)

            Toggle("Limit scan to selected folders only", isOn: $scanTopLevelOnly)

            Picker("Analysis Mode", selection: $selectedAnalysisMode) {
                ForEach(AnalysisMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Similarity Threshold")
                Slider(value: $similarityThreshold, in: 0.7...1.0, step: 0.01)
                Text(String(format: "%.2f", similarityThreshold))
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

            Divider()

            if comparisonResults.isEmpty {
                Text("No results yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(comparisonResults) { result in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(nsImage: ImageAnalyzer.loadThumbnail(for: result.reference, size: 48))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text("📌 \(result.reference)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        ForEach(result.similars.filter { $0.path != result.reference }, id: \.path) { item in
                            HStack(alignment: .center, spacing: 12) {
                                Image(nsImage: ImageAnalyzer.loadThumbnail(for: item.path, size: 48))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                if item.percent == 1.0 {
                                    Text("🟩 \(item.path) (100%)")
                                } else {
                                    Text("🟨 \(item.path) (\(Int(item.percent * 100))%)")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer()
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
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
        }
    }

    private func processImages() {
        guard !selectedFolderURLs.isEmpty else { return }
        isProcessing = true
        processingProgress = 0
        comparisonResults = []

        let folders = findLeafFolders(from: selectedFolderURLs)

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
                similarityThreshold: similarityThreshold,
                topLevelOnly: scanTopLevelOnly,
                progress: { self.processingProgress = $0 },
                completion: onComplete
            )

        case .deepFeature:
            ImageAnalyzer.analyzeWithDeepFeatures(
                inFolders: folders,
                threshold: Float(1.0 - similarityThreshold),
                topLevelOnly: scanTopLevelOnly,
                progress: { self.processingProgress = $0 },
                completion: onComplete
            )
        }
    }

    private func findLeafFolders(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var leafFolders = [URL]()
        var seen = Set<URL>()

        func recurse(_ url: URL) {
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                let subfolders = contents.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                if subfolders.isEmpty {
                    if seen.insert(url).inserted {
                        leafFolders.append(url)
                    }
                } else {
                    for subfolder in subfolders {
                        recurse(subfolder)
                    }
                }
            }
        }

        for url in urls {
            recurse(url)
        }

        return leafFolders
    }
}

