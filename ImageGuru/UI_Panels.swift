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
            
            Button("Cancel") {
                vm.cancelAnalysis()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!vm.isProcessing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var topSplitView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                controlsPanel
                    .frame(width: 520)
                Divider()
                duplicateFoldersPanel
                    .frame(minWidth: 220)
                    .padding()
            }
        }
        .frame(minHeight: 320)
    }

    var controlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Button("Select Folders") { selectFolders() }
                        .frame(maxWidth: .infinity, minHeight: 44)

                    Button("Analyze") {
                        vm.processImages(progress: { _ in })  // Simplified progress callback
                    }
                    .disabled(vm.selectedFolderURLs.isEmpty)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.borderedProminent)
                }

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

                Divider()

                if vm.flattenedResults.isEmpty {  // Changed from vm.cachedFlattened
                    Text("No matches yet.").foregroundStyle(.secondary)
                } else {
                    Text("Number of matches found: \(vm.flattenedResults.count)")  // Changed from vm.cachedFlattened
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if vm.selectedFolderURLs.isEmpty {
                    Text("No folders selected.").foregroundStyle(.secondary)
                } else {
                    Text("Selected Folders:\n" + vm.foldersToScanLabel)  // Now computed property
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
                                            // Removed thumbnail loading for now - can add simple on-demand loading later
                                            Text("\(vm.folderDuplicateCounts[folder, default: 0]) duplicates")  // Changed from vm.cachedFolderDuplicateCount
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
