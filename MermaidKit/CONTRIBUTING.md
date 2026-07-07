# Contributing to MermaidKit

## The lay of the land

One diagram type = three small, independent pieces:

- `Sources/MermaidLayout/MermaidParser+<Type>.swift` — text → model
- `Sources/MermaidLayout/DiagramLayout<Type>.swift` — model → geometry
  (frames/polylines; text metrics come in through `DiagramTextMeasurer`)
- `Sources/MermaidRender/DiagramRenderer+<Type>.swift` — geometry → CoreGraphics

Plus a lowering (`DiagramScene+<Type>.swift`) that hands the geometry to the
layout linter.

## Ground rules

- `swift test` and `swift test --package-path MermaidKit` must stay green.
- **Layout changes are judged by geometry.** Every type's dense fixture in
  `Fixtures/diagrams/` must lint clean (`LayoutLintTests`); iterate on one
  type with `QUOIN_LINT_TYPE=<type> swift test --filter testLintSingleType`.
  The linter is necessary, not sufficient — also render your fixture and
  *look at it*.
- **The parser never crashes.** New numeric fields go through
  `MermaidParser.finiteDouble`; new syntax must tolerate garbage (see
  `AdversarialInputTests` — add cases for anything you touch).
- Performance: `RenderBenchmarks` fails if any fixture renders cold in
  >250 ms.
- No new dependencies. Layout stays platform-free (`Foundation` +
  `CoreGraphics` only, `canImport`-guarded).
- Regenerate README images with `scripts/gen-gallery.sh` when a fix changes
  how a fixture renders.

## Most-wanted

- Syntax-coverage gaps in existing types (bring the diagram that broke).
- An SVG backend over `DiagramScene` / the layout structs — this makes the
  pipeline portable beyond Apple platforms.
- Lower OS floors, with CI to prove them.
