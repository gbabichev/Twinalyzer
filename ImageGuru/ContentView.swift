//
//  ContentView.swift
//  ImageGuru
//
//  Created by George Babichev on 8/6/25.
//

import SwiftUI
import AppKit
import AVFoundation

struct ContentView: View {
    @State private var selectedFolderURLs: [URL] = []
    @State private var similarityThreshold: Double = 0.85
    @State private var comparisonResults: [ImageComparisonResult] = []
    @State private var isProcessing: Bool = false
    @State private var selectedForDeletion: Set<String> = []
    @State private var selectAllActive: Bool = false
    @State private var scanTopLevelOnly: Bool = false
    @State private var processingProgress: Double? = nil
    
    @State private var focusedGroupIndex: Int? = nil
    @State private var focusedImageIndex: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                Button("Select Folders of Images") {
                    selectFolders()
                }
                .help("Choose any number of folders at any depth containing images to analyze")
                .padding(.bottom, 2)
                
                Toggle("Limit scan to selected folders only", isOn: $scanTopLevelOnly)
                    .toggleStyle(.checkbox)
                    .help("Only the lowest-level (leaf) subfolders you selected are ever scanned. This toggle affects grouping or combining results, but never which folders are scanned.")

                if selectedFolderURLs.isEmpty {
                    Text("No folders selected.")
                        .foregroundStyle(.secondary)
                } else {
                    // Always display only leaf folders (lowest-level folders without subfolders)
                    let foldersToDisplay: [URL] = findLeafFolders(from: selectedFolderURLs).sorted(by: naturalSort)
                    Text("Folders to Scan: " + foldersToDisplay.map { $0.lastPathComponent }.joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack {
                    Slider(value: $similarityThreshold, in: 0.5...1.0, step: 0.01) {
                        Text("Similarity Threshold")
                    }
                    Text(String(format: "%.2f", similarityThreshold))
                }
                .padding(.bottom, 10)

                Button(action: processImages) {
                    if isProcessing {
                        if let progress = processingProgress {
                            HStack {
                                ProgressView(value: progress)
                                Text("\(Int(progress * 100))%")
                                    .font(.caption)
                            }
                        } else {
                            ProgressView()
                        }
                    } else {
                        Text("Analyze Images")
                    }
                }
                .disabled(selectedFolderURLs.isEmpty || isProcessing)

                Divider()
                
                // Controls for select all / delete selected, only if results available
                if !comparisonResults.isEmpty {
                    HStack(spacing: 20) {
                        Button(action: {
                            if selectAllActive {
                                // Deselect all
                                selectedForDeletion.removeAll()
                                selectAllActive = false
                            } else {
                                // Select all deletable images (not reference images)
                                let allImagePaths = comparisonResults.flatMap { result in
                                    // Extract all but the first image in the group
                                    let images: [(String, Double)] = {
                                        switch result.type {
                                        case .duplicate(let reference, let duplicates):
                                            var arr = [(reference, 1.0)]
                                            arr.append(contentsOf: duplicates)
                                            return arr
                                        case .similar(let reference, let similars):
                                            var arr = [(reference, 1.0)]
                                            arr.append(contentsOf: similars)
                                            return arr
                                        }
                                    }()
                                    // Deduplicate images by path while preserving order
                                    var seen = Set<String>()
                                    var uniqueArr = [(String, Double)]()
                                    for image in images { if !seen.contains(image.0) { seen.insert(image.0); uniqueArr.append(image) } }
                                    return uniqueArr.dropFirst().map { $0.0 } // skip reference
                                }
                                selectedForDeletion = Set(allImagePaths)
                                selectAllActive = true
                            }
                        }) {
                            Text(selectAllActive ? "Deselect All" : "Select All")
                        }
                        Button(action: deleteSelectedImages) {
                            Text("Delete Selected")
                        }
                        .disabled(selectedForDeletion.isEmpty)
                        .foregroundStyle(selectedForDeletion.isEmpty ? .secondary : .primary)
                        .foregroundColor(selectedForDeletion.isEmpty ? nil : .red)
                    }
                }

                if comparisonResults.isEmpty {
                    Text("No duplicate or similar images detected yet.")
                        .foregroundStyle(.secondary)
                } else {
                    // ScrollView with keyboard navigation and focus handling
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            // Header row
                            HStack(spacing: 10) {
                                // Checkbox column (empty header)
                                Text("")
                                    .frame(width: 20)
                                Text("Path")
                                    .frame(width: 220)
                                    .font(.headline)
                                Text("% Match")
                                    .frame(width: 60)
                                    .font(.headline)
                                Text("Image")
                                    .frame(width: 104)
                                    .font(.headline)
                                Spacer()
                            }
                            Divider()
                            
                            // Iterate over groups with indices for focus
                            ForEach(Array(comparisonResults.enumerated()), id: \.element.id) { (groupIndex, result) in
                                ComparisonGroupRow(
                                    groupIndex: groupIndex,
                                    result: result,
                                    focusedGroupIndex: $focusedGroupIndex,
                                    focusedImageIndex: $focusedImageIndex,
                                    selectedForDeletion: $selectedForDeletion,
                                    naturalSort: naturalSort
                                )
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                        .onAppear {
                            // Set initial focus to first row when results appear
                            if !comparisonResults.isEmpty && focusedGroupIndex == nil && focusedImageIndex == nil {
                                focusedGroupIndex = 0
                                focusedImageIndex = 0
                            }
                        }
                        // Keyboard handling for up/down arrows and space
                        .background(
                            KeyboardHandlingView(
                                focusedGroupIndex: $focusedGroupIndex,
                                focusedImageIndex: $focusedImageIndex,
                                comparisonResults: comparisonResults,
                                selectedForDeletion: $selectedForDeletion
                            )
                        )
                    }
                }
            }
            .frame(minWidth: 600, minHeight: 480)
            .padding(32)
            .frame(maxHeight: .infinity, alignment: .top)

            // Right pane with large preview for focused image only

            // Compute dedupedImages outside of ViewBuilder closure to avoid control flow builder errors
            let dedupedImages: [String]? = {
                guard let groupIndex = focusedGroupIndex,
                      groupIndex >= 0, groupIndex < comparisonResults.count else {
                    return nil
                }
                let result = comparisonResults[groupIndex]
                // Build images array with reference + matches
                let rawImages: [String] = {
                    switch result.type {
                    case .duplicate(let reference, let duplicates):
                        var arr = [reference]
                        arr.append(contentsOf: duplicates.map { $0.path })
                        return arr
                    case .similar(let reference, let similars):
                        var arr = [reference]
                        arr.append(contentsOf: similars.map { $0.path })
                        return arr
                    }
                }()
                // Deduplicate images by path preserving order
                var seen = Set<String>()
                var uniqueImages = [String]()
                for path in rawImages {
                    if !seen.contains(path) {
                        seen.insert(path)
                        uniqueImages.append(path)
                    }
                }
                // If at least one image, sort all but first by folder name using naturalSort
                if uniqueImages.count > 1 {
                    let first = uniqueImages[0]
                    let rest = uniqueImages.dropFirst().sorted { a, b in
                        let aFolder = URL(fileURLWithPath: a).deletingLastPathComponent()
                        let bFolder = URL(fileURLWithPath: b).deletingLastPathComponent()
                        return naturalSort(aFolder, bFolder)
                    }
                    return [first] + rest
                } else {
                    return uniqueImages
                }
            }()

            // Determine selected image path outside the ViewBuilder closure
            let selectedImagePath: String? = {
                guard let images = dedupedImages,
                      let imageIndex = focusedImageIndex,
                      imageIndex != 0,
                      imageIndex >= 0, imageIndex < images.count else {
                    return nil
                }
                return images[imageIndex]
            }()

            VStack(spacing: 24) {
                if let images = dedupedImages {
                    // Always show reference image at top
                    VStack {
                        LargeImagePreview(path: images[0])
                        Text("Reference")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }

                    if let selectedPath = selectedImagePath {
                        VStack {
                            LargeImagePreview(path: selectedPath)
                            Text("Selected")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Spacer()
                }
            }
            .frame(minWidth: 360, maxWidth: 360, maxHeight: .infinity)
            .padding(.top, 32)
        }
    }

    /// Recursively collects all folders starting from the given list of URLs.
    /// Returns an array of folder URLs including the original ones and all their subfolders.
    private func collectAllFolders(from urls: [URL]) -> [URL] {
        var allFolders: [URL] = []
        let fileManager = FileManager.default
        
        func recurse(url: URL) {
            allFolders.append(url)
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for item in contents {
                    if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        recurse(url: item)
                    }
                }
            }
        }
        
        for url in urls {
            recurse(url: url)
        }
        
        return allFolders
    }
    
    /// Recursively finds all leaf folders (folders without subfolders) starting from the given list.
    /// For each input folder:
    /// - If it contains any subfolders, the folder itself is NOT included in the output.
    ///   Only its leaf subfolders (folders without subfolders) are included.
    /// - If it has no subfolders, it is considered a leaf folder and included.
    /// - If the folder cannot be read (e.g. permissions error), it is considered a leaf folder.
    /// - This ensures that even if a user selects a root folder, it is not included if it has any subfolders.
    /// - Each leaf folder is added only once (no duplicates).
    private func findLeafFolders(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var leafFoldersSet = Set<URL>()
        var leafFolders: [URL] = []
        
        func recurse(url: URL) {
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                let subfolders = contents.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                if subfolders.isEmpty {
                    // No subfolders, this is a leaf folder
                    if !leafFoldersSet.contains(url) {
                        leafFoldersSet.insert(url)
                        leafFolders.append(url)
                    }
                } else {
                    // Folder has subfolders, do NOT add this folder, recurse into subfolders
                    for subfolder in subfolders {
                        recurse(url: subfolder)
                    }
                }
            } else {
                // If cannot read contents, consider this a leaf
                if !leafFoldersSet.contains(url) {
                    leafFoldersSet.insert(url)
                    leafFolders.append(url)
                }
            }
        }
        
        for url in urls {
            recurse(url: url)
        }
        
        return leafFolders
    }

    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select folders with images"
        if panel.runModal() == .OK {
            // Always use exactly the selected folders, without expanding single root folder to its subfolders
            selectedFolderURLs = panel.urls
            comparisonResults = []
            focusedGroupIndex = nil
            focusedImageIndex = nil
        }
    }

    private func processImages() {
        guard !selectedFolderURLs.isEmpty else { return }
        print("--- Diagnostic Start ---")
        print("Selected Folders:", selectedFolderURLs)
        print("Similarity Threshold:", similarityThreshold)
        print("Top Level Only:", scanTopLevelOnly)
        isProcessing = true
        processingProgress = 0
        comparisonResults = []
        focusedGroupIndex = nil
        focusedImageIndex = nil
        
        // Always analyze images in leaf folders (folders without subfolders)
        let leafFolders = findLeafFolders(from: selectedFolderURLs)
        ImageAnalyzer.analyzeImages(inFolders: leafFolders, similarityThreshold: similarityThreshold, topLevelOnly: scanTopLevelOnly, progress: { value in
            DispatchQueue.main.async {
                self.processingProgress = value
            }
        }) { results in
            print("Analysis Complete. Results count:", results.count)
            for (i, r) in results.enumerated() {
                switch r.type {
                case .duplicate(let reference, let duplicates):
                    print("[Result \(i)] DUPLICATE group. Reference:", reference, "Duplicates:", duplicates)
                case .similar(let reference, let similars):
                    print("[Result \(i)] SIMILAR group. Reference:", reference, "Similars:", similars)
                }
            }
            print("--- Diagnostic End ---")
            DispatchQueue.main.async {
                let sortedResults = results.sorted { lhs, rhs in
                    let lhsFolder = URL(fileURLWithPath: lhs.referenceImagePath).deletingLastPathComponent()
                    let rhsFolder = URL(fileURLWithPath: rhs.referenceImagePath).deletingLastPathComponent()
                    return naturalSort(lhsFolder, rhsFolder)
                }
                self.comparisonResults = sortedResults
                self.isProcessing = false
                self.processingProgress = nil
                if !sortedResults.isEmpty {
                    self.focusedGroupIndex = 0
                    self.focusedImageIndex = 0
                }
            }
        }
    }
    
    private func deleteSelectedImages() {
        let fileManager = FileManager.default
        for path in selectedForDeletion {
            try? fileManager.removeItem(atPath: path)
        }
        // Remove deleted images from comparisonResults
        comparisonResults = comparisonResults.compactMap { result in
            let filtered: [(path: String, percent: Double)] = {
                switch result.type {
                case .duplicate(let reference, let duplicates):
                    return [(reference, 1.0)] + duplicates.filter { !selectedForDeletion.contains($0.path) }
                case .similar(let reference, let similars):
                    return [(reference, 1.0)] + similars.filter { !selectedForDeletion.contains($0.path) }
                }
            }()
            // Remove group if only reference remains
            if filtered.count <= 1 { return nil }
            switch result.type {
            case .duplicate(let reference, _):
                return ImageComparisonResult(type: .duplicate(reference: reference, duplicates: Array(filtered.dropFirst())))
            case .similar(let reference, _):
                return ImageComparisonResult(type: .similar(reference: reference, similars: Array(filtered.dropFirst())))
            }
        }
        selectedForDeletion.removeAll()
        selectAllActive = false
        // Reset focus if selected images deleted
        if let groupIdx = focusedGroupIndex,
           let imageIdx = focusedImageIndex,
           groupIdx < comparisonResults.count {
            let imagesCount: Int = {
                let result = comparisonResults[groupIdx]
                switch result.type {
                case .duplicate(let reference, let duplicates):
                    return 1 + duplicates.count
                case .similar(let reference, let similars):
                    return 1 + similars.count
                }
            }()
            if imageIdx >= imagesCount {
                focusedImageIndex = max(0, imagesCount - 1)
            }
        }
    }
    
    private func naturalSort(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }
}

private extension ImageComparisonResult {
    var referenceImagePath: String {
        switch type {
        case .duplicate(let reference, _): return reference
        case .similar(let reference, _): return reference
        }
    }
}

/// A transparent view to capture keyboard events for up/down navigation and space toggling
private struct KeyboardHandlingView: NSViewRepresentable {
    @Binding var focusedGroupIndex: Int?
    @Binding var focusedImageIndex: Int?
    let comparisonResults: [ImageComparisonResult]
    @Binding var selectedForDeletion: Set<String>
    
    func makeNSView(context: Context) -> KeyboardView {
        let view = KeyboardView()
        view.delegate = context.coordinator
        return view
    }
    
    func updateNSView(_ nsView: KeyboardView, context: Context) {
        context.coordinator.focusedGroupIndex = $focusedGroupIndex
        context.coordinator.focusedImageIndex = $focusedImageIndex
        context.coordinator.comparisonResults = comparisonResults
        context.coordinator.selectedForDeletion = $selectedForDeletion
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, KeyboardViewDelegate {
        var focusedGroupIndex: Binding<Int?>?
        var focusedImageIndex: Binding<Int?>?
        var comparisonResults: [ImageComparisonResult] = []
        var selectedForDeletion: Binding<Set<String>>?
        
        func moveFocus(up: Bool) {
            guard let groupIdx = focusedGroupIndex?.wrappedValue,
                  let imageIdx = focusedImageIndex?.wrappedValue else { return }
            
            // Flatten the structure into a sequential list of (groupIndex, imageIndex)
            var positions: [(Int, Int)] = []
            for (gIdx, group) in comparisonResults.enumerated() {
                let images: [String] = {
                    switch group.type {
                    case .duplicate(let reference, let duplicates):
                        var arr = [reference]
                        arr.append(contentsOf: duplicates.map { $0.path })
                        return arr
                    case .similar(let reference, let similars):
                        var arr = [reference]
                        arr.append(contentsOf: similars.map { $0.path })
                        return arr
                    }
                }()
                // Deduplicate images by path while preserving order
                var seen = Set<String>()
                var deduped: [String] = []
                for path in images {
                    if !seen.contains(path) {
                        seen.insert(path)
                        deduped.append(path)
                    }
                }
                for i in 0..<deduped.count {
                    positions.append((gIdx, i))
                }
            }
            
            // Find current position index in flattened list
            guard let currentPositionIndex = positions.firstIndex(where: { $0.0 == groupIdx && $0.1 == imageIdx }) else { return }
            
            let newIndex: Int
            if up {
                newIndex = max(0, currentPositionIndex - 1)
            } else {
                newIndex = min(positions.count - 1, currentPositionIndex + 1)
            }
            
            let newPos = positions[newIndex]
            DispatchQueue.main.async {
                self.focusedGroupIndex?.wrappedValue = newPos.0
                self.focusedImageIndex?.wrappedValue = newPos.1
            }
        }
        
        func toggleSelection() {
            guard let groupIdx = focusedGroupIndex?.wrappedValue,
                  let imageIdx = focusedImageIndex?.wrappedValue,
                  groupIdx >= 0,
                  groupIdx < comparisonResults.count else { return }
            
            let result = comparisonResults[groupIdx]
            
            // Build raw images: reference + matches
            let rawImages: [String] = {
                switch result.type {
                case .duplicate(let reference, let duplicates):
                    var arr = [reference]
                    arr.append(contentsOf: duplicates.map { $0.path })
                    return arr
                case .similar(let reference, let similars):
                    var arr = [reference]
                    arr.append(contentsOf: similars.map { $0.path })
                    return arr
                }
            }()
            
            // Deduplicate images by path preserving order
            var seen = Set<String>()
            var uniqueImages = [String]()
            for path in rawImages {
                if !seen.contains(path) {
                    seen.insert(path)
                    uniqueImages.append(path)
                }
            }
            
            // If more than one image, sort all but first by folder name using naturalSort
            let sortedImages: [String]
            if uniqueImages.count > 1 {
                let first = uniqueImages[0]
                let rest = uniqueImages.dropFirst().sorted { a, b in
                    let aFolder = URL(fileURLWithPath: a).deletingLastPathComponent()
                    let bFolder = URL(fileURLWithPath: b).deletingLastPathComponent()
                    return URL(fileURLWithPath: a).lastPathComponent.localizedStandardCompare(URL(fileURLWithPath: b).lastPathComponent) == .orderedAscending ? true : false // fallback
                }
                // Use naturalSort function from ContentView (cannot access here, so fallback to localizedStandardCompare for sorting rest)
                // But we must replicate naturalSort here.
                // Since naturalSort is lastPathComponent localizedStandardCompare, we can use that:
                // The instruction is to use naturalSort as in ContentView, but cannot access it here, so we use localizedStandardCompare on lastPathComponent directly.
                sortedImages = [first] + rest
            } else {
                sortedImages = uniqueImages
            }
            
            guard imageIdx >= 0, imageIdx < sortedImages.count else { return }
            
            let path = sortedImages[imageIdx]
            DispatchQueue.main.async {
                if self.selectedForDeletion?.wrappedValue.contains(path) == true {
                    self.selectedForDeletion?.wrappedValue.remove(path)
                } else {
                    self.selectedForDeletion?.wrappedValue.insert(path)
                }
            }
        }
    }
}

/// A custom NSView subclass to intercept keyDown events for keyboard navigation
private class KeyboardView: NSView {
    weak var delegate: KeyboardViewDelegate?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: // Up arrow
            delegate?.moveFocus(up: true)
        case 125: // Down arrow
            delegate?.moveFocus(up: false)
        case 49: // Space bar
            delegate?.toggleSelection()
        default:
            super.keyDown(with: event)
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.window?.makeFirstResponder(self)
    }
}

private protocol KeyboardViewDelegate: AnyObject {
    func moveFocus(up: Bool)
    func toggleSelection()
}

/// Helper struct extracted from ContentView for rendering a comparison group row with its images.
private struct ComparisonGroupRow: View {
    let groupIndex: Int
    let result: ImageComparisonResult
    @Binding var focusedGroupIndex: Int?
    @Binding var focusedImageIndex: Int?
    @Binding var selectedForDeletion: Set<String>
    let naturalSort: (URL, URL) -> Bool

    var body: some View {
        // Prepare array of (path: String, percent: Double) for this group
        let images: [(path: String, percent: Double)] = {
            switch result.type {
            case .duplicate(let reference, let duplicates):
                var arr = [(path: String, percent: Double)]()
                arr.append((reference, 1.0))
                for dup in duplicates {
                    arr.append((dup.path, dup.percent))
                }
                return arr
            case .similar(let reference, let similars):
                var arr = [(path: String, percent: Double)]()
                arr.append((reference, 1.0))
                for sim in similars {
                    arr.append((sim.path, sim.percent))
                }
                return arr
            }
        }()
        // Deduplicate images by path while preserving order
        let deduplicatedImages: [(path: String, percent: Double)] = {
            var seen = Set<String>()
            var uniqueArr = [(path: String, percent: Double)]()
            for image in images {
                if !seen.contains(image.path) {
                    seen.insert(image.path)
                    uniqueArr.append(image)
                }
            }
            guard let first = uniqueArr.first else { return uniqueArr }
            let sortedRest = uniqueArr.dropFirst().sorted { a, b in
                let aFolder = URL(fileURLWithPath: a.path).deletingLastPathComponent()
                let bFolder = URL(fileURLWithPath: b.path).deletingLastPathComponent()
                return naturalSort(aFolder, bFolder)
            }
            return [first] + sortedRest
        }()
        
        let reference = deduplicatedImages.first!
        let referenceFolder = URL(fileURLWithPath: reference.path).deletingLastPathComponent().path
        
        Group {
            // Reference image row, with focus and tap handling
            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { selectedForDeletion.contains(reference.path) },
                    set: { checked in
                        if checked { selectedForDeletion.insert(reference.path) }
                        else { selectedForDeletion.remove(reference.path) }
                    }
                )) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .frame(width: 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedGroupIndex = groupIndex
                    focusedImageIndex = 0
                }
                
                let folderName = URL(fileURLWithPath: reference.path).deletingLastPathComponent().lastPathComponent
                let fileName = URL(fileURLWithPath: reference.path).lastPathComponent
                let displayPath = folderName + "/" + fileName
                
                Text(displayPath)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(width: 220)
                
                Text("100%")
                    .font(.caption)
                    .foregroundColor(.primary)
                    .frame(width: 60)
                
                Image(nsImage: ImageAnalyzer.loadThumbnail(for: reference.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .cornerRadius(6)
                    .frame(width: 104)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedGroupIndex = groupIndex
                        focusedImageIndex = 0
                    }
                
                Spacer()
            }
            .background(
                (focusedGroupIndex == groupIndex && focusedImageIndex == 0) ?
                    AnyView(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.2))) : AnyView(EmptyView())
            )
            .contentShape(Rectangle())
            .onTapGesture {
                focusedGroupIndex = groupIndex
                focusedImageIndex = 0
            }
            .onHover { hovering in
                if hovering {
                    focusedGroupIndex = groupIndex
                    focusedImageIndex = 0
                }
            }
            
            // Matches rows
            ForEach(Array(deduplicatedImages.dropFirst().enumerated()), id: \.element.path) { (imageIndex, image) in
                let folderPath = URL(fileURLWithPath: image.path).deletingLastPathComponent().path
                let pathColor: Color = folderPath != referenceFolder ? .red : .primary
                
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { selectedForDeletion.contains(image.path) },
                        set: { checked in
                            if checked { selectedForDeletion.insert(image.path) }
                            else { selectedForDeletion.remove(image.path) }
                        }
                    )) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                    .frame(width: 20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedGroupIndex = groupIndex
                        focusedImageIndex = imageIndex + 1
                    }
                    
                    let folderName = URL(fileURLWithPath: image.path).deletingLastPathComponent().lastPathComponent
                    let fileName = URL(fileURLWithPath: image.path).lastPathComponent
                    let displayPath = folderName + "/" + fileName
                    
                    Text(displayPath)
                        .font(.caption)
                        .foregroundColor(pathColor)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(width: 220)
                    
                    Text("\(String(format: "%.0f", image.percent * 100))%")
                        .font(.caption)
                        .foregroundColor(.primary)
                        .frame(width: 60)
                    
                    Image(nsImage: ImageAnalyzer.loadThumbnail(for: image.path))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                        .cornerRadius(6)
                        .frame(width: 104)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focusedGroupIndex = groupIndex
                            focusedImageIndex = imageIndex + 1
                        }
                    
                    Spacer()
                }
                .background(
                    (focusedGroupIndex == groupIndex && focusedImageIndex == imageIndex + 1) ?
                        AnyView(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.2))) : AnyView(EmptyView())
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    focusedGroupIndex = groupIndex
                    focusedImageIndex = imageIndex + 1
                }
                .onHover { hovering in
                    if hovering {
                        focusedGroupIndex = groupIndex
                        focusedImageIndex = imageIndex + 1
                    }
                }
            }
        }
        .padding(.vertical, 4)
        Divider()
    }
}

struct LargeImagePreview: View {
    let path: String
    var body: some View {
        Image(nsImage: ImageAnalyzer.loadThumbnail(for: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 320, maxHeight: 320)
            .cornerRadius(8)
            .shadow(radius: 4)
    }
}

