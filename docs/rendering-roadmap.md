# Rendering & interaction roadmap

Driven by dogfooding against the two stress fixtures in `~/Documents/ClintNotes`
(`markdown_renderer_stress_test.md`, `markdown_renderer_extreme_stress_test.md`)
and Clint's direct feedback. Ordered by "does the app feel broken" first, then
polish, then coverage. Each item lists the symptom, the suspected cause, the
approach, and rough size (S/M/L).

## Done (recent)

- Long-doc scrolling (NSTextView maxSize).
- Block decorations: code canvas + copy, callout boxes, table rules, diagram
  frames, front-matter chip.
- Flowchart edges: fan-out attachment on the node outline, back-edges routed
  around the band.
- Five distinct callout types (Note/Tip/Important/Warning/Caution).
- Real gaps between adjacent cards; blockquote rule moved into the gutter.
- Double-click to edit embeds; smart-pair wrap-selection; word-under-caret
  formatting.

## Phase 1 — Interaction correctness (the app must feel reliable)

### 1.1 Outline / TOC navigation is unreliable  — M
- **Symptom:** clicking an outline row does nothing, or jumps to an unrelated
  section. Worse in docs with repeated heading text ("Repeated heading",
  "Batch N").
- **Suspected cause:** the heading's `BlockID` (`contentHash:occurrence`) used by
  the outline doesn't match the key in `rendered.blockRanges`; occurrence
  indexing likely diverges between outline build and block render. `[TOC]`
  in-doc links and heading anchors must resolve through the same path.
- **Approach:** make one canonical id→range resolver; unit-test it on a doc with
  duplicate headings; verify `scrollTarget`→`scrollRangeToVisible` lands on the
  exact heading. Extend to `quoin-anchor://` links and the `[TOC]` block.

### 1.2 Clicking the editor feels unpredictable  — M/L
- **Symptom:** clicking around the viewport reacts oddly as a block flips from
  rendered to editable; the caret jumps to the end of the block.
- **Cause:** single-click activates a block, which re-projects it as raw source
  and resets the caret to the block end (there is no rendered↔source caret map).
- **Near-term approach (M):** on activation, don't force the caret to block end;
  keep it near the click, and minimise the reflow surprise (only the caret's
  span reveals). Embeds already require double-click.
- **Stretch (L):** a real rendered↔source character map (attach source ranges to
  inline AST nodes) so a click in rendered text lands the caret precisely and
  ⌘B works on a rendered selection without entering edit mode. Hot-path change;
  guard the byte-lossless round-trip.

### 1.3 Nested block decorations don't draw  — M
- **Symptom:** a fenced code block inside a blockquote (or list item) renders as
  bare monospace with no dark canvas.
- **Cause:** decoration geometry/round-trip inside a nested container; the box's
  full-width override and the parent's indent/italic passes interact badly.
- **Approach:** compute decoration frames relative to the nested content bounds;
  don't let the blockquote's font/indent enumeration clobber child cards.

## Phase 2 — Diagram rendering quality

### 2.1 Class diagram edges  — M
- **Symptom:** relationship lines cross and tangle; center-to-center straight
  segments; markers (inheritance ▷, composition ◆, aggregation ◇) need clean
  placement.
- **Approach:** port the flowchart routing (fan-out attachment on box borders,
  orthogonal routes, label-on-segment). Draw relationship markers at the target
  border. Avoid label/line overlap.

### 2.2 State diagram layout  — L
- **Symptom:** complex machines (composite states, choice, fork/join) are a mess
  of crossings and long edges.
- **Approach:** reuse the improved layered routing; render choice as a small
  diamond, fork/join as bars, composite states as nested rounded containers with
  their own sub-layout. Phase: edges first, then composite/fork/join.

## Phase 3 — Coverage (breadth)

### 3.1 More Mermaid types  — L (per type)
- **Have:** flowchart, sequence, pie; class/ER partial.
- **Add, by likely usage:** solid state, gantt, then gitGraph / mindmap /
  timeline as reach. Each = parser + layout + renderer.
- **Guardrail:** anything unsupported must degrade to a *tidy* labelled source
  block, never a broken half-render.

### 3.2 Math coverage (toward MathJax-class)  — L
- **Symptom:** extreme LaTeX (matrices, `\begin{aligned}`, `cases`, `\nabla`,
  greek like `\varepsilon`, stacked sub/superscripts, nested fractions) falls
  back to source.
- **Options:** (a) grow the native typesetter incrementally for the constructs
  the fixtures actually use; (b) adopt a vetted math engine — requires a written
  TRD justification per the one-dependency policy. Recommend (a) first, measured
  against the fixture, then decide.

## Cross-cutting

- **Conformance harness (S/M):** parse+render both stress fixtures in CI; snapshot
  HTML export and key layout metrics so these regressions can't creep back.
- **Graceful fallback style (S):** one consistent "unsupported, shown as source"
  treatment for math/mermaid/extensions so degradation looks intentional.

## Suggested order

1.1 → 1.2 (near-term) → 1.3 → 2.1 → 2.2 → 3.x, with the conformance harness added
alongside 1.1 so fixes stay fixed.
