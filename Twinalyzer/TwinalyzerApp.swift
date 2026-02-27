/*
 
 TwinalyzerApp.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import UserNotifications

extension Notification.Name {
    static let showTutorial = Notification.Name("showTutorial")
    static let showAbout = Notification.Name("showAbout")
}

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
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appViewModel.clearDockBadge()
                }
                .task {
                    // Runs once when ContentView appears on launch
                    await requestNotificationAuthIfNeeded()
                }
        }
        .commands {
            ActionsCommands(viewModel: appViewModel)
            SidebarCommands()
        }
    }
}

struct ActionsCommands: Commands {
    @ObservedObject var viewModel: AppViewModel
    
    var body: some Commands {
        // Override the File menu to add Open command
        CommandGroup(replacing: .newItem) {
            Button {
                selectFolders()
            } label: {
                Label("Open Folder…", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(viewModel.isAnyOperationRunning) // FIXED: Use isAnyOperationRunning consistently
            
            Button {
                viewModel.triggerCSVExport()
            } label: {
                Label("Export CSV…", systemImage: "tablecells")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift]) // ⇧⌘E
            .disabled(viewModel.isAnyOperationRunning || viewModel.comparisonResults.isEmpty) // FIXED: Use isAnyOperationRunning
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
                    Label("Analyze Images", systemImage: "sparkle")
                }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(viewModel.activeLeafFolders.isEmpty)
            }
            
            Divider()
            
            Button {
                viewModel.deletePendingSelections()
            } label: {
                Label("Delete Matches", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(viewModel.isAnyOperationRunning || !viewModel.hasSelectedMatches) // FIXED: Use isAnyOperationRunning
            
            Button {
                viewModel.clearSelection()
            } label: {
                Label("Clear Selection", systemImage: "checkmark.circle.badge.xmark")
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(viewModel.isAnyOperationRunning || !viewModel.hasSelectedMatches) // FIXED: Use isAnyOperationRunning

            Divider()

            Button {
                viewModel.deleteMatchedFolders()
            } label: {
                Label("Delete Matched Folders", systemImage: "folder.badge.minus")
            }
            .disabled(viewModel.isAnyOperationRunning || viewModel.orderedCrossFolderPairsStatic.isEmpty)

            Divider()

            Button {
                viewModel.clearAll()
            } label: {
                Label("Clear All", systemImage: "arrow.counterclockwise")
            }
            .keyboardShortcut("l", modifiers: [.command])
            .disabled(viewModel.activeLeafFolders.isEmpty || viewModel.isAnyOperationRunning)
        }
        
        CommandGroup(replacing: .help) {
            Button("Show Tutorial") {
                NotificationCenter.default.post(name: .showTutorial, object: nil)
            }
            .keyboardShortcut("?", modifiers: [.command, .shift])

            Button("Twinalyzer Help") {
                if let url = URL(string: "https://github.com/gbabichev/") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
        
        CommandGroup(replacing: .appInfo) {
            Button("About Twinalyzer") {
                NotificationCenter.default.post(name: .showAbout, object: nil)
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

@MainActor
func requestNotificationAuthIfNeeded() async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    
    switch settings.authorizationStatus {
    case .notDetermined:
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        print("🔔 Notifications granted? \(granted)")
    case .denied:
        print("🔕 Notifications denied by user.")
    case .authorized, .provisional, .ephemeral:
        print("✅ Notifications already authorized.")
    @unknown default:
        break
    }
}
