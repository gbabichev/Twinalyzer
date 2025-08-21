/*
 
 ImageComparisonModels.swift
 Twinalyzer
 
 George Babichev
 
 */

//
//  Core data models for image comparison and analysis
//  Defines the fundamental data structures used throughout the duplicate detection pipeline
//  All models are Sendable for Swift 6 concurrency safety
//

import Foundation

// MARK: - Analysis Configuration Models
/// Configuration enums and types that control how image analysis is performed

/// Defines the two available analysis methods with user-friendly names
/// Each mode represents a different algorithmic approach with distinct trade-offs
public enum AnalysisMode: String, CaseIterable, Identifiable, RawRepresentable {
    case deepFeature = "Enhanced Scan"
    case perceptualHash = "Basic Scan"
    
    public var id: String { rawValue }
    
    // RawRepresentable conformance (may be automatically synthesized)
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

// MARK: - Core Data Models
/// Fundamental data structures for representing comparison results

/// Represents a single duplicate relationship between two images
/// Used primarily for table/list display in the UI where each row shows one comparison pair
/// Forms the basic building block for all duplicate visualizations
public struct TableRow: Identifiable, Hashable, Sendable {
    public var id: String { reference + "::" + similar }

    public let reference: String
    public let similar: String
    public let percent: Double

    // NEW: precomputed display + flag
    public let referenceShort: String
    public let similarShort: String
    public let isCrossFolder: Bool

    public nonisolated init(reference: String, similar: String, percent: Double) {
        self.reference = reference
        self.similar = similar
        self.percent = percent

        // Precompute short paths (last two components) & cross-folder flag
        let refURL = URL(fileURLWithPath: reference)
        let simURL = URL(fileURLWithPath: similar)

        self.referenceShort = TableRow.shortDisplayPath(refURL)
        self.similarShort  = TableRow.shortDisplayPath(simURL)

        let refFolder = refURL.deletingLastPathComponent().path
        let simFolder = simURL.deletingLastPathComponent().path
        self.isCrossFolder = (refFolder != simFolder)
    }

    // Same logic your DisplayHelpers used, but kept local to the model
    private nonisolated static func shortDisplayPath(_ url: URL) -> String {
        let components = url.pathComponents
        return components.count >= 2
            ? components.suffix(2).joined(separator: "/")
            : url.lastPathComponent
    }
}


/// Hierarchical representation of duplicate groups with one reference and multiple matches
/// This is the primary output format from the analysis engine
/// Groups related duplicates together for efficient processing and display
public struct ImageComparisonResult: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID                                          // Unique identifier for this result group
    public let reference: String                                 // Primary/reference image path
    public let similars: [(path: String, percent: Double)]      // All similar images with their similarity scores
    
    /// Creates a new comparison result with automatic UUID generation
    /// Similars array can include the reference itself with 100% similarity
    public nonisolated init(reference: String, similars: [(path: String, percent: Double)]) {
        self.id = UUID()
        self.reference = reference
        self.similars = similars
    }
    
    /// Equality based on UUID for stable collection operations
    /// Two results are equal if they have the same UUID, regardless of content
    public static func == (lhs: ImageComparisonResult, rhs: ImageComparisonResult) -> Bool {
        lhs.id == rhs.id
    }
    
    /// Hash implementation using UUID for efficient Set/Dictionary operations
    public func hash(into h: inout Hasher) {
        h.combine(id)
    }
}

// MARK: - Display and UI Helper Extensions
/// Extensions providing formatted data for UI presentation

extension TableRow {
    /// Converts decimal similarity to integer percentage for display
    /// Example: 0.847 becomes 85 (rounded)
    public var percentInt: Int {
        Int((percent * 100).rounded())
    }
    
    /// Creates a zero-padded string suitable for lexicographic sorting
    /// Ensures proper numerical ordering in table columns (e.g., "095" sorts before "100")
    /// Used by SwiftUI Table for consistent sort behavior
    public var percentSortKey: String {
        String(format: "%03d", percentInt)
    }
    
    /// User-friendly percentage string for display in UI
    /// Example: 85% (includes percentage symbol)
    public var percentDisplay: String {
        "\(percentInt)%"
    }
}

