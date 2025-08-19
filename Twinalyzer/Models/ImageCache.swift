/*
 
 ImageCache.swift
 Twinalyzer
 
 George Babichev
 
 */

//
//  Centralized image caching for preview thumbnails
//  Provides memory-efficient thumbnail generation and intelligent cache bucket sizing
//

import AppKit
import ImageIO
import CoreGraphics

// MARK: - Centralized Image Cache System
/// Singleton cache manager for storing processed image thumbnails in memory
/// Uses NSCache for automatic memory pressure handling and LRU eviction
/// Configured with reasonable limits to balance performance with memory usage
public final class ImageCache {
    /// Shared cache instance accessible throughout the app
    /// NSCache is thread-safe and handles memory pressure automatically
    public static let shared = NSCache<NSString, NSImage>()
    
    /// Private initializer to enforce singleton pattern
    /// Configures cache limits during first access to shared instance
    private init() {
        // Configure cache limits to prevent excessive memory usage
        ImageCache.shared.countLimit = 200  // Max 200 cached images (reasonable for preview UI)
        ImageCache.shared.totalCostLimit = 50 * 1024 * 1024  // 50MB limit (balances memory vs performance)
        
        // Note: NSCache automatically evicts items under memory pressure
        // and provides LRU (Least Recently Used) eviction policy
    }
}

// MARK: - Image Processing Utilities
/// Static utility functions for efficient image processing and cache management
/// All functions are nonisolated for Swift 6 concurrency safety
/// Focuses on memory-efficient thumbnail generation and smart cache bucketing
public enum ImageProcessingUtilities {

    // MARK: - Thumbnail Generation
    /// Creates a downsampled CGImage from a file URL using ImageIO for efficiency
    /// This is significantly more memory-efficient than loading full images and resizing
    /// Uses hardware-accelerated decoding when available for better performance
    ///
    /// Parameters:
    /// - url: File URL of the source image
    /// - targetMaxDimension: Maximum width or height for the resulting thumbnail
    ///
    /// Returns: Downsampled CGImage or nil if processing fails
    public nonisolated static func downsampledCGImage(at url: URL, targetMaxDimension: CGFloat) -> CGImage? {
        // Create image source from file URL
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        
        // Configure thumbnail generation options for optimal quality and performance
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,    // Always create thumbnail (even if none exists)
            kCGImageSourceCreateThumbnailWithTransform: true,     // Apply EXIF orientation automatically
            kCGImageSourceShouldCache: false,                     // Don't cache at ImageIO level (we handle caching)
            kCGImageSourceThumbnailMaxPixelSize: Int(targetMaxDimension)  // Target size constraint
        ]
        
        // Generate thumbnail at index 0 (main image) with specified options
        // This is much more memory-efficient than loading full image and scaling down
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
    
    // MARK: - Cache Bucket System
    /// Determines the appropriate cache bucket size for a given display dimension
    /// Bucketing prevents caching multiple similar sizes of the same image
    /// Reduces memory usage while maintaining acceptable quality for different UI contexts
    ///
    /// Strategy: Uses progressive bucket sizes optimized for common display scenarios:
    /// - 320px: Small thumbnails, list views, badges
    /// - 640px: Medium previews, table cells
    /// - 1024px: Large previews, detail views
    /// - 1600px: High-quality previews, comparison views
    /// - 2048px: Maximum quality for detailed inspection
    ///
    /// Example: Requesting 350px will use 640px bucket, requesting 1200px uses 1600px bucket
    public nonisolated static func cacheBucket(for dimension: CGFloat) -> Int {
        if dimension <= 320 { return 320 }      // Small thumbnails (sidebar, badges)
        if dimension <= 640 { return 640 }      // Medium previews (table cells)
        if dimension <= 1024 { return 1024 }    // Large previews (detail panes)
        if dimension <= 1600 { return 1600 }    // High-quality previews (comparison views)
        return 2048                             // Maximum quality (detailed inspection)
    }
}
