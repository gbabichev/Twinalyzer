import SwiftUI
import AppKit
import ImageIO

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
        let bucket = ImageProcessingUtilities.cacheBucket(for: maxDimension)
        return "\(path)::\(bucket)"
    }

    @MainActor private func setImage(_ img: NSImage?) { self.image = img }

    private func load() async {
        let key = cacheKey as NSString

        // Serve from cache immediately, on main.
        if let cached = ImageCache.shared.object(forKey: key) {
            setImage(cached)
            return
        }

        let bucket = ImageProcessingUtilities.cacheBucket(for: maxDimension)
        let url = URL(fileURLWithPath: path)

        // Do the decoding off-main
        let cg: CGImage? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: ImageProcessingUtilities.downsampledCGImage(at: url, targetMaxDimension: CGFloat(bucket)))
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
