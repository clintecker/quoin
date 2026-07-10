# UI refresh — preparation

*2026-07-10. Clint supplied five reference screenshots ("Prepare to do a
UI refresh") showing a soft, rounded, card-based visual language. This
doc extracts the design tokens from those references, maps them onto
Quoin's theme seams, and lists the decisions that need Clint before
implementation. The reference PNGs should be dropped into
`docs/design/ui-refresh/` (they exist only in the conversation today).*

**Canon note:** this supersedes parts of the Graphite handoff's visual
spec (option 1a). The handoff remains canonical for INTERACTION rules
(reveal model, viewport invariant, keyboard map); its palette/typography
give way to this language once approved.

## The language, extracted from the references

| Token | Reference value (eyeballed) | Quoin today (`Theme.swift`) |
|---|---|---|
| App canvas | soft cool gray `#F2F3F5` | flat white/system |
| Content surface | white floating cards, radius ~14, faint wide shadow | flat, no cards |
| Body type | rounded geometric sans (SF Pro Rounded-adjacent), ~17pt, ~1.5 leading | SF Pro, 15pt-ish |
| H1 | very heavy, ~34pt, tight | headingFont ramp |
| Secondary text | muted slate blue-gray `#8A96A8`-ish (subtitles, done-tasks) | secondaryTextColor (gray) |
| Accent | vivid blue ≈ `systemBlue` `#3478F6` | controlAccentColor ✓ close |
| Sidebar selection | full-width rounded PILL in accent, white label | system list selection |
| Sidebar icons | blue folders, gray doc glyphs, unsupported files dimmed | current tree |
| Inline code | light gray rounded chip `#EEF0F3`, mono, dark ink | inlineCodeFill ✓ shape flatter |
| Highlights | saturated pastel bands, generous padding + rounding; multiple hues coexist (lime, lavender) | Highlight.lime etc., tighter |
| Links | accent blue + small pencil glyph suffix (inline edit affordance!) | accent, no glyph |
| Checkboxes | large rounded-square outline; checked = gray fill-check + muted (not struck) label | ☑/☐ text glyphs, strikethrough |
| Tables | full hairline grid, zebra rows, rounded outer corners, roomy cells | header rule + hairlines, no grid/zebra |
| Callout (Note) | left accent bar + barely-tinted card, icon + bold title | tinted rounded box + border |
| Mermaid nodes | rounded boxes, per-state colored strokes w/ tinted fills, curved gray edges, mono labels | MermaidKit default theme (close!) |
| Window chrome | traffic lights inset on card; floating circular/pill toolbar buttons (B I U pill, panel toggles); filename as plain title | standard toolbar |
| TOC / outline | right slide-over card; rows with hairline underlines, chevrons, depth-dimmed | outline sidebar |
| Doc stats | dedicated panel ("word count, paragraph count, reading time at a glance") | status bar |

## Seam map (where each lands)

- **Palette + type ramp:** `Sources/QuoinRender/Theme.swift` — canvas,
  secondary, fills, highlight hues, `bodyFont()`/`headingFont()` (SF
  Rounded via `NSFont.systemFont(...).withDesign(.rounded)`; no bundled
  font unless Clint wants the exact face — licensing).
- **Block chrome:** `QuoinTextView.draw(_:)` cases — radii to ~12,
  callout → left-bar style, `tableRules` → full grid + zebra + rounded
  clip, checkbox glyphs → drawn SF Symbols (needs a decoration or
  attachment swap, not text glyphs).
- **Highlight/inline styling:** `AttributedRenderer` inline attributes +
  `Theme.Highlight` (padding via expanded background… per-glyph
  backgrounds were a shipped bug — pastel BANDS need decoration-drawn
  rounded runs, same machinery as chips).
- **Cards/canvas:** reader background + content inset in
  `MarkdownReaderView` (canvas color) — the floating-card reading
  surface is a bigger compositional change (document column as a card).
- **Sidebar/toolbar/TOC:** `App/macOS` SwiftUI (`MainWindow`,
  `ReaderScreen`, library list styling, format pill already exists and
  matches the reference's B/I/U pill idea).
- **Mermaid theme:** `Theme.diagramTheme` → MermaidKit `DiagramTheme`
  (already close to the reference look; tune fills/strokes).

## Phasing (proposed)

1. **Tokens:** palette + rounded type + spacing in `Theme` — one commit,
   snapshot/digest regeneration, both appearances.
2. **Block chrome:** radii, callout left-bar, table grid/zebra, drawn
   checkboxes, highlight bands.
3. **Chrome:** canvas + card reading surface, sidebar pill selection +
   icons, toolbar pills, TOC slide-over restyle, stats panel.
4. **Polish:** link edit-glyph affordance (pairs with the embed edit
   grammar), diagram theme tuning, dark-mode derivation.

## Open questions for Clint (blocking implementation)

1. **Wholesale or optional?** Replace Graphite as THE look, or ship as a
   second theme (Settings already has appearance plumbing)?
2. **Dark mode:** the references are all light. Derive a dark twin of
   the card language, or keep current dark palette until references
   exist?
3. **Code blocks:** references only show inline code (light chip). Keep
   the signature dark `#1E2430` block canvas, or go light-card?
4. **Type:** SF Pro Rounded (free, native, close) vs licensing the exact
   face from the mockups?
5. **Scope check:** the reference sidebar shows dimmed non-md files
   (images) in the tree — adopt showing non-markdown files?

## Risks

- Pastel highlight bands + rounded padding must pass contrast in both
  appearances (the lavender-on-white is borderline for small text).
- Digest/screenshot goldens churn heavily at the token commit — one
  regeneration with rationale, then stable.
- The handoff document remains referenced by CLAUDE.md as canonical —
  update the hierarchy note when phase 1 lands.
