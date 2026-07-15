# Quoin beyond the Mac: iPhone/iPad and Linux

Status: DIRECTION (2026-07-15). Grounded in what exists; nothing here is
started. Companion to the TRD's session model and `docs/design/suggestions.md`
(the review loop is load-bearing for both platforms).

## What already holds (the inventory that shapes everything)

- **QuoinCore is platform-free in fact, not just intent**: zero
  `canImport(AppKit)`, Linux-green by mandate, and it contains the ENTIRE
  document brain — parse, session actor, undo, autosave, search, stats,
  exporters (plain/markdown/HTML), and the whole review machinery
  (CriticScanner, SuggestionResolver, ReviewAuthoring, ReviewEndmatter,
  FrontMatterEditing, SuggestTransform). Every atomic-edit API added this
  cycle (`applyResolution`, `applyAnnotation`, `applyFrontMatterEdit`) is
  in-actor core code that runs anywhere Swift runs.
- **The iOS reader exists**: `QuoinRender/UIKit/MarkdownReaderViewIOS` +
  `App/iOS` shell (IOSReaderScreen), compiled in CI.
- **Diagram/math layout is platform-free** (MermaidLayout / VinculumLayout
  scene IR); only RASTERIZATION is CoreGraphics/CoreText.
- `ReaderModel` is ~2 AppKit touches away from platform-free (NSSound +
  the import) — the handoff rule ("view models are platform-free; only
  navigation containers differ") is one small extraction from true.
- Mac Catalyst stays a NON-goal (CLAUDE.md: the AppKit guards would
  mis-route; the UIKit path is the real iOS story anyway).

## iPhone / iPad: reader + reviewer first, editor later

**Thesis.** Phone Quoin is not a small Mac Quoin. Its killer loop is the
one nothing else has: an agent (or collaborator) writes RDFM marks into
your files at a desk or on a server; you read the document and
accept/reject from the couch, byte-safe, one undo per action. Reading and
reviewing are PERFECT touch interactions; block-level source editing is
not, and pretending otherwise would ship a bad editor instead of a great
reviewer.

**R1 — Reader parity (S).** Library via `UIDocumentPickerViewController`
folder grant + security-scoped bookmark (same pattern as the Mac, iOS
flavor); the iCloud Drive folder IS the sync story — same files, no
service, conflicts already handled by the session's banner machinery.
Outline as a sheet/sidebar (iPad gets the real sidebar). Recents + quick
open. The reader view exists; this phase is library plumbing + navigation
chrome around it.

**R2 — The review loop (M). The reason to build any of this.** Cards
render in a bottom sheet (iPhone) / trailing column (iPad). Swipe right
on a card = accept, left = reject; tap = jump-and-flash (the linkage
machinery is renderer-level and already compiles for UIKit). Creation
gestures: select text → Comment/Suggest in the edit menu
(`UIEditMenuInteraction`), riding `applyAnnotation` unchanged. This phase
also forces the ReaderModel extraction (below) — the review flows are the
first thing both shells genuinely share.

**R3 — Properties + field editing (M).** The Properties inspector
translates 1:1 (it's a form). "Field editing": tap a paragraph → edit
THAT block's source in a focused sheet with a commit button — the
session's relative-edit API already thinks in blocks, and a one-block
sheet dodges the whole caret/reveal/viewport problem class on touch.
Review Mode typing works here naturally (SuggestTransform is pure core).

**R4 — The full in-place editor (L, iPad-first).** A TextKit 2
`UITextView` port of the coordinator (reveal flips, caret anchoring,
decorations). Large, deliberate, and NOT a prerequisite for shipping
R1–R3 as a real product.

**Prerequisite refactor (do first, benefits macOS too):** split
`ReaderModel` into a platform-free core (App-agnostic target or QuoinCore
extension: document/session/undo/review/properties state) + a thin macOS
adapter (beep, pasteboard, AppKit-only affordances). The macOS app keeps
behavior; iOS imports the core.

## Linux: the agent-side toolkit, not a GUI

**Thesis.** Nobody wants a GTK Quoin. Linux is where agents live —
servers, CI, containers — and Quoin's differentiator there is SAFE
programmatic review: the same atomic, self-calibrating, refuse-on-drift
edits the app uses, exposed as a CLI instead of hand-spliced regex
CriticMarkup. Linux Quoin completes the agent handoff story: Claude Code
on any machine runs `quoin review add`, and the marks appear live in the
Mac/iPhone panel through ordinary file sync.

**L1 — `quoin` CLI (S).** An `executableTarget` on QuoinCore only:
- `quoin stats|outline|lint <file>` — parse-backed inspection.
- `quoin export --format html|md|txt` — the pure exporters.
- `quoin review list <file> --json` — marks + metadata (the
  "review index" agents consume).
- `quoin review add|accept|reject|reply` — ReviewAuthoring /
  SuggestionResolver through the session APIs: atomic, recorded,
  structure-preserving, refusing rather than corrupting. This is the
  payload; everything else is garnish.
CI gains a Linux job running the CLI's tests (the core suite already has
to pass there by mandate).

**L2 — SVG scene writers (M, upstream).** Mermaid/Vinculum layout is
platform-free; only CG rasterization isn't. An SVG writer over the scene
IR (pure string generation from typed geometry) unlocks full-fidelity
HTML export on Linux — diagrams and math included. Belongs in the
MermaidKit/Vinculum repos (filed as enhancement issues when this phase
starts, per the cross-repo rule).

**L3 — `quoin serve`: Quoin you can USE on Linux (M).** (Elevated from
garnish: the user runs Linux and wants Quoin there, not just a toolkit.)
A localhost server on the session actor rendering the library and
documents as SERVER-SIDE HTML — reader + reviewer, not a toy: outline,
the field-grid front matter, review cards with Accept/Reject/Comment as
plain HTTP form posts hitting the same in-actor APIs, live reload via
the file watcher. The zero-JS-at-runtime principle HOLDS — no client
framework, ideally zero script (form posts + meta-refresh/SSE degrade
gracefully); all rendering is Swift. Diagrams/math arrive with the L2
SVG scene writers (same layout geometry as the Mac, byte-identical
documents). Field editing = a per-block textarea form riding the
relative-edit session API — the same "focused sheet" shape as iOS R3.
This is the honest Linux Quoin until Swift's native GUI story matures.

**L4 — Native-shell spike (exploratory, no commitment).** Track
SwiftCrossUI/Adwaita-Swift maturity; a native reader shell over the
scene IR + HTML-free projection would be the long-game replacement for
L3's browser chrome. Spike when the ecosystem earns it; the L1–L3
layers are exactly the substrate it would sit on, so nothing is wasted.

## Sequencing recommendation

1. ReaderModel extraction (unlocks iOS, pays macOS immediately).
2. L1 CLI (small, ships the agent story end-to-end, exercises the
   Linux mandate for real).
3. R1+R2 (the phone reviewer — the demo that sells the whole design).
4. L2 SVG upstream ↔ R3 in parallel-ish; R4 when the iPad demands it.

## Non-goals

Mac Catalyst; a Linux GUI *toolkit port* (GTK/Qt reimplementation of the
TextKit editor); any sync service (files + iCloud Drive/git are the sync
layer); WYSIWYG phone editing before the reviewer is excellent; client-side
JS frameworks anywhere, ever.
