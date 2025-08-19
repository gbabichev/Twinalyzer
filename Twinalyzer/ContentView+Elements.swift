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
    
    // Replace the duplicatesFolderPanel in ContentView+Elements.swift

    var duplicatesFolderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cross-Folder Duplicates")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if !vm.folderClusters.isEmpty {
                    Text("\(vm.folderClusters.count) relationship\(vm.folderClusters.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            
            if vm.folderClusters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    
                    Text("No cross-folder duplicate relationships found.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    
                    Text("Run an analysis to discover duplicates between different folders.")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let isCompact = geometry.size.height < 200
                    
                    List {
                        ForEach(Array(vm.folderClusters.enumerated()), id: \.offset) { i, cluster in
                            Section {
                                // Show all folders in the cluster as peers
                                ForEach(cluster.indices, id: \.self) { j in
                                    let folder = cluster[j]
                                    
                                    responsiveFolderRow(
                                        folder: folder,
                                        isCompact: isCompact,
                                        isReference: false // No special reference styling for simple pairs
                                    )
                                }
                            } header: {
                                HStack {
                                    Text("Group \(i + 1)")
                                        .font(isCompact ? .caption2 : .caption)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text("\(cluster.count) folder\(cluster.count == 1 ? "" : "s")")
                                        .foregroundStyle(.secondary)
                                        .font(isCompact ? .caption2 : .caption2)
                                }
                            }
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Update the responsiveFolderRow function to show reference vs match
    private func responsiveFolderRow(folder: String, isCompact: Bool, isReference: Bool = false) -> some View {
        Button(action: { vm.openFolderInFinder(folder) }) {
            HStack(alignment: .center, spacing: isCompact ? 4 : 8) {
                let url = URL(fileURLWithPath: folder)
                let displayName = DisplayHelpers.formatFolderDisplayName(for: url)
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.system(size: isCompact ? 11 : 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    // Remove the full path subtitle for cleaner look
                }
                
                Spacer(minLength: 0)
                
                HStack(spacing: isCompact ? 3 : 6) {
                    // Simple on-demand thumbnail (only in non-compact mode)
                    if !isCompact, let imagePath = vm.representativeImageByFolder[folder] {
                        PreviewImage(path: imagePath, maxDimension: 24)
                            .frame(width: 24, height: 24)
                            .clipped()
                            .cornerRadius(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                            )
                    }
                    
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(vm.crossFolderDuplicateCounts[folder, default: 0])")
                            .font(.system(size: isCompact ? 11 : 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !isCompact {
                            Text("dupes")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, isCompact ? 1 : 2)
        }
        .buttonStyle(.plain)
        .help("Folder: \(folder)")
    }
    
    // IMPROVED: Much more responsive preview panel
    var previewPanel: some View {
        GeometryReader { geometry in
            VStack {
                if let row = selectedRow, !vm.flattenedResults.isEmpty {
                    adaptivePreviewLayout(for: row, in: geometry.size)
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
    
    // IMPROVED: Adaptive preview layout based on available space
    @ViewBuilder
    private func adaptivePreviewLayout(for row: TableRow, in size: CGSize) -> some View {
        let isWide = size.width > size.height * 1.2
        let isVeryNarrow = size.width < 400
        let isVeryShort = size.height < 300
        
        if isVeryNarrow || isVeryShort {
            // Very constrained: Minimal layout
            compactPreviewLayout(for: row, in: size)
        } else if isWide {
            // Wide layout: Side by side
            horizontalPreviewLayout(for: row, in: size)
        } else {
            // Tall layout: Stacked vertically
            verticalPreviewLayout(for: row, in: size)
        }
    }
    
    // IMPROVED: Compact preview for very small spaces
    @ViewBuilder
    private func compactPreviewLayout(for row: TableRow, in size: CGSize) -> some View {
        VStack(spacing: 6) {
            Text("Reference vs Match")
                .font(.caption)
                .fontWeight(.medium)
            
            HStack(spacing: 8) {
                let imageSize = max(40, min(size.width / 2 - 20, size.height - 60, 120))
                
                VStack(spacing: 2) {
                    PreviewImage(path: row.reference, maxDimension: imageSize)
                        .frame(width: imageSize, height: imageSize)
                        .clipped()
                    
                    Button("Del Ref") { vm.deleteFile(row.reference) }
                        .font(.caption2)
                        .controlSize(.mini)
                }
                
                VStack(spacing: 2) {
                    PreviewImage(path: row.similar, maxDimension: imageSize)
                        .frame(width: imageSize, height: imageSize)
                        .clipped()
                    
                    Button("Del Match") { vm.deleteFile(row.similar) }
                        .font(.caption2)
                        .controlSize(.mini)
                }
            }
        }
        .padding(8)
    }
    
    // IMPROVED: Horizontal preview layout for wide spaces
    @ViewBuilder
    private func horizontalPreviewLayout(for row: TableRow, in size: CGSize) -> some View {
        let spacing: CGFloat = 20
        let inset: CGFloat = 16
        let twoColumnWidth = max(0, size.width - spacing - inset * 2)
        let singleColumn = twoColumnWidth / 2
        let maxDim = max(80, min(singleColumn - 40, size.height - 120, 400))
        
        HStack(alignment: .top, spacing: spacing) {
            VStack(spacing: 8) {
                Text("Reference")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(DisplayHelpers.shortDisplayPath(for: row.reference))
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                
                PreviewImage(path: row.reference, maxDimension: maxDim)
                    .frame(maxWidth: maxDim, maxHeight: maxDim)
                    .clipped()
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                
                Button("Delete Reference") {
                    vm.deleteFile(row.reference)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: max(100, singleColumn))
            
            VStack(spacing: 8) {
                Text("Match")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(DisplayHelpers.shortDisplayPath(for: row.similar))
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                
                PreviewImage(path: row.similar, maxDimension: maxDim)
                    .frame(maxWidth: maxDim, maxHeight: maxDim)
                    .clipped()
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(DisplayHelpers.isCrossFolder(row) ? Color.red.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: 1)
                    )
                
                Button("Delete Match") {
                    vm.deleteFile(row.similar)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: max(100, singleColumn))
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    // IMPROVED: Vertical preview layout for tall spaces
    @ViewBuilder
    private func verticalPreviewLayout(for row: TableRow, in size: CGSize) -> some View {
        let spacing: CGFloat = 16
        let inset: CGFloat = 12
        let availableHeight = size.height - inset * 2 - spacing - 120 // Account for labels and buttons
        let maxDim = max(60, min(size.width - inset * 2 - 40, availableHeight / 2, 300))
        
        VStack(spacing: spacing) {
            // Reference section
            VStack(spacing: 6) {
                Text("Reference")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(DisplayHelpers.shortDisplayPath(for: row.reference))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                PreviewImage(path: row.reference, maxDimension: maxDim)
                    .frame(maxWidth: maxDim, maxHeight: maxDim)
                    .clipped()
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                
                Button("Delete Reference") {
                    vm.deleteFile(row.reference)
                }
                .controlSize(.small)
            }
            
            // Match section
            VStack(spacing: 6) {
                Text("Match")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(DisplayHelpers.shortDisplayPath(for: row.similar))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                
                PreviewImage(path: row.similar, maxDimension: maxDim)
                    .frame(maxWidth: maxDim, maxHeight: maxDim)
                    .clipped()
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(DisplayHelpers.isCrossFolder(row) ? Color.red.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: 1)
                    )
                
                Button("Delete Match") {
                    vm.deleteFile(row.similar)
                }
                .controlSize(.small)
            }
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
