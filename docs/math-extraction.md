# The math engine extraction: Vinculum

*DONE 2026-07-11. The native math typesetter — Quoin's second-largest
self-contained engine after diagrams — was extracted into its own
published package, **Vinculum** (`github.com/clintecker/Vinculum`), the
way MermaidKit was. This doc records how, and remains the reference for
co-developing the engine going forward.*

## Why

Same case as MermaidKit: an independent package gets its own CI and
version cadence, is reusable by other apps, shrinks Quoin's compile
surface, and forces a clean public API. Math is a natural unit — a pure
LaTeX→geometry pipeline with **zero third-party dependencies** and no
Quoin-specific logic once the theme seam is in place.

The precedent is fully worked out: MermaidKit is public
(github.com/clintecker/MermaidKit), consumed from Quoin via
`.package(url:from:)`, allowlisted in `scripts/check-dependency-policy.sh`,
and re-exported through `Sources/QuoinCore/MermaidReexport.swift` so
`import QuoinCore` still exposes `MermaidParser`. The math extraction
should mirror this exactly.

## The name: Vinculum

**Decided (2026-07-11): `Vinculum`.** The vinculum is the horizontal bar
in a fraction, the line over a root, the `\overline` — the exact stroke
the typesetter hand-draws everywhere. It's unmistakably *math*, has zero
collisions in the Swift ecosystem (unlike the crowded `SwiftMath`/`iosMath`
descriptive space), and — like MermaidKit naming itself for its domain
rather than "DiagramKit" — it gives the engine an identity of its own.
Package repo: `github.com/clintecker/Vinculum`. No "Kit" suffix — the word
carries itself.

## Target shape (mirrors MermaidLayout / MermaidRender)

Two products, matching the split that already exists in-repo:

- **VinculumLayout** (platform-free, Linux-safe, zero deps) — the current
  `Sources/QuoinCore/Math/` files: `MathParser` (+ `MathNode`,
  `MathAtomClass`, `MathSymbolStyle`, `MathMatrixStyle`, `MathAccent`,
  `MathOverUnder`, `MathDecoration`), `MathScanner`, `MathAlphabet`,
  `MathMacros`. The analog of MermaidLayout: parse + model, no drawing.
  (Type names keep their `Math*` prefix — they're the vocabulary of the
  domain, and renaming them would churn every call site for no gain, just
  as MermaidLayout kept `MermaidParser`/`DiagramScene`.)
- **VinculumRender** (CoreText/CoreGraphics, AppKit/UIKit-guarded) — the
  current `Sources/QuoinRender/Math/` files: `MathTypesetter` (the
  `MathBox` layout), `MathImageRenderer` (the cached `NSTextAttachment`
  API), `MathTheme` (the seam). The analog of MermaidRender. Needs its
  own `Platform.swift` with the `PlatformColor/Font/Image` typealiases
  (copy MermaidRender's verbatim).

`VinculumRender` depends on `VinculumLayout`. QuoinCore depends on
`VinculumLayout` and `@_exported import VinculumLayout`s it (new
`VinculumReexport.swift`, mirror of `MermaidReexport.swift`) so every
`import QuoinCore` call site is unchanged. QuoinRender depends on
`VinculumRender`.

## Already done (this session — the hard part)

The one thing that genuinely blocked extraction was the coupling to
Quoin's `Theme`. That is now severed, mirroring `DiagramTheme`:

- **`MathTheme` seam** (`Sources/QuoinRender/Math/MathTheme.swift`) — a
  minimal value type (`ink`, `prefersDark`, a resolved-ink `fingerprint`
  for cache keying) with `.light`/`.dark` presets. `MathTypesetter` and
  `MathImageRenderer` depend on it, never on `Theme`. Quoin adapts via
  `Theme.mathTheme` (mirror of `Theme.diagramTheme`). Grep confirms the
  seam is exactly two values — the render was already all but decoupled.
- **`Math/` file grouping** — sources are pre-sorted into
  `Sources/QuoinCore/Math/` (→ MathLayout) and `Sources/QuoinRender/Math/`
  (→ MathRender), so the future split is a folder move, not archaeology.
- **Render cache** keys on the ink fingerprint, so a host passing custom
  ink can't collide with the default theme's cached renders.

Both changes are behavior-preserving — every math golden is byte-identical.

## Remaining coupling to sever at extraction time

Small and mechanical; none of it needs doing before the split is scheduled:

1. **Platform typealiases.** `MathRender` currently borrows
   `PlatformColor/Font` from `Theme.swift` and `PlatformImage` from
   `AttributedRenderer.swift`. The package needs its own `Platform.swift`
   (copy MermaidRender's). *Trivial.*
2. **QuoinCore imports.** `MathTypesetter`/`MathImageRenderer` import
   `QuoinCore` only for `MathParser` et al. — after the split they import
   `MathLayout`. `MarkdownConverter` (QuoinCore) uses `MathScanner`,
   `MathMacros`, `MathParser` — those move to MathLayout, which QuoinCore
   already depends on. No call-site churn thanks to the re-export.
3. **Nothing else.** The math code reaches into no other Quoin subsystem.
   `AttributedRenderer`'s fallback source-card, the `mathSource` attribute
   tagging, the `‹/› edit` reveal integration, and the live-preview panel
   are all Quoin glue that consume `MathImageRenderer.attachmentString` /
   `MathParser.unsupportedCommands` — they STAY in Quoin and keep working
   through the package API, exactly as the diagram glue does today.

## Migration mechanics (when scheduled)

1. Assemble the new package from the two `Math/` folders into
   `Sources/MathLayout/` + `Sources/MathRender/` (+ `Platform.swift`,
   `Package.swift`, `CONTRIBUTING.md` with the same pre-1.0 stability
   stance MermaidKit uses). Because the two products come from two
   different current targets, this is a *move-and-assemble*, not a single
   `git subtree split` — history for each folder can still be preserved
   with per-folder subtree splits merged into the new repo if desired.
2. Move the math tests + fixtures: `MathParserTests`, `MathMacroTests`,
   `MathAndDiagramTests` (math half), `MathGoldenRenderTests` +
   `Tests/fixtures/math-golden/` → the package's own CI. Quoin keeps a
   thin conformance test (the guide already is one) and the render-digest
   snapshot (which exercises the integration, not the engine).
3. Publish to `github.com/clintecker/Vinculum`, tag, add its own green CI.
4. In Quoin: add the `.package(url:from:)` dependency, wire
   `VinculumLayout` into QuoinCore and `VinculumRender` into QuoinRender,
   add `VinculumReexport.swift`, delete the vendored `Math/` folders, and
   **allowlist the identity** in `scripts/check-dependency-policy.sh`
   (`vinculum` in `approved_urls` + `approved_identities`) — it's
   first-party, exempt from the one-dependency policy, same as mermaidkit.
5. Heed the MermaidKit gotchas (from memory): after each pin bump,
   `swift package clean` before testing (a changed public-struct layout
   has caused link failures AND a runtime segfault on incremental builds);
   and a green LOCAL build does not guarantee green package CI (Swift
   version skew — the `.toolTip` iOS break this session is the same class
   of "shared file, one platform" hazard).

## Status checklist — DONE (2026-07-11)

- [x] Theme decoupled behind `MathTheme` seam + `Theme.mathTheme` adapter
- [x] Sources grouped into `Math/` folders matching the product split
- [x] Cache keyed on ink fingerprint (custom-ink correctness)
- [x] Name chosen: **Vinculum** (`github.com/clintecker/Vinculum`)
- [x] `Platform.swift` for VinculumRender (copy MermaidRender's)
- [x] Repo assembled, tests + golden fixtures moved (regenerated with
      `MathTheme.light`), own CI green
- [x] Published + tagged (`0.1.0`); Quoin pins it (`from: "0.1.0"`),
      re-exports it (`VinculumReexport.swift`), allowlists it (`vinculum`)
- [x] Vendored `Math/` folders deleted from Quoin

**Extraction complete.** The engine now lives at
[github.com/clintecker/Vinculum](https://github.com/clintecker/Vinculum);
Quoin consumes it from GitHub exactly like MermaidKit. Follow-ups for
Vinculum's own backlog: a Swift 6 strict-concurrency pass, and the math
gaps still tracked (array rule drawing, `\tag`, `\DeclareMathOperator`, a
real OpenType MATH font). Engine changes now happen in the Vinculum repo →
publish → bump Quoin's pin (remember `swift package clean` after each bump).
