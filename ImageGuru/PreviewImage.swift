import SwiftUI
import AppKit

final class ImageCache {
    static let shared = NSCache<NSString, NSImage>()
    private init() {}
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
        if let cached = ImageCache.shared.object(forKey: key) {
            setImage(cached)
            return
        }
        let bucket = Self.bucket(for: maxDimension)
        let url = URL(fileURLWithPath: path)

        let ns: NSImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let ns = downsampledNSImage(at: url, targetMaxDimension: CGFloat(bucket))
                cont.resume(returning: ns)
            }
        }

        if let ns { ImageCache.shared.setObject(ns, forKey: key) }
        setImage(ns)
    }
}

