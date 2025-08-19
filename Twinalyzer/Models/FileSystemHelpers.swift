/*
 
 FileSystemHelpers.swift
 Twinalyzer
 
 George Babichev
 
 */

import Foundation

// MARK: - File System Utility Functions
/// Static utility enum providing common file system operations for directory management
/// All functions are designed to be safe, efficient, and handle edge cases gracefully
/// Used throughout the app for folder discovery, validation, and deduplication
public enum FileSystemHelpers {
    
    // MARK: - Leaf Folder Discovery
    /// Recursively finds all leaf folders (directories with no subdirectories) from a list of root URLs
    /// Useful for discovering the deepest folder levels that actually contain files
    /// Deduplicates results automatically using a Set to avoid processing the same folder multiple times
    ///
    /// Example: Given "/Photos" containing "/Photos/2023" and "/Photos/2024" (both empty of subdirs),
    /// returns ["/Photos/2023", "/Photos/2024"] but not "/Photos"
    public static func findLeafFolders(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var leafFolders = [URL]()
        var seen = Set<URL>()  // Prevents duplicate processing of the same folder

        /// Recursive helper function that traverses directory tree depth-first
        /// Adds folders to leafFolders only if they contain no subdirectories
        func recurse(_ url: URL) {
            // Attempt to read directory contents, safely handling permission errors
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) {
                // Filter contents to find only subdirectories (not files)
                let subfolders = contents.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                
                if subfolders.isEmpty {
                    // This is a leaf folder (no subdirectories) - add it to results
                    if seen.insert(url).inserted {
                        leafFolders.append(url)
                    }
                } else {
                    // This folder has subdirectories - recurse into each one
                    for subfolder in subfolders {
                        recurse(subfolder)
                    }
                }
            }
            // Note: If directory reading fails (permissions, etc.), we silently skip it
        }

        // Start recursion from each provided root URL
        for url in urls {
            recurse(url)
        }

        return leafFolders
    }
    
    // MARK: - Directory Validation
    /// Safely checks if a URL represents a directory (not a file or non-existent path)
    /// Uses FileManager's fileExists method with directory flag for accuracy
    /// Returns false for files, symbolic links to files, or non-existent paths
    public static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    
    // MARK: - URL Filtering
    /// Filters a list of URLs to include only those that represent valid directories
    /// Useful for processing drag-and-drop operations or file picker results
    /// Automatically excludes files, broken links, and non-existent paths
    public static func filterDirectories(from urls: [URL]) -> [URL] {
        return urls.filter { isDirectory($0) }
    }
    
    // MARK: - Deduplication
    /// Returns unique URLs by comparing standardized file paths
    /// Prevents duplicate folder processing when users select overlapping directories
    /// Uses standardizedFileURL to resolve symbolic links and relative paths for accurate comparison
    ///
    /// Parameters:
    /// - urls: New URLs to check for uniqueness
    /// - existingURLs: Already selected URLs to compare against (defaults to empty)
    ///
    /// Example: If existingURLs contains "/Users/john/Photos" and urls contains
    /// "/Users/john/Photos/../Photos", this will detect them as duplicates and exclude the new one
    public static func uniqueURLs(from urls: [URL], existingURLs: [URL] = []) -> [URL] {
        // Create set of standardized existing URLs for O(1) lookup performance
        let existing = Set(existingURLs.map { $0.standardizedFileURL })
        
        // Filter new URLs to exclude any that already exist
        return urls.filter { !existing.contains($0.standardizedFileURL) }
    }
}
