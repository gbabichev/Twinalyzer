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
enum FileSystemHelpers {
    
    // MARK: - Directory Validation
    /// Safely checks if a URL represents a directory (not a file or non-existent path)
    /// Uses FileManager's fileExists method with directory flag for accuracy
    /// Returns false for files, symbolic links to files, or non-existent paths
    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    
    // MARK: - URL Filtering
    /// Filters a list of URLs to include only those that represent valid directories
    /// Useful for processing drag-and-drop operations or file picker results
    /// Automatically excludes files, broken links, and non-existent paths
    static func filterDirectories(from urls: [URL]) -> [URL] {
        return urls.filter { isDirectory($0) }
    }
    
}
