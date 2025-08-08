import AppKit
import ImageIO

/// Fast, memory-efficient downsampling to a target max dimension.
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
