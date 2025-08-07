// ContentViewHelpers.swift
// Helper functions extracted from ContentView.swift
import Foundation
import AppKit

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

/// Recursively finds the first NSTableView in the view hierarchy.
func findTableView(in view: NSView?) -> NSTableView? {
    guard let view else { return nil }
    if let table = view as? NSTableView { return table }
    for sub in view.subviews {
        if let found = findTableView(in: sub) {
            return found
        }
    }
    return nil
}
