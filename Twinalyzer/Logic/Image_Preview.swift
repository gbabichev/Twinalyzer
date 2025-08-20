/*
 
 Image_Preview.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import ImageIO

// MARK: - Optimized Image Preview Component
/// High-performance SwiftUI view for displaying image thumbnails with intelligent caching
/// Handles async loading, memory management, and performance optimization for large image collections
/// Uses bucketed caching system to balance memory usage with display quality
/// ENHANCED: Now includes lazy loading to only load images when visible
struct PreviewImage: View {
    let path: String              // File system path to the image
    let maxDimension: CGFloat     // Maximum width/height for the displayed image
    let priority: TaskPriority    // Loading priority for this image
    
    @State private var image: NSImage?  // Currently loaded image (nil while loading)
    @State private var isLoading: Bool = false     // Loading state for better UX
    @State private var hasAppeared: Bool = false   // Track if view has appeared (lazy loading)
    @State private var loadingTask: Task<Void, Never>?  // Cancellable loading task
    
    // MARK: - Initializers
    /// Default initializer with standard priority
    init(path: String, maxDimension: CGFloat) {
        self.path = path
        self.maxDimension = maxDimension
        self.priority = .userInitiated
    }
    
    /// Priority-aware initializer for performance tuning
    /// Use .background for small thumbnails, .userInitiated for detail views
    init(path: String, maxDimension: CGFloat, priority: TaskPriority) {
        self.path = path
        self.maxDimension = maxDimension
        self.priority = priority
    }
    
    var body: some View {
        ZStack {
            if let img = image {
                // Display loaded image with aspect ratio preservation
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                // Loading indicator while image is being processed
                ProgressView()
                    .frame(width: min(32, maxDimension * 0.3), height: min(32, maxDimension * 0.3))
            } else {
                // Placeholder for unloaded images - scales with image size
                RoundedRectangle(cornerRadius: max(2, maxDimension * 0.05))
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.gray.opacity(0.6))
                            .font(.system(size: min(24, maxDimension * 0.3)))
                    )
            }
        }
        // LAZY LOADING: Only start loading when view appears
        .onAppear {
            if !hasAppeared {
                hasAppeared = true
                loadingTask = Task(priority: priority) {
                    await load()
                }
            }
        }
        .onDisappear {
            // Cancel loading task when view disappears to save resources
            loadingTask?.cancel()
            loadingTask = nil
        }
        // Legacy support: Also trigger on cache key changes for existing usage patterns
        .task(id: cacheKey) {
            // Only load if we've appeared (prevents eager loading)
            if hasAppeared {
                await load()
            }
        }
        // Accessibility support with filename as label
        .accessibilityLabel(Text((path as NSString).lastPathComponent))
    }

    // MARK: - Cache Key Generation
    /// Creates a unique cache identifier combining file path and size bucket
    /// Bucketing ensures we don't cache multiple sizes of the same image unnecessarily
    /// Example: "/path/to/image.jpg::320" for 320px bucket
    private var cacheKey: String {
        let bucket = ImageProcessingUtilities.cacheBucket(for: maxDimension)
        return "\(path)::\(bucket)"
    }

    /// Thread-safe image setter that must run on main thread for UI updates
    @MainActor private func setImage(_ img: NSImage?) {
        self.image = img
        self.isLoading = false
    }

    // MARK: - Enhanced Async Image Loading Pipeline
    /// Multi-stage loading process optimized for performance and memory efficiency
    /// 1. Check cache for immediate display (main thread)
    /// 2. Set loading state for better UX
    /// 3. Decode image off-main thread to avoid blocking UI
    /// 4. Create NSImage and update cache on main thread
    /// ENHANCED: Now includes cancellation support and loading states
    private func load() async {
        let key = cacheKey as NSString

        // STAGE 1: Fast cache lookup on main thread
        // If image is already cached, display immediately without any async work
        if let cached = ImageCache.shared.object(forKey: key) {
            setImage(cached)
            return
        }

        // STAGE 2: Set loading state for better user experience
        isLoading = true

        // STAGE 3: Determine target size and prepare for background processing
        let bucket = ImageProcessingUtilities.cacheBucket(for: maxDimension)
        let url = URL(fileURLWithPath: path)

        // STAGE 4: Decode image on background thread to avoid blocking UI
        // This is the expensive operation that involves file I/O and image decoding
        // Enhanced with cancellation support
        let cg: CGImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: priority.qosClass).async {
                // Check for cancellation before expensive operation
                guard !Task.isCancelled else {
                    cont.resume(returning: nil)
                    return
                }
                
                let result = ImageProcessingUtilities.downsampledCGImage(
                    at: url,
                    targetMaxDimension: CGFloat(bucket)
                )
                cont.resume(returning: result)
            }
        }

        // STAGE 5: Final cancellation check and UI update
        guard !Task.isCancelled else {
            isLoading = false
            return
        }

        // STAGE 6: Convert to NSImage and update cache on main thread
        // NSImage creation and cache updates must happen on main thread
        await MainActor.run {
            let ns = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let ns {
                ImageCache.shared.setObject(ns, forKey: key)
            }
            self.image = ns
            self.isLoading = false
        }
    }
}

// MARK: - TaskPriority QoS Extension
/// Maps TaskPriority to QoSClass for DispatchQueue compatibility
private extension TaskPriority {
    var qosClass: DispatchQoS.QoSClass {
        // Use rawValue comparison to handle all cases including future ones
        if self >= .high {
            return .userInteractive
        } else if self >= .userInitiated {
            return .userInitiated
        } else if self >= .medium {
            return .default
        } else if self >= .utility {
            return .utility
        } else {
            return .background
        }
    }
}
