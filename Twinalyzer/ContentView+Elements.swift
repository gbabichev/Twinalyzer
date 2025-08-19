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
                List {
                    ForEach(Array(vm.folderClusters.enumerated()), id: \.offset) { i, cluster in
                        Section {
                            ForEach(cluster.indices, id: \.self) { j in
                                let folder = cluster[j]
                                folderRow(folder: folder)
                            }
                        } header: {
                            HStack {
                                Text("Group \(i + 1)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(cluster.count) folder\(cluster.count == 1 ? "" : "s")")
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

    private func folderRow(folder: String) -> some View {
        Button(action: { vm.openFolderInFinder(folder) }) {
            HStack(alignment: .center, spacing: 8) {
                let url = URL(fileURLWithPath: folder)
                let displayName = DisplayHelpers.formatFolderDisplayName(for: url)
                
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer(minLength: 0)
                
                HStack(spacing: 6) {
                    // Simple thumbnail
                    if let imagePath = vm.representativeImageByFolder[folder] {
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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("dupes")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help("Folder: \(folder)")
    }
    
    var previewPanel: some View {
        GeometryReader { geometry in
            VStack {
                if let row = selectedRow, !vm.flattenedResults.isEmpty {
                    previewLayout(for: row, in: geometry.size)
                } else {
                    VStack(spacing: 8) {
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
    
    @ViewBuilder
    private func previewLayout(for row: TableRow, in size: CGSize) -> some View {
        let spacing: CGFloat = 20
        let inset: CGFloat = 16
        let twoColumnWidth = max(0, size.width - spacing - inset * 2)
        let singleColumn = twoColumnWidth / 2
        let maxDim = max(80, min(singleColumn - 40, size.height - 120, 400))
        
        HStack(alignment: .top, spacing: spacing) {
            // Reference side
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
                .disabled(vm.isProcessing)
            }
            .frame(maxWidth: max(100, singleColumn))
            
            // Match side
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
                .disabled(vm.isProcessing)
            }
            .frame(maxWidth: max(100, singleColumn))
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    var selectedMatchPaths: [String] {
        let selectedRows = sortedRows.filter { deletionSelection.contains($0.id) }
        return selectedRows.map { $0.similar } // Only delete the matched photos, not references
    }
        
    var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Selected Folders")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top)
            
            if !vm.discoveredLeafFolders.isEmpty {
                List {
                    ForEach(vm.activeLeafFolders, id: \.self) { leafURL in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(leafURL.lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                
                                Text(leafURL.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            
                            Spacer(minLength: 4)
                            
                            if !vm.isProcessing {
                                Button {
                                    vm.removeLeafFolder(leafURL)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red.opacity(0.7))
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .help("Remove this folder")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.sidebar)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    
                    Text("Drop parent folders here to discover image folders.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Open Folder") {
                        selectFolders()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Folders")
        .frame(minWidth: 250, idealWidth: 300)
    }
    
    var tableView: some View {
        Table(sortedRows, selection: $tableSelection, sortOrder: $sortOrder) {
            TableColumn("Reference", value: \.reference) { row in
                HStack(spacing: 8) {
                    // Clickable deletion selection checkbox
                    Button(action: {
                        if deletionSelection.contains(row.id) {
                            deletionSelection.remove(row.id)
                        } else {
                            deletionSelection.insert(row.id)
                        }
                    }) {
                        Image(systemName: deletionSelection.contains(row.id) ? "checkmark.square.fill" : "square")
                            .foregroundColor(deletionSelection.contains(row.id) ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20)
                    
                    Text(DisplayHelpers.shortDisplayPath(for: row.reference))
                        .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 250)
            
            TableColumn("Match", value: \.similar) { row in
                Text(DisplayHelpers.shortDisplayPath(for: row.similar))
                    .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 200, ideal: 250)
            
            TableColumn("Similarity", value: \.percentSortKey) { row in
                Text(row.percentDisplay)
                    .font(.system(.body, design: .monospaced))
            }
            .width(80)
        }
        .tableStyle(.automatic)
        .navigationTitle("Results")
    }
    
    var detailSplitView: some View {
        VSplitView {
            duplicatesFolderPanel
                .frame(minHeight: 150, idealHeight: 200)
            
            previewPanel
                .frame(minHeight: 200)
        }
    }
    
}
