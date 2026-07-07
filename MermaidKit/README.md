# MermaidKit

Native [Mermaid](https://mermaid.js.org) diagrams for Apple platforms — no
JavaScript, no WebView, no dependencies. Parse, lay out, and render all 23
Mermaid diagram types with pure Swift and CoreGraphics.

```swift
import MermaidRender

let image = MermaidRenderer.image(
    source: """
    flowchart TD
        A[Start] --> B{Choice}
        B -->|yes| C[Do it]
        B -->|no| D[Skip]
    """,
    theme: DiagramTheme(prefersDark: false)
)
```

## Why

Embedding Mermaid today means shipping mermaid.js inside a `WKWebView`:
heavyweight, async, non-native text rendering, and no offline guarantees.
MermaidKit renders the same source natively — synchronously, to an
`NSImage`/`UIImage` or an `NSAttributedString` attachment you can drop into
a text view.

## Supported diagram types

architecture-beta, block-beta, C4, class, entity-relationship, flowchart,
gantt, gitGraph, kanban, mindmap, packet-beta, pie, quadrant, radar,
requirement, sankey-beta, sequence, state (v2), journey, timeline, treemap,
xychart-beta, zenuml — one native layout engine per type.

Not every syntax variation of every type is covered; unrecognized sources
return `nil` so hosts can fall back to showing the fenced code.

## Architecture

Two targets:

- **MermaidLayout** — platform-free. `MermaidParser.parse(String)` →
  per-type models → `DiagramLayoutEngine.layout(_:measure:)` → pure geometry
  (frames, polylines). Text measurement is injected (`DiagramTextMeasurer`),
  so layout is fully testable without a display server.
- **MermaidRender** — CoreGraphics/CoreText drawing on macOS, iOS, iPadOS,
  and visionOS. The only styling input is `DiagramTheme` (7 colors + a
  dark-mode flag).

### The layout linter

MermaidLayout includes something unusual: every diagram lowers to a
`DiagramScene` — a machine-readable IR of boxes, edge routes, and labels —
and `DiagramLayoutLinter` checks it against geometric invariants of good
layout (no edge through a box, no overlapping nodes, no off-canvas or
colliding labels, no marks escaping a plot). The linter runs in this
package's test suite over dense fixtures for all 23 types, so layout
regressions fail CI as *geometry*, not as pixel diffs.

## Usage notes

- `MermaidRenderer.image(source:theme:)` — one-shot render, auto-sized.
- `MermaidRenderer.attachmentString(source:theme:)` — the diagram as a
  single-attachment `NSAttributedString` for embedding in text views.
- `MermaidRenderer.textMeasurer` — the renderer's own CoreText measurer;
  pass it to `DiagramLayoutEngine.layout` / `DiagramScene.lower` when you
  want layout or lint geometry to match the render exactly.
- Renders are cached per (source, dark-mode) pair.

MermaidKit was extracted from [Quoin](https://github.com/clintecker/quoin),
a native WYSIWYG markdown editor, which consumes it as a package.
