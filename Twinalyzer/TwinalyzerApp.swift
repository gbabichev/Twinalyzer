/*
 
 TwinalyzerApp.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI

@main
struct TwinalyzerApp: App {
    init() {
        ImageCache.ensureBootstrapped()
    }
    
    @StateObject private var appViewModel = AppViewModel()
    
    var body: some Scene {

        WindowGroup {
            ContentView()
                .environmentObject(appViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            ActionsCommands(viewModel: appViewModel)
        }
    
        // MARK: - Custom About Window
        Window("About Twinalyzer", id: "AboutWindow") {
            AboutView()
                .frame(width: 400, height: 400)
        }
        .windowResizability(.contentSize) // Makes window non-resizable and size == content
        .defaultSize(width: 400, height: 400)
        .windowStyle(.hiddenTitleBar)
        
    }
}

struct ActionsCommands: Commands {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.openWindow) private var openWindow
    
    var body: some Commands {
        // Override the File menu to add Open command
        CommandGroup(replacing: .newItem) {
            Button {
                selectFolders()
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(viewModel.isProcessing)

            Button {
                viewModel.triggerCSVExport()
            } label: {
                Label("Export CSV…", systemImage: "tablecells")
            }
            .disabled(viewModel.isProcessing || viewModel.comparisonResults.isEmpty)

        }
        


        
        CommandMenu("Actions") {
            if viewModel.isProcessing {
                Button {
                    viewModel.cancelAnalysis()
                } label: {
                    Label("Cancel Analysis", systemImage: "xmark.circle")
                }
                .keyboardShortcut(.escape)
            } else {
                Button {
                    viewModel.processImages(progress: { _ in })
                } label: {
                    Label("Analyze Images", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(viewModel.activeLeafFolders.isEmpty)
            }
            
            Divider()
            
            Button {
                viewModel.deleteSelectedMatches()
            } label: {
                Label("Delete Matches", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(viewModel.isProcessing || !viewModel.hasSelectedMatches)
            
            Button {
                viewModel.clearSelection()
            } label: {
                Label("Clear Selection", systemImage: "checkmark.circle.badge.xmark")
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(viewModel.isProcessing || !viewModel.hasSelectedMatches)
            
            Button {
                viewModel.clearAll()
            } label: {
                Label("Clear All", systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(viewModel.selectedParentFolders.isEmpty || viewModel.isProcessing)
        }

        CommandGroup(replacing: .help) {
            Button("Twinalyzer Help") {
                if let url = URL(string: "https://github.com/gbabichev/") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
        
        CommandGroup(replacing: .appInfo) {
            Button("About Twinalyzer") {
                openWindow(id: "AboutWindow")
            }
        }
    }
    
    // MARK: - Helper Methods
    /// Presents a native macOS folder picker for selecting parent directories
    /// Configured to allow multiple directory selection for batch processing
    /// Automatically adds selected folders to the view model for analysis
    private func selectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Select Parent Folders to Scan"
        
        if panel.runModal() == .OK {
            viewModel.addParentFolders(panel.urls)
        }
    }
}
