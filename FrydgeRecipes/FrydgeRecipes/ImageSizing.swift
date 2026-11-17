//
//  ImageSizing.swift
//  FrydgeRecipes
//
//  One size policy for every bitmap the app decodes, stores or uploads.
//
//  Why: "images not loading" in App Review is as often a memory problem as a
//  network one. A 12 MP camera frame is ~48 MB decoded; a Commons original can
//  be 8000 px wide; a user photo library full of such frames gets the app (or
//  a notification extension) jetsammed, and the user just sees empty tiles.
//  Every path that turns bytes into a UIImage, or a UIImage into bytes, goes
//  through the helpers below so no image can exceed a known pixel budget.
//
//  Rules of thumb:
//    • Never call `UIImage(data:)` / `UIImage(contentsOfFile:)` directly in
//      app code — use `UIImage.frydgeBounded(data:maxPixelSize:)`.
//    • Never persist/upload `jpegData(...)` of an unbounded image — use
//      `frydgeBoundedJPEG`.
//    • Camera/picker output is bounded to `ImageBudget.capture` at the source.
//

import UIKit
import ImageIO

/// Longest-edge pixel budgets. Chosen for 3x displays: a full-width hero on a
/// 430 pt phone is ~1300 px, a 44–120 pt tile is ≤ 360 px.
nonisolated enum ImageBudget {
    /// List rows, tiles, avatars rendered small (44–160 pt).
    static let thumbnail: CGFloat = 480
    /// Cards, carousels, detail headers, anything shown near full width.
    static let display: CGFloat = 1600
    /// Anything persisted to disk or uploaded (CKAsset, community photos,
    /// vendor/listing images, user photo library).
    static let upload: CGFloat = 1600
    /// Camera / picker output kept for OCR or on-device recognition, where
    /// text legibility matters more than memory. Still bounded.
    static let capture: CGFloat = 2600
    /// Hard cap on persisted/uploaded JPEG bytes.
    static let maxUploadBytes = 1_500_000
}

extension UIImage {

    // MARK: Decode (bytes → bounded bitmap)

    /// Bounded replacement for `UIImage(data:)`. Decodes straight to a bitmap
    /// no larger than `maxPixelSize` on its longest edge, with EXIF orientation
    /// applied, without ever materialising the full-resolution image. Results
    /// are memoised so SwiftUI bodies that decode the same bytes on every
    /// render don't pay for the decode twice.
    static func frydgeBounded(data: Data?, maxPixelSize: CGFloat) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        let key = BoundedDecodeCache.key(for: data, maxPixelSize: maxPixelSize)
        if let hit = BoundedDecodeCache.shared.object(forKey: key) { return hit }
        guard let image = RemoteImageFetcher.decodeDownsampled(data, maxPixelSize: maxPixelSize) else { return nil }
        BoundedDecodeCache.shared.setObject(image, forKey: key, cost: image.frydgeByteCost)
        return image
    }

    /// Bounded replacement for `UIImage(contentsOfFile:)`.
    static func frydgeBounded(contentsOf fileURL: URL?, maxPixelSize: CGFloat) -> UIImage? {
        guard let fileURL else { return nil }
        return RemoteImageFetcher.decodeDownsampled(contentsOf: fileURL, maxPixelSize: maxPixelSize)
    }

    // MARK: Resize (bitmap → bounded bitmap)

    /// Returns `self` if it already fits, otherwise a copy scaled so the
    /// longest edge is `maxPixelSize`. Orientation is baked in either way, so
    /// callers can drop their own `normalized()` step.
    func frydgeBounded(maxPixelSize: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > 0 else { return self }

        let factor = min(1, maxPixelSize / longest)
        let targetSize = CGSize(width: (pixelWidth * factor).rounded(.down),
                                height: (pixelHeight * factor).rounded(.down))
        if factor == 1 && imageOrientation == .up { return self }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    // MARK: Encode (bitmap → bounded bytes)

    /// JPEG bytes for persistence or upload: pixel-bounded first, then quality
    /// stepped down until under `maxBytes`.
    func frydgeBoundedJPEG(
        maxPixelSize: CGFloat = ImageBudget.upload,
        quality: CGFloat = 0.82,
        maxBytes: Int = ImageBudget.maxUploadBytes
    ) -> Data? {
        let bounded = frydgeBounded(maxPixelSize: maxPixelSize)
        var q = quality
        var best: Data? = nil
        while q >= 0.3 {
            guard let data = bounded.jpegData(compressionQuality: q) else { break }
            best = data
            if data.count <= maxBytes { return data }
            q -= 0.12
        }
        return best
    }

    /// Approximate decoded size, for NSCache costing.
    var frydgeByteCost: Int {
        Int(size.width * scale) * Int(size.height * scale) * 4
    }
}

/// Memo for `frydgeBounded(data:)`. Keyed by byte count plus a sample of the
/// head and tail of the data (cheap, and distinct for any two real photos)
/// and the requested budget.
private nonisolated enum BoundedDecodeCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func key(for data: Data, maxPixelSize: CGFloat) -> NSString {
        var hasher = Hasher()
        hasher.combine(data.count)
        let sample = 1024
        if data.count <= sample * 2 {
            hasher.combine(data)
        } else {
            hasher.combine(data.prefix(sample))
            hasher.combine(data.suffix(sample))
            // A slice from the middle too, so two crops of the same frame differ.
            let mid = data.count / 2
            hasher.combine(data[data.startIndex.advanced(by: mid) ..< data.startIndex.advanced(by: mid + 256)])
        }
        hasher.combine(Int(maxPixelSize))
        return "\(hasher.finalize())" as NSString
    }
}
