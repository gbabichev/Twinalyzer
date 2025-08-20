/*
 
 TwinalyzerApp.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI

@main
struct TwinalyzerApp: App {
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
        Window("About Thumbnailer", id: "AboutWindow") {
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
            Button("Open Folder...") {
                selectFolders()
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(viewModel.isProcessing)
        }
        
        CommandMenu("Actions") {
            if viewModel.isProcessing {
                Button("Cancel Analysis") {
                    viewModel.cancelAnalysis()
                }
                .keyboardShortcut(.escape)
            } else {
                Button("Analyze Images") {
                    viewModel.processImages(progress: { _ in })
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(viewModel.activeLeafFolders.isEmpty)
            }
            
            Divider()
            
            // Delete Matches command - cmd+del
            Button("Delete Matches") {
                viewModel.deleteSelectedMatches()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(viewModel.isProcessing || !viewModel.hasSelectedMatches)
            
            // Clear Selection command - cmd+opt+l
            Button("Clear Selection") {
                viewModel.clearSelection()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(viewModel.isProcessing || !viewModel.hasSelectedMatches)
            
            Button("Clear All") {
                viewModel.clearAll()
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(viewModel.selectedParentFolders.isEmpty || viewModel.isProcessing)
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
