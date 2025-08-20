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
/// ENHANCED: Added timeout protection, better error handling, and memory pressure monitoring
struct PreviewImage: View {
    let path: String              // File system path to the image
    let maxDimension: CGFloat     // Maximum width/height for the displayed image
    let priority: TaskPriority    // Loading priority for this image
    
    @State private var image: NSImage?  // Currently loaded image (nil while loading)
    @State private var isLoading: Bool = false     // Loading state for better UX
    @State private var hasAppeared: Bool = false   // Track if view has appeared (lazy loading)
    @State private var loadingTask: Task<Void, Never>?  // Cancellable loading task
    @State private var hasError: Bool = false      // Track if loading failed
    
    // MARK: - Constants
    private static let loadingTimeout: TimeInterval = 10.0  // 10 second timeout for image loading
    private static let memoryPressureThreshold = 256 * 1024 * 1024  // 256MB
    fileprivate let PREVIEW_QOS: DispatchQoS.QoSClass = .userInitiated
    fileprivate let MEMORY_PRESSURE_THRESHOLD: UInt64 = 512 * 1024 * 1024
    
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
            } else if hasError {
                // Error state with retry option
                errorPlaceholder
            } else if isLoading {
                // Loading indicator while image is being processed
                ProgressView()
                    .frame(width: min(32, maxDimension * 0.3), height: min(32, maxDimension * 0.3))
            } else {
                // Placeholder for unloaded images - scales with image size
                loadingPlaceholder
            }
        }
        // LAZY LOADING: Only start loading when view appears
        .onAppear {
            if !hasAppeared {
                hasAppeared = true
                startLoading()
            }
        }
        .onDisappear {
            // Cancel loading task when view disappears to save resources
            cancelLoading()
        }
        // Legacy support: Also trigger on cache key changes for existing usage patterns
        .task(id: cacheKey) {
            // Only load if we've appeared (prevents eager loading)
            if hasAppeared && image == nil && !hasError {
                startLoading()
            }
        }
        // Accessibility support with filename as label
        .accessibilityLabel(Text((path as NSString).lastPathComponent))
    }

    // MARK: - UI Components
    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: max(2, maxDimension * 0.05))
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Image(systemName: "photo")
                    .foregroundColor(.gray.opacity(0.6))
                    .font(.system(size: min(24, maxDimension * 0.3)))
            )
    }
    
    private var errorPlaceholder: some View {
        RoundedRectangle(cornerRadius: max(2, maxDimension * 0.05))
            .fill(Color.red.opacity(0.1))
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.red.opacity(0.7))
                        .font(.system(size: min(20, maxDimension * 0.25)))
                    
                    if maxDimension > 60 {
                        Button("Retry") {
                            retryLoading()
                        }
                        .font(.system(size: max(8, min(12, maxDimension * 0.15))))
                        .controlSize(.mini)
                    }
                }
            )
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
        self.hasError = (img == nil && self.isLoading) // Only set error if we were loading
    }
    
    @MainActor private func setError() {
        self.image = nil
        self.isLoading = false
        self.hasError = true
    }
    
    @MainActor private func setLoading(_ loading: Bool) {
        self.isLoading = loading
        if loading {
            self.hasError = false
        }
    }

    // MARK: - Loading Management
    private func startLoading() {
        guard loadingTask == nil else { return }
        
        loadingTask = Task(priority: priority) {
            await load()
        }
    }
    
    private func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
    }
    
    private func retryLoading() {
        hasError = false
        startLoading()
    }

    // MARK: - Enhanced Async Image Loading Pipeline
    /// Multi-stage loading process optimized for performance and memory efficiency
    /// 1. Check cache for immediate display (main thread)
    /// 2. Set loading state for better UX
    /// 3. Decode image off-main thread to avoid blocking UI
    /// 4. Create NSImage and update cache on main thread
    /// ENHANCED: Added timeout, memory pressure monitoring, and better error handling
    private func load() async {
        let key = cacheKey as NSString

        // STAGE 1: Fast cache lookup on main thread
        // If image is already cached, display immediately without any async work
        if let cached = ImageCache.shared.object(forKey: key) {
            setImage(cached)
            return
        }

        // STAGE 2: Set loading state for better user experience
        setLoading(true)

        // STAGE 3: Check memory pressure before proceeding
        if await isMemoryPressureHigh() {
            print("Warning: High memory pressure, skipping image load for \((path as NSString).lastPathComponent)")
            setError()
            return
        }

        // STAGE 4: Determine target size and prepare for background processing
        let bucket = ImageProcessingUtilities.cacheBucket(for: maxDimension)
        let url = URL(fileURLWithPath: path)

        // STAGE 5: Decode image on background thread with timeout protection
        let cg: CGImage? = await withTimeout(seconds: Self.loadingTimeout) {
            await withCheckedContinuation { cont in
                let _: () = DispatchQueue.global(qos: PREVIEW_QOS).async {
                    autoreleasepool {
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
            }
        }

        // STAGE 6: Final cancellation check and UI update
        guard !Task.isCancelled else {
            setLoading(false)
            return
        }

        // STAGE 7: Convert to NSImage and update cache on main thread
        // NSImage creation and cache updates must happen on main thread
        if let cg = cg {
            await MainActor.run {
                let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                ImageCache.shared.setObject(ns, forKey: key)
                self.image = ns
                self.isLoading = false
                self.hasError = false
            }
        } else {
            setError()
        }
    }
    
    // MARK: - Memory Pressure Monitoring
    /// Checks if system is under memory pressure
    /// Returns true if available memory is low
    private func isMemoryPressureHigh() async -> Bool {
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
                    let isHighMemory = info.resident_size > MEMORY_PRESSURE_THRESHOLD
                    continuation.resume(returning: isHighMemory)
                } else {
                    // If we can't get memory info, assume we're fine
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    // MARK: - Timeout Utility
    /// Wraps an async operation with a timeout
    /// Returns nil if the operation doesn't complete within the specified time
    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        return await withTaskGroup(of: T?.self) { group in
            // Add the actual operation
            group.addTask {
                await operation()
            }
            
            // Add a timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            
            // Return the first result (either success or timeout)
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }
}

// MARK: - TaskPriority QoS Extension
/// Maps TaskPriority to QoSClass for DispatchQueue compatibility
/// ENHANCED: Added better fallback handling
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
