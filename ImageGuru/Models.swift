import Foundation

/// Flattened table row representing a match between a reference image and a similar image.
struct TableRow: Identifiable, Hashable {
    var id: String { reference + "::" + similar }
    let reference: String
    let similar: String
    let percent: Double
}
