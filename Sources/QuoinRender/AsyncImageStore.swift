#if canImport(AppKit) || canImport(UIKit)
import Foundation
import ImageIO
import CoreGraphics

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Off-main-thread image decoding with a shared cache, so opening a
/// document with heavy images never blocks first render. The renderer asks
/// for an image; on a miss it gets nil (draws a placeholder), decoding is
/// scheduled, and `onReady` fires once so the document can re-render.
final class AsyncImageStore: @unchecked Sendable {

    static let shared = AsyncImageStore()

    private let cache = NSCache<NSString, PlatformImage>()
    private var pending: Set<String> = []
    private let lock = NSLock()

    private init() {
        cache.countLimit = 200
    }

    /// Cache key includes mtime so an edited image refreshes on reload.
    private func key(for url: URL, maxDimension: CGFloat) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .map { String($0.timeIntervalSince1970) } ?? "0"
        return "\(url.path)|\(mtime)|\(Int(maxDimension))"
    }

    func image(at url: URL, maxDimension: CGFloat, onReady: @escaping @Sendable () -> Void) -> PlatformImage? {
        let cacheKey = key(for: url, maxDimension: maxDimension)
        if let hit = cache.object(forKey: cacheKey as NSString) {
            return hit
        }

        lock.lock()
        let alreadyPending = pending.contains(cacheKey)
        if !alreadyPending { pending.insert(cacheKey) }
        lock.unlock()
        guard !alreadyPending else { return nil }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let decoded = Self.decode(url: url, maxDimension: maxDimension)
            if let decoded {
                self.cache.setObject(decoded, forKey: cacheKey as NSString)
            }
            self.lock.lock()
            self.pending.remove(cacheKey)
            self.lock.unlock()
            if decoded != nil { onReady() }
        }
        return nil
    }

    /// Decodes at display size via ImageIO so a 20 MP photo doesn't cost
    /// 80 MB of memory to show at 680 points wide.
    static func decode(url: URL, maxDimension: CGFloat) -> PlatformImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        #if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}
#endif
