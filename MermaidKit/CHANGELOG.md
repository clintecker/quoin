# Changelog

## Unreleased (pre-0.1)

Initial extraction from [Quoin](https://github.com/clintecker/quoin).

- 23 Mermaid diagram types parsed, laid out, and rendered natively
  (Swift + CoreGraphics, zero dependencies).
- `MermaidView` (SwiftUI), `MermaidRenderer.image`/`.attachmentString`,
  `DiagramTheme`.
- `DiagramScene` geometry IR + `DiagramLayoutLinter` — layout quality
  enforced in CI as geometric invariants.
- Adversarial-input hardening: numeric sanitation at the parser boundary,
  mermaid.js-style input caps (`maxTextSize` 50k, `maxEdges` 500), fuzz-style
  pipeline tests.
- Render benchmarks: every fixture type renders cold in <25 ms on Apple
  silicon (CI-enforced <250 ms).
- Themeable categorical palette: `DiagramTheme(palette:)` re-skins node
  tints/pie slices/sankey bands across all types; render cache now keys on
  the full theme fingerprint (a same-appearance theme change previously
  could serve a stale cached render).
- Second external audit round: fixed two reproduced process crashes
  (gantt `inf`/`nan` duration skipping the sanitizer; packet bit index at
  Int.max overflowing in layout) and two hostile-input hangs (packet
  0..1M-bit ranges, unbounded radar tick loops) — all now clamped at parse
  with adversarial regression tests. Render-layer correctness: iOS trait
  resolution pinned to the theme's appearance (dynamic colors no longer
  bake at ambient traits), theme fingerprint resolved under the same
  pinned appearance and memoized (was ambient-dependent, with a crash
  path on unconvertible colors), cache cost accounts for backing-scale
  bytes, cache hits skip re-parsing, and returned NSImages are copies so
  host mutations can't poison the cache. Async API renamed to
  `renderImage` (a same-name overload made the sync path unreachable in
  async contexts) and now propagates cancellation. Benchmarks force
  rasterization — published numbers were flattered by NSImage's deferred
  drawing; honest worst is ~19 ms (was reported 13.1).
- Swift 6 language mode (swift-tools-version 6.0), zero warnings; async
  `MermaidRenderer.image(source:theme:)` twin renders off the calling
  thread via `sending`.
- `MermaidParser.diagnose(_:)`: human-readable parse failures with 1-based
  line numbers, cap explanations, and did-you-mean header suggestions.
- Performance/robustness audit: A* router's open set is a binary heap
  (architecture fixture 22.4 -> 13.1 ms cold); render cache is bounded
  (64 MB cost limit, NSCache pressure eviction) and wrapped Sendable; both
  targets compile with ZERO warnings under -strict-concurrency=complete.
- DocC documentation catalogs for both targets (Getting Started, Theming,
  Embedding in Text Views, Headless Layout, Scene Geometry and Linting,
  Adding a Diagram Type) + `.spi.yml` for Swift Package Index hosting.
