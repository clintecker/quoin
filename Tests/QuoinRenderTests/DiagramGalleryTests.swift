#if canImport(AppKit)
import XCTest
import AppKit
@testable import QuoinRender
import QuoinCore

/// A visual harness — not a CI assertion. Renders each Mermaid diagram type to
/// a PNG so the drawing can be *observed* and iterated toward a polished look.
/// Gated on the `QUOIN_RENDER_GALLERY` env var (an output directory), so it is
/// skipped in normal `swift test` runs:
///
///   QUOIN_RENDER_GALLERY=/tmp/gallery swift test --filter DiagramGalleryTests
///
/// Each sample renders in both light and dark themes at 2.5×, on a padded card
/// matching the theme's canvas.
final class DiagramGalleryTests: XCTestCase {

    static let samples: [(name: String, source: String)] = [
        ("flowchart", """
        flowchart TD
            A[Start] --> B{Ready?}
            B -->|Yes| C[Process input]
            B -->|No| D[Wait]
            C --> E[(Store)]
            D --> B
            E --> F([Done])
        """),
        ("sequence", """
        sequenceDiagram
            participant U as User
            participant A as API
            participant DB as Database
            U->>A: POST /order
            A->>DB: insert order
            DB-->>A: order id
            A-->>U: 201 Created
        """),
        ("pie", """
        pie title Time by phase
            "Parsing" : 35
            "Layout" : 25
            "Drawing" : 30
            "Tests" : 10
        """),
        ("class", """
        classDiagram
            class Shape {
                +String name
                +area() double
            }
            class Circle {
                +double radius
                +area() double
            }
            class Rectangle {
                +double w
                +double h
            }
            Shape <|-- Circle
            Shape <|-- Rectangle
        """),
        ("er", """
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE_ITEM : contains
            CUSTOMER {
                string name
                string email
            }
            ORDER {
                int id
                date created
            }
        """),
        ("state", """
        stateDiagram-v2
            [*] --> Idle
            Idle --> Running : start
            Running --> Paused : pause
            Paused --> Running : resume
            Running --> Idle : stop
            Running --> [*]
        """),
        ("gantt", """
        gantt
            title Renderer Hardening Schedule
            section Parser
            CommonMark baseline    :done,    cm, 2026-07-01, 2d
            GFM tables/tasks       :active,  gfm, after cm, 3d
            Unicode and RTL sweep  :         uni, after gfm, 2d
            section Extensions
            Mermaid pass           :crit,    mer, 2026-07-06, 4d
            MathJax pass           :crit,    mj,  after mer, 3d
            section Release
            Visual regression      :milestone, vr, 2026-07-17, 0d
            Canary                 :         canary, after vr, 2d
        """),
    ]

    func testRenderGallery() throws {
        guard let dir = ProcessInfo.processInfo.environment["QUOIN_RENDER_GALLERY"] else {
            throw XCTSkip("set QUOIN_RENDER_GALLERY=<dir> to render the diagram gallery")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, source) in Self.samples {
            for (suffix, dark) in [("light", false), ("dark", true)] {
                guard let png = Self.renderPNG(source: source, theme: Theme(prefersDark: dark), scale: 2.5) else {
                    print("SKIP \(name)-\(suffix): no native render"); continue
                }
                let file = out.appendingPathComponent("\(name)-\(suffix).png")
                try png.write(to: file)
                print("wrote \(file.path)")
            }
        }
    }

    /// Renders a diagram to a padded PNG card, or nil if the source isn't
    /// natively rendered. Draws the diagram image under the theme's appearance
    /// so dynamic colors resolve to match the card.
    static func renderPNG(source: String, theme: Theme, scale: CGFloat, pad: CGFloat = 24) -> Data? {
        guard let attachment = DiagramRenderer.attachmentString(source: source, theme: theme),
              let image = (attachment.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.image
        else { return nil }
        let size = NSSize(width: image.size.width * scale + pad * 2, height: image.size.height * scale + pad * 2)
        let card = NSImage(size: size)
        card.lockFocus()
        let background = theme.prefersDark ? NSColor(srgbRed: 0x1B / 255, green: 0x1B / 255, blue: 0x1D / 255, alpha: 1) : .white
        background.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(x: pad, y: pad, width: image.size.width * scale, height: image.size.height * scale),
                   from: .zero, operation: .sourceOver, fraction: 1)
        card.unlockFocus()
        guard let tiff = card.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
