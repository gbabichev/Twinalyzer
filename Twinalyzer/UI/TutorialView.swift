/*

 TutorialView.swift
 Twinalyzer

 First-launch tutorial overlay showing how to use the app.

 George Babichev

 */

import SwiftUI

struct TutorialView: View {
    @Binding var isPresented: Bool
    @State private var dontShowAgain = UserDefaults.standard.bool(forKey: "hasSeenTutorial")

    var body: some View {
        ZStack {
            // Semi-transparent background overlay
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Tutorial content card
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.yellow)

                    Text("Welcome to Twinalyzer")
                        .font(.title)
                        .bold()

                    Text("Find and manage duplicate images")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Tutorial steps
                VStack(alignment: .leading, spacing: 20) {
                    TutorialStep(
                        icon: "folder",
                        title: "1. Open Folders",
                        description: "Click the folder icon or use \u{2318}O to select parent folders containing images to scan."
                    )
                    
                    TutorialStep(
                        icon: "gearshape",
                        title: "2. Adjust Settings",
                        description: "Fine-tune similarity threshold, hash algorithm, and other options in the Settings panel."
                    )

                    TutorialStep(
                        icon: "sparkle",
                        title: "3. Analyze Images",
                        description: "Click 'Analyze' or press \u{2318}P to start finding duplicate image."
                    )

                    TutorialStep(
                        icon: "checklist",
                        title: "4. Review Matches"
                    ) {
                        Text("Browse the results table. ") +
                        Text("Press Space to preview images, Z to mark references, X to mark matches for deletion.").bold()
                    }

                    TutorialStep(
                        icon: "trash",
                        title: "4. Delete Duplicates",
                        description: "Select images to delete and click the trash icon or press \u{2318}\u{232B} to remove them."
                    )


                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Footer with checkbox and dismiss button
                VStack(spacing: 12) {
                    Text("You can always re-open the tutorial from the Help Menu!")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Don't show this again", isOn: $dontShowAgain)
                        .toggleStyle(.checkbox)

                    Button {
                        dismiss()
                    } label: {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(32)
            .frame(width: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(16)
            .shadow(radius: 20)
        }
    }

    private func dismiss() {
        UserDefaults.standard.set(dontShowAgain, forKey: "hasSeenTutorial")
        isPresented = false
    }
}

// MARK: - Tutorial Step Component

struct TutorialStep<Description: View>: View {
    let icon: String
    let title: String
    let description: Description

    init(icon: String, title: String, description: String) where Description == Text {
        self.icon = icon
        self.title = title
        self.description = Text(description)
    }

    init(icon: String, title: String, @ViewBuilder description: () -> Description) {
        self.icon = icon
        self.title = title
        self.description = description()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                description
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    TutorialView(isPresented: .constant(true))
}
