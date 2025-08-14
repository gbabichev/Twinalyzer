import SwiftUI
import AppKit
import ImageIO

final class ImageCache {
    static let shared = NSCache<NSString, NSImage>()
    private init() {}
}

func downsampledNSImage(at url: URL, targetMaxDimension: CGFloat) -> NSImage? {
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

struct PreviewImage: View {
    let path: String
    let maxDimension: CGFloat
    @State private var image: NSImage?
    
    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .border(Color.gray.opacity(0.4))
            } else {
                ProgressView().frame(width: 32, height: 32)
            }
        }
        .task(id: cacheKey) {
            await load()
        }
        .accessibilityLabel(Text((path as NSString).lastPathComponent))
    }

    private var cacheKey: String {
        let bucket = Self.bucket(for: maxDimension)
        return "\(path)::\(bucket)"
    }

    private static func bucket(for dim: CGFloat) -> Int {
        if dim <= 320 { return 320 }
        if dim <= 640 { return 640 }
        if dim <= 1024 { return 1024 }
        if dim <= 1600 { return 1600 }
        return 2048
    }

    @MainActor private func setImage(_ img: NSImage?) { self.image = img }

    private func load() async {
        let key = cacheKey as NSString

        // Serve from cache immediately, on main.
        if let cached = ImageCache.shared.object(forKey: key) {
            setImage(cached)
            return
        }

        let bucket = Self.bucket(for: maxDimension)
        let url = URL(fileURLWithPath: path)

        // Do the decoding off-main
        let cg: CGImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: downsampledCGImage(at: url, targetMaxDimension: CGFloat(bucket)))
            }
        }

        // Build NSImage and publish on main
        await MainActor.run {
            let ns = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let ns { ImageCache.shared.setObject(ns, forKey: key) }
            self.image = ns
        }
    }
}

