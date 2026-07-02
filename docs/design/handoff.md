# Handoff: Markdown Editor for macOS (WYSIWYG)

## Overview
A minimalist WYSIWYG markdown editor for macOS (portable to iPadOS/iOS): markdown renders as you type (Typora/Bear model), with a document-library sidebar, an outline panel, tabs, live statistics, and rich export (PDF/HTML/MD/RTF/TXT). Documents are plain `.md` files on disk — no proprietary container.

## About the Design Files
`Markdown Editor Design Doc.dc.html` in this bundle is a **design reference created in HTML** — a spec document with static hi-fi mockups, not production code. Your task is to **recreate these designs in SwiftUI** (the intended target) using native patterns (NavigationSplitView, inspector, NSDocument, SF Symbols). Do not port the HTML/CSS. If the target changes, the spec still holds; only the containers differ.

## Fidelity
**High-fidelity.** Colors, type ramp, spacing, and states are final and exact. Recreate pixel-perfectly within native-control constraints (e.g. defer to `controlAccentColor` where noted).

## Canonical decisions (options resolved)
The design doc explores variations. These are **decided** — everything else in the doc's sections 01/03/04/05 is rejected-alternative reference only:
- Visual direction: **1a "Graphite"** — native macOS, white canvas, #F5F5F7 sidebar, system accent
- Sidebar: **1e "Classic tree"** — icons, filled accent selection, disclosure chevrons
- Outline panel: **1h "Ruled tree"** — hairline rule under each row, collapsible chevrons
- Text styling: **1k "Rounded"** — SF Pro Rounded editor face, pill highlights

## Architecture constraints (non-negotiable)
1. **Source of truth is the markdown string + AST** (swift-markdown / cmark-gfm), never attributed strings. The editor is a projection: edits mutate the AST; the renderer re-projects. This enables tables, math, footnotes, mermaid, and lossless export.
2. **Documents are files on disk.** Folders = directories. Moving a doc in the sidebar moves the file. Non-md assets (images) appear grayed in the tree.
3. **NSDocument** for autosave-in-place + version history. **FSEvents** for external edits: reload silently if clean; non-blocking merge banner if dirty. Sync = iCloud Drive / any file provider.
4. **View models are platform-free.** Only navigation containers and the format-control surface differ per platform.
5. **Never override system shortcuts** (⌘P = Print, ⌘E = Use Selection for Find, ⌘H = Hide).

## Content model
CommonMark + GFM (tables, task lists, strikethrough), LaTeX math (`$…$` inline, `$$…$$` display), Mermaid fences, footnotes, `==highlight==`, callouts (`> [!NOTE|TIP|WARNING|DANGER]`), `[TOC]` block, YAML front matter, code fences with syntax highlighting.

## Screens / Views

### 1. Main window (default ~1180×760pt)
Three columns: **Library sidebar** (200–320pt, user-resizable, collapsible ⌘0) · **Editor** (flexible; text column max-width 680pt, centered, gutters ≥48pt) · **Outline** (220pt, collapsible ⌥⌘0, SwiftUI `.inspector`).

**Sidebar** (`#F5F5F7`, 1px right border rgba(0,0,0,.07)):
- Header: traffic lights; trailing `plus` (new doc) and `sidebar.leading` (toggle) buttons
- Search field: rgba(0,0,0,.05) fill, radius 6
- Section label: 10.5pt semibold, 40% ink, e.g. "Side Projects iOS"
- Rows: 12.5pt system, 26pt tall (44pt on touch), radius 5–6, icon + name; folder rows have disclosure chevron; nested indent +14pt
- Row states — default: transparent · hover: rgba(0,0,0,.05) fill · selected: accent fill, white text, weight 500 · dragging: white card, shadow 0 4 14 rgba(0,0,0,.18), −1.5° tilt · drop-between: 2pt accent caret line with circle terminal · drop-into-folder: 2pt accent inset ring; folder spring-opens after 400ms hover · rename: inline text field, 1.5pt accent border · non-md asset: 35% ink, not openable
- Footer: "11 documents · synced ✓", 10.5pt, 40% ink, top hairline

**Tab bar** (`#FAFAFA`, bottom hairline): active tab white bg, 12pt medium; inactive 50% ink; unsaved = 6pt accent dot (swaps to ✕ close on hover). ⌘T new tab, ⌘W close, ⌘1–9 jump. Tabs ≥120pt, overflow scrolls. Tabs hide with one doc open, but the chrome row persists: **format pill** (B/I/U, white, radius 14, hairline border, expands to full format menu on click; floats over content when scrolled) + **outline toggle** (`sidebar.trailing`).

**Editor**: see Element spec below. Caret/selection in accent.

**Status bar** (top hairline, 10.5pt mono, 40% ink): left = current section ("§ Key types"); right = "412 words · 2,304 chars · 2 min read". Click stats → detail popover. Selecting text swaps counts to the selection. Hideable in Settings.

**Outline panel** (white, left hairline): "OUTLINE" label 10pt caps 35% ink; rows 12pt, hairline rule under each (rgba(0,0,0,.08)), indent per heading level (0 / 16 / 34pt), H1 bold, H2 semibold, H3+ regular; chevrons collapse subtrees; current section = accent + weight 500; click scrolls to section. Generated live from the heading tree.

### 2. Quick open (⇧⌘O)
Centered floating panel: white, radius 10, shadow 0 12 32 rgba(0,0,0,.14). Search row + results list (fuzzy titles + full-text snippets, match text bolded, path in secondary). Selected row = accent fill. ⌘F = in-document find; ⇧⌘F = persistent library-wide search in sidebar.

### 3. Export sheet (⇧⌘E, native `.sheet`)
Title "Export ‹doc name›". Format grid (3-up cards, radius 7): PDF (default-selected: 2pt accent border, 5% accent fill) · HTML (standalone, assets inlined) · MD (source + asset folder) · RTF · TXT · DOCX (disabled, "later"). Options row: include-footnotes checkbox, theme picker. Primary button accent-filled. PDF uses the element spec as print stylesheet; mermaid/math rasterized @2x.

### 4. Empty states
- No doc open: centered `doc.text` symbol at 35%, "No document open" 13pt semibold 55% ink, "Select a document, or press ⌘N", outlined accent "New Document" pill button.
- New doc: ghost "Untitled" H1 placeholder at 30% ink, caret in title. First H1 becomes the filename live until manually renamed; duplicates get " 2" suffix — never a modal.

## Element render spec (editor, default text size)
Editor face: SF Pro Rounded. UI face: SF Pro. Mono: SF Mono. ⌘＋/− scales the whole ramp.

- **H1** 26/1.25 · 700 · space above 32 / below 12
- **H2** 20/1.3 · 700 · above 28 / below 10
- **H3** 16/1.35 · 600 · above 22 / below 8; H4–H6 14/600, 55% ink
- **Body** 14/1.7 · 400 · #333 · paragraph gap 12
- **Inline**: bold #1D1D1F; italic; strikethrough 45% ink; link accent with 35%-alpha underline; inline code 12.5pt mono on #F2F2F4, radius 4, pad 1×5; footnote ref superscript accent; highlight = pill (radius 3, pad 0×2) in lime by default
- **Lists**: marker column 24pt, nested indent +24; bullets/numbers in accent; tasks = interactive 15pt checkbox radius 4 (checked: accent fill, white check, row strikes + fades to 40%, animated)
- **Blockquote**: 3pt rule rgba(0,0,0,.15), pad-left 16, italic, 55% ink; nested quotes stack rules
- **Callouts**: radius 8, 4% tint bg + 15% border of semantic color, 12.5pt semibold title with SF Symbol (Note=blue/info.circle, Tip=green, Warning=amber, Danger=red)
- **Code block**: canvas #1E2430 in BOTH appearances, radius 8; header row = language chip 10.5pt mono 45% white + copy button (hover); code 12/1.6 mono #D6DCE6; one syntax theme, 6 token colors (keyword #C792EA, function #82AAFF, type #FFCB6B, comment #697794)
- **Table**: header 600 with 1.5pt bottom rule @15% ink; body rows 1pt @7%; cell pad 6×10; numerics tabular-nums right-aligned; hover reveals add-row/column buttons at edges
- **Math**: inline `$…$`; display `$$…$$` centered, 16 above/below; SwiftMath or equivalent
- **Mermaid**: rendered inline in a radius-8 bordered block; double-click flips to source editor
- **Images**: max-width 100%, radius 8; drag-drop/paste copies asset into library; alt text renders as 11pt centered caption
- **HR**: 1px hairline @12%, 20 above/below
- **Footnotes**: gather at document end, 12/1.6 secondary, top hairline, bidirectional jump on click
- **[TOC]**: inline linked list mirroring the outline
- **YAML front matter**: collapses to a compact metadata chip above the H1; click to edit source

**Syntax reveal (core WYSIWYG rule):** when the caret enters a styled span, its markdown delimiters fade in at 35% ink in mono; leaving hides them. Whole blocks (code, math, mermaid, tables) flip to source on double-click instead. **Smart pairs** auto-close `**` `_` `==` `$` `` ` `` — suspended inside code spans/fences.

## Interactions & Behavior
- All transitions 150ms ease-out; drag uses system lift shadow
- Sidebar: drag to reorder/nest (multi-select ⌘-click), right-click context menu, inline rename; ⌘Z undoes moves (including on disk)
- Highlight: ⇧⌘H cycles the 5-color palette on selection
- Format: ⌘B/I/U, ⌘K link

### Keyboard map (conflict-audited)
⌘N/⌘T/⌘W doc/tab/close · ⌘1–9 tabs · ⌘0 sidebar · ⌥⌘0 outline · ⇧⌘O quick open · ⌘F find · ⇧⌘F library search · ⌘B/I/U format · ⌘K link · ⇧⌘H cycle highlight · ⇧⌘E export · ⌘＋/− text size. ⌘P and ⌘E keep system meanings.

## Responsive behavior
Thresholds are on **editor column width**, not window width:
- ≥900pt: all three columns
- 560–900pt: outline auto-hides (⌥⌘0 overlays it)
- <560pt: editor only; panels overlay with scrim
- <700pt: format pill collapses to single "Aa" button; <560pt: tab bar becomes compact popup menu
- Status bar drops statistics first, section name last
- Editor text column never exceeds 680pt

### Platform ports
- **iPadOS**: same NavigationSplitView; outline via trailing inspector; 44pt rows
- **iOS**: push navigation (library → doc); outline = bottom sheet; format bar docks above keyboard
- Multi-window supported on all platforms; each window has independent panel state

## Design Tokens (Theme struct / asset catalog)
Colors:
- `ink` #1D1D1F · `ink.body` #333333 · `ink.secondary` 55% ink · `ink.tertiary` 35–40% ink
- `canvas` #FFFFFF · `surface.sidebar` #F5F5F7 · `fill.codeInline` #F2F2F4 · `surface.code` #1E2430
- `accent` — use `controlAccentColor`; #2A6FDB is the default/marketing value
- Highlights: lime #D9F59B (default) · pink #F7D9F0 · yellow #FDEEAA · blue #CFE6FB · orange #FEDBC6 — all ≥4.5:1 with ink.body
- Callout tints: 4% bg + 15% border of blue/green/amber/red semantic colors
- Dark mode: invert ink/canvas, keep `surface.code`, reduce highlight saturation ~15% (full dark mockups not yet produced)

Spacing: 4 · 8 · 12 · 16 · 24 · 32. Radii: 4 inline-code · 6 rows/buttons · 8 blocks · 10 panels. Hit targets ≥28pt mac / 44pt touch.

Icons: SF Symbols only — doc.text, folder, photo, pin.fill, magnifyingglass, sidebar.leading, sidebar.trailing, plus, info.circle. (Emoji in the mockups are placeholders.)

## Acceptance checklist
- [ ] Markdown string + AST is the only source of truth; round-trip (open → edit → save) is byte-lossless for untouched regions
- [ ] Syntax reveal: delimiters appear only for the span containing the caret
- [ ] First H1 renames the file live; duplicate names get " 2" suffix silently
- [ ] Task checkbox toggles with animation; done rows strike + fade to 40%
- [ ] Outline tracks scroll position; click scrolls to heading; chevrons collapse subtrees
- [ ] Dragging a doc onto a folder moves the file on disk; ⌘Z restores it
- [ ] External edit while clean reloads silently; while dirty shows a non-blocking merge banner
- [ ] Code blocks stay dark (#1E2430) in light and dark appearance
- [ ] Editor column ≤680pt at every window size; panels collapse in order (outline → sidebar)
- [ ] Every shortcut in the keyboard map works; ⌘P prints; ⌘E does Use-Selection-for-Find
- [ ] Tab bar hidden with one doc, format pill + outline toggle still visible
- [ ] Export produces PDF, standalone HTML, MD+assets, RTF, TXT

## Assets
None bundled — all iconography is SF Symbols; sample content in mockups is illustrative.

## Files
- `Markdown Editor Design Doc.dc.html` — the full visual spec (10 sections). Sections 02 (anatomy), 06 (element sheet), 07 (states), 08 (flows), 09 (responsive), 10 (tokens) are canonical; sections 01/03/04/05 contain the chosen options (1a/1e/1h/1k) alongside rejected alternatives.
