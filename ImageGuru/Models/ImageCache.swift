//
//  ImageCache.swift
//  ImageGuru
//
//  Centralized image caching for preview thumbnails
//

import AppKit
import ImageIO
import CoreGraphics

// MARK: - Image Cache

public final class ImageCache {
    public static let shared = NSCache<NSString, NSImage>()
    
    private init() {
        // Configure cache limits
        ImageCache.shared.countLimit = 200  // Max 200 cached images
        ImageCache.shared.totalCostLimit = 50 * 1024 * 1024  // 50MB limit
    }
}

// MARK: - Image Processing Utilities

public enum ImageProcessingUtilities {
    
    /// Creates a downsampled NSImage from a file URL
    public nonisolated static func downsampledNSImage(at url: URL, targetMaxDimension: CGFloat) -> NSImage? {
        let options: [NSString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(targetMaxDimension)
        ]

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }

        return NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
    }
    
    /// Creates a downsampled CGImage from a file URL
    public nonisolated static func downsampledCGImage(at url: URL, targetMaxDimension: CGFloat) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: Int(targetMaxDimension)
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
    
    /// Determines the appropriate cache bucket size for a given dimension
    public nonisolated static func cacheBucket(for dimension: CGFloat) -> Int {
        if dimension <= 320 { return 320 }
        if dimension <= 640 { return 640 }
        if dimension <= 1024 { return 1024 }
        if dimension <= 1600 { return 1600 }
        return 2048
    }
}
