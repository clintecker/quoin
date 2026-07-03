#if canImport(AppKit) || canImport(UIKit)
import Foundation

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Block-level chrome the element spec calls for that per-glyph attributes
/// can't express: the code block's full-width canvas, the callout's tinted
/// rounded box, the blockquote's 3pt rule, the diagram frame, and table
/// rules. The renderer tags each block's character range with one of these;
/// the reader view draws them behind the text at fragment-layout time, so
/// the shapes always track the laid-out geometry.
///
/// Colors are resolved from the theme at render time but stay dynamic
/// (appearance-aware) — they resolve to light/dark values when drawn.
public final class BlockDecoration: NSObject {

    public enum Kind {
        /// Rounded canvas behind a code block (`#1E2430` in both appearances).
        case codeCanvas(fill: PlatformColor)
        /// Tinted rounded box + border in the callout's semantic color.
        case callout(color: PlatformColor)
        /// 3pt vertical rule along the blockquote's left edge.
        case quoteRule(color: PlatformColor)
        /// Hairline rounded frame around a rendered diagram.
        case diagramFrame(color: PlatformColor)
        /// Compact chip fill behind a single-line run (front matter).
        case chip(fill: PlatformColor)
        /// Table rules: heavier line under the first (header) row, hairline
        /// under body rows. `width` is the table's content width.
        case tableRules(width: CGFloat, header: PlatformColor, body: PlatformColor)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}
#endif
