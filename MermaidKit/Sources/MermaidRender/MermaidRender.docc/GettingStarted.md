# Getting Started

Render your first diagram in one line, then choose the right API for your
app's shape.

## Add the package

```swift
.package(url: "https://github.com/<org>/MermaidKit.git", from: "0.1.0")
```

Depend on the `MermaidRender` product (it brings `MermaidLayout` with it).

## SwiftUI: MermaidView

```swift
import MermaidRender

struct Docs: View {
    var body: some View {
        ScrollView {
            MermaidView("""
            sequenceDiagram
                App->>API: POST /session
                API-->>App: 201 token
            """)
            .padding()
        }
    }
}
```

``MermaidView`` follows the environment's color scheme and re-renders when
it flips. It displays at the diagram's natural size and scales *down* to fit
a narrower container — never up. If the source isn't recognized Mermaid, it
degrades to the raw text in monospaced type, so a typo'd diagram stays
inspectable instead of vanishing.

Pass an explicit theme to opt out of appearance-following:

```swift
MermaidView(source, theme: DiagramTheme(prefersDark: true))
```

## AppKit/UIKit: images

```swift
let image = MermaidRenderer.image(
    source: source,
    theme: DiagramTheme(prefersDark: view.effectiveAppearance.isDark)
)
imageView.image = image   // NSImage on macOS, UIImage elsewhere
```

`image(source:theme:)` returns `nil` for unrecognized sources — branch to
your own fallback (most apps show the fenced source).

## What parses, what doesn't

23 diagram types parse their core syntax. Styling and interaction
directives from mermaid.js (`%%{init:}%%`, `classDef`, `style`, `click`…)
are **ignored, not fatal** — the diagram renders with your
``DiagramTheme`` instead. Unknown dialects return `nil`. Input is bounded
(`MermaidParser.maxTextSize`, `MermaidParser.maxEdges`); past the caps,
parsing returns `nil` fast.

## Performance model

Rendering is synchronous and cached per (source, appearance). Cold renders
are single-digit milliseconds for most types (worst measured: ~22 ms for a
dense architecture diagram), so calling from a SwiftUI `body` or a
main-thread layout pass is by design. If you're rendering hundreds of
diagrams in one pass, do it off-main and hand images back.
