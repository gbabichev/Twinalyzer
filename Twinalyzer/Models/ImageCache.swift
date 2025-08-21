/*
 
 ImageCache.swift
 Twinalyzer
 
 George Babichev
 
 */

//  Centralized image caching for preview thumbnails
//  Provides memory-efficient thumbnail generation and intelligent cache bucket sizing
//  ENHANCED: Added memory pressure monitoring and timeout protection

import AppKit
import ImageIO
import CoreGraphics
import Darwin.Mach

// MARK: - Non-isolated config (safe from any actor/thread)
private enum _ImageCacheConfig {
    @inline(__always)
    nonisolated static func memThreshold() -> UInt64 { 256 * 1024 * 1024 } // 256 MB
}

// MARK: - Centralized Image Cache System
/// Singleton cache manager for storing processed image thumbnails in memory
/// Uses NSCache for automatic memory pressure handling and LRU eviction
/// Configured with reasonable limits to balance performance with memory usage
/// ENHANCED: Added memory pressure monitoring and cache size adjustment
public final class ImageCache {
    /// Shared cache instance accessible throughout the app
    /// NSCache is thread-safe and handles memory pressure automatically
    ///
    
    private static let _bootstrap: Void = {
        configureCacheLimits()
        setupMemoryPressureMonitoring()
    }()
    @inline(__always) public static func ensureBootstrapped() { _ = _bootstrap }

    public static let shared = NSCache<NSString, NSImage>()
    
    // MARK: - Configuration
    private static let baseCountLimit = 200                   // Base limit for cached images
    private static let baseTotalCostLimit = 50 * 1024 * 1024  // 50MB base limit
    
    /// Private initializer to enforce singleton pattern
    /// Configures cache limits during first access to shared instance
    private init() {
        // Configure initial cache limits
        Self.configureCacheLimits()
        // Set up memory pressure monitoring
        Self.setupMemoryPressureMonitoring()
    }
    
    /// Configure cache limits based on current memory situation
    /// Nonisolated to be callable from anywhere; hops to main actor internally.
    private nonisolated static func configureCacheLimits() {
        Task.detached(priority: .utility) {
            let isHighMemory = await isMemoryPressureHigh()
            await MainActor.run {
                if isHighMemory {
                    shared.countLimit = baseCountLimit / 2
                    shared.totalCostLimit = baseTotalCostLimit / 2
                } else {
                    shared.countLimit = baseCountLimit
                    shared.totalCostLimit = baseTotalCostLimit
                }
            }
        }
    }

    /// Periodically re-evaluate limits under possible memory pressure.
    private nonisolated static func setupMemoryPressureMonitoring() {
        // Timer runs on the current run loop; keep work minimal.
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            configureCacheLimits()
        }
    }

    /// Reads current resident memory usage to infer pressure.
    private nonisolated static func isMemoryPressureHigh() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(
                    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
                )
                let kerr = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }

                if kerr == KERN_SUCCESS {
                    let isHigh = info.resident_size > _ImageCacheConfig.memThreshold()
                    continuation.resume(returning: isHigh)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    /// Force cache cleanup when memory pressure is detected
    public static func clearCacheIfNeeded() {
        Task.detached(priority: .utility) {
            let isHighMemory = await isMemoryPressureHigh()
            if isHighMemory {
                await MainActor.run {
                    shared.removeAllObjects()
                }
            }
        }
    }
}

// MARK: - Enhanced Image Processing Utilities
/// Static utility functions for efficient image processing and cache management
/// All functions are nonisolated for Swift 6 concurrency safety
/// ENHANCED: Added timeout protection, better error handling, and memory monitoring
public enum ImageProcessingUtilities {
    
    // MARK: - Configuration
    // Keep private, but DO NOT use in a default argument (fixes the compiler error).
    private nonisolated static let processingTimeout: TimeInterval = 15.0  // 15 second timeout
    private nonisolated static let maxImageDimension: CGFloat = 8192       // Reject extremely large images
    
    public nonisolated static func runWithQoS<T>(
            _ qos: DispatchQoS.QoSClass,
            _ work: @escaping () -> T
        ) -> T {
            DispatchQueue.global(qos: qos).sync(execute: work)
        }

        public nonisolated static func downsampledCGImage(
            at url: URL,
            targetMaxDimension: CGFloat,
            qos: DispatchQoS.QoSClass = .userInitiated   // <- NEW
        ) -> CGImage? {
            return runWithQoS(qos) {                     // <- NEW
                autoreleasepool {
                    guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          fileSize > 0, fileSize < 500 * 1024 * 1024 else { return nil }
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

                    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                        let w = props[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
                        let h = props[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
                        if w > maxImageDimension || h > maxImageDimension { return nil }
                    }

                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCache: false,
                        kCGImageSourceThumbnailMaxPixelSize: Int(targetMaxDimension)
                    ]
                    return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
                }
            }
        }

    public nonisolated static func downsampledCGImageWithTimeout(
        at url: URL,
        targetMaxDimension: CGFloat,
        timeout: TimeInterval? = nil
    ) async -> CGImage? {
        let effectiveTimeout = timeout ?? processingTimeout

        return await withTaskGroup(of: CGImage?.self) { group in
            // Run the decode on a lower-QoS GCD thread, not on the caller's task thread.
            group.addTask(priority: .utility) {
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .utility).async {
                        let img = downsampledCGImage(at: url, targetMaxDimension: targetMaxDimension)
                        cont.resume(returning: img)
                    }
                }
            }

            // Timeout race
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                return nil
            }

            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }
    
    // MARK: - Enhanced Cache Bucket System
    public nonisolated static func cacheBucket(for dimension: CGFloat) -> Int {
        return cacheBucketSync(for: dimension)
    }
    
    public nonisolated static func cacheBucketSync(for dimension: CGFloat) -> Int {
        if dimension <= 320 { return 320 }
        if dimension <= 640 { return 640 }
        if dimension <= 1024 { return 1024 }
        if dimension <= 1600 { return 1600 }
        return 2048
    }
    
    public nonisolated static func cacheBucketWithMemoryCheck(for dimension: CGFloat) async -> Int {
        let isHighMemory = await isMemoryPressureHigh()
        if isHighMemory {
            if dimension <= 160 { return 160 }
            if dimension <= 320 { return 320 }
            if dimension <= 512 { return 512 }
            return 1024
        } else {
            return cacheBucketSync(for: dimension)
        }
    }
    
    // MARK: - Memory Pressure Monitoring
    /// Checks if system is under memory pressure
    private nonisolated static func isMemoryPressureHigh() async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var info = mach_task_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
                let kerr = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }
                
                if kerr == KERN_SUCCESS {
                    let isHighMemory = info.resident_size > _ImageCacheConfig.memThreshold()
                    continuation.resume(returning: isHighMemory)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    // MARK: - Cache Management Utilities
    public static func clearCacheIfNeeded() {
        ImageCache.clearCacheIfNeeded()
    }
    
    public static func getCacheStatistics() -> (count: Int, totalCost: Int) {
        _ = ImageCache.shared // placeholder; NSCache doesn't expose stats
        return (count: 0, totalCost: 0)
        // If you later track costs manually, return real values here.
    }
    
}

