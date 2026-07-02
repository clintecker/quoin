#if canImport(AppKit) || canImport(UIKit)
import Foundation
import QuoinCore

/// Custom attributed-string keys that carry Quoin semantics through the
/// text system: block identity for scroll anchoring and diff patching,
/// and task-marker ranges for checkbox interaction.
public enum QuoinAttribute {
    /// Value: `String` — the `BlockID` description of the enclosing block.
    public static let blockID = NSAttributedString.Key("quoin.blockID")
    /// Value: `NSNumber` (byte offset) — start of a `[ ]`/`[x]` marker.
    public static let taskMarkerOffset = NSAttributedString.Key("quoin.taskMarkerOffset")
    /// Value: `String` — LaTeX source of a math run (styled-source fallback
    /// today; swapped for QuoinMath rendering in M2a).
    public static let mathSource = NSAttributedString.Key("quoin.mathSource")
    /// Value: `String` — mermaid source of a diagram block (styled-source
    /// fallback today; QuoinDiagram in M2b).
    public static let diagramSource = NSAttributedString.Key("quoin.diagramSource")
    /// Value: `NSNumber(true)` — marks the active block's editable source
    /// run in the editor (the syntax-reveal region).
    public static let editableSource = NSAttributedString.Key("quoin.editableSource")
}

/// Custom URL schemes used for in-document interaction via the text view's
/// standard link plumbing.
public enum QuoinLink {
    public static let taskScheme = "quoin-task"
    public static let anchorScheme = "quoin-anchor"

    /// quoin-task://toggle?offset=N — a clickable checkbox.
    public static func taskURL(markerOffset: Int) -> URL? {
        URL(string: "\(taskScheme)://toggle?offset=\(markerOffset)")
    }

    public static func markerOffset(from url: URL) -> Int? {
        guard url.scheme == taskScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "offset" })?.value
        else { return nil }
        return Int(value)
    }

    /// quoin-anchor://slug — an internal heading link.
    public static func anchorURL(slug: String) -> URL? {
        var components = URLComponents()
        components.scheme = anchorScheme
        components.host = slug
        return components.url
    }

    public static func anchorSlug(from url: URL) -> String? {
        guard url.scheme == anchorScheme else { return nil }
        return url.host
    }
}
#endif
