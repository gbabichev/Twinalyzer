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
                    Slider(value: $vm.similarityThreshold, in: 0.1...1.0, step: 0.1)
                    Text(String(format: "%.0f%% (%@)", vm.similarityThreshold * 100, sliderLabel(vm.similarityThreshold)))
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
        GeometryReader { geometry in
            HSplitView {
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
                .frame(width: geometry.size.width * 0.5)

                previewPanel
            }
        }
        .frame(minHeight: 320)
    }

var previewPanel: some View {
        VStack {
            if let row = selectedRow, !vm.cachedFlattened.isEmpty {
                GeometryReader { geo in
                    let maxDim = max(300, min(max(geo.size.width, geo.size.height), 1600))
                    HStack(alignment: .top, spacing: 20) {
                        VStack {
                            Text("Reference")
                            PreviewImage(path: row.reference, maxDimension: maxDim)
                            Button("Delete Reference") { vm.deleteFile(row.reference) }
                        }
                        VStack {
                            Text("Match")
                            PreviewImage(path: row.similar, maxDimension: maxDim)
                            Button("Delete Match") { vm.deleteFile(row.similar) }
                        }
                    }
                }
            } else {
                ZStack {
                    VStack(spacing: 8) {
                        Text(vm.comparisonResults.isEmpty ? "Run an analysis to see results here." : "Select a row to preview")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

// moved to AppViewModel


// moved to AppViewModel


    func toggleSelectedRow() {
        guard let id = selectedRowID else { return }
        if selectedRowIDs.contains(id) {
            selectedRowIDs.remove(id)
        } else {
            selectedRowIDs.insert(id)
        }
    }

    // MARK: - UI helpers still owned by the view

    func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select Folders of Images"

        if panel.runModal() == .OK {
            vm.selectedFolderURLs = panel.urls
            let leafs = findLeafFolders(from: panel.urls)
            vm.foldersToScanLabel = leafs.map { $0.lastPathComponent }.joined(separator: "\n")
            vm.recomputeDerived()
            vm.preloadAllFolderThumbnails()
        }
    }

    /// Formats the similarity slider’s value as a percent label.
    func sliderLabel(_ value: Double) -> String {
        "\(Int(round(value * 100)))%"
    }

    /// Returns true if the match is across different folders (used to tint cross‑folder rows).
    func isCrossFolder(_ row: TableRow) -> Bool {
        let refFolder = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
        let simFolder = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
        return refFolder != simFolder
    }

    func installSpacebarToggle() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 49 = spacebar
            if event.keyCode == 49 {
                toggleSelectedRow()
                return nil // swallow the event so it doesn't scroll the view
            }
            return event
        }
    }
}
