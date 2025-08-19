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
struct PreviewImage: View {
    let path: String              // File system path to the image
    let maxDimension: CGFloat     // Maximum width/height for the displayed image
    @State private var image: NSImage?  // Currently loaded image (nil while loading)
    
    var body: some View {
        ZStack {
            if let img = image {
                // Display loaded image with aspect ratio preservation
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .border(Color.gray.opacity(0.4))
            } else {
                // Loading indicator while image is being processed
                ProgressView().frame(width: 32, height: 32)
            }
        }
        // Trigger loading when cache key changes (path or size requirements)
        .task(id: cacheKey) {
            await load()
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
    @MainActor private func setImage(_ img: NSImage?) { self.image = img }

    // MARK: - Async Image Loading Pipeline
    /// Multi-stage loading process optimized for performance and memory efficiency
    /// 1. Check cache for immediate display (main thread)
    /// 2. Decode image off-main thread to avoid blocking UI
    /// 3. Create NSImage and update cache on main thread
    private func load() async {
        let key = cacheKey as NSString

        // STAGE 1: Fast cache lookup on main thread
        // If image is already cached, display immediately without any async work
        if let cached = ImageCache.shared.object(forKey: key) {
            setImage(cached)
            return
        }

        // STAGE 2: Determine target size and prepare for background processing
        let bucket = ImageProcessingUtilities.cacheBucket(for: maxDimension)
        let url = URL(fileURLWithPath: path)

        // STAGE 3: Decode image on background thread to avoid blocking UI
        // This is the expensive operation that involves file I/O and image decoding
        let cg: CGImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ImageProcessingUtilities.downsampledCGImage(at: url, targetMaxDimension: CGFloat(bucket)))
            }
        }

        // STAGE 4: Convert to NSImage and update cache on main thread
        // NSImage creation and cache updates must happen on main thread
        await MainActor.run {
            let ns = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let ns { ImageCache.shared.setObject(ns, forKey: key) }
            self.image = ns
        }
    }
}
