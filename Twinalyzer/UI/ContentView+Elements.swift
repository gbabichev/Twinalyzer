/*

 ContentView+Elements.swift
 Twinalyzer

 George Babichev

 */

import SwiftUI
import AppKit

// MARK: - Scroll Offset Preference Key
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension ContentView {
    
    // MARK: - Processing View
    var processingView: some View {
        VStack(spacing: 16) {
            if vm.isDiscoveringFolders {
                ProgressView().frame(width: 320)
                Text("Discovering folders...").foregroundStyle(.secondary)
            } else if vm.isProcessing {
                if let p = vm.processingProgress {
                    ProgressView(value: p).frame(width: 320)
                    Text(DisplayHelpers.formatProcessingProgress(p)).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(width: 320)
                    Text("Preparing analysis...").foregroundStyle(.secondary)
                }
            }
            folderListWithScrollIndicators
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Folder List with Custom Scroll Indicators
    var folderListWithScrollIndicators: some View { /* unchanged */
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.isDiscoveringFolders ? "Scanning Parent Folders..." : "Processing Folders...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if vm.allFoldersBeingProcessed.isEmpty {
                Text("No folders selected.").foregroundStyle(.secondary)
            } else {
                ZStack {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(vm.allFoldersBeingProcessed.enumerated()), id: \.offset) { index, url in
                                    Text(DisplayHelpers.shortDisplayPath(for: url.path))
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .id(index)
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear { isScrolledToBottom = true }
                                    .onDisappear { isScrolledToBottom = false }
                            }
                            .padding(.vertical, 8)
                            .padding(.bottom, isScrollable ? 40 : 0)
                            .background(
                                GeometryReader { contentGeometry in
                                    Color.clear
                                        .onAppear { contentHeight = contentGeometry.size.height }
                                        .onChange(of: contentGeometry.size.height) { _, newHeight in
                                            contentHeight = newHeight
                                            updateScrollableState(availableHeight: 200)
                                        }
                                }
                            )
                        }
                        .background(
                            GeometryReader { scrollGeometry in
                                Color.clear
                                    .preference(key: ScrollOffsetPreferenceKey.self,
                                                value: scrollGeometry.frame(in: .named("scroll")).minY)
                            }
                        )
                        .coordinateSpace(name: "scroll")
                        .onChange(of: vm.allFoldersBeingProcessed.count) { _, _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                updateScrollableState(availableHeight: 200)
                            }
                        }
                    }
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(NSColor.controlBackgroundColor), location: 0),
                            .init(color: Color(NSColor.controlBackgroundColor).opacity(0), location: 1)
                        ]),
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(scrollOffset < -10 ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: scrollOffset < -10)
                    
                    VStack(spacing: 0) {
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color(NSColor.controlBackgroundColor).opacity(0), location: 0),
                                .init(color: Color(NSColor.controlBackgroundColor), location: 1)
                            ]),
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 30)
                        HStack {
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.8))
                                .padding(.bottom, 4)
                            Spacer()
                        }
                        .background(Color(NSColor.controlBackgroundColor))
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(isScrollable && !isScrolledToBottom ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: isScrollable && !isScrolledToBottom)
                }
                .frame(maxHeight: 200)
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollOffset = value
                }
                .onAppear { updateScrollableState(availableHeight: 200) }
                .onChange(of: vm.allFoldersBeingProcessed) { _, _ in
                    updateScrollableState(availableHeight: 200)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    
    // MARK: - Settings Panel
    var controlsPanelPopover: some View { /* unchanged */
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.headline)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Ignored Folder Name").font(.subheadline)
                    Image(systemName: "info.circle").foregroundColor(.secondary).font(.caption)
                        .help("Enter a folder name to skip during scanning. For example, entering 'thumb' will ignore all folders named 'thumb' at any level in the directory tree.")
                }
                HStack {
                    TextField("Enter folder name to ignore", text: Binding(
                        get: { vm.ignoredFolderName },
                        set: { newValue in DispatchQueue.main.async { vm.ignoredFolderName = newValue } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    if !vm.ignoredFolderName.isEmpty {
                        Button {
                            DispatchQueue.main.async { vm.ignoredFolderName = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear ignored folder name")
                    }
                }
            }
            Toggle("Limit scan to selected folders only", isOn: $vm.scanTopLevelOnly)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Analysis Method").font(.subheadline)
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
            }
            VStack {
                Text("Similarity Threshold")
                Slider(
                    value: Binding(
                        get: { vm.similarityThreshold },
                        set: { newValue in DispatchQueue.main.async { vm.similarityThreshold = newValue } }
                    ),
                    in: 0.45...1.0,
                    step: 0.01
                )
                Text(DisplayHelpers.formatSimilarityThreshold(vm.similarityThreshold))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
    
    // MARK: - Cross-Folder Duplicates Panel (STATIC)
    var duplicatesFolderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cross-Folder Duplicates")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if !vm.folderClustersStatic.isEmpty {
                    Text("\(vm.folderClustersStatic.count) relationship\(vm.folderClustersStatic.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            
            if vm.folderClustersStatic.isEmpty {
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
                    ForEach(Array(vm.folderClustersStatic.enumerated()), id: \.offset) { i, cluster in
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
                    if let imagePath = vm.representativeImageByFolderStatic[folder] {
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
                        Text("\(vm.crossFolderDuplicateCountsStatic[folder, default: 0])")
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
    
    // MARK: - Preview Panel (unchanged)
    var previewPanel: some View { /* unchanged from your latest file */
        GeometryReader { geometry in
            VStack {
                if let row = selectedRow, !vm.flattenedResults.isEmpty {
                    renderPreview(for: row, size: geometry.size)                } else {
                    VStack(spacing: 8) {
                        if vm.selectedMatchesForDeletion.count > 1 {
                            Text("\(vm.selectedMatchesForDeletion.count) matches selected")
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
    
    // MARK: - Sidebar Content & Table View & Detail Split View
    var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Show folders if any have been discovered
            if !vm.discoveredLeafFolders.isEmpty {
                
                List {
                    HStack {
                        Image(systemName: "folder.fill")
                             .font(.system(size: 14))
                             .frame(width: 16, height: 16)
                        
                        Text("Selected Folders")
                            .font(.title3)
                        
                    }

                    Divider()
                    ForEach(vm.activeLeafFolders, id: \.self) { leafURL in

                        HStack {
                            // Folder info: folder name and parent/folder structure
                            VStack(alignment: .leading, spacing: 2) {
                                
                                // PRIMARY: Just the folder name
                                Text(leafURL.lastPathComponent)
                                    .font(.body)
                                    .lineLimit(1)
                                
                                // SECONDARY: Parent/folder structure (smaller, gray)
                                Text(DisplayHelpers.formatFolderDisplayName(for: leafURL))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            
                            Spacer(minLength: 4)
                            
                            // Remove folder button (hidden during processing)
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
                // Empty state: prompt user to add folders
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
    // MARK: - Results Table
    /// Center panel displaying comparison results in sortable table format
    /// Includes checkboxes for deletion selection and similarity percentages
    // ContentView.swift - Table Section Only
    // Replace your existing tableView with this simplified version

    // MARK: - Results Table with Native Sorting
    /// Simplified table that uses SwiftUI's native sorting - no custom caching!
    // MARK: - Detail Split View
    /// Right panel with vertical split: cross-folder duplicates on top, preview on bottom
    var detailSplitView: some View {
        VSplitView {
            duplicatesFolderPanel
                .frame(minHeight: 150, idealHeight: 200)
            
            previewPanel
                .frame(minHeight: 200)
        }
    }
}
    
// MARK: - Content Size Preference Key
struct ContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

