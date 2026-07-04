# Renderer fixtures

`renderer/` holds focused markdown modules — one per feature area — split from
the original monolithic stress documents. They serve two jobs:

1. **CI conformance.** `RendererConformanceTests` (in `Tests/QuoinCoreTests`)
   parses every module and checks:
   - it parses, produces blocks, and preserves its source byte-for-byte;
   - structural metrics (block / heading / diagram / math / table counts) match
     the committed snapshot in `Tests/QuoinCoreTests/Snapshots/renderer-metrics.json`;
   - every natively-rendered mermaid diagram lays out non-degenerately.

   After an intentional fixture or parser change, regenerate the snapshot:

   ```sh
   QUOIN_UPDATE_SNAPSHOTS=1 swift test --filter RendererConformanceTests
   ```

2. **Dogfooding.** To browse the modules in the app instead of scrolling a
   70k-char document, copy the folder into your Quoin library (the sandbox
   blocks `-QuoinLibraryPath` from reaching an arbitrary repo folder on a
   normal launch):

   ```sh
   cp -R Fixtures/renderer ~/Documents/ClintNotes/RendererFixtures
   ```

   They then appear as a `RendererFixtures` folder in the sidebar; re-copy
   after editing a fixture.

## Modules

| File | Covers |
|---|---|
| `01-headings.md` | ATX/Setext headings, anchors, thematic breaks |
| `02-inline-and-links.md` | emphasis/code/strikethrough, links, images |
| `03-lists-and-tasks.md` | lists, nesting, definition lists, checkboxes |
| `04-blockquotes-callouts.md` | quotes, nested cards, alert callouts |
| `05-code-blocks.md` | fenced/indented code, fences, long lines |
| `06-tables.md` | alignment, escaped pipes, wide/empty cells |
| `07-html-and-footnotes.md` | raw HTML, footnotes, reference definitions |
| `08-unicode-edge-cases.md` | mixed scripts, RTL, ambiguous escapes |
| `09-math.md` | inline/display math, matrices/cases/aligned gallery |
| `10-diagrams.md` | mermaid gallery (native + tidy-fallback types) |
| `11-extensions.md` | non-standard extensions (mostly plain-text fallback) |
| `12-torture.md` | pathological inputs, large repeated content |
