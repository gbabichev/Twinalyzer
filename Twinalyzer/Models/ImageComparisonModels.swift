/*
 
 ImageComparisonModels.swift - Simplified Version
 Twinalyzer
 
 */

import Foundation

// MARK: - Analysis Configuration Models
enum AnalysisMode: String, CaseIterable, Identifiable, RawRepresentable {
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

// MARK: - Hierarchical Result (unchanged)
struct ImageComparisonResult: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    let reference: String
    let similars: [(path: String, percent: Double)]
    
    nonisolated init(reference: String, similars: [(path: String, percent: Double)]) {
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
