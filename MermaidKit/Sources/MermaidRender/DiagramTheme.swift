#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreGraphics

/// The full color surface a Mermaid diagram render needs — the sole external
/// seam. Host apps build one (or use the light/dark presets).
public struct DiagramTheme: Sendable {
    /// Primary text and stroke color (node borders, arrows, main labels).
    public let ink: PlatformColor
    /// De-emphasized text: member rows, message text, legend entries.
    public let secondaryTextColor: PlatformColor
    /// Most-muted text: tick captions, section headers, bit indices.
    public let tertiaryTextColor: PlatformColor
    /// The diagram background fill.
    public let canvas: PlatformColor
    /// Highlight color: node fills (at low alpha), markers, single-hue accents.
    public let accent: PlatformColor
    /// Thin rules: gridlines, lifelines, box dividers.
    public let hairline: PlatformColor
    /// Whether the theme targets a dark canvas (drives tint/contrast choices).
    public let prefersDark: Bool
    /// Categorical accents — the colors data series actually wear: node
    /// tints, pie slices, sankey bands, gantt sections, git branches.
    /// Cycled by index via `categoricalColor(_:)`. Override to re-skin every
    /// diagram type at once.
    public let palette: [PlatformColor]

    /// The default categorical palette: six hues tuned to stay distinct on
    /// both light and dark canvases.
    public static let defaultPalette: [PlatformColor] = [
        rgbStatic(0x5B8FF9), // blue
        rgbStatic(0x5AD8A6), // green
        rgbStatic(0xF6BD16), // gold
        rgbStatic(0xE8684A), // coral
        rgbStatic(0x6DC8EC), // sky
        rgbStatic(0x9270CA), // purple
    ]

    /// A stable digest of every color in the theme — the render-cache key
    /// component, so two themes with the same appearance but different
    /// colors can never serve each other's cached renders.
    public var fingerprint: String {
        func hex(_ c: PlatformColor) -> String {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #if canImport(AppKit)
            (c.usingColorSpace(.sRGB) ?? c).getRed(&r, green: &g, blue: &b, alpha: &a)
            #else
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            #endif
            return String(format: "%02X%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255), Int(a * 255))
        }
        let colors = [ink, secondaryTextColor, tertiaryTextColor, canvas, accent, hairline] + palette
        return (prefersDark ? "d" : "l") + colors.map(hex).joined()
    }

    /// The palette color for a categorical index (wraps around).
    public func categoricalColor(_ index: Int) -> PlatformColor {
        let count = palette.count
        guard count > 0 else { return accent }
        return palette[((index % count) + count) % count]
    }

    /// Memberwise init for a fully custom theme; parameters mirror the stored
    /// properties. `palette` defaults to `defaultPalette`.
    public init(ink: PlatformColor, secondaryTextColor: PlatformColor,
                tertiaryTextColor: PlatformColor, canvas: PlatformColor,
                accent: PlatformColor, hairline: PlatformColor, prefersDark: Bool,
                palette: [PlatformColor] = DiagramTheme.defaultPalette) {
        self.ink = ink; self.secondaryTextColor = secondaryTextColor
        self.tertiaryTextColor = tertiaryTextColor; self.canvas = canvas
        self.accent = accent; self.hairline = hairline; self.prefersDark = prefersDark
        self.palette = palette
    }

    /// The built-in preset: a near-black (light) or near-white (dark) ink
    /// ramp at 100/55/38% alpha, white or near-black canvas, the system
    /// accent color, 12% hairlines, and the default palette.
    public init(prefersDark: Bool) {
        let fg: UInt32 = prefersDark ? 0xF2F2F4 : 0x1D1D1F
        #if canImport(AppKit)
        let sys = PlatformColor.controlAccentColor
        #else
        let sys = PlatformColor.tintColor
        #endif
        self.init(
            ink: rgbStatic(fg),
            secondaryTextColor: rgbStatic(fg, alpha: 0.55),
            tertiaryTextColor: rgbStatic(fg, alpha: 0.38),
            canvas: rgbStatic(prefersDark ? 0x1B1B1D : 0xFFFFFF),
            accent: sys,
            hairline: rgbStatic(prefersDark ? 0xFFFFFF : 0x000000, alpha: 0.12),
            prefersDark: prefersDark)
    }
}
#endif
