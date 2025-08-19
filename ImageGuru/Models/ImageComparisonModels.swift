//
//  ImageComparisonModels.swift
//  ImageGuru
//
//  Core data models for image comparison and analysis
//

import Foundation

// MARK: - Analysis Configuration

public enum AnalysisMode: String, CaseIterable, Identifiable {
    case deepFeature = "Enhanced Scan" // Deep Feature Embedding
    case perceptualHash = "Basic Scan" // Perceptual Hash
    public var id: String { rawValue }
}

// MARK: - Comparison Results

public struct TableRow: Identifiable, Hashable, Sendable {
    public var id: String { reference + "::" + similar }
    public let reference: String
    public let similar: String
    public let percent: Double
    
    public nonisolated init(reference: String, similar: String, percent: Double) {
        self.reference = reference
        self.similar = similar
        self.percent = percent
    }
}

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

// MARK: - TableRow Display Extensions

extension TableRow {
    public var percentInt: Int {
        Int((percent * 100).rounded())
    }
    
    public var percentSortKey: String {
        String(format: "%03d", percentInt)
    }
    
    public var percentDisplay: String {
        "\(percentInt)%"
    }
}
