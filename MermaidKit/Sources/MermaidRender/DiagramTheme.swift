#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreGraphics

/// The full color surface a Mermaid diagram render needs — the sole external
/// seam. Host apps build one (or use the light/dark presets).
public struct DiagramTheme: Sendable {
    public let ink: PlatformColor
    public let secondaryTextColor: PlatformColor
    public let tertiaryTextColor: PlatformColor
    public let canvas: PlatformColor
    public let accent: PlatformColor
    public let hairline: PlatformColor
    public let prefersDark: Bool

    public init(ink: PlatformColor, secondaryTextColor: PlatformColor,
                tertiaryTextColor: PlatformColor, canvas: PlatformColor,
                accent: PlatformColor, hairline: PlatformColor, prefersDark: Bool) {
        self.ink = ink; self.secondaryTextColor = secondaryTextColor
        self.tertiaryTextColor = tertiaryTextColor; self.canvas = canvas
        self.accent = accent; self.hairline = hairline; self.prefersDark = prefersDark
    }

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
