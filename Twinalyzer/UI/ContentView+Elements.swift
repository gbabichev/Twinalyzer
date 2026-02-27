/*
 
 ContentView+Elements.swift - Streamlined
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import QuickLookUI

extension ContentView {
    
    // MARK: - Quick Look Support
    final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        static let shared = QuickLookPreview()
        private var items: [NSURL] = []
        
        func show(urls: [URL]) {
            items = urls.map { $0 as NSURL }
            guard let panel = QLPreviewPanel.shared() else { return }
            panel.dataSource = self
            panel.delegate  = self
            if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
        
        // QLPreviewPanelDataSource
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { items[index] }
    }
    
    @MainActor
    private func openInQuickLook(at path: String) {
        // If we know the currently selected row, provide both images to Quick Look
        // so the user can use arrow keys to move between them.
        if let row = selectedRow {
            let refURL = URL(fileURLWithPath: row.reference)
            let matchURL = URL(fileURLWithPath: row.similar)
            let fm = FileManager.default
            let hasRef = fm.fileExists(atPath: refURL.path)
            let hasMatch = fm.fileExists(atPath: matchURL.path)
            var urls: [URL] = []

            if path == refURL.path {
                if hasRef { urls.append(refURL) }
                if hasMatch { urls.append(matchURL) }
            } else if path == matchURL.path {
                if hasMatch { urls.append(matchURL) }
                if hasRef { urls.append(refURL) }
            } else {
                // Fallback if the path doesn't match the current row (shouldn't happen)
                if fm.fileExists(atPath: path) { urls = [URL(fileURLWithPath: path)] }
            }

            guard !urls.isEmpty else { return }
            QuickLookPreview.shared.show(urls: urls)
            return
        }

        // Fallback: just preview the single item
        guard FileManager.default.fileExists(atPath: path) else { return }
        QuickLookPreview.shared.show(urls: [URL(fileURLWithPath: path)])
    }
    
    // MARK: - Processing View
    var processingView: some View {
        VStack(spacing: 16) {
            if vm.isDiscoveringFolders {
                ProgressView()
                    .frame(width: columnWidth)
                Text("Discovering folders...")
                    .foregroundStyle(.secondary)
            } else if vm.isProcessing {
                if let p = vm.processingProgress {
                    ProgressView(value: p)
                        .frame(width: columnWidth)
                    Text(DisplayHelpers.formatProcessingProgress(p))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .frame(width: columnWidth)
                    Text("Preparing analysis...")
                        .foregroundStyle(.secondary)
                }
            }
            
            processingFolderList
                .frame(width: columnWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    var processingFolderList: some View {
        VStack(spacing: 6) {
            Text(vm.isDiscoveringFolders ? "Scanning Parent Folders..." : "Processing Folders...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            
            Text("💡 99% takes a while sometimes... don't be alarmed by the beachball!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            
            if vm.allFoldersBeingProcessed.isEmpty {
                Text("No folders selected.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 6) {
                        // Top chevron — only when not at top
                        if !atTop {
                            Button {
                                withAnimation(.easeInOut) { proxy.scrollTo("topSentinel", anchor: .top) }
                            } label: {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .center, spacing: 2) {
                                // Top sentinel flips atTop as you scroll away/return
                                Color.clear
                                    .frame(height: 1)
                                    .id("topSentinel")
                                    .onAppear { atTop = true }
                                    .onDisappear { atTop = false }
                                
                                ForEach(Array(vm.allFoldersBeingProcessed.enumerated()), id: \.offset) { _, url in
                                    Text(DisplayHelpers.shortDisplayPath(for: url.path))
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                                
                                // Bottom sentinel flips atBottom at end
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottomSentinel")
                                    .onAppear { atBottom = true }
                                    .onDisappear { atBottom = false }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(width: columnWidth, height: viewportHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        
                        // Bottom chevron — only when not at bottom
                        if !atBottom {
                            Button {
                                withAnimation(.easeInOut) { proxy.scrollTo("bottomSentinel", anchor: .bottom) }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
    
    // MARK: - Sidebar Content
    var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !vm.discoveredLeafFolders.isEmpty {
                SidebarHoverList(vm: vm)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    
                    Text("Drop folders here to start!")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Open Folder") {
                        selectFolders()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Folders")
        .frame(minWidth: 250, idealWidth: 300)
    }
    
    // MARK: - Detail Split View
    var detailSplitView: some View {
        VSplitView {
            previewPanel
                .frame(minHeight: 200)
            
            duplicatesFolderPanel
        }
    }
    
    // MARK: - Cross-Folder Duplicates Panel
    var duplicatesFolderPanel: some View {
        DuplicatesFolderPanel(vm: vm)
    }

private struct DuplicatesFolderPanel: View {
    @ObservedObject var vm: AppViewModel
    @State private var isMinimized: Bool = false

    var body: some View {
        // Use a VStack that can collapse its content while keeping a small header visible
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Cross-Folder Duplicates")
                    .font(.headline).fontWeight(.semibold)
                Spacer()
                if !vm.orderedCrossFolderPairsStatic.isEmpty && !isMinimized {
                    Text("\(vm.orderedCrossFolderPairsStatic.count) relationship\(vm.orderedCrossFolderPairsStatic.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                Button(action: { withAnimation(.easeInOut) { isMinimized.toggle() } }) {
                    Image(systemName: isMinimized ? "chevron.up" : "chevron.down")
                        .padding(.trailing, 10)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(isMinimized ? "Expand" : "Minimize")
                }
                .buttonStyle(.plain)
                .help(isMinimized ? "Expand" : "Minimize")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            // Content (collapsible)
            Group {
                let pairs = vm.orderedCrossFolderPairsStatic
                if isMinimized {
                    // Empty, but keep a thin spacer to avoid zero-height flicker
                    Spacer(minLength: 0)
                } else {
                    if pairs.isEmpty {
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
                        .padding(.vertical, 8)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(pairs) { pair in
                                    VStack(alignment: .leading, spacing: 2) {
                                        // Reference row
                                        HStack {
                                            Button {
                                                vm.openFolderInFinder(pair.reference)
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "folder")
                                                        .foregroundStyle(.secondary)
                                                    Text(vm.folderDisplayNamesStatic[pair.reference] ?? pair.reference)
                                                        .font(.system(size: 13, weight: .medium))
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .help("Open in Finder")

                                            Spacer(minLength: 8)

                                            // Optional strength badge
                                            Text("×\(pair.count)")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.tertiary)
                                        }

                                        // Match row (indented)
                                        HStack {
                                            Button {
                                                vm.openFolderInFinder(pair.match)
                                            } label: {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "folder")
                                                        .foregroundStyle(.secondary)
                                                    Text(vm.folderDisplayNamesStatic[pair.match] ?? pair.match)
                                                        .font(.system(size: 12))
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                        .truncationMode(.middle)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .help("Open in Finder")
                                        }
                                        .padding(.leading, 16)
                                    }
                                    Divider()
                                        .contentShape(Rectangle())
                                        .padding(.vertical, 2)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .transaction { $0.disablesAnimations = true }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: isMinimized ? 0 : .infinity)
            .clipped()
        }
        // When minimized, suggest a compact height to the split view
        .frame(minHeight: isMinimized ? 32 : 150, idealHeight: isMinimized ? 36 : 200)
        .animation(.easeInOut(duration: 0.2), value: isMinimized)
    }
}
    
    // MARK: - Preview Panel
    var previewPanel: some View {
        GeometryReader { geometry in
            VStack {
                if let row = selectedRow, !vm.tableRows.isEmpty {
                    renderPreview(for: row, size: geometry.size)
                    Text("💡 Tip: Click a preview image to open in Preview. Click the path name to open the folder.")
                        .font(.footnote)
                        .padding(.bottom, 10)
                } else {
                    VStack(spacing: 8) {
                        let pendingCount = vm.selectedMatchesForDeletion.count + vm.selectedReferencesForDeletion.count
                        if pendingCount > 0 {
                            Text("\(pendingCount) item\(pendingCount == 1 ? "" : "s") selected")
                                .foregroundStyle(.secondary)
                            Text("Press Delete or use toolbar button to apply pending deletions")
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
    
    // MARK: - Preview Image Content
    func renderPreview(for row: TableRow, size: CGSize) -> some View {
        // Calculate layout dimensions based on available space
        let spacing: CGFloat = 20
        let inset: CGFloat = 16
        let twoColumnWidth = max(0, size.width - spacing - inset * 2)
        let singleColumn = twoColumnWidth / 2
        let maxDim = max(80, min(singleColumn - 40, size.height - 120))
        let refDir = URL(fileURLWithPath: row.reference).deletingLastPathComponent().path
        let matchDir = URL(fileURLWithPath: row.similar).deletingLastPathComponent().path
        let referenceMarkedForDeletion = vm.selectedReferencesForDeletion.contains(row.id)
        let matchMarkedForDeletion = vm.selectedMatchesForDeletion.contains(row.id)
        
        return HStack(alignment: .top, spacing: spacing) {
            // Left side: Reference image
            VStack(spacing: 8) {
                Text("Reference" + (referenceMarkedForDeletion ? " (to delete)" : ""))
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 4) {
                    Button {
                        vm.openFolderInFinder(refDir)
                    } label: {
                        Label {
                            Text(row.referenceShort)
                                .font(.caption)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.center)
                                .underline()
                        } icon: {
                            Image(systemName: "folder")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Reveal containing folder in Finder")
                }

                Button {
                    openInQuickLook(at: row.reference)
                } label: {
                    PreviewImage(path: row.reference, maxDimension: maxDim)
                        .frame(maxWidth: maxDim, maxHeight: maxDim)
                        .clipped()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Preview")

                Button("Mark Reference for Deletion") {
                    vm.selectReferenceDeletionSelection(forRowID: row.id)
                    tableSelection = Set([row.id])
                }
                .help("Mark this reference image for deletion; you can batch delete later")
                .controlSize(.small)
                .disabled(vm.isProcessing)

                Button("Delete Reference Folder") {
                    vm.deleteFolder(refDir)
                }
                .help("Delete reference folder")
                .controlSize(.small)
                .tint(.red)
                .disabled(vm.isProcessing)
            }
            .frame(maxWidth: max(100, singleColumn))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(referenceMarkedForDeletion ? Color.red.opacity(0.14) : Color.clear)
            )

            // Right side: Match image
            VStack(spacing: 8) {
                Text("Match" + (matchMarkedForDeletion ? " (to delete)" : ""))
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                HStack(spacing: 4) {
                    Button {
                        vm.openFolderInFinder(matchDir)
                    } label: {
                        Label {
                            Text(row.similarShort)
                                .font(.caption)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(row.isCrossFolder ? .red : .black)
                                .underline()
                        } icon: {
                            Image(systemName: "folder")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Reveal containing folder in Finder")
                }

                Button {
                    openInQuickLook(at: row.similar)
                } label: {
                    PreviewImage(path: row.similar, maxDimension: maxDim)
                        .frame(maxWidth: maxDim, maxHeight: maxDim)
                        .clipped()
                        .contentShape(Rectangle())
                        .overlay(alignment: .topLeading) {
                            // Non-interactive badge so clicks still trigger Quick Look
                            Text(row.percentDisplay) // e.g. “97.2%”
                                .font(.caption2).fontDesign(.monospaced)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                                .shadow(radius: 1.5, y: 0.5)
                                .padding(6)
                                .allowsHitTesting(false)
                        }
                }
                .buttonStyle(.plain)
                .help("Open in Preview")

                Button("Mark Match for Deletion") {
                    vm.selectedMatchesForDeletion.insert(row.id)
                    tableSelection = Set([row.id])
                }
                .help("Mark this match image for deletion; you can batch delete later")
                .controlSize(.small)
                .disabled(vm.isProcessing)

                Button("Delete Match Folder") {
                    vm.deleteFolder(matchDir)
                }
                .help("Delete match folder")
                .controlSize(.small)
                .tint(.red)
                .disabled(vm.isProcessing)
            }
            .frame(maxWidth: max(100, singleColumn))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(matchMarkedForDeletion ? Color.red.opacity(0.14) : Color.clear)
            )
        }
        .padding(inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
    
    // MARK: - Results Table Panel
    var macOS15Padding: CGFloat {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 ? 1 : 0
    }
    
    var tableView: some View {
        Table(displayedRows, selection: $tableSelection, sortOrder: $sortOrder) {
            
            // Row index column (narrow)
            TableColumn("#") { row in
                if let idx = displayedRows.firstIndex(where: { $0.id == row.id }) {
                    Text("\(idx + 1)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    Text("")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .width(36)
                        
            
            // Reference column with deletion checkbox
            TableColumn("Reference", value: \.referenceShortLower) { row in
                let crossedRef = vm.selectedReferencesForDeletion.contains(row.id)
                HStack(spacing: 8) {
                    // Deletion checkbox
                    Button(action: { toggleRowDeletion(row.id) }) {
                        Image(systemName: vm.selectedReferencesForDeletion.contains(row.id) ? "checkmark.square.fill" : "square")
                            .foregroundColor(vm.selectedReferencesForDeletion.contains(row.id) ? .blue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20)
                    
                    // Reference path
                    Text(row.referenceShort)
                        .foregroundStyle(row.isCrossFolder ? .red : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .strikethrough(crossedRef)
                        .opacity(crossedRef ? 0.4 : 1.0)
                }
            }
            .width(min: 200, ideal: 250)
            
            // Match column
            TableColumn("Match", value: \.similarShortLower) { row in
                let crossedMatch = vm.selectedMatchesForDeletion.contains(row.id)
                Text(row.similarShort)
                    .foregroundStyle(row.isCrossFolder ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(crossedMatch)
                    .opacity(crossedMatch ? 0.4 : 1.0)
            }
            .width(min: 200, ideal: 250)
            
            // Cross-folder indicator column
            TableColumn("Cross-Folder", value: \.crossFolderText) { row in
                Text(row.crossFolderText)
                    .foregroundStyle(row.isCrossFolder ? .red : .secondary)
                    .font(.system(.body, design: .monospaced))
            }
            .width(90)
            
            // Similarity percentage column
            TableColumn("Similarity", value: \.percent) { row in
                Text(row.percentDisplay)
                    .font(.system(.body, design: .monospaced))
            }
            .width(80)
        }
        .navigationTitle("Results (\(displayedRows.count))")
        .focused($isTableFocused)
        .id(vm.tableReloadToken)
        .transaction { $0.disablesAnimations = true }  // Prevent sort animations
        .padding(.top, macOS15Padding)
        .overlay {
            if vm.discoveredLeafFolders.isEmpty {
                ContentUnavailableView("No files",
                                       systemImage: "magnifyingglass",
                                       description: Text("Drop a folder or add files to begin."))
                .transition(.opacity)
            }
        }
        
    }
}

private struct SidebarHoverList: View {
    @ObservedObject var vm: AppViewModel
    @State private var hoveredLeafIdx: Int? = nil
    
    var body: some View {
        List {
            Section(
                header:
                    HStack {
                        Text("Selected Folders")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 10)
            ) {
                // Human-friendly sort: first by parent folder name, then by folder name (numeric & case aware)
                let sortedLeaves = vm.activeLeafFolders.sorted { lhs, rhs in
                    let lp = lhs.deletingLastPathComponent().lastPathComponent
                    let ln = lhs.lastPathComponent
                    let rp = rhs.deletingLastPathComponent().lastPathComponent
                    let rn = rhs.lastPathComponent
                    let parentOrder = lp.localizedStandardCompare(rp)
                    if parentOrder == .orderedSame {
                        return ln.localizedStandardCompare(rn) == .orderedAscending
                    }
                    return parentOrder == .orderedAscending
                }
                
                ForEach(Array(sortedLeaves.enumerated()), id: \.offset) { idx, leafURL in
                    let parentName = leafURL.deletingLastPathComponent().lastPathComponent
                    let leafName = leafURL.lastPathComponent
                    let displayPath = "\(parentName)\\\(leafName)"
                    
                    HStack {
                        Image(systemName: "folder")
                            .imageScale(.medium)
                            .foregroundStyle(.secondary)
                        
                        Text(displayPath)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Spacer()
                        
                        if hoveredLeafIdx == idx && !vm.isProcessing {
                            Button {
                                vm.removeLeafFolder(leafURL)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .imageScale(.small)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityLabel("Remove folder")
                            }
                            .buttonStyle(.borderless)
                            .transition(.opacity)
                        }
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hoveredLeafIdx = inside ? idx : (hoveredLeafIdx == idx ? nil : hoveredLeafIdx)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .listSectionSeparator(.automatic)
        .listRowSeparator(.automatic)
    }
}

struct SettingsPanelPopover: View {
    @ObservedObject var vm: AppViewModel
    @FocusState private var textFieldFocused: Bool
    @State private var localSimilarity: Double = 0.8
    @State private var similarityDebounce: DispatchWorkItem?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ignored Folder Name")
                .bold()
            
            ZStack(alignment: .trailing) {
                TextField("Enter folder name to ignore", text: Binding(
                    get: { vm.ignoredFolderName },
                    set: { newValue in DispatchQueue.main.async { vm.ignoredFolderName = newValue } }
                ))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    Capsule()
                        .stroke(textFieldFocused ? .blue : .clear, lineWidth: 1)
                )
                .focused($textFieldFocused)
                
                if !vm.ignoredFolderName.isEmpty {
                    Button {
                        DispatchQueue.main.async { vm.ignoredFolderName = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .padding(.trailing, 8)
                    }
                    .buttonStyle(.plain)
                    .help("Clear ignored folder name")
                }
            }
            
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Limit scan to selected folders only", isOn: $vm.scanTopLevelOnly)
                    .toggleStyle(.switch)
                Text("Will not scan for duplicates between folders. ")
                    .font(.footnote)
            }
            
            Divider()
            
            HStack {
                Text("Analysis Method")
                    .bold()
                Button(action: {}) {
                    Image(systemName: "info.circle").foregroundColor(.secondary).font(.caption)
                }
                .buttonStyle(.plain)
                .help("Enhanced Scan: AI-based analysis that can detect similar content even with different crops or lighting.\nAnything under ~66% produces lots of false positives. \n\nBasic Scan: Fast comparison using image fingerprints, good for exact duplicates.\nAnything under 80% produces lots of false positives.")
            }
            Picker("", selection: Binding(
                get: { vm.selectedAnalysisMode },
                set: { newValue in DispatchQueue.main.async { vm.selectedAnalysisMode = newValue } }
            )) {
                ForEach(AnalysisMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            
            Text("Similarity Threshold")
                .bold()
            Slider(
                value: $localSimilarity,
                in: 0.5...1.0,
                step: 0.01,
                onEditingChanged: { editing in
                    // When the user lets go, commit immediately
                    if !editing {
                        similarityDebounce?.cancel()
                        DispatchQueue.main.async { vm.similarityThreshold = localSimilarity }
                    }
                }
            )
            .onChange(of: localSimilarity) { _, newValue in
                // Debounce updates while the knob is moving to avoid recomputing heavy results on every tick
                similarityDebounce?.cancel()
                let work = DispatchWorkItem {
                    vm.similarityThreshold = newValue
                }
                similarityDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
            .onAppear {
                // Initialize local slider state from the model
                localSimilarity = vm.similarityThreshold
            }
            Text(DisplayHelpers.formatSimilarityThreshold(vm.similarityThreshold))
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Preset buttons
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach([0.70, 0.75, 0.80], id: \.self) { preset in
                        Button {
                            similarityDebounce?.cancel()
                            localSimilarity = preset
                            vm.similarityThreshold = preset
                        } label: {
                            Text("\(Int(preset * 100))")
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    ForEach([0.85, 0.90, 0.95], id: \.self) { preset in
                        Button {
                            similarityDebounce?.cancel()
                            localSimilarity = preset
                            vm.similarityThreshold = preset
                        } label: {
                            Text("\(Int(preset * 100))")
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    ForEach([0.98, 0.99, 1.00], id: \.self) { preset in
                        Button {
                            similarityDebounce?.cancel()
                            localSimilarity = preset
                            vm.similarityThreshold = preset
                        } label: {
                            Text("\(Int(preset * 100))")
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

        }
        .padding(20)
    }
}
