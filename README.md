# Quoin

**A native WYSIWYG markdown editor for macOS (and a reader for iOS). Zero
JavaScript, zero web views, local-only.**

Quoin edits real `.md` files with a rendered feel. The markdown string and its
AST are the single source of truth — never an attributed string — so opening a
file, editing one paragraph, and saving leaves every untouched byte identical.
Math, diagrams, tables, callouts, and a full **review / suggestions loop** all
render natively with TextKit 2, CoreText, and CoreGraphics. There is no embedded
browser, no JS bridge, and no network at runtime.

A *quoin* is the wedge a letterpress printer uses to lock type into the
chase — the small, precise tool that makes the whole page hold.

![Quoin rendering a document](docs/images/hero.png)

## What makes Quoin different

**The source is the document.** The markdown string + AST are authoritative; the
editor is a *projection*. Edits mutate the source through a session actor and the
renderer re-projects. Round-trip (open → edit → save) is byte-lossless for every
untouched region, by rule — enforced by conformance and round-trip tests.

**Suggestions and comments live in the file.** Quoin's differentiator is a
Google-Docs-class review loop expressed in plain markdown bytes
(CriticMarkup + RDFM metadata). An agent — or a person — writes marks; Quoin
renders them as tracked changes and review cards; Accept/Reject are atomic,
byte-safe source edits. See **[Review, suggestions & comments](#review-suggestions--comments)**
below — this is the section to read first.

**Syntax-reveal editing.** Click into a paragraph and it re-renders as its
literal source, character-for-character 1:1 with the file — hidden delimiters
become 1-point clear glyphs rather than being removed, so caret math never lies.
Only the span under the caret reveals its `**` / `*` / `==` delimiters;
structural prefixes (`>`, `- [ ]`) stay faded-visible. Escape flips back to
rendered.

**Incremental rendering.** Re-renders reuse per-block fragments keyed by
content-hash-stable block IDs, and updates splice only the changed span into the
live text storage. A keystroke re-renders one block, TextKit 2 re-lays-out one
region, and the viewport never jumps.

**Degrade, never break.** Unsupported LaTeX constructs and Mermaid types render
as a tidy labelled source card with a copy button — and the caption *names the
command* that isn't typeset yet (`math · \DeclareMathOperator isn't natively
typeset yet`), so degradation is legible, not a shrug. Pathological input
(10k-deep nesting, unclosed everything) parses to *something* without crashing;
the torture suite keeps it that way.

---

## Review, suggestions & comments

Quoin's defining feature: **a complete review loop that lives as literal bytes in
the `.md` file.** No sidecar database, no proprietary format. The marks are
[CriticMarkup](https://github.com/CriticMarkup/CriticMarkup-toolkit); the
metadata (author, time, resolution) rides along as RDFM YAML endmatter that plain
renderers ignore. Because the file *is* the review, it is portable,
git-diffable, and agent-readable. Design + rationale:
[`docs/design/suggestions.md`](docs/design/suggestions.md).

<!-- SCREENSHOT: review-panel — Review inspector cards beside a marked document; see docs/screenshots.md -->

**Marks, rendered as tracked changes.** Five mark kinds render richly; the raw
delimiters never appear in the read projection:

| Mark | Source | Renders as |
| :--- | :--- | :--- |
| Insertion | `{++added++}` | accent underlay |
| Deletion | `{--removed--}` | strike + red tint |
| Substitution | `{~~old~>new~~}` | both halves in suggestion tints |
| Comment | `{>>note<<}` | collapsed chip → review card |
| Highlight | `{==marked==}` | accent pill |

**Review inspector.** A third sidebar mode lists every mark as a card — author
and relative time (from RDFM endmatter; absent metadata falls back to just the
kind), the change body, and **Accept / Reject / Dismiss** chips. **Accept All /
Reject All** apply every per-mark edit right-to-left as *one* atomic edit and one
undo. Resolutions read back as `status: resolved` endmatter and collect in a
disclosure of history ("acted-on things"), never lost. Clicking a card scrolls
its mark to viewport and flashes an accent ring; caret-in-mark highlights the
card. A live count sits in the status bar.

**Create a review without editing the prose.** A CriticMarkup mark *wraps* the
text it concerns — `{--vague--}` still contains "vague", byte-exact — so
annotating never changes what the document says; only *resolving* does. Select
text and:

| Gesture | Shortcut | Produces |
| :--- | :--- | :--- |
| Add Comment… | ⇧⌘M | `{==sel==}{>>body<<}` + endmatter entry |
| Suggest Replacement… | ⇧⌘R | `{~~old~>new~~}` (popover pre-filled) |
| Suggest Deletion | menu | `{--sel--}` |
| Highlight for Review | menu | `{==sel==}` |

Each gesture is one atomic source edit (mark splice + appended `by:`/`at:`
entry); one undo removes the whole annotation. (⇧⌘H stays with the formatting
highlight, so the review highlight is menu-only.)

**Comment opaque blocks.** Code, tables, diagrams, and math can't carry inline
marks (RDFM opacity is normative — a mark inside runnable content would corrupt
it). They get a block-adjacent `{>>comment<<}` paragraph instead, so every block
type is reviewable.

**Review Mode (⌃⌘R).** Toggle "Suggest Edits" and ordinary typing becomes
suggestion marks — insertions `{++…++}`, deletions `{--…--}`, replacing a
selection `{~~old~>new~~}` — with coalescing so consecutive keystrokes *grow* one
mark instead of minting one per character. The mode is loud (status chip, live
count) and never persists ON across launch.

**Safety by construction.** Every resolution and annotation is computed inside
the session actor *at apply time* against current truth (`applyResolution`,
`applyBulkResolution`, `applyAnnotation`), refusing on drift rather than splicing
stale offsets. Creation self-calibrates: the candidate source is re-parsed and
rejected unless exactly the expected mark comes back — so code/math opacity,
block-spanning selections, and sigil collisions are all unrepresentable, not
patched later.

**The agent-handoff story.** Because the file is the source of truth, any tool
that writes markdown + CriticMarkup writes Quoin documents. An agent proposes
edits as durable marks; the app renders them as cards; a human accepts or rejects
in a real UI; the agent reads the resolutions back out of the same file. That
round-trip is the whole reason the format is byte-native.

<!-- SCREENSHOT: review-mode — status-bar "Suggesting" chip while typing produces marks; see docs/screenshots.md -->

---

## Support matrix

### Markdown

| Feature | Status | Notes |
| :--- | :---: | :--- |
| CommonMark core (headings, emphasis, lists, links, images, code, quotes, breaks) | ✅ | via swift-markdown / cmark-gfm |
| GFM tables | ✅ | per-column alignment, numeric columns right-aligned |
| GFM task lists | ✅ | checkboxes toggle with a click and write back to source |
| GFM strikethrough & autolinks | ✅ | |
| Callouts / alerts (`> [!NOTE]` …) | ✅ | 5 semantic types: note, tip, important, warning, caution |
| Highlights (`==text==`) | ✅ | palette cycling with ⇧⌘H (`=={pink}…==`) |
| Footnotes (`[^id]`) | ✅ | click-to-jump to definition, hover-preview bubble, ↩ backlinks |
| YAML front matter | ✅ | rendered as a field grid; edited via the Properties inspector (typed editors) |
| `[TOC]` | ✅ | live table-of-contents block |
| Code syntax highlighting | ✅ | Swift, Python, JS/TS, Go, Rust, Ruby, C/C++/ObjC, Java/Kotlin, shell, SQL, YAML/TOML, JSON, HTML/XML/CSS; **12 selectable canvas themes**, default follows app appearance |
| Review / suggestions (CriticMarkup + RDFM) | ✅ | insert/delete/replace/comment/highlight marks, review inspector, Review Mode — see [above](#review-suggestions--comments) |
| Raw HTML blocks | 🟡 | shown as a labelled source card (no HTML engine, by design) |
| Local images | ✅ | async decode at display size; drag-and-drop copies into `assets/` |
| Remote images | 🟡 | placeholder by default (local-only policy) |

### Editor & app

| Feature | Status |
| :--- | :---: |
| Syntax-reveal editing (click to edit, Esc to close) | ✅ |
| Double-click to edit code, tables, and TOC | ✅ |
| Diagrams & math open via the explicit ‹/› edit chip, ⌘↩, or the context menu (presentation objects never flip by accident) | ✅ |
| Side-by-side live preview while editing diagrams & math (last-good render held while mid-edit source is broken) | ✅ |
| Properties inspector — front matter as a key/value panel with typed editors (date picker, bool toggle, number field, list-as-CSV; Edit-as-Text escape hatch) | ✅ |
| Smart pairs, wrap-selection, word-under-caret formatting | ✅ |
| ⌘B / ⌘I / ⇧⌘H / ⌘K + floating format pill | ✅ |
| Library sidebar (folders = directories), document tabs, quick open | ✅ |
| Multi-folder windows — Open Folder in New Window; each window restores its folder on relaunch | ✅ |
| Outline panel with live section tracking (manual collapse is authoritative) | ✅ |
| Find in document (⌘F / ⌘G), library-wide search (⇧⌘F) | ✅ |
| Live reload + non-blocking conflict banner on external change | ✅ |
| Source-level undo/redo through the session | ✅ |
| First-H1 auto-rename of Untitled files | ✅ |
| Export: PDF, HTML, Markdown, RTF, TXT — light or dark | ✅ |
| Word count, reading time, per-element statistics | ✅ |
| Focus mode, typewriter scrolling, jump history (⌘[ / ⌘]) | ✅ |
| Dark mode (code canvas constant across appearances, per design spec) | ✅ |

### Math (LaTeX)

Math is powered by **[Vinculum](https://github.com/clintecker/Vinculum)** —
Quoin's own native TeX-style typesetter (no MathJax, no KaTeX). LaTeX is parsed
into a TeX-style atom tree and laid out with real inter-atom spacing classes,
stacked big-operator limits, radicals with indices, auto-sized fences, and grid
environments (`matrix`/`pmatrix`/…, `cases`, `aligned`), then drawn with
CoreText. Inline `$…$` `\(…\)` and display `$$…$$` `\[…\]` are both supported;
directly-typed Unicode math (`∫ ∑ ≤ α →`) is classed like its command spelling.

Coverage is large (~400 commands). **Quoin does not restate the command table —
it drifts when duplicated.** The exhaustive, always-current matrix is in
Vinculum's own docs:
**[COVERAGE.md](https://github.com/clintecker/Vinculum/blob/main/docs/COVERAGE.md)**
and **[COMMANDS.md](https://github.com/clintecker/Vinculum/blob/main/docs/COMMANDS.md)**.
Unsupported commands fall back to a named source card.

![Native math typesetting](docs/images/gallery-math.png)

### Diagrams (Mermaid)

Diagrams are powered by **[MermaidKit](https://github.com/clintecker/MermaidKit)**
— Quoin's own native Mermaid engine (no Mermaid.js, no network). Sources are
parsed and laid out with Sugiyama-style layering, fan-out edge attachment,
orthogonal elbow routing, cycle-safe layering, UML relationship markers
(▷ ◆ ◇, crow's feet), and recursive composite states. Front-matter `title` /
`config` and `accTitle` / `accDescr` are honored.

**Quoin does not restate the per-type diagram matrix** — the source of truth is
MermaidKit's repository (its `Fixtures/diagrams/` corpus and CI gallery), so the
list can't quietly drift. Unsupported diagram types fall back to a named source
card. See MermaidKit for full per-type capability, and the in-repo
**[diagram gallery](docs/diagram-gallery.md)** for rendered examples.

![Native diagrams](docs/images/gallery-diagrams.png)

![Blocks, callouts, and tables](docs/images/gallery-blocks.png)

## Performance

Budgets from the PRD, enforced in CI (`PerformanceTests`); representative
benchmarks on a ~1.2 MB / 5,402-line / 2,701-block document
([`docs/performance-baselines.md`](docs/performance-baselines.md)):

- Parse 1 MB of markdown to interactive: **< 1 s** (initial full parse ~345 ms)
- Apply one byte-precise middle edit: **~0.8 ms**; incremental parse-after-edit
  fast path: **~9 ms**
- Keystroke → paint: one block re-rendered, one region re-laid-out (fragment
  cache + text-storage splicing)
- 70k-character stress documents scroll at full frame rate — TextKit 2 lays out
  only the visible viewport

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/architecture-overview-dark.png">
  <img alt="Quoin module architecture" src="docs/images/architecture-overview.png">
</picture>

<sub>The image above is drawn by **Quoin's own native Mermaid engine** — no Mermaid.js, no JavaScript. Regenerate with `QUOIN_DOC_DIAGRAMS=$PWD swift test --filter testRenderDocDiagrams`.</sub>

- **`QuoinCore`** — platform-free engine: parse, `DocumentSession` (edits, undo,
  autosave, file watching), search, statistics, exporters, and the **entire
  review + front-matter machinery**, with zero AppKit imports. Builds and tests
  on Linux.
- **`QuoinRender`** — `AttributedRenderer` projects the AST into one attributed
  string; `QuoinTextView` (an NSTextView subclass) draws block decorations,
  code canvases, callout boxes, diagram frames, and review chrome behind the
  text via TextKit 2 fragment frames.
- **`Vinculum`** / **`MermaidKit`** — first-party math and diagram engines,
  layout/render split behind theme seams, consumed from GitHub and tested by
  their own CI.

See [docs/architecture.md](docs/architecture.md) for the full data-flow and the
[docs map](docs/README.md) for everything else.

## Building

Requires Xcode 16+ / Swift 5.10 on macOS 14+.

```sh
swift build            # QuoinCore + QuoinRender
swift test             # full suite: 634 tests — unit, torture, performance, conformance
```

App targets are generated with XcodeGen:

```sh
brew install xcodegen
cd App/macOS && xcodegen && open Quoin.xcodeproj      # macOS
cd App/iOS   && xcodegen && open QuoinIOS.xcodeproj   # iOS/iPadOS
```

Fixtures for every feature area live in [`Fixtures/renderer/`](Fixtures/renderer/) —
they drive the CI conformance harness (parse + metric snapshots + diagram-layout
invariants) and double as in-app preview documents. CI runs the full test suite,
builds both apps, enforces the performance budgets, and publishes UI screenshots
to the `ci-screenshots` branch on every push.

## Dependency policy

One third-party code dependency:
[swift-markdown](https://github.com/swiftlang/swift-markdown) (Apple's cmark-gfm
wrapper, pinned `from: 0.8.0`).
[MermaidKit](https://github.com/clintecker/MermaidKit) (`from: 0.10.0`) and
[Vinculum](https://github.com/clintecker/Vinculum) (`from: 0.23.0`) are
**first-party** — Quoin's own published engines, consumed from GitHub like any
host app would, and exempt from the policy. Anything new requires written
justification in the TRD; the default answer is no.

## Privacy

Local-only by design: no network calls, no telemetry, no indexing services.
Documents are plain `.md` files on disk; folders are directories. Remote images
are placeholders unless explicitly enabled per document.
