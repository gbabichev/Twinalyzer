/*
 
 ImageComparisonModels.swift - Simplified Version
 Twinalyzer
 
 */

import Foundation

// MARK: - Analysis Configuration Models
public enum AnalysisMode: String, CaseIterable, Identifiable, RawRepresentable {
    case deepFeature = "Enhanced Scan"
    case perceptualHash = "Basic Scan"
    
    public var id: String { rawValue }
    
    public var rawValue: String {
        switch self {
        case .deepFeature: return "Enhanced Scan"
        case .perceptualHash: return "Basic Scan"
        }
    }
    
    public init?(rawValue: String) {
        switch rawValue {
        case "Enhanced Scan": self = .deepFeature
        case "Basic Scan": self = .perceptualHash
        default: return nil
        }
    }
}

// MARK: - Simplified TableRow with Native Sorting Support
/// Simplified table row that works perfectly with SwiftUI's native Table sorting
/// All computed properties are lightweight and work great with KeyPath-based sorting
public struct TableRow: Identifiable, Hashable, Sendable {
    public var id: String { reference + "::" + similar }
    
    public let reference: String
    public let similar: String
    public let percent: Double
    
    // MARK: - Computed Properties for Native Sorting
    /// Short display path for reference (last 2 components)
    public var referenceShort: String {
        let url = URL(fileURLWithPath: reference)
        let components = url.pathComponents
        return components.count >= 2 ? components.suffix(2).joined(separator: "/") : url.lastPathComponent
    }
    
    /// Short display path for similar (last 2 components)
    public var similarShort: String {
        let url = URL(fileURLWithPath: similar)
        let components = url.pathComponents
        return components.count >= 2 ? components.suffix(2).joined(separator: "/") : url.lastPathComponent
    }
    
    /// Cross-folder detection for sorting and display
    public var isCrossFolder: Bool {
        let refFolder = URL(fileURLWithPath: reference).deletingLastPathComponent().path
        let simFolder = URL(fileURLWithPath: similar).deletingLastPathComponent().path
        return refFolder != simFolder
    }
    
    /// Cross-folder as sortable string ("Yes"/"No")
    public var crossFolderText: String {
        isCrossFolder ? "Yes" : "No"
    }
    
    /// Integer percentage for display
    public var percentInt: Int {
        Int((percent * 100).rounded())
    }
    
    /// Display percentage with % symbol
    public var percentDisplay: String {
        "\(percentInt)%"
    }
    
    public nonisolated init(reference: String, similar: String, percent: Double) {
        self.reference = reference
        self.similar = similar
        self.percent = percent
    }
}

// MARK: - Hierarchical Result (unchanged)
public struct ImageComparisonResult: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let reference: String
    public let similars: [(path: String, percent: Double)]
    
    public nonisolated init(reference: String, similars: [(path: String, percent: Double)]) {
        self.id = UUID()
        self.reference = reference
        self.similars = similars
    }
    
    public static func == (lhs: ImageComparisonResult, rhs: ImageComparisonResult) -> Bool {
        lhs.id == rhs.id
    }
    
    public func hash(into h: inout Hasher) {
        h.combine(id)
    }
}
