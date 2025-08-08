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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var topSplitView: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                controlsPanel
                    .frame(width: max(geometry.size.width * 0.3, 320))
                Divider()
                duplicateFoldersPanel
                    .frame(minWidth: 220)
                    .frame(width: geometry.size.width * 0.7)
                    .padding()
            }
        }
        .frame(minHeight: 320)
    }

    var controlsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button("Select Folders") { selectFolders() }
                    Button("Analyze") { vm.processImages(progress: { p in vm.processingProgress = p }) }
                        .disabled(vm.selectedFolderURLs.isEmpty)
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
                    Slider(value: $vm.similarityThreshold, in: 0.1...1.0)
                        .overlay(
                            HStack {
                                ForEach(Array(stride(from: 0.1, through: 1.0, by: 0.05)), id: \.self) { _ in
                                    Spacer()
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 1, height: 8)
                                    Spacer()
                                }
                            }
                        )

                    Text(String(format: "%.0f%%", vm.similarityThreshold * 100, sliderLabel(vm.similarityThreshold)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !selectedMatches.isEmpty {
                    Button(role: .destructive) {
                        vm.deleteSelectedMatches(selectedMatches: selectedMatches)
                    } label: {
                        Label("Delete Selected Matches (\(selectedMatches.count))", systemImage: "trash")
                    }
                }

                Divider()

                if vm.cachedFlattened.isEmpty {
                    Text("No matches yet.").foregroundStyle(.secondary)
                } else {
                    Text("Number of matches found: \(vm.cachedFlattened.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if vm.selectedFolderURLs.isEmpty {
                    Text("No folders selected.").foregroundStyle(.secondary)
                } else {
                    Text("Selected Folders:\n" + vm.foldersToScanLabel)
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

            if vm.cachedClusters.isEmpty {
                Text("No cross-folder duplicate relationships found.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(Array(vm.cachedClusters.enumerated()), id: \.offset) { index, cluster in
                        Section {
                            ForEach(cluster, id: \.self) { folder in
                                Button(action: { vm.openFolderInFinder(folder) }) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(folder)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Spacer()
                                        HStack(spacing: 8) {
                                            if let img = vm.folderThumbs[folder] {
                                                Image(nsImage: img)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 36, height: 36)
                                                    .clipped()
                                                    .cornerRadius(4)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 4)
                                                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                                                    )
                                            }
                                            Text("\(vm.cachedFolderDuplicateCount[folder, default: 0]) duplicates")
                                                .foregroundColor(.secondary)
                                                .font(.footnote)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(folder)
                            }
                        } header: {
                            HStack {
                                Text("Group \(index + 1)")
                                Spacer()
                                Text("\(cluster.count) folder\(cluster.count == 1 ? "" : "s")")
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
            // LEFT: table — flexible width, not fixed 50%
            Table(sortedRows, selection: $selectedRowID, sortOrder: $sortOrder) {
                TableColumn("") { row in
                    Toggle("", isOn: Binding(
                        get: { selectedRowIDs.contains(row.id) },
                        set: { isSelected in
                            if isSelected { selectedRowIDs.insert(row.id) }
                            else { selectedRowIDs.remove(row.id) }
                            toggleVersion += 1
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                }
                .width(30)

                TableColumn("Reference", value: \.reference) { row in
                    Text(row.reference)
                        .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                }

                TableColumn("Match", value: \.similar) { row in
                    Text(row.similar)
                        .foregroundStyle(isCrossFolder(row) ? .red : .primary)
                }

                TableColumn("Percent", value: \.percent) { row in
                    Text("\(Int(row.percent * 100))%")
                }
                .width(70)
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

            // RIGHT: preview — also flexible
            previewPanel
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1) // bias growth toward the preview when space increases
        }
        .frame(minHeight: 320)
    }

    var previewPanel: some View {
        VStack {
            if let row = selectedRow, !vm.cachedFlattened.isEmpty {
                GeometryReader { geo in
                    // Available width for two images, minus spacing & some padding
                    let spacing: CGFloat = 20
                    let inset: CGFloat = 16
                    let twoColumnWidth = max(0, geo.size.width - spacing - inset * 2)
                    let singleColumn = twoColumnWidth / 2

                    // Use the smaller of width/height so images fit in both axes
                    let maxDim = max(200, min(singleColumn, geo.size.height - 80)) // the -80 gives room for labels/buttons

                    HStack(alignment: .top, spacing: spacing) {
                        VStack(spacing: 8) {
                            Text("Reference")
                            PreviewImage(path: row.reference, maxDimension: maxDim)
                                .frame(width: maxDim, height: maxDim)
                                .clipped()
                            Button("Delete Reference") { vm.deleteFile(row.reference) }
                        }
                        VStack(spacing: 8) {
                            Text("Match")
                            PreviewImage(path: row.similar, maxDimension: maxDim)
                                .frame(width: maxDim, height: maxDim)
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
