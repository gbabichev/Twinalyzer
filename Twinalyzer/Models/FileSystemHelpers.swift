//
//  FileSystemHelpers.swift
//  ImageGuru
//
//  Created by George Babichev on 8/19/25.
//


//
//  FileSystemHelpers.swift
//  ImageGuru
//
//  Utilities for file system operations
//

import Foundation

public enum FileSystemHelpers {
    /// Recursively finds all leaf folders from a list of folder URLs.
    public static func findLeafFolders(from urls: [URL]) -> [URL] {
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
    
    /// Checks if a URL represents a directory
    public static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    
    /// Filters URLs to only include directories
    public static func filterDirectories(from urls: [URL]) -> [URL] {
        return urls.filter { isDirectory($0) }
    }
    
    /// Gets unique URLs by standardizing file paths
    public static func uniqueURLs(from urls: [URL], existingURLs: [URL] = []) -> [URL] {
        let existing = Set(existingURLs.map { $0.standardizedFileURL })
        return urls.filter { !existing.contains($0.standardizedFileURL) }
    }
}