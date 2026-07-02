#if canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#endif

#if canImport(AppKit) || canImport(UIKit)
import Foundation

/// All type, color, and spacing decisions for the reading surface live here,
/// so restyling the app (or adding reader themes) touches one file. Colors
/// are semantic system colors and adapt to light/dark automatically.
public struct Theme: Sendable {

    public var bodySize: CGFloat = 15
    public var lineHeightMultiple: CGFloat = 1.35
    public var paragraphSpacing: CGFloat = 10
    public var contentInset: CGFloat = 28
    /// Comfortable reading measure; the text container caps at this width.
    public var maxContentWidth: CGFloat = 680

    public init() {}

    // MARK: Fonts

    public func bodyFont() -> PlatformFont {
        .systemFont(ofSize: bodySize)
    }

    public func headingFont(level: Int) -> PlatformFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.9
        case 2: scale = 1.5
        case 3: scale = 1.25
        case 4: scale = 1.1
        default: scale = 1.0
        }
        return .systemFont(ofSize: (bodySize * scale).rounded(), weight: level <= 2 ? .bold : .semibold)
    }

    public func codeFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular)
    }

    // MARK: Colors

    public var textColor: PlatformColor {
        #if canImport(AppKit)
        .labelColor
        #else
        .label
        #endif
    }

    public var secondaryTextColor: PlatformColor {
        #if canImport(AppKit)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    public var linkColor: PlatformColor {
        #if canImport(AppKit)
        .linkColor
        #else
        .link
        #endif
    }

    public var codeBackground: PlatformColor {
        #if canImport(AppKit)
        PlatformColor.labelColor.withAlphaComponent(0.06)
        #else
        PlatformColor.label.withAlphaComponent(0.06)
        #endif
    }

    public var searchHighlight: PlatformColor {
        #if canImport(AppKit)
        .findHighlightColor
        #else
        .systemYellow
        #endif
    }
}
#endif
