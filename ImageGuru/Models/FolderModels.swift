//
//  FolderModels.swift
//  ImageGuru
//
//  Models for folder selection and management
//

import Foundation

// MARK: - Folder Selection Models

public struct LeafFolder: Identifiable, Comparable, Sendable {
    public let id = UUID()
    public let url: URL
    
    public var displayName: String {
        url.lastPathComponent
    }
    
    public var parentPath: String {
        url.deletingLastPathComponent().path
    }
    
    public var fullPath: String {
        url.path
    }
    
    public init(url: URL) {
        self.url = url
    }
    
    public static func < (lhs: LeafFolder, rhs: LeafFolder) -> Bool {
        lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }
    
    public static func == (lhs: LeafFolder, rhs: LeafFolder) -> Bool {
        lhs.url == rhs.url
    }
}
