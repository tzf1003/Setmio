#if canImport(UIKit) && !os(watchOS)
import Foundation
import UIKit

/// Prepares a food photo for `/v1/food/recognize`: redraws through `UIGraphicsImageRenderer` (bakes the EXIF
/// orientation into pixels and drops every metadata tag incl. GPS), caps the longest edge, and re-encodes
/// at a lower quality when the JPEG is still above `maxBytes` (§7.8: 1536 px, 0.8 → 0.7, ≤ 1.5 MB).
public enum ImagePreprocessor {
    public static let fallbackQuality: CGFloat = 0.7
    public static let fallbackMaxEdge: CGFloat = 1024

    public static func jpegForUpload(_ image: UIImage, maxEdge: CGFloat = 1536, quality: CGFloat = 0.8, maxBytes: Int = 1_500_000) -> (data: Data, width: Int, height: Int)? {
        guard let first = render(image, maxEdge: maxEdge, quality: quality) else { return nil }
        if first.data.count <= maxBytes { return first }

        guard let second = render(image, maxEdge: maxEdge, quality: fallbackQuality) else { return first }
        if second.data.count <= maxBytes { return second }

        // Still too large (very busy scene): shrink the edge as a last resort so the proxy's 2 MB limit is never hit.
        if let third = render(image, maxEdge: min(maxEdge, fallbackMaxEdge), quality: fallbackQuality), third.data.count < second.data.count {
            return third
        }
        return second
    }

    /// Target pixel size after capping the longest edge (never upscales).
    public static func targetPixelSize(for image: UIImage, maxEdge: CGFloat) -> CGSize {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return .zero }
        let factor = min(1, maxEdge / longest)
        return CGSize(width: max(1, (pixelWidth * factor).rounded()), height: max(1, (pixelHeight * factor).rounded()))
    }

    private static func render(_ image: UIImage, maxEdge: CGFloat, quality: CGFloat) -> (data: Data, width: Int, height: Int)? {
        let target = targetPixelSize(for: image, maxEdge: maxEdge)
        guard target.width > 0, target.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1   // 1 pt == 1 px so `target` is the output pixel size
        format.opaque = true   // JPEG has no alpha; avoids a black fill for transparent inputs
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            // `draw(in:)` honours `imageOrientation`, so the output is upright with `.up` orientation and no EXIF.
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = rendered.jpegData(compressionQuality: quality) else { return nil }
        return (data, Int(target.width), Int(target.height))
    }
}
// VERIFY: on device, inspect the uploaded JPEG with `CGImageSourceCopyPropertiesAtIndex` — no `{GPS}` / `{Exif}` dictionaries
// should remain after re-encoding via UIImage.jpegData (UIKit writes only basic JFIF + orientation .up).
#endif
