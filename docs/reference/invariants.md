# Invariants — the rules this codebase will fire you for breaking

Every invariant here names its **enforcement** — the test or mechanism that
fails when it's violated. A rule without a guard is an opinion; these are not
opinions. When you add a feature, find every invariant it touches and extend
the named guard. (Docs rule of the house: every claim cites its evidence.)

## Source & round-trip

1. **The markdown string + AST is the only source of truth.** The editor is a
   projection; attributed strings are never authoritative. Edits mutate the
   source through `DocumentSession`; the renderer re-projects.
   *Guard:* architecture — there is no API to write storage back to source.
2. **Byte-lossless round-trip.** Open → edit → save must leave untouched
   regions byte-for-byte identical. Recognition never rewrites; only explicit
   `SourceEdit`s splice bytes. *Guard:* session tests; exporters read the
   source, not the projection.
3. **Revealed source is 1:1 with the file.** Hidden span delimiters are
   1pt-clear glyphs, never removed — a caret offset in revealed text IS a
   source offset (via `EditMapping` at the edit boundary).
   *Guard:* `RevealFidelityTests`; `MarkdownSourceStyler`'s contract.

## Viewport & caret

4. **The viewport invariant (user directive).** On ANY projection change —
   reveal, close, keystroke, every block type — the line the caret/click is
   on must not move on screen. Scroll only when the caret leaves the
   viewport, then minimally. This applies to the pre-draw settle itself
   (which preserves the caret line across estimate resolution).
   *Guard:* `CaretLineAnchorTests` (including the >200k settle case),
   `RevealFidelityTests`.
5. **Caret hints carry their coordinate space.** `.rendered` offsets map
   through `EditMapping`; `.source` offsets (embed bodies) are used verbatim.
   Feeding one through the other's mapping lands the caret early.
   *Guard:* `EmbedCaretHintTests`, `ReverseCaretMappingTests`.

## Projection

6. **Patch paths must equal the full render.** Any bounded update (activation
   flip, per-keystroke edit) applied to live storage must be byte- and
   attribute-identical to a fresh full render of the same state; any validity
   doubt returns nil and falls back to the full render (always correct).
   *Guard:* `ProjectorEquivalenceTests` — the corpus runs every fixture ×
   scripted interaction in CI.
7. **Single derivations.** The block separator (`separator(after:before:
   revealedSlice:)`), the reveal styler config (`revealStylerConfig`), and
   the presentation map (`presentation(for:activeBlockID:)`) are each derived
   in exactly ONE place; consumers read, never re-derive.
   *Guard:* `BlockPresentationTests` pins the tables; the equivalence corpus
   catches any consumer that re-derives and drifts.
8. **`RevealedFragment.editableRange.location == 0`.** The editable source IS
   the fragment; the live preview lives in the side panel, never inline.
   *Guard:* documented at the type; equivalence corpus exercises it.
9. **Patches apply to the exact storage they were diffed against.**
   `patchBaseLength` must match or the view resyncs by splicing to the
   authoritative string. *Guard:* `ProjectionCoalescingTests`.
10. **One block edits at a time; one caret.** An invariant, not an accident —
    the presentation model hard-codes it. *Guard:* `PresentationMap` can only
    represent one `.editing`.

## Drawing

11. **Decorations are drawn ink, never `.backgroundColor` attributes**
    (per-glyph backgrounds render as per-line strips — a shipped bug once).
    A character carries exactly ONE `BlockDecoration`.
    *Guard:* `DecorationGeometryTests`; code review.
12. **Every draw is a settled draw.** `viewWillDraw` finishes viewport layout
    before pixels; ONE measure pass feeds all chrome geometry; border, chip,
    tooltip, panel anchor, and AX element derive from one `EditingChrome`
    box. *Guard:* `DecorationGeometryTests` (chrome-from-one-box,
    viewport-scoped measure).
13. **The flip is cosmetic by construction.** Real layout applies instantly;
    only frozen pixels animate; any user input or newer projection truncates
    to the end state; a 500ms watchdog removes the cover unconditionally.
    *Guard:* `FlipTransitionFidelityTests` (which also enforces: pixel-test
    retries must `Thread.sleep`, never drain the runloop — draining starts
    the animations the test measures through).

## Sessions & data safety

14. **One live session per file.** `OpenDocumentStore` keys by resolved +
    standardized URL, ref-counted across windows/tabs — never two autosavers
    for one file. *Guard:* store keying; ledger #12 regression history.
15. **A file that can't be read is never bound to its URL.** Open failure ⇒
    detached session (nil URL) + sticky banner; nothing can autosave over
    the user's bytes. *Guard:* `ReaderModel.start`; ledger BLOCKER #1.
16. **⌘Q flushes every live session** (detached-task flush registry, 3s
    watchdog). *Guard:* ledger BLOCKER #4 history; `SessionEditingTests`.
17. **Stale edits are rejected, not spliced.** Every edit is stamped with the
    session's `contentRevision`; a reload between compute and apply makes
    the session refuse (`staleEditBase`). *Guard:* `SessionEditingTests`.

## Testing culture

18. **There are no flaky tests, only bad tests.** An intermittent failure is
    either a nondeterministic measurement channel (fix the channel) or a
    real race (fix the race) — never label-and-ignore.
    *Precedent:* the FlipTransitionFidelity "GPU flake" was the retry loop
    starting the animations it measured through (commit 729ae2b).
19. **Coverage floors on loop-driven tests.** A corpus/property test asserts
    a minimum check count, so universal bailing can't fake a pass.
    *Guard:* `ProjectorEquivalenceTests`' floors.
