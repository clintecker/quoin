# Editor modes — a first-principles model for reveal, editing, and embeds

Status: **design proposal** (not yet implemented). Owner: editor/render layer.
This doc defines the *presentation* model that governs how a block is shown
and edited, why the current implementation produces rendering overlaps, the
prior art we're drawing on, and a staged, test-guarded path to the clean model.

It sits under the handoff/TRD in authority: where it conflicts with
`docs/design/handoff.md`, the handoff wins. This doc is about the *machinery*
behind the handoff's visuals, not the visuals themselves.

---

## 1. The irreducible tension

Quoin's source of truth is the markdown string + AST. The editor is a
**projection** of it. But a source-truth WYSIWYG editor has one unavoidable
duality: **every element has a *rendered* form (what you read) and a *source*
form (what you edit).** The screen must default to rendered but let you edit
source locally, around the caret.

"Modes" are not a feature we chose — they are the *mechanism that resolves this
duality per element, per moment.* The design question is therefore:

> **What is the minimal, complete description of an element's presentation
> state, and what transitions connect those states?**

Today that description does not exist as a single value. It is re-derived on the
fly from `activeBlockID` + caret + block kind, scattered across four projection
paths and five geometry consumers. That diffusion — not code blocks
specifically — is the root problem.

---

## 2. The mode taxonomy (what we actually need to support)

The whole space is small. A block is in exactly one **presentation state**:

- **Rendered** (default): formatted; delimiters hidden (1pt clear); embeds show
  their drawn artifact (code canvas, diagram, typeset math, ruled table).
- **Editing**, in one of three *content flavors*:
  - **Prose** — markdown source; delimiters styled; inline spans reveal only
    where the caret sits (paragraph, heading, list, quote, callout, table).
  - **Verbatim** — raw source, zero markdown styling (code, HTML, front-matter).
  - **Preview** — raw source **plus** a side-panel live artifact, last-good held
    while the source is unparseable (mermaid, math).

**Always-on affordances** (independent of state): checkbox, quote gutter, list
marker, heading level; interactive runs (task toggle, anchor jump, copy button,
`‹/›` edit chip).

**Cross-cutting display filters** (orthogonal — they dim/scroll, never change
which representation is shown): focus mode, typewriter, search highlight.

**Transitions** (the state machine):
- **Activate** (rendered → editing): single click / caret-move into prose;
  double-click an embed; type on a rendered block (replays the keystroke as
  `pendingInsertion`); ⌘↩. Carries a `CaretHint` (`.rendered` vs `.source`).
- **Deactivate** (editing → rendered): Escape, the `✓ done` chip, or clicking
  away; restores the caret to the rendered position.
- **Within editing**: caret move (may reveal/hide inline spans), keystroke.

**Invariants that constrain every state and transition** (from the handoff /
CLAUDE.md): the caret's line must not move on a projection change; round-trip
must be byte-lossless; revealed source is 1:1 with the file (hidden delimiters
are 1pt clear text, never removed).

That is the entire model: **Rendered + 3 editing flavors**, orthogonal
overlays, a 3-transition state machine, under the viewport/round-trip
invariants. Everything the editor does is a point in this grid.

---

## 3. Why the current implementation is messy

### 3.1 No single owner of "mode"

Reveal state lives as `ReaderModel` fields (`activeBlockID`,
`caretInActiveBlock`, `caretGeneration`); the *rendering* of that state is
produced by **four** distinct paths across two modules; the live preview is a
**fifth**, out-of-band channel. Nothing owns "what mode is this block in," so:

- **Four projection paths, each re-deriving mode + offsets:**
  1. **Full render** (`AttributedRenderer.render`) — rebuilds the whole
     attributed string; the fallback when any patch declines.
  2. **Activation flip patch** (`activationFlipUpdate`) — ≤2 storage patches on
     activate/deactivate; recomputes `blockRanges` + `activeEditableRange`.
  3. **Per-keystroke `ActiveBlockRenderPatch`** (`makeActiveBlockRenderPatch`) —
     re-renders just the active fragment; shifts all ranges by one delta.
  4. **Caret-move restyle** (`ReaderCoordinator.restyleActiveBlock`) — runs *in
     the view*, **bypasses the projection entirely**, rebuilds a
     `MarkdownSourceStyler` that must be hand-configured (via a single
     `revealVerbatimCode` bool) to match what the renderer did.
- **Dead accommodation nobody removed:** the inline live-preview offset — the
  "`editableRange` ≠ block start; all paths must offset through it" invariant
  CLAUDE.md warns about — is **unreachable today**. The preview moved to a side
  panel, so `editableRange.location` is *always 0*. The three-path offset
  arithmetic survives only because no owner exists to notice it's dead.

### 3.2 No single authority for a block's geometry

The overlap you see is **not** stacked decorations. `blockDecoration` is a
single attribute key — a character carries exactly one `BlockDecoration`, so an
open code block draws the accent `editingFrame` *instead of* the dark
`codeCanvas`, never both. The overlap is that **five consumers each measure the
open block's geometry independently, with different layout engines, at different
instants**, reconciled only by best-effort async passes:

1. the **editing-frame box** — live TextKit fragment frames at *draw* time;
2. the **revealed source runs** — TextKit at *splice* time;
3. the **frozen flip snapshot** — a `cacheDisplay` bitmap of the *old*
   dark-canvas block, captured *before* the splice;
4. the **flip capture gate** — an `NSAttributedString.boundingRect` *estimate*
   (a different engine than TextKit 2). Review note: this authority is
   **cosmetic-only** — the slide delta itself is TextKit-measured on both
   sides; a wrong gate answer costs a missing/superfluous animation and
   cannot produce overlap;
5. the **preview panel** — derived from the editing-frame rect.

### 3.3 The concrete seams (grounded failure modes)

- **T1 — separator/clamp math duplicated** across the full, flip, and
  per-keystroke paths; disagree by a line → ranges drift.
- **T3 — the caret-move restyle re-implements styling outside the renderer**;
  the single largest "two paths compute the same projection independently" seam.
- **T4 — preview geometry split**: the model reserves horizontal room via a
  `tailIndent` written into source paragraphs; the view positions the panel from
  the drawn frame rect. Two computations of one layout, agreeing only by shared
  constants.
- **Seam 1 (primary overlap) — decorations drawn against estimated geometry.**
  After a reveal/keystroke flips delimiter fonts (a reflow), the first draw can
  read pre-settle geometry. Precisely (review-sharpened): run *ranges* are
  never stale (rebuilt from live attributes or shifted arithmetically); what's
  stale is fragment **y-origins derived from unsettled *preceding* content** —
  `.ensuresLayout` forces layout of the enumerated run's own fragments only,
  and a layout forced mid-draw cannot expand the already-committed dirty rect,
  so geometry that settles after the draw leaves painted boxes behind with no
  repaint scheduled. The per-keystroke path (`noteStorageEdit`) settles more
  weakly than the spliced path, and above 200k chars eager layout is skipped
  entirely.
- **T1 is live, not latent (review finding — separator-clamp drift).** The
  per-keystroke patch guards with a *character*-level `separatorSignature`,
  but the separator's clamped-vs-normal *style* depends on whether the slice
  ends with a newline — which typing changes. Typing a trailing newline into a
  revealed block yields a phantom empty paragraph until the next flip.
- **Two owners of caret truth (review finding — stale-caret rerender).** Plain
  caret moves update only the coordinator's copy; the model's
  `caretInActiveBlock` refreshes only on activation/edit-echo. A
  model-initiated rerender while a block is open (async image decode) styles
  the reveal with the activation-time caret — the revealed span snaps back.
- **Seam 2 — the flip crossfade paints the old dark canvas over the new frame.**
  Activation is a content swap (dark canvas → stroked frame). The frozen
  old-block slice **does not resize**; if revealed source is taller, its
  dark-canvas pixels overlap the new frame's lower rows for the ~170 ms fade.
- **Seam 5 — the `✓ done` chip is painted in `drawBackground` (behind glyphs)**,
  so a long unwrapped code line can paint over it; its `x` derives from a
  container-width `maxX`, so a mid-reflow width read mislocates both the chip
  and its hit target.

---

## 4. Prior art & lineage

The target model is the mainstream architecture of modern structured editors,
adapted to TextKit 2 / AppKit. We are catching up, not inventing.

- **CodeMirror 6** — immutable `EditorState` vs `EditorView`, one-way. All view
  adornments are **Decorations** (mark / widget / replace / line) supplied as a
  **pure function of state** in an immutable `RangeSet`, never mixed into the
  document. Its **measure phase** (`requestMeasure`) batches *all* layout reads
  separately from writes — the direct cure for our Seam 1. Highest-ROI reference.
- **Obsidian "Live Preview"** is built on CM6 and implements *our exact reveal
  UX*: rendered elements are replace-widget decorations; when the selection
  intersects the range, the widget drops to reveal source. The canonical name
  for reveal-on-cursor is **"conceal"** (Vim `conceal` + `concealcursor`).
- **ProseMirror** — tree document, changes as `Transaction`→`Step`, `Decoration`s
  as a separate layer, `NodeView`s for custom-rendered nodes (our embeds); the
  view is a pure projection reconciled via diff+patch.
- **Zed `DisplayMap`** — a **stack of pure coordinate transforms**
  (buffer → folds → soft-wrap → block/widget → display). Our `EditMapping`
  (source↔rendered, hidden-delimiter accounting) is an ad-hoc single-purpose
  version; generalizing it into a composed transform stack is Principle 3.
- **Position mapping / `ChangeSet`** (ProseMirror `Mapping`, CM6 `ChangeSet`) —
  never recompute absolute positions; describe each edit as a mapping and
  *compose* them. The systematic fix for T1/T6 offset drift.
- **TextKit 2 native widgets** — `NSTextAttachmentViewProvider` +
  `NSTextLayoutFragment` + `NSTextViewportLayoutController` are the
  Apple-blessed inline-live-view model. Our embeds are drawn manually in
  `drawBackground`; for the live-preview panel specifically, an attachment view
  provider would let TextKit own the geometry and collapse authorities #1/#5.
  (Tradeoff: view providers are heavier/less controllable than drawn ink, which
  is why the codebase went custom for the *decorations* — keep drawn ink for
  passive chrome, consider providers only for the live artifact.)

**The three moves every one of these systems shares:** (1) state is immutable
and the view is a pure function of it; (2) all adornments live in a decoration
layer mapped across changes, never in the document; (3) layout reads are batched
into one measure phase, never interleaved with writes.

---

## 5. Target architecture — four principles

1. **One `BlockPresentation`, computed once.** A pure function
   `present(document, activeBlockID, caret) → [BlockID: BlockPresentation]`
   where `BlockPresentation` is `.rendered` or
   `.editing(source, flavor: .prose | .verbatim | .preview(lastGood))`. The
   renderer, the decorator, the chrome, and the transition all *read* this one
   value — no consumer re-derives "is this block editing." Dead states (the
   inline-preview offset) become states nothing constructs, and drop out.
2. **One `BlockLayout` geometry snapshot.** After each projection applies and
   TextKit settles, compute one `[BlockID: (fragmentUnion, lineRects,
   containerWidth)]` in a single measure pass. Every consumer — canvas, editing
   frame, done chip, preview panel, flip — reads from it. If it's stale,
   everything is *consistently* stale (looks fine) instead of *partially* stale
   (overlap). The editing frame + done chip merge into one "editing chrome"
   decoration that owns the block rect and derives both border and chip from it.
3. **One incremental projector.** A block-diff (reuse `BlockDiff.between`) that
   re-realizes only changed blocks; the separator/clamp math lives in one
   joiner; the caret-move restyle folds back in (kill path #4) as "re-project
   this one block"; positions move through one composed mapping, not
   per-path recomputation; the dead `editableRange`-offset arithmetic is deleted.
4. **Transitions animate settled endpoints.** Capture old and new rects from the
   *same* engine (TextKit) — never the `boundingRect` estimate; the frozen
   snapshot resizes/clips to the new rect during the fade. Decorations only ever
   read settled geometry, which makes the `invalidateDecorations` "second draw"
   unnecessary rather than load-bearing.

---

## 6. Staged plan → see `editor-modes-plan.md`

The detailed, file-level implementation plan lives in
**`docs/design/editor-modes-plan.md`** (post-review). Summary of the review's
per-stage verdicts, which the plan incorporates:

- **Phase 0 (Stage 0 amended)** — settle in `viewWillDraw` (kills the
  remaining one-stale-frame and the `setFrameSize` hole); >200k caret-pin
  test; fix the separator-clamp drift and stale-caret rerender bugs.
- **Phase 1 (`BlockPresentation` owner)** — with the **view-owned caret
  contract** (caret is a parameter of the styler pass, never of the mode; one
  function, two call sites) and the purity precursor (evict
  `activePreviewBox` / `revealVerbatimBox` from the renderer first).
- **Phase 2 (geometry snapshot)** — **viewport-scoped** (document-wide would
  reinstate the lay-out-the-whole-file regression) and **double-buffered**
  (the flip needs the pre-splice endpoint). Merged editing chrome + the
  re-scoped accessibility work.
- **Phase 3 (one projector)** — hot-path output is **storage patches**, never
  a materialized full string (that's the actual perf property); bail-to-full
  escape hatch stays; caret-move restyle stays synchronous view-side; dead
  offset machinery + stale comments + CLAUDE.md's outdated embed paragraph
  deleted; IME/marked-text gate added; equivalence property test in CI.
- **Stage 4 (attachment providers) — dropped.** Providers would resurrect the
  offset machinery Phase 3 deletes and break the 1:1 revealed-source
  invariant; the one real benefit (accessibility) is re-scoped into Phase 2's
  chrome AX element.

---

## 7. Spec gaps the review surfaced (owned by the plan's phases)

- **Undo/redo × mode transitions** (Phase 1.5): Escape's fence-heal is an
  undoable edit; the state machine gains an undo transition row (active block
  vanishes ⇒ deactivate to rendered, no flip, caret at the undo's location).
- **IME / marked text** (Phase 3.5): fragment replacement freezes during
  composition; `pendingInsertion` replay suppressed while composing.
- **Accessibility** (Phase 2.3): the editing chrome becomes a real AX button;
  representation swaps are announced.
- **RTL/bidi**: explicitly **LTR-only for now**; Phase 2 centralizes chrome
  geometry so a future RTL pass is single-site.
- **Preview panel interaction**: pointer-transparent, no keyboard access — a
  deliberate choice, now stated.
- **One active block + one caret is an invariant, not an accident**
  (multi-caret is out of scope by design).

## 8. Non-goals (this design)

New editing *capabilities* (multi-block selection, block drag beyond today,
whole-document raw-source view) are out of scope — this is about making the
existing mode set correct and clean. Diagram/math *coverage* is tracked
separately (`docs/rendering-roadmap.md`).
