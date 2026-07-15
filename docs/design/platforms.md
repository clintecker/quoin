# Quoin beyond the Mac: iPhone/iPad and Linux

Status: DIRECTION v2 (2026-07-15). v1 was debated by five adversarial
product squads (iOS product, Linux/agent infra, macOS guardian,
engineering reality, owner persona) across two rounds; this revision keeps
only what survived. The decision log at the end records what changed and
why. Companion to the TRD and `docs/design/suggestions.md`.

## Corrected inventory (what ACTUALLY holds)

- QuoinCore has zero AppKit imports and contains the entire document brain
  including all review machinery — TRUE and verified.
- **"Linux-green" is currently FALSE**: a swift:6.0 container build fails
  twice — `CGVector` in MermaidLayout (absent from corelibs Foundation;
  upstream, filed) and `NSString` `.byWords` enumeration in
  MarkdownConverter (two sites, the word-count path). CI runs macOS only;
  the Linux mandate is unenforced. Nothing in the Linux sections is
  citable until a Linux CI job is green.
- The iOS "reader" is a 98-line UITextView WITHOUT the decoration layer
  (code canvases, callout boxes, quote/table rules live in macOS
  `drawBackground` and have no UIKit counterpart), without Dynamic Type,
  behind a single-document viewer shell that the library replaces
  wholesale. It is a spike, not a reader.
- ReaderModel is NOT "~2 AppKit touches from platform-free": it is ~1,161
  lines of untested orchestration with 14+ QuoinRender couplings, and
  `CaretHint` is defined in the AppKit view layer. The honest framing is
  two tiers — UIKit-shareable vs. truly platform-free — reached via
  characterization tests first, extraction later.
- The session actor's atomicity is SINGLE-PROCESS. Any second writer (the
  CLI, an agent) racing the app's open session + autosave is a corruption
  seam the current design does not cover. Cross-process write safety is a
  designed contract, not an assumption.
- iCloud on iOS is not "free sync": picker-granted folders hold dataless
  placeholders, kqueue watchers see nothing, conflicts arrive as
  NSFileVersion versions, and reads/writes must be coordinated. The
  couch-review demo is exactly as good as this section.

## Phase 0 — enforce the claims (days, Mac-risk-free)

1. Linux CI job in Quoin's ci.yml building + testing QuoinCore (and a
   matching job upstream in MermaidKit; issue filed for the CGVector
   breaks). Fix the two `byWords` sites with a Linux word-break fallback
   and a cross-platform word-count parity test.
2. ReaderModel characterization tests — the step that "pays macOS
   immediately" and the prerequisite for ever extracting it. No
   extraction yet.
3. In parallel (already queued): adversarial review of the review-machinery
   surge (SuggestionResolver / ReviewAuthoring / SuggestTransform /
   FrontMatterEditing splice paths); #60 forensics continue when the
   owner can supply a live trace.

## Phase 1 — L1: the `quoin` CLI (M, was S)

The agent-side story and the owner's own Linux tool, scoped honestly:

- `quoin stats|outline|lint`, `quoin export --format html|md|txt`,
  `quoin review list --json` (VERSIONED schema — agents will pin to it),
  `quoin review add|accept|reject|reply` through the same in-actor,
  self-calibrating, refuse-on-drift core APIs.
- **Cross-process write contract** (the part that makes it an M): CLI
  writes are compare-and-swap against a content hash with the same
  refuse-don't-corrupt posture as in-app drift checks; the app's file
  watcher absorbs external CLI writes as it does any external edit. A
  torture test drives CLI writes against an open session.
- Ships WITH a Claude Code skill (`/quoin-review` or similar) so the
  handoff story is usable the day it lands, and dogfoodable immediately.
- Gated behind the Phase 0 CI and the adversarial review of the APIs it
  exposes.

## Phase 2 — the phone, behind a dogfood gate

The squads' sharpest finding: the async couch-review behavior the phone
bet rests on is UNDEMONSTRATED — the owner's observed review loop is
synchronous, live, at the Mac. So the phone earns its build with an
experiment, not a hunch:

- **Dogfood gate (≈3 weeks, near-zero cost):** with the L1 CLI live,
  agents write marks into the iCloud-synced library during normal work.
  If the owner repeatedly finds himself WANTING to triage from the phone
  (observed, not imagined), R1 starts. If not, the phone stays a reader
  idea and no months were spent.
- **R1 (M, was S) — "a reader that passes the Jobs bar":** folder-grant
  library (UIDocumentPicker + bookmark), UIKit port of the decoration
  draw/measure pass over TextKit 2 fragment frames, Dynamic Type via
  UIFontMetrics scaling of the theme ramp, explicit iOS behavior for
  every quoin-* URL scheme, replacement of the DocumentGroup shell.
- **R1.5 — field editing pulled forward:** tap a block → focused source
  sheet → commit via the relative-edit session API. Reader + fix-a-typo
  is the minimum app that isn't embarrassing; it ships before the
  review loop, not after.
- **R2 — the review loop:** cards in sheet/column; primary interaction is
  tap → jump-and-flash diff in context → explicit Accept/Reject → undo
  toast. Swipe survives only as an opt-in full-swipe accelerator with
  haptic confirm (gesture conflicts + destructive-action muscle memory
  killed it as the headline). Requires the **iCloud mechanics section**:
  NSMetadataQuery discovery + download of dataless files, coordinated
  reads/writes, NSFileVersion conflict UX, and the pull-only answer —
  BGAppRefresh scan + local notification + badge ("3 new suggestions in
  Weekly Notes"), because a reviewer nobody is told about is a room
  nobody enters.
- **R3 — Properties panel** (translates 1:1). **R4 — the full editor:**
  demoted to an unsized, demand-gated note; no iPad usage is in
  evidence, and the TextKit2/UITextView coordinator port is XL, not L.
- iPad throughout R1–R3: hardware-keyboard citizenship (arrow-key card
  nav, ⌘-return accept, ⌘F) and pointer hover — cheap, and the
  difference between an iPad app and a stretched iPhone app.

## Phase 3 — L3: `quoin serve`, demoted to a sketch

The owner wants usable Quoin on Linux; a localhost server over the
session actor is still the honest medium-term answer — but v1's spec
overclaimed and it is NOT a committed phase until three problems have
designs:

1. **HTTP server vs. the one-dependency policy**: swift-nio needs TRD
   justification or a minimal vendored/hand-rolled epoll server —
   decided, not discovered.
2. **The zero-script claim, corrected**: SSE without JS does not exist
   and meta-refresh loses scroll/form state (killed). The honest stance:
   server-rendered HTML, no frameworks ever, and AT MOST one small
   inline script for live-reload/scroll-preservation — an explicit,
   documented exception to the letter of zero-JS that preserves its
   spirit, or no live reload at all.
3. **FileWatcher needs an inotify backend** (kqueue is Darwin-only) —
   also a prerequisite for `quoin watch`.

Interim Linux reality: the CLI + `$EDITOR` + `quoin export html` opened
in a browser. Less romantic, shippable in Phase 1.

## L2 — SVG scene writers (unchanged, upstream) + Silica raster option

Platform-free scene IR → SVG strings in MermaidKit/Vinculum unlocks
full-fidelity export everywhere. Enhancement issues at phase start.

**Silica (PureSwift) evaluation queued (#84):** a maintained (v3.0.0,
2026-07) MIT CoreGraphics implementation over Cairo/FreeType on Linux.
Because both layout engines already take injected text measurers, a
Silica-backed renderer + FreeType measurer could rasterize diagrams and
math on Linux with the SAME geometry as the Mac — PNG export and serve
thumbnails. Posture: optional products UPSTREAM only (never a Quoin-app
dependency; system libs acceptable in CLI/server contexts).
Complementary to SVG, which stays the zero-dependency path — and either
way Linux needs a real text MEASURER, which Silica's font stack could
supply for both.

## Sequencing (post-debate consensus, all five squads)

1. **Phase 0** now: Linux CI + two compile fixes + ReaderModel
   characterization tests; adversarial review + #60 in parallel lanes.
2. **L1 CLI** with the cross-process contract + versioned JSON + skill.
3. **Dogfood gate** runs during/after L1 → decides the phone.
4. R1/R1.5/R2 if the gate passes; L3 when its three designs exist; L2
   upstream when export demands it; R4 on demonstrated iPad demand.

## Decision log (what the debate changed)

- KILLED: "Linux-green in fact" (container build fails; CI now required
  first); "~2 AppKit touches" (replaced with tiered coupling truth);
  R1 as S ("reader exists" — it doesn't, at the polish bar); swipe as
  headline interaction; zero-script SSE/meta-refresh fiction; L3 as a
  committed phase; R4 as a sized phase; "conflicts already handled"
  (single-process only; iOS/iCloud unaddressed).
- ADDED: Phase 0 CI enforcement; cross-process CAS write contract +
  torture test; versioned CLI JSON schema + Claude Code skill; the
  dogfood gate; R1.5 field editing before the review loop; iCloud
  mechanics + notification/badge requirements; Dynamic Type/VoiceOver/
  hardware-keyboard citizenship; ReaderModel characterization-first.
- SURVIVED INTACT: reviewer-first on touch; editor-last; no Catalyst;
  no GTK port; no sync service; no client-side JS frameworks, ever;
  files as the only truth.

## Non-goals

Mac Catalyst; a Linux GUI toolkit port; any sync service; WYSIWYG phone
editing before the reviewer is excellent; client-side JS frameworks
anywhere, ever.
