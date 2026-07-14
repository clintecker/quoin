# Suggestions — tracked changes, comments & review for Quoin

Status: **design proposal** (post-research, pre-implementation).
Sources: RoughDraft app source (github.com/Lex-Inc/roughdraft, MIT), the
CriticMarkup spec + toolkit (fletcher.github.io/MultiMarkdown-6/syntax/critic
+ github.com/CriticMarkup/CriticMarkup-toolkit), the RoughDraft Flavored
Markdown 0.2 draft spec (roughdraft.md), and a file:line integration map of
this codebase. Four research reports (2026-07-14) underlie every claim here.

## 1. What we're building

Google-Docs-class review, in plain markdown files: **insertions, deletions,
substitutions, comments, and highlights** that live as literal bytes in the
source, render richly in the editor, and resolve (accept/reject) as ordinary
undoable edits. Metadata (author, time, threading, resolution) rides along in
a way plain renderers ignore.

Why this fits Quoin exactly:

- **Source of truth is the markdown string** — the annotation format that
  won this space (CriticMarkup) is *designed* to live as literal bytes.
  RoughDraft's rich editor round-trips through HTML→ProseMirror→turndown and
  its own ADR concedes lossiness; Quoin's string-first architecture makes
  the round-trip lossless *by construction*. We get their hardest problem
  for free.
- **The agent-review loop is the growth story.** RoughDraft's whole product
  is "AI writes a draft → human reviews in an editor → agent reads the
  feedback back out of the markdown file." Quoin speaking the same format
  (RDFM) joins that ecosystem: any agent that can write CriticMarkup+RDFM
  can request review in Quoin.

## 2. Format decision

**Layer 1 — marks: classic CriticMarkup, verbatim.**

```
{++inserted++}   {--deleted--}   {~~old~>new~~}   {>>comment<<}   {==highlight==}
```

One shape: `{` + doubled sigil + lazy content + doubled sigil + `}`;
substitution splits on a single `~>` (old text always left of the arrow).

**Layer 2 — metadata: RDFM 0.2's `{#id}` + YAML endmatter**, recognized and
preserved from day one, *required* never:

```markdown
Please revisit {==this sentence==}{>>Needs a source.<<}{#c1}.

---
comments:
  c1: { by: user, at: "2026-04-28T12:00:00Z" }
  c2: { body: "I can add one.", by: AI, at: "2026-04-28T12:05:00Z", re: c1 }
suggestions:
  s1: { by: AI, at: "2026-04-28T12:01:00Z" }
```

- ids are document-local counters (`c1…`, `s1…`); `by: AI` marks agent
  authorship; `re:` threads replies (reply *bodies* live in endmatter so
  prose never accumulates nested markup); `status: resolved` + summary.
- A document with marks and no endmatter is plain CriticMarkup — fully
  supported. A document with neither is unaffected.
- Compatibility posture (inherited from both specs): the file stays valid
  CommonMark+GFM — plain renderers show the marks as literal text; nothing
  breaks anywhere.

**Normative rules we adopt from the research:**

- Marks inside inline code and fenced blocks are LITERAL, never parsed
  (RDFM MUST; falls out of our raw-slice parse route by construction).
- No escape mechanism exists in the wild; like RDFM's writer, ours REJECTS
  comment bodies containing a raw close delimiter rather than inventing one.
- **Intra-block marks only in v1.** Every implementation surveyed breaks or
  bans block-spanning marks (MMD-6 refuses them; RoughDraft encodes
  paragraph splits with an invisible U+2060 sentinel — fragile, explicitly
  avoided). Unbalanced marks degrade to literal text (the existing
  `spliceHighlights` philosophy). Multi-block suggestions later = N
  per-block marks sharing one `{#id}` (RoughDraft's model).
- Substitution grammar: we implement the *intent* (split on first `~>`), not
  the toolkit regex — whose original-side can't contain a bare `>` (a
  documented reference-implementation bug we will not reproduce).

## 3. Architecture (from the integration map — file:line verified)

### Parse — raw-slice scanner, not a post-pass

A post-pass over cmark output **cannot work**: smart punctuation turns `--`
into en-dashes, GFM strikethrough consumes `{~~…~~}` interiors, and
`spliceHighlights` half-eats `{==…==}`. So: new `CriticScanner` in QuoinCore
mirroring `MathScanner`'s segment model, hooked into `convertParagraph`'s
raw-slice routing (`MarkdownConverter.swift:637-651`), ordered before the
highlight splice for fallback contexts. New `Inline.suggestion(kind:…)`
carrying children + a **byte-exact `ByteRange`** (the `taskMarkerRange`
precedent — accept/reject needs byte precision).

Fast-path care (verified trap): embedding an absolute range makes
`plainParagraphFastPath`'s kind-equality check fail for marked paragraphs →
correct but slower per keystroke *in marked paragraphs only*; acceptable for
v1, measured in `PerformanceTests`, with the side-table + `suggestions.isEmpty`
guards (footnotes precedent) as the optimization path if needed. Add `{` to
`isSafePlainParagraphSource`'s forbidden set for explicitness.

Endmatter: detect RDFM endmatter (last `\n---\n` whose tail parses as YAML
with `comments:`/`suggestions:` keys AND a `{#` in the body — the app's
ambiguity heuristic against ordinary trailing hrules), preserve byte-lossless,
render as a chip like front matter.

### Render — the existing new-inline checklist

- `.suggestion` case in `AttributedRenderer.renderInline` (beside
  `.highlight` :1750; deletion reuses `.strikethrough`'s treatment :1701):
  insertion = accent underlay, deletion = strike + red tint, substitution =
  both halves, comment = collapsed chip, highlight = existing pill + accent.
- ✓/✕ **accept/reject chips** as link runs: new `quoin-suggest://` scheme in
  `QuoinLink`, a `QuoinAttribute.suggestionRange` carrying the mark's bytes,
  dispatched in `ReaderCoordinator.textView(_:clickedOnLink:at:)` — the
  checkbox pattern end-to-end (callback chain mirrors `onTaskToggle`).
- Syntax reveal: a new asymmetric-delimiter styler pass (the symmetric
  `styleDelimited` can't express `{++`/`++}`), claimed **before** the `~~`
  and `==` passes or reveal styling flickers; mark braces stay faded-visible
  (like `>` prefixes) — a suggestion's boundaries are semantically
  load-bearing.

### Resolve — ordinary undoable edits

Accept/reject each reduce to ONE `SourceEdit` (pure byte splice: accept
insertion = strip delimiters keep body; reject = delete mark; deletion
inverse; substitution = replace with chosen half; comment/highlight = strip
annotation) applied through `DocumentSession.applyEdit` — **undo, debounced
autosave, and `staleEditBase` protection for free**. NOT `toggleTask`'s
direct-write path. A `SuggestionLocator` (TaskLocator clone: kind + literal
content + ordinal) guards click-vs-disk races, refusing on ambiguity.

Accept-all / reject-all = `FormatCommand`s applying the per-mark edits
right-to-left (offset-stable), one undo group.

### Modes — clean split under the editor-modes taxonomy

- **Markup display** (show marks / preview final / hide) is a document-level
  renderer *overlay* — a config input like `theme`, NOT a new
  `BlockPresentation` case. "Preview final" renders each mark's
  would-be-accepted form without touching source.
- **Suggest-edits input mode** (typing produces marks instead of edits) is a
  transform at the `EditIntent → SourceEdit` seam: wrap deletions in
  `{--…--}`, insertions in `{++…++}`, with **adjacent-mark coalescing**
  (extend the open `{++…++}` rather than one mark per keystroke — RoughDraft
  does this as editor-input interception; ours is a byte-level transform).
  The hard sub-problem is caret math (inserted bytes ≠ typed bytes).

## 4. Staged plan

- **S1 — read-only marks (M).** CriticScanner + `Inline.suggestion` +
  renderer case + styler pass + endmatter chip. Byte-lossless round-trip
  tests; TortureTests (marks in fences, fences in marks, `{~~` with
  backticks, `=={pink}` vs `{==`); RevealFidelity + CaretLineAnchor
  extensions (CLAUDE.md mandate). Ships alone: Quoin *displays* any
  CriticMarkup/RDFM document beautifully.
- **S2 — resolve + metadata (M).** quoin-suggest:// chips, SuggestionLocator,
  accept/reject via applyEdit, accept-all/reject-all commands, RDFM
  metadata surfaced (author/time on hover; resolved dimming), suggestion
  count in stats.
- **S3 — suggest-edits input mode (L; after editor-modes Phase 3).** The
  EditIntent transform + coalescing + caret math. Sequenced after the one-
  projector work so the overlay threads through ONE path, not four.
- **S4 — review UX polish (M).** Margin rail or panel listing marks
  (RoughDraft's rail pattern, adapted to the preview-panel machinery),
  threaded replies (endmatter-backed), resolve-with-summary, jump-to-next
  (⌘-based), reading-mode treatment. Optional: an agent handoff story
  (watch + review-index) — Quoin already has the file-watch machinery.

## 5. Risks (each verified against the code)

1. Block-spanning marks vs per-block projection → v1 bans them (unbalanced
   = literal), matching MMD-6.
2. Smart-punct/strikethrough mangling → raw-slice route only; headings/table
   cells fall back with documented limitation in v1.
3. Fast-path perf in marked paragraphs → measured; side-table escape hatch.
4. Styler claim ordering (`{~~`/`{==` vs `~~`/`==` passes) → claim-first +
   tests.
5. Marked-paragraph reveal must keep the 1:1 contract — chips render in the
   READ projection only, never inside revealed source.
6. RDFM spec is a 0.2 draft with acknowledged inconsistencies → we treat the
   RoughDraft `packages/rfm` scanner (MIT) as the de-facto reference and pin
   our behavior with fixtures, not the prose spec.

## 6. Non-goals (v1)

Real-time multi-user editing, CRDTs, base-revision conflict semantics (the
format has none; git is the merge layer), block-spanning marks, WYSIWYG
comment *composition* UI beyond a minimal affordance (S4 decides).
