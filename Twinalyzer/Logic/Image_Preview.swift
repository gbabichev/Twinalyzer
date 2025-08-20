/*
 
 Image_Preview.swift
 Twinalyzer
 
 George Babichev
 
 */

import SwiftUI
import AppKit
import ImageIO
import Darwin.Mach

// MARK: - Optimized Image Preview Component
/// High-performance SwiftUI view for displaying image thumbnails with intelligent caching
/// Handles async loading, memory management, and performance optimization for large image collections
/// Uses bucketed caching system to balance memory usage with display quality
/// ENHANCED: Uses ImageProcessingUtilities timeout helper and QoS mapped from TaskPriority
struct PreviewImage: View {
    let path: String              // File system path to the image
    let maxDimension: CGFloat     // Maximum width/height for the displayed image
    let priority: TaskPriority    // Loading priority for this image
    
    @State private var image: NSImage?            // Currently loaded image (nil while loading)
    @State private var isLoading: Bool = false    // Loading state for better UX
    @State private var hasAppeared: Bool = false  // Track if view has appeared (lazy loading)
    @State private var loadingTask: Task<Void, Never>?  // Cancellable loading task
    @State private var hasError: Bool = false     // Track if loading failed
    @State private var currentPath: String = ""   // Track current path being loaded
    
    // MARK: - Constants
    private static let loadingTimeout: TimeInterval = 10.0  // 10 second timeout for image loading
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
            if let img = image, currentPath == path {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            } else if hasError {
                errorPlaceholder
            } else if isLoading {
                ProgressView()
                    .frame(width: min(32, maxDimension * 0.3), height: min(32, maxDimension * 0.3))
            } else {
                loadingPlaceholder
            }
        }
        // IMMEDIATE LOADING: Start loading immediately when path changes
        .onChange(of: path) { oldPath, newPath in
            cancelLoading()
            if oldPath != newPath {
                image = nil
                hasError = false
                currentPath = newPath
                startLoading()
            }
        }
        .onAppear {
            if !hasAppeared {
                hasAppeared = true
                currentPath = path
                startLoading()
            }
        }
        .onDisappear {
            cancelLoading()
        }
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

    // MARK: - Cache Key
    private var cacheKey: String {
        let bucket = ImageProcessingUtilities.cacheBucket(for: maxDimension)
        return "\(path)::\(bucket)"
    }

    // MARK: - Main-actor state setters
    @MainActor private func setImage(_ img: NSImage?, forPath imagePath: String) {
        guard imagePath == self.path else { return }
        self.image = img
        self.isLoading = false
        self.hasError = (img == nil)
        self.currentPath = imagePath
    }
    
    @MainActor private func setError() {
        self.image = nil
        self.isLoading = false
        self.hasError = true
    }
    
    @MainActor private func setLoading(_ loading: Bool) {
        self.isLoading = loading
        if loading { self.hasError = false }
    }

    // MARK: - Loading Management
    private func startLoading() {
        guard loadingTask == nil else { return }
        let pathToLoad = path
        loadingTask = Task(priority: priority) {
            await load(pathToLoad)
            await MainActor.run { self.loadingTask = nil }
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

    // MARK: - Async Image Loading Pipeline
    private func load(_ pathToLoad: String) async {
        ImageCache.ensureBootstrapped()
        let bucket = ImageProcessingUtilities.cacheBucket(for: maxDimension)
        let key = "\(pathToLoad)::\(bucket)" as NSString

        // 1) Cache hit fast path
        if let cached = ImageCache.shared.object(forKey: key) {
            await MainActor.run { self.setImage(cached, forPath: pathToLoad) }
            return
        }


        // 2) Early cancellation / state
        guard !Task.isCancelled, pathToLoad == self.path else { return }
        await MainActor.run { self.setLoading(true) }

        // 3) Memory pressure check
        if await isMemoryPressureHigh() {
            await MainActor.run { self.setError() }
            return
        }


        // 4) Decode off-main with timeout (via utility)
        let url = URL(fileURLWithPath: pathToLoad)

        let cg = await ImageProcessingUtilities.downsampledCGImageWithTimeout(
            at: url,
            targetMaxDimension: CGFloat(bucket),
            timeout: Self.loadingTimeout
        )

        // 5) Final cancellation / state
        guard !Task.isCancelled, pathToLoad == self.path else {
            await MainActor.run { self.isLoading = false }
            return
        }

        // 6) Publish on main + cache
        if let cg {
            await MainActor.run {
                let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                ImageCache.shared.setObject(ns, forKey: key)
                setImage(ns, forPath: pathToLoad)
            }
        } else {
            await MainActor.run { self.setError() }
        }
    }
    
    // MARK: - Memory Pressure Monitoring
    private func isMemoryPressureHigh() async -> Bool {
        await withCheckedContinuation { continuation in
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
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

// MARK: - TaskPriority QoS Extension
private extension TaskPriority {
    var qosClass: DispatchQoS.QoSClass {
        if self >= .high { return .userInteractive }
        else if self >= .userInitiated { return .userInitiated }
        else if self >= .medium { return .default }
        else if self >= .utility { return .utility }
        else { return .background }
    }
}

