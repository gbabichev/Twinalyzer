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
class ImageCache {
    /// Shared cache instance accessible throughout the app
    /// NSCache is thread-safe and handles memory pressure automatically
    static let shared = NSCache<NSString, NSImage>()
    private static var memoryMonitorTimer: Timer?
    
    // MARK: - Configuration
    private static let baseCountLimit = 200                   // Base limit for cached images
    private static let baseTotalCostLimit = 50 * 1024 * 1024  // 50MB base limit
    
    /// Private initializer to enforce singleton pattern
    /// Configures cache limits during first access to shared instance
    private static let _bootstrap: Void = {
        configureCacheLimits()
        setupMemoryPressureMonitoring()
    }()
    @inline(__always) static func ensureBootstrapped() { _ = _bootstrap }
    
    /// Private initializer to enforce singleton pattern
    /// Configures cache limits during first access to shared instance
    private init() {
        // Configure initial cache limits
        Self.configureCacheLimits()
        // Set up memory pressure monitoring
        Self.setupMemoryPressureMonitoring()
    }
    
    // MARK: - Enhanced Memory Management
    
    /// Add aggressive cleanup methods
    static func clearCache() {
        shared.removeAllObjects()
    }
    
    static func reduceCacheSize() {
        // Reduce cache limits during cleanup
        shared.countLimit = shared.countLimit / 4
        shared.totalCostLimit = shared.totalCostLimit / 4
        
        // Restore after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            configureCacheLimits()
        }
    }
    
    // Add method to stop monitoring and cleanup
    static func stopMonitoringAndCleanup() {
        memoryMonitorTimer?.invalidate()
        memoryMonitorTimer = nil
        shared.removeAllObjects()
        
        // Reset to minimal limits
        shared.countLimit = 5
        shared.totalCostLimit = 512 * 1024 // 512KB
    }
    
    static func aggressiveClear() {
        stopMonitoringAndCleanup()
        
        // Force garbage collection
        autoreleasepool {
            shared.removeAllObjects()
        }
        
        // Restart monitoring with clean slate
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            setupMemoryPressureMonitoring()
        }
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
        DispatchQueue.main.async {
            memoryMonitorTimer?.invalidate() // Clean up any existing timer
            memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
                configureCacheLimits()
            }
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
}

// MARK: - Enhanced Image Processing Utilities
/// Static utility functions for efficient image processing and cache management
/// All functions are nonisolated for Swift 6 concurrency safety
/// ENHANCED: Added timeout protection, better error handling, and memory monitoring
enum ImageProcessingUtilities {
    
    // MARK: - Configuration
    // Keep private, but DO NOT use in a default argument (fixes the compiler error).
    private nonisolated static let processingTimeout: TimeInterval = 15.0  // 15 second timeout
    private nonisolated static let maxImageDimension: CGFloat = 8192       // Reject extremely large images
    
    nonisolated static func runWithQoS<T>(
        _ qos: DispatchQoS.QoSClass,
        _ work: @escaping () -> T
    ) -> T {
        DispatchQueue.global(qos: qos).sync(execute: work)
    }
    
    nonisolated static func downsampledCGImage(
        at url: URL,
        targetMaxDimension: CGFloat,
        qos: DispatchQoS.QoSClass = .userInitiated
    ) -> CGImage? {
        return runWithQoS(qos) {
            return autoreleasepool {
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
                    kCGImageSourceShouldCache: false, // CRITICAL: Don't cache
                    kCGImageSourceThumbnailMaxPixelSize: Int(targetMaxDimension)
                ]
                
                let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
                
                // The autoreleasepool will handle cleanup when this block exits
                return image
            }
        }
    }
    
    nonisolated static func downsampledCGImageWithTimeout(
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
    nonisolated static func cacheBucket(for dimension: CGFloat) -> Int {
        return cacheBucketSync(for: dimension)
    }
    
    nonisolated static func cacheBucketSync(for dimension: CGFloat) -> Int {
        if dimension <= 320 { return 320 }
        if dimension <= 640 { return 640 }
        if dimension <= 1024 { return 1024 }
        if dimension <= 1600 { return 1600 }
        return 2048
    }
}
