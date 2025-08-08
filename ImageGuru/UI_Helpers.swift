//
//  UI_Helpers.swift
//  ImageGuru
//
//  Created by George Babichev on 8/8/25.
//

import SwiftUI
import AppKit

extension ContentView {
    // MARK: - UI helpers still owned by the view

    func toggleSelectedRow() {
        guard let id = selectedRowID else { return }
        if selectedRowIDs.contains(id) {
            selectedRowIDs.remove(id)
        } else {
            selectedRowIDs.insert(id)
        }
    }    
    
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

    /// Recursively finds all leaf folders from a list of folder URLs.
    func findLeafFolders(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var leafFolders = [URL]()
        var seen = Set<URL>()

        func recurse(_ url: URL) {
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                let subfolders = contents.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                if subfolders.isEmpty {
                    if seen.insert(url).inserted {
                        leafFolders.append(url)
                    }
                } else {
                    for subfolder in subfolders {
                        recurse(subfolder)
                    }
                }
            }
        }

        for url in urls {
            recurse(url)
        }

        return leafFolders
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
    
    func shortDisplayPath(for fullPath: String) -> String {
        let url = URL(fileURLWithPath: fullPath)
        let comps = url.pathComponents
        if comps.count >= 2 {
            return comps.suffix(2).joined(separator: "/")
        } else {
            return url.lastPathComponent
        }
    }

    
    
    
    
}

