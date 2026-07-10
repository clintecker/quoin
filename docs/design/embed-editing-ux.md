# Embed editing UX — design brief

*2026-07-09. Synthesis of a four-expert design panel (Apple-platform motion
engineering, macOS HIG/accessibility, writing-tools product strategy,
text-interaction research), each briefed on the live codebase, the Graphite
handoff, and the viewport-invariant work. This is the blueprint for the
"embed editing" milestone: how entering/editing/exiting code, diagram, math,
and table blocks should look, move, and feel.*

**Status (2026-07-10): all four phases implemented and shipped**, plus
tooltips and a stateful Format menu. Deltas from spec, each deliberate:
chips are always-visible (matching `⧉ copy`; hover-gating deferred — no
tracking machinery exists), the `✓ done` chip is decoration-drawn (a text
run would break the revealed source's 1:1 mapping), the motion mechanism
uses two slices (block crossfade + below-content slide; content above the
pinned anchor never moves, so it is never covered), and the
object-selection ring / Enter-to-open grammar remains queued. Bugs found
by building it: embed caret hints were double-mapped (fixed with typed
`CaretHint`), html-block hints off by one, `BlockDecoration` compared by
pointer identity.

## The bar we are building to

Hovering a diagram frames it softly and shows a quiet edit chip; opening it
(click the chip, double-click, or Enter) leaves the diagram exactly where it
is while its markdown source unfolds beneath, caret ready at the point you
aimed at. Every keystroke re-renders the diagram in real time, natively,
without flicker; broken source keeps the last good render and lights one calm
note in the gutter. Escape, click-away, or Done closes the source — the
diagram simply remains, updated, never having moved a pixel. Undo works
across the whole session like ordinary typing. At no point does anything on
screen disappear, jump, or ask what mode you're in.

## Non-negotiable principles (from all four reports)

1. **Commit on exit, always.** Escape/click-away/Done all mean "done" —
   never revert. Every keystroke is already in the file (live-commit
   architecture); a reverting exit is a data-loss bug. Backing out is ⌘Z's
   job, and undo works identically in both representations.
2. **The 1:1 mapping and the viewport invariant are untouchable.** Any
   animation is cosmetic — an overlay over an instantly-committed truth.
   Nothing may write to storage or scroll position on an animation's behalf.
3. **Prose stays instant, forever.** Caret-driven syntax reveal is the
   editor's Raskin-clean quasimode (the caret *is* the mode). No animation,
   no affordance chrome, no change. Embeds are the exception, which is why
   affordances on them mean something.
4. **Never let the preview flicker.** Hold the last good render until a new
   frame is committed; debounce error states (~400ms); a 5ms re-render that
   blinks reads slower than a 50ms one that crossfades.
5. **Motion restraint.** Two verbs (*dissolve*, *slide*), one animated
   gesture in the whole app (the embed flip), 260ms ceiling, damping ratio
   exactly 1.0 (text never overshoots), any user input truncates to zero,
   Reduce Motion collapses to a 120ms crossfade or instant.
6. **Mode is announced at the locus of attention, in shape** — chrome, not
   tint alone. The 5% wash stays, but the open block's frame changes form
   (label + Done), because peripheral indicators don't prevent mode errors.

## Phase 1 — Interaction correctness (small; do first)

Fixes for contract violations that exist today, from the interaction report:

- **The swallowed keystroke.** Typing on a rendered embed currently flips it
  and DROPS the character. Contract: typing reveals the source AND inserts
  the character at the mapped position, atomically (replay after
  activation).
- **Reverse caret mapping on flip-back.** Closing source currently leaves
  the caret unspecified. Contract: the caret lands at the rendered image of
  its source position, rounded BACKWARD to visible content (never forward
  into the next block); the flip-back viewport pin keys on the block's TOP
  EDGE (line counts don't survive the flip; block-top is the only geometry
  present in both representations).
- **Selection through a flip.** A selection straddling a flipping block
  remaps both endpoints through the alignment mapper, or collapses to a
  caret at the activation point. Never a clamped garbage range.
- **Regression armor** (invariants nothing in the type system protects):
  double-click on an already-open embed word-selects (the
  `id != activeBlockID` gate); `activateBlock` never touches the undo stack;
  undo past the active block's creation deactivates rather than crashes.

## Phase 2 — Affordances + keyboard grammar

**The chip** (HIG report; extends the existing `⧉ copy` idiom exactly):

- `‹/› edit` — SF Symbol `chevron.left.forwardslash.chevron.right` (~9pt) +
  lowercase mono label, 10.5pt SF Mono, 45% ink (45% white on the code
  canvas), radius 6, 2×6 padding, ≥28pt hit target, tooltip
  "Edit Source (⌘↩)".
- **Visible when the pointer is over the block OR the caret/selection is
  inside it** (the caret condition is what makes a confused single-click
  produce the affordance, serves keyboard users, and ports to touch).
  Fade in 150ms; hard cut under Reduce Motion.
- Placement: code → header row beside copy (`‹/› edit  ⧉ copy`); mermaid →
  top-right inside the frame, 8pt inset; math → right edge of the column,
  centered on the equation band; table → right-aligned in the band above,
  joining the specced add-row/column edge controls; front matter → append
  `· edit` inside the existing chip on hover.
- **Open state: `✓ done` in accent, always visible** (mode indicators are
  never hover-gated), plus a 1.5pt accent border on the block — the same
  editing-state token the sidebar rename field uses. Done = commit + close.
- NOT a pencil (promises direct manipulation; `‹/›` promises source, which
  is the truth). No chrome on prose/inline spans/images. No first-run hints.

**Keyboard grammar** (interaction report):

- Arrow keys treat a rendered embed as **one selectable atom** with a
  visible object-selection ring (ProseMirror-style node selection) — never
  auto-reveal on caret transit.
- **Enter or ⌘↩ on a selected embed opens it**; caret at body start
  (entering from above) / body end (from below). ⌘↩ also closes when open.
  Plain Return in text keeps inserting newlines — never overloaded.
- **Escape while editing: commit, close, reselect the block** (so
  Enter/edit/Escape/Enter round-trips eyes-free). Escape on a selected
  closed embed: drop to caret. Two stages, one meaning each.
- Menu: Format ▸ "Edit Source" (⌘↩) ↔ "Done Editing". Context menu: "Edit
  Source", "Copy Markdown Source" (+ "Copy Code"/"Copy Image" where apt).
- VoiceOver: embeds are single elements with descriptive labels
  ("Diagram, mermaid flowchart, 8 nodes"); "Edit Source" as a custom action
  in the rotor; announce entry ("Editing diagram source…") and exit; never
  strand focus on a control that disappeared.
- Fallback if hover tracking proves fragile (none exists in QuoinTextView
  today): ship caret-visibility-only first — 80% of the value, no tracking
  machinery, same visual design.

## Phase 3 — Motion system

**Mechanism** (motion report): pre-splice viewport snapshot (+600pt
overscan below) → frozen cover held through the splice/pin/settle turn
(which also HIDES the settle correction — improving today's worst frame) →
three-slice clip-space choreography (above/block/below) converging on the
real post-settle geometry → overlay removal as an unconditional epilogue
(with a 500ms watchdog; a stuck cover is the worst failure). New
`FlipTransitionController` owned by `QuoinTextView`; capture hooks at the
`flipPending` branch of `updateNSView`, run enqueued `main.async` (after the
settle turn by queue order). Never a storage placeholder; never animate real
layout.

**Specs, keyed to height delta** (motion + interaction reports agree):

| Case | Treatment |
|---|---|
| \|Δh\| ≤ ~40pt (typical code flip) | **Instant or 140ms block-only crossfade** — this is a habituated high-frequency loop; ≥100ms mediation taxes every check-the-render cycle |
| Large Δh (diagram/math ↔ source) | Block crossfades in place 160–180ms `.easeOut`; above/below content **slides** its true reflow 220–240ms on `(0.2, 0.0, 0.0, 1.0)` (or critically-damped spring, stiffness 420 / damping 41); fade lands before the slide so the transition ends on one event |
| Flip-back (expanding) | Same reversed, 260ms/180ms — the incoming render needs a beat to be received |
| Δh > half the viewport | Full-viewport 200ms crossfade (sliding most of a screen reads as scrolling — a lie) |
| Reduce Motion / >200k chars / offscreen | 120ms crossfade / crossfade / nothing |

Slide the reflow rather than masking it: the reflow is *real*, and animating
a true layout change lets users track what moved (Bederson & Boltman);
motion radiates outward from the pinned caret line, which itself never
moves. **Never animate:** the caret, the pin correction, the mode
chrome/tint (binary signals that fade read as uncertainty), scale, blur, or
anything in prose. Cancel-to-end on any storage mutation, user scroll
(live-scroll notification / scrollWheel — NOT boundsDidChange, which the pin
itself fires), resize, appearance change, or re-flip.

## Phase 4 — Preview-anchored reveal (the flagship)

For mermaid and math only (product + interaction reports): while the source
is open, the **rendered preview stays visible**, anchored where the diagram
already was, with the source unfolding below it.

- The artifact never moves: the viewport invariant pins the PREVIEW;
  the source panel expands downward; exit is the removal of the source
  lines with the preview untouched — nothing at the anchor changes on exit.
- Live re-render per keystroke (the native engine is ms-fast; hold the
  previous frame until the new one commits — anti-flicker; keep frame size
  stable across re-renders where possible).
- Broken source: last good render stays; one calm amber note in the panel
  gutter pointing at the offending line, debounced ~400–500ms. Never blank,
  never flash per keystroke.
- The preview is first-class and crisp (never dimmed — a grayed diagram
  reads as broken); the SOURCE panel carries the editing identity (recessed
  background, mono, the `✓ done` chip). Clicking the preview while open
  focuses the source.
- v1 fence: attachment embeds only (mermaid, math); the preview is inert;
  code and tables are explicitly out. This phase largely obsoletes Phase 3's
  large-delta case for diagrams (the tall content never disappears), so
  Phase 3's motion budget partially folds into this phase's open/close
  height tween.

## Declined, with reasons

- **Line-scoped reveal** (only the caret's line shows source): this is
  Obsidian Live Preview, whose embed behavior is its most-complained-about
  feature; it is category-inapplicable to diagrams (a rendered image has no
  per-line decomposition); highest cost on the table for value that
  preview-anchored reveal + affordances already capture. Off the roadmap.
- **Structured table editing** is the industry-unanimous eventual answer for
  tables (Typora, Bear, Obsidian all converged there) — a future initiative
  of its own, not a reveal change.
- **Pencil icon** (wrong promise), **Enter overload in text**, **per-block
  child NSTextViews** (the single-first-responder architecture is why
  IME/focus never break), **reverting Escape** (data-loss bug by
  definition), **min-height reservation for diagrams** (lies about content,
  defers the jump to exit), **popover/modal editors** (Notion's proven
  container mistake; says "you left the document"), **coach marks**.

## Sequencing and effort

| Phase | Scope | Effort |
|---|---|---|
| 1. Interaction correctness | keystroke replay, reverse mapping, selection, armor tests | ~1 session |
| 2. Affordances + grammar | chips, ⌘↩/Enter/Escape, object selection, menus, VO | ~1–2 sessions |
| 3. Motion system | FlipTransitionController + specs above | ~1 session |
| 4. Preview-anchored reveal | mermaid + math live preview | ~2 sessions (flagship) |

Phases 1–2 are pure wins with no design risk. Phase 3 and 4 interact:
if Phase 4 ships first for diagrams/math, Phase 3's large-delta choreography
applies mainly to tables and outsized code blocks — building Phase 3's
mechanism (snapshot overlay) is still worthwhile because Phase 4's
open/close tween uses the same machinery.
