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
    @State var sortOrder: [KeyPathComparator<TableRow>] = [
        .init(\.percent, order: .reverse)
    ]

    var sortedRows: [TableRow] {
        var rows = vm.cachedFlattened
        rows.sort(using: sortOrder)
        return rows
    }

    var selectedRow: TableRow? {
        sortedRows.first(where: { $0.id == selectedRowID })
    }

    var selectedMatches: [String] {
        vm.cachedFlattened.filter { selectedRowIDs.contains($0.id) }.map { $0.similar }
    }

    var body: some View {
        Group {
            if vm.isProcessing { processingView }
            else { mainSplitView }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { installSpacebarToggle() }
        .onChange(of: vm.selectedFolderURLs) { _, urls in
            let leafs = findLeafFolders(from: urls)
            vm.foldersToScanLabel = leafs.map { $0.lastPathComponent }.joined(separator: "\n")
        }
        .onChange(of: vm.comparisonResults.count) { _, _ in vm.recomputeDerived() }
    }

    var mainSplitView: some View {
        VSplitView {
            topSplitView
            bottomSplitView
        }
    }
}

