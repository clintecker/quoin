# Quoin

A fast, native markdown viewer for macOS and iOS. Fully native rendering —
zero JavaScript, no web views — with complete markdown support: GFM tables,
task lists, math, Mermaid diagrams, inline images, table of contents,
statistics, quick search, tabs, live rendering, and PDF/RTF/TXT/MD export.
Local-only: no sync, no accounts, no network at runtime.

A *quoin* is the wedge a letterpress printer uses to lock type into the
chase — the small, precise tool that makes the whole page hold.

## Structure

- `Sources/QuoinCore` — platform-agnostic engine: document model with a
  UTF-8 source map, swift-markdown (cmark-gfm) parse pipeline with math and
  mermaid post-passes, `DocumentSession` actor, file watching, block diffing,
  search, statistics, TXT/MD exporters.
- `Sources/QuoinRender` — AST → attributed strings, TextKit 2 layout,
  themes (Apple platforms only).
- `App/macOS` — the macOS app shell (document-based, native window tabs).

## Building

Requires Xcode 16+ / Swift 5.10 on macOS 14+.

```sh
swift build            # builds QuoinCore + QuoinRender
swift test             # runs the QuoinCore test suite
```

The macOS app target lives in `App/macOS` — see `App/macOS/README.md`.

> **Status:** early development (M1, reading core). This tree was authored in
> a Linux cloud session without access to a Swift toolchain, so it has not
> yet been compiled — expect a shakedown pass in Xcode on first build.

## Dependency policy

One code dependency: [swift-markdown](https://github.com/swiftlang/swift-markdown)
(Apple's cmark-gfm wrapper). New dependencies require written justification
in the TRD; the default answer is no.
