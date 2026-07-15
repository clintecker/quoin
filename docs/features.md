# What you can do with Quoin

A feature tour organized by what you *do*, not how it's built. The
capability spec (`docs/PRODUCT.md`) and the public overview (`README.md`)
are the companions; this is the "what's in my hands" doc. Every feature
names its shortcut and cites where it lives.

## Write

Quoin is WYSIWYG on a plain `.md` file — the rendered document *is* the
editor, and the file on disk stays clean markdown you own.

- **Rich rendering as you read** — headings, emphasis, lists, tables,
  task lists, callouts (`> [!NOTE]` … 5 types), highlights, footnotes,
  code with syntax highlighting, math, and Mermaid diagrams, all native
  (no web view, no JavaScript).
- **Edit in place** — click into any block and it reveals its literal
  markdown source, character-for-character with the file; edit, click
  away, it re-renders. The line you're on never jumps on screen.
- **Formatting** — bold ⌘B, italic ⌘I, link ⌘K, highlight ⇧⌘H (cycles a
  palette). All write real markdown to the source.
- **Task lists** — click a checkbox; it toggles and writes back to the
  file.
- **Byte-lossless** — anything you don't touch is saved exactly as it was.
  (`docs/INVARIANTS.md`.)

## Review — the thing nothing else does

Suggestions and comments live *in the markdown file* (RDFM /
CriticMarkup), so an agent or collaborator can propose edits anywhere and
you triage them in a real UI — byte-safely. Design:
`docs/design/suggestions.md`; internals: `docs/architecture.md`.

- **See tracked changes** — `{++insert++}`, `{--delete--}`,
  `{~~old~>new~~}`, `{>>comment<<}`, `{==highlight==}` render as tracked
  changes; the raw delimiters never show.
- **The Review inspector** — a sidebar mode (beside Outline) listing every
  mark as a card with author and time. **Accept**, **Reject**, or
  **Dismiss** per card, or **Accept All / Reject All** — each one atomic
  edit, one undo. Resolved items move to a history list (recorded in the
  file, never lost).
- **Card ↔ document** — click a card to scroll its mark into view and
  flash it; put the caret in a mark to highlight its card. A resolution
  pulses where it landed.
- **Suggest without editing the prose** — select text and:
  **Add Comment…** (⇧⌘M), **Suggest Replacement…** (⇧⌘R), **Suggest
  Deletion**, **Highlight**. Each wraps the selection byte-exactly; the
  document only changes when someone accepts.
- **Comment on code, tables, diagrams, math** — right-click →
  **Comment on Block…** drops a comment paragraph beside the block
  (marks can't live inside runnable content, so they live next to it).
- **Review Mode** (⌃⌘R) — flip it on and your typing *becomes* suggestions
  instead of edits: insertions, deletions, and replacements land as marks.
  A **SUGGESTING** chip shows while it's on.
- **Agent handoff** — because it's all just marks in the file, an agent
  (e.g. Claude Code) writes suggestions into your document and the cards
  appear in your panel. The review loop is the interface.

## Organize

- **Library** — pick a folder; its tree is your sidebar (⌘0). Folders are
  directories, documents are plain files. **Open Folder in New Window**
  gives each window its own folder, restored on relaunch.
- **Outline** — a live heading tree (⌥⌘0); manual collapse sticks, and the
  current-section highlight follows your reading position.
- **Properties** — a third inspector mode editing YAML front matter as a
  key/value panel with type-appropriate editors (date picker, toggle,
  number, comma-list) and an *Edit as Text* escape hatch. The in-document
  view shows front matter as a tidy field grid.
- **Find** — in-document find (⌘F) with match highlighting and ⌘G cycling;
  library-wide search (⇧⌘F); quick open; recents; daily note (⌘D).
- **Tabs & navigation** — document tabs (⌘1–9), jump history (⌘[ / ⌘]),
  breadcrumb path, footnote click-to-jump with hover preview and ↩
  backlinks.

## Read comfortably

- **Focus mode** — everything but the current block (or sentence) dims.
- **Typewriter scrolling**, **word-count goals**, a **reading-progress**
  hairline, and **12 selectable code themes** (default follows the app's
  light/dark appearance).

## Reference: math & diagrams

Rendered natively — no MathJax, no KaTeX, no Mermaid.js. Quoin edits them
in place with a live side-panel preview; unsupported constructs degrade to
a labeled source card (never a blank, never a crash). The engines are
first-party packages with their own full documentation:

- **Math** — LaTeX via **[Vinculum](https://github.com/clintecker/Vinculum)**
  (TeX-style typesetting; ~400 commands). Full coverage matrix in
  Vinculum's docs.
- **Diagrams** — Mermaid via
  **[MermaidKit](https://github.com/clintecker/MermaidKit)**. Full
  diagram-type catalog in MermaidKit's docs.

## Export & interop

- Export to Markdown (round-trip), plain text, or HTML.
- Everything is a plain file: any tool that writes markdown (or RDFM /
  CriticMarkup) produces Quoin documents. There is no lock-in and no
  service — files on disk are the whole story.
