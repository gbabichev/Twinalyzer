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
public enum AnalysisMode: String, CaseIterable, Identifiable {
    case deepFeature = "Enhanced Scan"    // AI-based analysis using Vision framework
    case perceptualHash = "Basic Scan"    // Fast fingerprint-based comparison
    
    public var id: String { rawValue }
    
    // Analysis method characteristics:
    // Enhanced Scan: Slower but more intelligent, detects similar content with different crops/lighting
    // Basic Scan: Faster but stricter, good for finding exact or near-exact duplicates
}

// MARK: - Core Data Models
/// Fundamental data structures for representing comparison results

/// Represents a single duplicate relationship between two images
/// Used primarily for table/list display in the UI where each row shows one comparison pair
/// Forms the basic building block for all duplicate visualizations
public struct TableRow: Identifiable, Hashable, Sendable {
    /// Unique identifier combining both file paths for stable row identity
    /// Format: "reference_path::similar_path" ensures each comparison pair has unique ID
    public var id: String { reference + "::" + similar }
    
    public let reference: String    // File path of the reference image (typically chosen as "original")
    public let similar: String      // File path of the matching/duplicate image
    public let percent: Double      // Similarity percentage (0.0 to 1.0)
    
    /// Initializer marked nonisolated for Swift 6 concurrency compliance
    public nonisolated init(reference: String, similar: String, percent: Double) {
        self.reference = reference
        self.similar = similar
        self.percent = percent
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
