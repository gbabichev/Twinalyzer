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
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FolderRowKey: Hashable {
    let section: Int
    let folder: String
}

extension ContentView {
    
    // MARK: - Processing View
    /// Full-screen view displayed during image analysis OR folder discovery
    /// Shows progress bar for analysis, spinner for discovery
    /// ENHANCED: Added elegant scroll indicators instead of system scrollbars
    var processingView: some View {
        VStack(spacing: 16) {
            if vm.isDiscoveringFolders {
                // FOLDER DISCOVERY: Always indeterminate spinner
                ProgressView()
                    .frame(width: 320)
                Text("Discovering folders...")
                    .foregroundStyle(.secondary)
            } else if vm.isProcessing {
                // IMAGE ANALYSIS: Progress bar (determinate) or spinner (indeterminate)
                if let p = vm.processingProgress {
                    ProgressView(value: p)
                        .frame(width: 320)
                    Text(DisplayHelpers.formatProcessingProgress(p))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .frame(width: 320)
                    Text("Preparing analysis...")
                        .foregroundStyle(.secondary)
                }
            }
            
            // Enhanced scrollable list with custom indicators
            folderListWithScrollIndicators
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Folder List with Custom Scroll Indicators
    var folderListWithScrollIndicators: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.isDiscoveringFolders ? "Scanning Parent Folders..." : "Processing Folders...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if vm.allFoldersBeingProcessed.isEmpty {
                Text("No folders selected.")
                    .foregroundStyle(.secondary)
            } else {
                // Custom scroll view with fade indicators - remove GeometryReader width constraint
                ZStack {
                    // Main scroll view (hidden scrollbar)
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(vm.allFoldersBeingProcessed.enumerated()), id: \.offset) { index, url in
                                    Text(DisplayHelpers.shortDisplayPath(for: url.path))
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false) // Allow text to expand horizontally
                                        .id(index) // For scroll tracking
                                }
                                
                                // Invisible bottom detector
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        isScrolledToBottom = true
                                    }
                                    .onDisappear {
                                        isScrolledToBottom = false
                                    }
                            }
                            .padding(.vertical, 8)
                            .padding(.bottom, isScrollable ? 40 : 0) // Extra padding when scrollable to clear the fade
                            .background(
                                // Content height measurement - fixed approach
                                GeometryReader { contentGeometry in
                                    Color.clear
                                        .onAppear {
                                            contentHeight = contentGeometry.size.height
                                        }
                                        .onChange(of: contentGeometry.size.height) { _, newHeight in
                                            contentHeight = newHeight
                                            updateScrollableState(availableHeight: 200)
                                        }
                                }
                            )
                        }
                        .background(
                            // Scroll offset tracking
                            GeometryReader { scrollGeometry in
                                Color.clear
                                    .preference(key: ScrollOffsetPreferenceKey.self,
                                              value: scrollGeometry.frame(in: .named("scroll")).minY)
                            }
                        )
                        .coordinateSpace(name: "scroll")
                        .onChange(of: vm.allFoldersBeingProcessed.count) { _, newCount in
                            // Update scrollable state when folder count changes
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                updateScrollableState(availableHeight: 200)
                            }
                        }
                    }
                    
                    // Top fade indicator (when scrolled down)
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(NSColor.controlBackgroundColor), location: 0),
                            .init(color: Color(NSColor.controlBackgroundColor).opacity(0), location: 1)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(scrollOffset < -10 ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: scrollOffset < -10)
                    
                    // Bottom fade indicator with arrow (when content extends below)
                    VStack(spacing: 0) {
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: Color(NSColor.controlBackgroundColor).opacity(0), location: 0),
                                .init(color: Color(NSColor.controlBackgroundColor), location: 1)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 30)
                        
                        // Subtle down arrow indicator
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
                    // Don't call updateScrolledToBottomState here - let the invisible detector handle it
                }
                .onAppear {
                    updateScrollableState(availableHeight: 200)
                }
                .onChange(of: vm.allFoldersBeingProcessed) { _, _ in
                    updateScrollableState(availableHeight: 200)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false) // Size to content width, flexible height
    }
    
    // MARK: - Settings Panel
    /// Popover containing analysis configuration options
    /// Includes scan depth, analysis method, similarity threshold, and ignored folder controls
    var controlsPanelPopover: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            Text("Settings").font(.headline)
            Divider()
            
            // Ignored folder name input
            VStack(alignment: .leading, spacing: 8) {

                HStack {
                    Text("Ignored Folder Name")
                        .font(.subheadline)
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .help("Enter a folder name to skip during scanning. For example, entering 'thumb' will ignore all folders named 'thumb' at any level in the directory tree.")
                }
                
                HStack {
                    TextField("Enter folder name to ignore", text: Binding(
                        get: { vm.ignoredFolderName },
                        set: { newValue in
                            // Defer the update to prevent publishing during view updates
                            DispatchQueue.main.async {
                                vm.ignoredFolderName = newValue
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    
                    // Clear button
                    if !vm.ignoredFolderName.isEmpty {
                        Button {
                            DispatchQueue.main.async {
                                vm.ignoredFolderName = ""
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear ignored folder name")
                    }
                }
                
            }
            
            // Scan depth control: top-level only vs recursive scanning
            Toggle("Limit scan to selected folders only", isOn: $vm.scanTopLevelOnly)
            
            Divider()
            
            // Analysis method selection with info tooltip
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
                    .help("Enhanced Scan: AI-based analysis that can detect similar content even with different crops or lighting.\nAnything under ~66% produces lots of false positives. \n\nBasic Scan: Fast comparison using image fingerprints, good for exact duplicates.\nAnything under 80% produces lots of false positives.")
                }
                
                // FIXED: Use local state with deferred updates to prevent publishing during view updates
                Picker("", selection: Binding(
                    get: { vm.selectedAnalysisMode },
                    set: { newValue in
                        // Defer the update to the next run loop cycle
                        DispatchQueue.main.async {
                            vm.selectedAnalysisMode = newValue
                        }
                    }
                )) {
                    ForEach(AnalysisMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            // FIXED: Similarity threshold slider with deferred updates
            VStack {
                Text("Similarity Threshold")
                Slider(
                    value: Binding(
                        get: { vm.similarityThreshold },
                        set: { newValue in
                            // Defer the update to prevent publishing during view updates
                            DispatchQueue.main.async {
                                vm.similarityThreshold = newValue
                            }
                        }
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

    // MARK: - Cross-Folder Duplicates Panel
    /// Top section of detail view showing folder relationships
    /// Groups folders that contain duplicate images across different directories
    var duplicatesFolderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cross-Folder Duplicates")
                    .font(.headline).fontWeight(.semibold)
                Spacer()
                if !vm.folderClusters.isEmpty {
                    Text("\(vm.folderClusters.count) relationship\(vm.folderClusters.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary).font(.subheadline)
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)

            if vm.folderClusters.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 24)).foregroundStyle(.secondary)
                    Text("No cross-folder duplicate relationships found.")
                        .foregroundStyle(.secondary).font(.subheadline)
                    Text("Run an analysis to discover duplicates between different folders.")
                        .foregroundStyle(.tertiary).font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Use a local to avoid the Binding/C overload confusion
                let clusters: [[String]] = vm.folderClusters

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        // Concrete Range avoids tuple key-paths & Binding overloads
                        ForEach(0..<clusters.count, id: \.self) { sectionIndex in
                            let cluster = clusters[sectionIndex]

                            HStack {
                                Text("Group \(sectionIndex + 1)")
                                    .font(.caption).fontWeight(.medium)
                                Spacer()
                                Text("\(cluster.count) folder\(cluster.count == 1 ? "" : "s")")
                                    .foregroundStyle(.secondary).font(.caption2)
                            }
                            .padding(.horizontal, 12)

                            // Unique identity per group+folder fixes duplicate-ID warning
                            ForEach(cluster, id: \.self) { folder in
                                folderRow(folder: folder)
                                    .id(FolderRowKey(section: sectionIndex, folder: folder))
                                    .padding(.horizontal, 8)
                            }

                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    /// Individual folder row in the cross-folder duplicates list
    /// Shows folder name, thumbnail, and duplicate count
    /// Clickable to open folder in Finder
    private func folderRow(folder: String) -> some View {
        Button(action: { vm.openFolderInFinder(folder) }) {
            HStack(alignment: .center, spacing: 8) {
                let url = URL(fileURLWithPath: folder)
                let displayName = DisplayHelpers.formatFolderDisplayName(for: url)
                
                // Folder name with middle truncation for long paths
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer(minLength: 0)
                
                HStack(spacing: 6) {
                    // Representative thumbnail from this folder
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
                    
                    // Duplicate count badge
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
    
    // MARK: - Preview Panel
    /// Bottom section of detail view showing side-by-side image comparison
    /// Displays reference and match images with delete buttons
    
    /// Side-by-side layout for comparing reference and match images
    /// Calculates optimal image sizes based on available space
    /// Includes delete buttons for individual image removal
    @ViewBuilder
    private func previewLayout(for row: TableRow, in size: CGSize) -> some View {
        // Calculate layout dimensions based on available space
        let spacing: CGFloat = 20
        let inset: CGFloat = 16
        let twoColumnWidth = max(0, size.width - spacing - inset * 2)
        let singleColumn = twoColumnWidth / 2
        let maxDim = max(80, min(singleColumn - 40, size.height - 120, 400))
        
        HStack(alignment: .top, spacing: spacing) {
            // Left side: Reference image
            VStack(spacing: 8) {
                Text("Reference")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                // Shortened path display
                Text(row.referenceShort)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                
                // Reference image with border
                PreviewImage(path: row.reference, maxDimension: maxDim, priority: .userInitiated)
                    .frame(maxWidth: maxDim, maxHeight: maxDim)
                    .clipped()
//                    .overlay(
//                        RoundedRectangle(cornerRadius: 4)
//                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
//                    )
                
                // Delete reference button
                Button("Delete Reference") {
                    vm.deleteFile(row.reference)
                }
                .controlSize(.small)
                .disabled(vm.isProcessing)
            }
            .frame(maxWidth: max(100, singleColumn))
            
            // Right side: Match image
            VStack(spacing: 8) {
                Text("Match")
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                // Match path with cross-folder highlighting
                Text(row.similarShort)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(row.isCrossFolder ? .red : .primary)

                
                // Match image with conditional red border for cross-folder duplicates
                PreviewImage(path: row.similar, maxDimension: maxDim, priority: .utility)
                    .frame(maxWidth: maxDim, maxHeight: maxDim)
                    .clipped()
//                    .overlay(
//                        RoundedRectangle(cornerRadius: 4)
//                            .stroke(DisplayHelpers.isCrossFolder(row) ? Color.red.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: 1)
//                    )
                
                // Delete match button
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

    // MARK: - Sidebar Content
    /// Left panel showing selected folders and their management
    /// Displays discovered leaf folders with removal options
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
 
    private struct RefCell: View, Equatable {
        let id: String
        let isMarked: Bool
        let referenceShort: String
        let isCrossFolder: Bool
        let toggle: () -> Void

        static func == (lhs: RefCell, rhs: RefCell) -> Bool {
            lhs.id == rhs.id &&
            lhs.isMarked == rhs.isMarked &&
            lhs.referenceShort == rhs.referenceShort &&
            lhs.isCrossFolder == rhs.isCrossFolder
        }

        var body: some View {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Image(systemName: isMarked ? "checkmark.square.fill" : "square")
                        .foregroundColor(isMarked ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 20)

                Text(referenceShort)
                    .foregroundStyle(isCrossFolder ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
    
}

// MARK: - Content Size Preference Key
struct ContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FolderRowView: View, Equatable {
    let folder: String
    let displayName: String
    let imagePath: String?
    let dupes: Int
    let open: () -> Void

    static func == (lhs: FolderRowView, rhs: FolderRowView) -> Bool {
        lhs.folder == rhs.folder &&
        lhs.displayName == rhs.displayName &&
        lhs.imagePath == rhs.imagePath &&
        lhs.dupes == rhs.dupes
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if let imagePath {
                        PreviewImage(path: imagePath, maxDimension: 24, priority: .utility)
                            .frame(width: 24, height: 24)
                            .clipped()
                            .cornerRadius(3)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.gray.opacity(0.25), lineWidth: 1))
                            .allowsHitTesting(false)
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(dupes)").font(.system(size: 14, weight: .semibold))
                        Text("dupes").font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help("Folder: \(folder)")
    }
}

