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
  mermaid post-passes, `DocumentSession` actor (edits, undo, autosave,
  conflicts), file watching, block diffing, search, statistics, library
  tree + quick open, the QuoinMath LaTeX parser, the Mermaid parser and
  layout engines, TXT/MD/HTML exporters.
- `Sources/QuoinRender` — AST → attributed strings, TextKit 2 reader/editor
  views for macOS and iOS, the native math typesetter and diagram drawing,
  PDF/RTF export, themes (Apple platforms, `#if canImport` guarded).
- `App/macOS` — the macOS app: library window, tabs, WYSIWYG editing,
  export sheet, print.
- `App/iOS` — the iOS/iPadOS app: Files-integrated document reader with
  outline/stats sheets and share-sheet exports.

## Building

Requires Xcode 16+ / Swift 5.10 on macOS 14+.

```sh
swift build            # builds QuoinCore + QuoinRender
swift test             # runs the QuoinCore test suite
```

App targets are generated with XcodeGen:

```sh
brew install xcodegen
cd App/macOS && xcodegen && open Quoin.xcodeproj      # macOS
cd App/iOS   && xcodegen && open QuoinIOS.xcodeproj   # iOS/iPadOS
```

CI (`.github/workflows/ci.yml`) runs the full test suite, builds both
apps, enforces the PRD performance budgets, and captures UI screenshots
to the `ci-screenshots` branch on every push.

## Dependency policy

One code dependency: [swift-markdown](https://github.com/swiftlang/swift-markdown)
(Apple's cmark-gfm wrapper). New dependencies require written justification
in the TRD; the default answer is no.
