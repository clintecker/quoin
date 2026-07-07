# ``MermaidRender``

Draw Mermaid diagrams natively with CoreGraphics — SwiftUI views, images,
and text-view attachments, themed by a single value.

## Overview

`MermaidRender` is the drawing half of MermaidKit. It consumes the geometry
produced by `MermaidLayout` and renders it with CoreGraphics/CoreText on
macOS, iOS, iPadOS, and visionOS. There is no JavaScript, no WebView, and no
dependency beyond `MermaidLayout` itself.

Three ways in, from highest-level to lowest:

- ``MermaidView`` — a SwiftUI view: give it Mermaid source, it renders.
- ``MermaidRenderer/image(source:theme:)`` — one call, one native image.
- ``MermaidRenderer/attachmentString(source:theme:)`` — the diagram as a
  single-attachment `NSAttributedString` for embedding in a text view.

All rendering is synchronous (every built-in diagram type renders cold in
under 15 ms on Apple silicon; see the repository README for per-type
numbers) and cached per (source, appearance).

## Topics

### Getting started

- <doc:GettingStarted>
- ``MermaidView``
- ``MermaidRenderer``

### Styling

- <doc:Theming>
- ``DiagramTheme``

### Embedding in text views

- <doc:EmbeddingInTextViews>
