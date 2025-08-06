//
//  ContentView.swift
//  ImageGuru
//
//  Created by George Babichev on 8/6/25.
//

import SwiftUI
import AppKit
import AVFoundation

struct ContentView: View {
    @State private var selectedFolderURLs: [URL] = []
    @State private var similarityThreshold: Double = 0.8
    @State private var comparisonResults: [ImageComparisonResult] = []
    @State private var isProcessing: Bool = false
    @State private var selectedForDeletion: Set<String> = []
    @State private var selectAllActive: Bool = false
    @State private var scanTopLevelOnly: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
//            Text("ImageGuru: Duplicate & Similar Photo Finder")
//                .font(.title)
//                .padding(.bottom, 10)

            Button("Select Folders of Images") {
                selectFolders()
            }
            .help("Choose folders containing images to analyze")
            .padding(.bottom, 2)
            
            Toggle("Limit scan to selected folders only", isOn: $scanTopLevelOnly)
                .toggleStyle(.checkbox)
                .help("When checked, only scans images directly inside each selected folder (no subfolders and no cross-folder matches). Uncheck to scan recursively as before.")

            if selectedFolderURLs.isEmpty {
                Text("No folders selected.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Selected Folders: " + selectedFolderURLs.map { $0.lastPathComponent }.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text("Similarity Precision: ")
                Slider(value: $similarityThreshold, in: 0.5...1.0, step: 0.01) {
                    Text("Similarity Threshold")
                }
                Text(String(format: "%.2f", similarityThreshold))
            }
            .padding(.bottom, 10)

            Button(action: processImages) {
                if isProcessing {
                    ProgressView()
                } else {
                    Text("Analyze Images")
                }
            }
            .disabled(selectedFolderURLs.isEmpty || isProcessing)

            Divider()
            
            if !comparisonResults.isEmpty {
                HStack(spacing: 20) {
                    Button(action: {
                        if selectAllActive {
                            // Deselect all
                            selectedForDeletion.removeAll()
                            selectAllActive = false
                        } else {
                            // Select all deletable images (not reference images)
                            let allImagePaths = comparisonResults.flatMap { result in
                                // Extract all but the first image in the group
                                let images: [(String, Double)] = {
                                    switch result.type {
                                    case .duplicate(let reference, let duplicates):
                                        var arr = [(reference, 1.0)]
                                        arr.append(contentsOf: duplicates)
                                        return arr
                                    case .similar(let reference, let similars):
                                        var arr = [(reference, 1.0)]
                                        arr.append(contentsOf: similars)
                                        return arr
                                    }
                                }()
                                // Deduplicate images by path while preserving order
                                var seen = Set<String>()
                                var uniqueArr = [(String, Double)]()
                                for image in images { if !seen.contains(image.0) { seen.insert(image.0); uniqueArr.append(image) } }
                                return uniqueArr.dropFirst().map { $0.0 } // skip reference
                            }
                            selectedForDeletion = Set(allImagePaths)
                            selectAllActive = true
                        }
                    }) {
                        Text(selectAllActive ? "Deselect All" : "Select All")
                    }
                    Button(action: deleteSelectedImages) {
                        Text("Delete Selected")
                    }
                    .disabled(selectedForDeletion.isEmpty)
                    .foregroundStyle(selectedForDeletion.isEmpty ? .secondary : .primary)
                    .foregroundColor(selectedForDeletion.isEmpty ? nil : .red)
                }
            }

            if comparisonResults.isEmpty {
                Text("No duplicate or similar images detected yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(comparisonResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        // Prepare array of (path, percent) for this group
                        let images: [(path: String, percent: Double)] = {
                            switch result.type {
                            case .duplicate(let reference, let duplicates):
                                var arr = [(path: String, percent: Double)]()
                                arr.append((reference, 1.0))
                                for dup in duplicates {
                                    arr.append((dup.path, dup.percent))
                                }
                                return arr
                            case .similar(let reference, let similars):
                                var arr = [(path: String, percent: Double)]()
                                arr.append((reference, 1.0))
                                for sim in similars {
                                    arr.append((sim.path, sim.percent))
                                }
                                return arr
                            }
                        }()
                        // Deduplicate images by path while preserving order
                        let deduplicatedImages: [(path: String, percent: Double)] = {
                            var seen = Set<String>()
                            var uniqueArr = [(path: String, percent: Double)]()
                            for image in images {
                                if !seen.contains(image.path) {
                                    seen.insert(image.path)
                                    uniqueArr.append(image)
                                }
                            }
                            return uniqueArr
                        }()
                        let referenceFolder: String = {
                            guard let first = deduplicatedImages.first else { return "" }
                            return URL(fileURLWithPath: first.path).deletingLastPathComponent().path
                        }()
                        ForEach(Array(deduplicatedImages.enumerated()), id: \.element.path) { index, image in
                            let folderPath = URL(fileURLWithPath: image.path).deletingLastPathComponent().path
                            let pathColor: Color = {
                                if index == 0 {
                                    return .blue
                                } else {
                                    return Color.red
                                }
                            }()
                            let folderName = URL(fileURLWithPath: image.path).deletingLastPathComponent().lastPathComponent
                            let fileName = URL(fileURLWithPath: image.path).lastPathComponent
                            let displayPath = folderName + "/" + fileName
                            HStack(alignment: .center, spacing: 10) {
                                if index != 0 {
                                    Toggle(isOn: Binding(
                                        get: { selectedForDeletion.contains(image.path) },
                                        set: { checked in
                                            if checked { selectedForDeletion.insert(image.path) }
                                            else { selectedForDeletion.remove(image.path) }
                                        }
                                    )) {
                                        EmptyView()
                                    }
                                    .toggleStyle(.checkbox)
                                    .frame(width: 20)
                                }
                                Image(nsImage: ImageAnalyzer.loadThumbnail(for: image.path))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 96, height: 96)
                                    .cornerRadius(6)
                                if index == 0 {
                                    Text(displayPath)
                                        .font(.caption)
                                        .foregroundColor(pathColor)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                } else {
                                    Text(displayPath)
                                        .font(.caption)
                                        .foregroundColor(pathColor)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    Text("\(String(format: "%.0f", image.percent * 100))% match")
                                        .font(.caption)
                                        .foregroundColor(.primary)

                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 150)
            }
            Spacer()
        }
        .padding(32)
        .frame(minWidth: 600, minHeight: 480)
    }

    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select folders with images"
        if panel.runModal() == .OK {
            if panel.urls.count == 1 {
                // User selected a single root folder. Use all its immediate subfolders
                let rootURL = panel.urls[0]
                let fileManager = FileManager.default
                if let subfolders = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    let folderURLs = subfolders.filter { url in
                        var isDir: ObjCBool = false
                        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                    }
                    selectedFolderURLs = folderURLs
                } else {
                    selectedFolderURLs = []
                }
            } else {
                selectedFolderURLs = panel.urls
            }
            comparisonResults = []
        }
    }

    private func processImages() {
        guard !selectedFolderURLs.isEmpty else { return }
        print("--- Diagnostic Start ---")
        print("Selected Folders:", selectedFolderURLs)
        print("Similarity Threshold:", similarityThreshold)
        print("Top Level Only:", scanTopLevelOnly)
        isProcessing = true
        comparisonResults = []
        ImageAnalyzer.analyzeImages(inFolders: selectedFolderURLs, similarityThreshold: similarityThreshold, topLevelOnly: scanTopLevelOnly) { results in
            print("Analysis Complete. Results count:", results.count)
            for (i, r) in results.enumerated() {
                switch r.type {
                case .duplicate(let reference, let duplicates):
                    print("[Result \(i)] DUPLICATE group. Reference:", reference, "Duplicates:", duplicates)
                case .similar(let reference, let similars):
                    print("[Result \(i)] SIMILAR group. Reference:", reference, "Similars:", similars)
                }
            }
            print("--- Diagnostic End ---")
            self.comparisonResults = results
            self.isProcessing = false
        }
    }
    
    private func deleteSelectedImages() {
        let fileManager = FileManager.default
        for path in selectedForDeletion {
            try? fileManager.removeItem(atPath: path)
        }
        // Remove deleted images from comparisonResults
        comparisonResults = comparisonResults.compactMap { result in
            let filtered: [(path: String, percent: Double)] = {
                switch result.type {
                case .duplicate(let reference, let duplicates):
                    return [(reference, 1.0)] + duplicates.filter { !selectedForDeletion.contains($0.path) }
                case .similar(let reference, let similars):
                    return [(reference, 1.0)] + similars.filter { !selectedForDeletion.contains($0.path) }
                }
            }()
            // Remove group if only reference remains
            if filtered.count <= 1 { return nil }
            switch result.type {
            case .duplicate(let reference, _):
                return ImageComparisonResult(type: .duplicate(reference: reference, duplicates: Array(filtered.dropFirst())))
            case .similar(let reference, _):
                return ImageComparisonResult(type: .similar(reference: reference, similars: Array(filtered.dropFirst())))
            }
        }
        selectedForDeletion.removeAll()
        selectAllActive = false
    }
}

