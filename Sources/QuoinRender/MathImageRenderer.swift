#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreGraphics
import QuoinCore

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Produces baseline-aligned text attachments for math, backed by the
/// native typesetter. Results are cached by content + size. Returns nil
/// when the LaTeX contains unsupported commands — callers keep the styled
/// source fallback so a document never breaks.
enum MathImageRenderer {

    private final class Entry {
        let image: PlatformImage
        let descent: CGFloat
        init(image: PlatformImage, descent: CGFloat) {
            self.image = image
            self.descent = descent
        }
    }

    private static let cache = NSCache<NSString, Entry>()

    /// An attachment string for the given LaTeX, or nil if unsupported.
    static func attachmentString(
        latex: String,
        display: Bool,
        theme: Theme,
        baseSize: CGFloat
    ) -> NSAttributedString? {
        let node = MathParser.parse(latex)
        guard MathParser.isFullySupported(node) else { return nil }

        let key = "\(display ? "D" : "I")|\(baseSize)|\(latex)" as NSString
        let entry: Entry
        if let cached = cache.object(forKey: key) {
            entry = cached
        } else {
            let typesetter = MathTypesetter(theme: theme, baseSize: display ? baseSize * 1.15 : baseSize)
            let box = typesetter.layout(node, display: display)
            guard box.width > 0, box.height > 0 else { return nil }

            let padding: CGFloat = 2
            let size = CGSize(
                width: ceil(box.width) + padding * 2,
                height: ceil(box.height) + padding * 2
            )

            #if canImport(AppKit)
            // Handler-based NSImage: the draw closure runs at display time,
            // so dynamic colors resolve for the current appearance — math
            // adapts to dark mode with no re-render.
            let image = NSImage(size: size, flipped: false) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                box.draw(context, CGPoint(x: padding, y: box.descent + padding))
                return true
            }
            #else
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { rendererContext in
                let context = rendererContext.cgContext
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                box.draw(context, CGPoint(x: padding, y: box.descent + padding))
            }
            #endif
            entry = Entry(image: image, descent: box.descent + padding)
            cache.setObject(entry, forKey: key)
        }

        let attachment = NSTextAttachment()
        attachment.image = entry.image
        let imageSize = entry.image.size
        attachment.bounds = CGRect(
            x: 0,
            y: -entry.descent,
            width: imageSize.width,
            height: imageSize.height
        )
        return NSAttributedString(attachment: attachment)
    }
}
#endif
