import SwiftUI
import AppKit
import ImageIO

enum AnalysisMode: String, CaseIterable, Identifiable {
    case perceptualHash = "Perceptual Hash"
    case deepFeature = "Deep Feature Embedding"
    var id: String { rawValue }
}

/// Root view using a lightweight state and a dedicated AppViewModel for data/logic.
struct ContentView: View {
    @StateObject var vm = AppViewModel()

    // Selection + sorting remains in the view for keyboard focus reasons
    @State var selectedRowID: String? = nil
    @State var selectedRowIDs: Set<String> = []
    @State var toggleVersion = 0
    @State var sortOrder: [KeyPathComparator<TableRow>] = []

    var sortedRows: [TableRow] {
        let rows = vm.flattenedResults  // Changed from vm.cachedFlattened
        guard !sortOrder.isEmpty else { return rows }
        return rows.sorted(using: sortOrder)
    }

    var selectedRow: TableRow? {
        sortedRows.first(where: { $0.id == selectedRowID })
    }

    var selectedMatches: [String] {
        vm.flattenedResults.filter { selectedRowIDs.contains($0.id) }.map { $0.similar }  // Changed from vm.cachedFlattened
    }

    var body: some View {
        Group {
            if vm.isProcessing { processingView }
            else { mainSplitView }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { installSpacebarToggle() }
        // Removed the onChange modifiers since foldersToScanLabel is now computed
        // and recomputeDerived() is no longer needed
    }

    var mainSplitView: some View {
        VSplitView {
            topSplitView
            bottomSplitView
        }
    }
}
