#if canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformAppearance = NSAppearance
#elseif canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
/// UIKit has no NSAppearance analogue; exports use trait collections there.
public typealias PlatformAppearance = NSObject
#endif

#if canImport(AppKit) || canImport(UIKit)
import Foundation
import MermaidRender

/// The Graphite design system from `docs/design/handoff.md`. Colors, type
/// ramp, spacing, and radii are the handoff's exact values — change them
/// there first, here second. Dark mode inverts ink/canvas, keeps the code
/// surface, and desaturates highlights ~15%.
public struct Theme: Sendable {

    /// Captured at creation: whether the app is in dark appearance. Keys
    /// the engine render caches so cached math/diagram images match the
    /// surrounding canvas. (A mid-session appearance switch re-creates
    /// themes via the SwiftUI environment on the next render.)
    public let prefersDark: Bool

    public init() {
        #if canImport(AppKit)
        if Thread.isMainThread, let app = NSApp {
            prefersDark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        } else {
            prefersDark = false
        }
        #else
        prefersDark = false
        #endif
    }

    /// Pinned appearance, for exports that force light or dark output
    /// regardless of the app's current appearance.
    public init(prefersDark: Bool) {
        self.prefersDark = prefersDark
    }

    // MARK: - Spacing & metrics (handoff: 4 · 8 · 12 · 16 · 24 · 32)

    public var bodySize: CGFloat = 14
    public var bodyLineHeightMultiple: CGFloat = 1.7
    public var paragraphSpacing: CGFloat = 12
    public var contentInset: CGFloat = 48   // gutters ≥48pt
    public var maxContentWidth: CGFloat = 680

    public enum Radius {
        public static let inlineCode: CGFloat = 4
        public static let control: CGFloat = 6
        public static let block: CGFloat = 8
        public static let panel: CGFloat = 10
    }

    // MARK: - Type ramp (editor face: SF Pro Rounded; mono: SF Mono)

    /// H1 26/700 · H2 20/700 · H3 16/600 · H4–H6 14/600.
    public func headingFont(level: Int) -> PlatformFont {
        switch level {
        case 1: return roundedFont(size: 26, weight: .bold)
        case 2: return roundedFont(size: 20, weight: .bold)
        case 3: return roundedFont(size: 16, weight: .semibold)
        default: return roundedFont(size: 14, weight: .semibold)
        }
    }

    public func headingLineHeightMultiple(level: Int) -> CGFloat {
        switch level {
        case 1: return 1.25
        case 2: return 1.3
        default: return 1.35
        }
    }

    /// Space above/below headings: H1 32/12 · H2 28/10 · H3 22/8.
    public func headingSpacing(level: Int) -> (above: CGFloat, below: CGFloat) {
        switch level {
        case 1: return (32, 12)
        case 2: return (28, 10)
        case 3: return (22, 8)
        default: return (16, 8)
        }
    }

    public func bodyFont() -> PlatformFont {
        roundedFont(size: bodySize, weight: .regular)
    }

    public func boldBodyFont() -> PlatformFont {
        roundedFont(size: bodySize, weight: .bold)
    }

    /// Inline code: 12.5pt mono. Code blocks: 12pt mono, line height 1.6.
    public func inlineCodeFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    }

    public func codeBlockFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: 12, weight: .regular)
    }

    /// UI captions/status: 10.5pt mono per spec.
    public func captionFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: 10.5, weight: .regular)
    }

    private func roundedFont(size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        #if canImport(AppKit)
        let descriptor = base.fontDescriptor.withDesign(.rounded)
        return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? base
        #else
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #endif
    }

    // MARK: - Colors (dynamic: light per handoff, dark = inverted ink/canvas)

    /// `ink` #1D1D1F — headings, bold text.
    public var ink: PlatformColor {
        dynamic(light: rgb(0x1D1D1F), dark: rgb(0xF2F2F4))
    }

    /// `ink.body` #333333 — body text.
    public var textColor: PlatformColor {
        dynamic(light: rgb(0x333333), dark: rgb(0xD9D9DE))
    }

    /// `ink.secondary` — 55% ink.
    public var secondaryTextColor: PlatformColor {
        dynamic(light: rgb(0x1D1D1F, alpha: 0.55), dark: rgb(0xF2F2F4, alpha: 0.55))
    }

    /// `ink.tertiary` — 35–40% ink.
    public var tertiaryTextColor: PlatformColor {
        dynamic(light: rgb(0x1D1D1F, alpha: 0.38), dark: rgb(0xF2F2F4, alpha: 0.38))
    }

    /// `canvas` — the editor page.
    public var canvas: PlatformColor {
        dynamic(light: rgb(0xFFFFFF), dark: rgb(0x1B1B1D))
    }

    /// `surface.sidebar` #F5F5F7.
    public var sidebarSurface: PlatformColor {
        dynamic(light: rgb(0xF5F5F7), dark: rgb(0x232326))
    }

    /// `fill.codeInline` #F2F2F4.
    public var inlineCodeFill: PlatformColor {
        dynamic(light: rgb(0xF2F2F4), dark: rgb(0x2E2E32))
    }

    /// `surface.code` #1E2430 — the SAME in both appearances (handoff rule).
    public var codeSurface: PlatformColor { rgb(0x1E2430) }

    /// Code block body text #D6DCE6.
    public var codeText: PlatformColor { rgb(0xD6DCE6) }

    /// Syntax token colors (one theme, both appearances).
    public enum CodeToken {
        public static let keyword = rgbStatic(0xC792EA)
        public static let function = rgbStatic(0x82AAFF)
        public static let type = rgbStatic(0xFFCB6B)
        public static let comment = rgbStatic(0x697794)
        public static let string = rgbStatic(0xC3E88D)
        public static let number = rgbStatic(0xF78C6C)
    }

    /// System accent (`controlAccentColor`); #2A6FDB is the marketing value.
    public var accent: PlatformColor {
        #if canImport(AppKit)
        .controlAccentColor
        #else
        .tintColor
        #endif
    }

    public var linkColor: PlatformColor { accent }

    /// Hairlines: 12% ink (HR), 8% (outline rules), 7% (borders).
    public var hairline: PlatformColor {
        dynamic(light: rgb(0x000000, alpha: 0.12), dark: rgb(0xFFFFFF, alpha: 0.12))
    }

    /// Blockquote rule: 15% ink, 3pt wide.
    public var quoteRule: PlatformColor {
        dynamic(light: rgb(0x000000, alpha: 0.15), dark: rgb(0xFFFFFF, alpha: 0.15))
    }

    /// Table body-row hairline: 7% ink (header rule uses `quoteRule`, 15%).
    public var tableRule: PlatformColor {
        dynamic(light: rgb(0x000000, alpha: 0.07), dark: rgb(0xFFFFFF, alpha: 0.09))
    }

    /// Highlight palette (≥4.5:1 with ink.body); dark variants desaturated ~15%.
    public enum Highlight: String, CaseIterable, Sendable {
        case lime, pink, yellow, blue, orange

        public var color: PlatformColor {
            switch self {
            case .lime: return themeDynamic(light: rgbStatic(0xD9F59B), dark: rgbStatic(0x5A6B33))
            case .pink: return themeDynamic(light: rgbStatic(0xF7D9F0), dark: rgbStatic(0x6B4462))
            case .yellow: return themeDynamic(light: rgbStatic(0xFDEEAA), dark: rgbStatic(0x6E6337))
            case .blue: return themeDynamic(light: rgbStatic(0xCFE6FB), dark: rgbStatic(0x3A5570))
            case .orange: return themeDynamic(light: rgbStatic(0xFEDBC6), dark: rgbStatic(0x6E4A34))
            }
        }
    }

    public var searchHighlight: PlatformColor {
        #if canImport(AppKit)
        .findHighlightColor
        #else
        .systemYellow
        #endif
    }

    // MARK: - Helpers

    private func dynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
        themeDynamic(light: light, dark: dark)
    }

    private func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> PlatformColor {
        rgbStatic(hex, alpha: alpha)
    }
}

// Free functions so nested enums can share them.

func rgbStatic(_ hex: UInt32, alpha: CGFloat = 1) -> PlatformColor {
    PlatformColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func themeDynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
    #if canImport(AppKit)
    return NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
    #else
    return UIColor { traits in
        traits.userInterfaceStyle == .dark ? dark : light
    }
    #endif
}

// MARK: - MermaidKit adapter

extension Theme {
    /// Quoin's design system projected onto MermaidKit's theme seam — the
    /// same seven values the diagram renderers used before extraction.
    public var diagramTheme: DiagramTheme {
        DiagramTheme(
            ink: ink,
            secondaryTextColor: secondaryTextColor,
            tertiaryTextColor: tertiaryTextColor,
            canvas: canvas,
            accent: accent,
            hairline: hairline,
            prefersDark: prefersDark
        )
    }
}
#endif
