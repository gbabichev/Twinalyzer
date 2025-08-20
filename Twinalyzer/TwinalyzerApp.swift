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
            }
            
            Divider()
            
            Button("Clear All") {
                viewModel.clearAll()
            }
            .keyboardShortcut("l", modifiers: [.command])
        }
        
        CommandGroup(replacing: .appInfo) {
            Button("About Twinalyzer") {
                openWindow(id: "AboutWindow")
            }
        }
    }
}
