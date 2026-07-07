#if canImport(AppKit) || canImport(UIKit)
import Foundation
import CoreGraphics
#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
public typealias PlatformImage = UIImage
#endif

func rgbStatic(_ hex: UInt32, alpha: CGFloat = 1) -> PlatformColor {
    PlatformColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func themeDynamic(light: PlatformColor, dark: PlatformColor) -> PlatformColor {
    #if canImport(AppKit)
    return NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    #else
    return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    #endif
}
func resolvedCGColor(_ color: PlatformColor) -> CGColor {
    #if canImport(AppKit)
    return color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor
    #else
    return color.cgColor
    #endif
}
#endif
