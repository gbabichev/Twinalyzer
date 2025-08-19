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
    
    var topSplitView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                selectedFoldersPanel
                    .frame(width: 520)
                Divider()
                duplicateFoldersPanel
                    .frame(minWidth: 220)
                    .padding()
            }
        }
        .frame(minHeight: 320)
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
    
    var selectedFoldersPanel: some View {
        VStack {
            if !vm.discoveredLeafFolders.isEmpty {
                List {
                    ForEach(vm.activeLeafFolders, id: \.self) { leafURL in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(leafURL.lastPathComponent)
                                    .font(.system(size: 13, weight: .medium))
                                
                                Text(leafURL.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            
                            Spacer()
                            
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
                .frame(minHeight: 150, maxHeight: 300)
            } else {
                Text("Drop parent folders here to discover image folders.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
    
    var duplicateFoldersPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duplicate Folder Groups").font(.headline)
            
            if vm.folderClusters.isEmpty {
                Text("No cross-folder duplicate relationships found.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(vm.folderClusters.indices, id: \.self) { i in
                        Section {
                            ForEach(vm.folderClusters[i], id: \.self) { folder in
                                Button(action: { vm.openFolderInFinder(folder) }) {
                                    HStack(alignment: .center, spacing: 12) {
                                        let url = URL(fileURLWithPath: folder)
                                        Text(DisplayHelpers.formatFolderDisplayName(for: url))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        
                                        Spacer(minLength: 12)
                                        
                                        HStack(spacing: 8) {
                                            // Simple on-demand thumbnail
                                            if let imagePath = vm.representativeImageByFolder[folder] {
                                                PreviewImage(path: imagePath, maxDimension: 36)
                                                    .frame(width: 36, height: 36)
                                                    .clipped()
                                                    .cornerRadius(4)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 4)
                                                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                                                    )
                                            }
                                            Text("\(vm.folderDuplicateCounts[folder, default: 0]) duplicates")
                                                .foregroundStyle(.secondary)
                                                .font(.footnote)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(folder)
                            }
                        } header: {
                            HStack {
                                Text("Group \(i + 1)")
                                Spacer()
                                Text("\(vm.folderClusters[i].count) folder\(vm.folderClusters[i].count == 1 ? "" : "s")")
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
        HSplitView {
            // LEFT: table - Native navigation, separate deletion selection
            Table(sortedRows, selection: $tableSelection, sortOrder: $sortOrder) {
                TableColumn("Reference", value: \.reference) { row in
                    HStack {
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
                        
                        Text(DisplayHelpers.shortDisplayPath(for: row.reference))
                            .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                    }
                }
                
                TableColumn("Match", value: \.similar) { row in
                    Text(DisplayHelpers.shortDisplayPath(for: row.similar))
                        .foregroundStyle(DisplayHelpers.isCrossFolder(row) ? .red : .primary)
                }
                
                TableColumn("Percent", value: \.percentSortKey) { row in
                    Text(row.percentDisplay)
                }
                .width(70)
            }
            .tableStyle(.automatic)
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            
            // RIGHT: preview
            previewPanel
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
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
