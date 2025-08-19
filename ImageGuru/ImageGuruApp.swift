//
//  ImageGuruApp.swift
//  ImageGuru
//
//  Created by George Babichev on 8/6/25.
//

import SwiftUI

@main
struct ImageGuruApp: App {
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
    }
}

struct ActionsCommands: Commands {
    @ObservedObject var viewModel: AppViewModel
    
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
                //.disabled(viewModel.selectedFolderURLs.isEmpty)
            }
            
            Divider()
            
            Button("Clear All") {
                viewModel.clearAll()
            }
            .keyboardShortcut("l", modifiers: [.command])
           //.disabled(viewModel.selectedFolderURLs.isEmpty)
        }
    }
}
