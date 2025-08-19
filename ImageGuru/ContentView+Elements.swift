import SwiftUI
import AppKit

extension ContentView {
    
    var processingView: some View {
        VStack(spacing: 16) {
            if let p = vm.processingProgress {
                ProgressView(value: p).frame(width: 320)
                Text(DisplayHelpers.formatProcessingProgress(p)).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 320)
                Text(DisplayHelpers.formatProcessingProgress(nil)).foregroundStyle(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Processing Folders...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if vm.allFoldersBeingProcessed.isEmpty {
                    Text("No folders selected.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(vm.allFoldersBeingProcessed, id: \.self) { url in
                                Text(DisplayHelpers.shortDisplayPath(for: url.path))
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    var controlsPanelPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            Text("Settings").font(.headline)
            Divider()
            
            Toggle("Limit scan to selected folders only", isOn: $vm.scanTopLevelOnly)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Analysis Method")
                        .font(.subheadline)
                    Button(action: {}) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Enhanced Scan: AI-based analysis that can detect similar content even with different crops or lighting.\n\nBasic Scan: Fast comparison using image fingerprints, good for exact duplicates.")
                }
                
                Picker("", selection: $vm.selectedAnalysisMode) {
                    ForEach(AnalysisMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            VStack {
                Text("Similarity Threshold")
                Slider(value: $vm.similarityThreshold, in: 0.45...1.0, step: 0.025)
                Text(DisplayHelpers.formatSimilarityThreshold(vm.similarityThreshold))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
    
    // CHANGED: Adjusted for detail column in vertical split
    var duplicatesFolderPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Duplicate Folder Groups")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if !vm.folderClusters.isEmpty {
                    Text("\(vm.folderClusters.count) group\(vm.folderClusters.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)
            
            if vm.folderClusters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    
                    Text("No cross-folder duplicate relationships found.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    
                    Text("Run an analysis to discover duplicate groups.")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(vm.folderClusters.indices, id: \.self) { i in
                        Section {
                            ForEach(vm.folderClusters[i], id: \.self) { folder in
                                Button(action: { vm.openFolderInFinder(folder) }) {
                                    HStack(alignment: .center, spacing: 8) {
                                        let url = URL(fileURLWithPath: folder)
                                        
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(DisplayHelpers.formatFolderDisplayName(for: url))
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            
                                            Text(folder)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 6) {
                                            // Simple on-demand thumbnail
                                            if let imagePath = vm.representativeImageByFolder[folder] {
                                                PreviewImage(path: imagePath, maxDimension: 32)
                                                    .frame(width: 32, height: 32)
                                                    .clipped()
                                                    .cornerRadius(4)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 4)
                                                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                                                    )
                                            }
                                            
                                            VStack(alignment: .trailing, spacing: 1) {
                                                Text("\(vm.folderDuplicateCounts[folder, default: 0])")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(.primary)
                                                Text("dupes")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .buttonStyle(.plain)
                                .help(folder)
                            }
                        } header: {
                            HStack {
                                Text("Group \(i + 1)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(vm.folderClusters[i].count) folder\(vm.folderClusters[i].count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary)
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    var previewPanel: some View {
        VStack {
            if let row = selectedRow, !vm.flattenedResults.isEmpty {
                GeometryReader { geo in
                    let spacing: CGFloat = 20
                    let inset: CGFloat = 16
                    let twoColumnWidth = max(0, geo.size.width - spacing - inset * 2)
                    let singleColumn = twoColumnWidth / 2
                    let maxDim = min(singleColumn, geo.size.height - 120)
                    
                    HStack(alignment: .top, spacing: spacing) {
                        VStack(spacing: 8) {
                            Text("Reference")
                            Text(DisplayHelpers.shortDisplayPath(for: row.reference))
                            PreviewImage(path: row.reference, maxDimension: maxDim)
                                .clipped()
                            Button("Delete Reference") { vm.deleteFile(row.reference) }
                        }
                        VStack(spacing: 8) {
                            Text("Match")
                            Text(DisplayHelpers.shortDisplayPath(for: row.similar))
                                .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                            PreviewImage(path: row.similar, maxDimension: maxDim)
                                .clipped()
                            Button("Delete Match") { vm.deleteFile(row.similar) }
                        }
                    }
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            } else {
                VStack(spacing: 8) {
                    // CHANGED: Show selection count when multiple items selected
                    if deletionSelection.count > 1 {
                        Text("\(deletionSelection.count) matches selected")
                            .foregroundStyle(.secondary)
                        Text("Press Delete or use toolbar button to delete selected matches")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    } else {
                        Text(vm.comparisonResults.isEmpty ? "Run an analysis to see results here." : "Select a row to preview")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
