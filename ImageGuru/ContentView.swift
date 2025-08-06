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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("ImageGuru: Duplicate & Similar Photo Finder")
                .font(.title)
                .padding(.bottom, 10)

            Button("Select Folders of Images") {
                selectFolders()
            }
            .help("Choose folders containing images to analyze")
            .padding(.bottom, 2)

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

            if comparisonResults.isEmpty {
                Text("No duplicate or similar images detected yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(comparisonResults) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        switch result.type {
                        case .duplicate(let reference, let duplicates):
                            Text("Duplicate:").bold()
                            // Show the reference image first, labeled
                            HStack(alignment: .center, spacing: 10) {
                                Image(nsImage: ImageAnalyzer.loadThumbnail(for: reference))
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 48, height: 48)
                                    .cornerRadius(6)
                                Text("Reference: \(reference)")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            // Now show the duplicates, labeled
                            ForEach(duplicates, id: \.path) { dup in
                                HStack(alignment: .center, spacing: 10) {
                                    Image(nsImage: ImageAnalyzer.loadThumbnail(for: dup.path))
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 48, height: 48)
                                        .cornerRadius(6)
                                    Text("Duplicate: \(dup.path) (\(String(format: "%.0f", dup.percent * 100))% match)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }
                            }
                        case .similar(let imagePaths):
                            Text("Similar:").bold()
                            ForEach(imagePaths, id: \.self) { path in
                                HStack(alignment: .center, spacing: 10) {
                                    Image(nsImage: ImageAnalyzer.loadThumbnail(for: path))
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 48, height: 48)
                                        .cornerRadius(6)
                                    Text(path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.middle)
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
            selectedFolderURLs = panel.urls
            comparisonResults = []
        }
    }

    private func processImages() {
        guard !selectedFolderURLs.isEmpty else { return }
        isProcessing = true
        comparisonResults = []
        ImageAnalyzer.analyzeImages(inFolders: selectedFolderURLs, similarityThreshold: similarityThreshold) { results in
            self.comparisonResults = results
            self.isProcessing = false
        }
    }
}
