//
//  UI_Helpers.swift
//  ImageGuru
//
//  Created by George Babichev on 8/8/25.
//

import SwiftUI
import AppKit

extension ContentView {
    // MARK: - UI helpers for view-specific functionality only

    func toggleSelectedRow() {
        guard let id = selectedRowID else { return }
        if selectedRowIDs.contains(id) {
            selectedRowIDs.remove(id)
        } else {
            selectedRowIDs.insert(id)
        }
    }
    
    func installSpacebarToggle() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 49 = spacebar
            if event.keyCode == 49 {
                toggleSelectedRow()
                return nil // swallow the event so it doesn't scroll the view
            }
            return event
        }
    }
}
