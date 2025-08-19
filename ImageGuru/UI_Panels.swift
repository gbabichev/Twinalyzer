import SwiftUI
import AppKit

extension ContentView {

    var processingView: some View {
        VStack(spacing: 16) {
            if let p = vm.processingProgress {
                ProgressView(value: p).frame(width: 320)
                Text("\(Int(p * 100))%").foregroundStyle(.secondary)
            } else {
                ProgressView().frame(width: 320)
                Text("Preparing…").foregroundStyle(.secondary)
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
                                Text(shortDisplayPath(for: url.path))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                Toggle("Limit scan to selected folders only", isOn: $vm.scanTopLevelOnly)

                Picker("", selection: $vm.selectedAnalysisMode) {
                    ForEach(AnalysisMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                
                VStack {
                    Text("Similarity Threshold")
                    Slider(value: $vm.similarityThreshold, in: 0.45...1.0, step: 0.025)
                    Text(String(format: "%.0f%%", vm.similarityThreshold * 100))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !selectedMatches.isEmpty {
                    Button(role: .destructive) {
                        vm.deleteSelectedMatches(selectedMatches: selectedMatches)
                    } label: {
                        Label("Delete Selected Matches (\(selectedMatches.count))", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    
    var selectedFoldersPanel: some View {
        VStack {
            if !sortedLeafFolders.isEmpty {
                Table(sortedLeafFolders, selection: $selectedLeafIDs, sortOrder: $leafSortOrder) {
                    TableColumn("Folder Name", value: \.displayName) { leaf in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leaf.url.lastPathComponent)
                                .font(.system(size: 13, weight: .medium))
                            Text(leaf.url.path)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .width(min: 200, ideal: 350)
                    
                    TableColumn("Actions") { leaf in
                        HStack {
                            if !vm.isProcessing {
                                Button {
                                    removeLeaf(leaf)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red.opacity(0.7))
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .help("Remove this folder")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .width(60)
                }
                .frame(minHeight: 150, maxHeight: 300)
                .contextMenu(forSelectionType: UUID.self) { selectedIDs in
                    if !selectedIDs.isEmpty && !vm.isProcessing {
                        Button("Remove Selected (\(selectedIDs.count))") {
                            removeLeafs(withIDs: selectedIDs)
                        }
                        
                        Divider()
                        
                        Button("Select All") {
                            selectedLeafIDs = Set(sortedLeafFolders.map(\.id))
                        }
                        .disabled(selectedLeafIDs.count == sortedLeafFolders.count)
                        
                        Button("Deselect All") {
                            selectedLeafIDs.removeAll()
                        }
                        .disabled(selectedLeafIDs.isEmpty)
                    } else if !vm.isProcessing {
                        Button("Select All") {
                            selectedLeafIDs = Set(sortedLeafFolders.map(\.id))
                        }
                    }
                }
                .onDeleteCommand {
                    if !selectedLeafIDs.isEmpty && !vm.isProcessing {
                        removeSelectedLeafs()
                    }
                }
            } else {
                Text("Select folders to scan.")
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    
    
    var duplicateFoldersPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Duplicate Folder Groups").font(.headline)

            if vm.folderClusters.isEmpty {  // Changed from vm.cachedClusters
                Text("No cross-folder duplicate relationships found.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(vm.folderClusters.indices, id: \.self) { i in  // Changed from vm.cachedClusters
                        Section {
                            ForEach(vm.folderClusters[i], id: \.self) { folder in  // Changed from vm.cachedClusters
                                Button(action: { vm.openFolderInFinder(folder) }) {
                                    HStack(alignment: .center, spacing: 12) {
                                        let url = URL(fileURLWithPath: folder)
                                        let name = url.lastPathComponent
                                        let parent = url.deletingLastPathComponent().lastPathComponent
                                        Text(parent.isEmpty ? name : "\(parent)/\(name)")
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
                                Text("\(vm.folderClusters[i].count) folder\(vm.folderClusters[i].count == 1 ? "" : "s")")  // Changed from vm.cachedClusters
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
            // LEFT: table
            Table(sortedRows, selection: $selectedRowID, sortOrder: $sortOrder) {
                TableColumn("Reference", value: \.reference) { row in
                    Text(shortDisplayPath(for: row.reference))
                        .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                }

                TableColumn("Match", value: \.similar) { row in
                    Text(shortDisplayPath(for: row.similar))
                        .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                }

                TableColumn("Percent", value: \.percentSortKey) { row in
                    Text(row.percentDisplay)
                }
                .width(70)
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            // RIGHT: preview
            previewPanel
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
    }

    var previewPanel: some View {
        VStack {
            if let row = selectedRow, !vm.flattenedResults.isEmpty {  // Changed from vm.cachedFlattened
                GeometryReader { geo in
                    let spacing: CGFloat = 20
                    let inset: CGFloat = 16
                    let twoColumnWidth = max(0, geo.size.width - spacing - inset * 2)
                    let singleColumn = twoColumnWidth / 2
                    let maxDim = min(singleColumn, geo.size.height - 120)

                    HStack(alignment: .top, spacing: spacing) {
                        VStack(spacing: 8) {
                            Text("Reference")
                            Text(shortDisplayPath(for: row.reference))
                            PreviewImage(path: row.reference, maxDimension: maxDim)
                                .clipped()
                            Button("Delete Reference") { vm.deleteFile(row.reference) }
                        }
                        VStack(spacing: 8) {
                            Text("Match")
                            Text(shortDisplayPath(for: row.similar))
                                .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                            PreviewImage(path: row.similar, maxDimension: maxDim)
                                .clipped()
                            Button("Delete Match") { vm.deleteFile(row.similar) }
                        }
                    }
                    .padding(inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                VStack(spacing: 8) {
                    Text(vm.comparisonResults.isEmpty ? "Run an analysis to see results here." : "Select a row to preview")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension TableRow {
    var percentInt: Int { Int((percent * 100).rounded()) }
    var percentSortKey: String { String(format: "%03d", percentInt) }
    var percentDisplay: String { "\(percentInt)%" }
}
