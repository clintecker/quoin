# Launch ledger

*2026-07-10. Four-track pre-launch review (senior Swift, macOS platform/UI,
performance, product). Every entry verified against code at review time.
Status: OPEN / FIXED (commit) / DECISION (needs Clint). Work the BLOCKERs
top-down; nothing ships while a BLOCKER is open.*

## BLOCKERS

- **[FIXED] Open-failure data loss** — a file that exists but can't be read
  (encoding/permissions/cloud placeholder) silently became a BLANK session
  bound to the real URL; first keystroke autosaved ~1 byte over the user's
  document. Now: detached session (no fileURL) + sticky banner. `ReaderModel.start`.
- **[FIXED] Silent autosave failure** — `try? saveNow()` swallowed every save
  error forever (`lastSaveError` had no consumer). Now: retry once, then a
  sticky banner via `setSaveFailureHandler`. `DocumentSession`.
- **[FIXED] ⌘N black hole** — an empty document has no blocks, so every
  keystroke was silently dropped. Now: `onEmptyDocumentInsert` routes typing
  into the session at offset 0. Follow-up polish: dimmed "Start typing…"
  placeholder. `ReaderCoordinator`/`ReaderModel`.
- **[FIXED] No termination flush** — ⌘Q inside the 400ms autosave debounce
  dropped the last keystrokes (`onDisappear` unreliable at quit). Now:
  `applicationShouldTerminate` → `.terminateLater` → drain all live sessions.
- **[OPEN] Menu commands broadcast to every window** — all menu items post
  unfiltered notifications; with two windows, ⌘Z undoes in BOTH documents,
  Export opens two sheets. Fix: key-window guard or @FocusedValue action
  routing. `QuoinApp`/`ReaderScreen`/`MainWindow`. **Top remaining item.**
- **[OPEN] App icon does not exist** — generic AppKit icon today; no
  .xcassets anywhere. Commission now (lead time). (PM L6)
- **[DECIDED 2026-07-10: DIRECT distribution]** — consequences now on the
  ledger: (a) Sparkle 2.x for updates — a real third-party dependency
  requiring the written TRD justification per policy, plus an appcast
  host; (b) Developer ID signing + notarization pipeline (hardened
  runtime already on; needs an archive/notarize script in scripts/);
  (c) privacy copy amended to "no network except the update check, which
  you can disable"; (d) pricing/licensing mechanics are ours to build.
  (PM L9/L10)

## HIGH — data integrity & correctness (senior review)

- [OPEN] Undo/redo stacks survive external reloads — ⌘Z after a disk change
  splices stale bytes at old offsets, then autosaves the corruption. Fix:
  clear/rebase stacks on any non-edit adoption. `DocumentSession` #3.
- [OPEN] Conflict banner doesn't stop subsequent autosaves — continued
  typing clobbers the disk version while the user "decides". #5.
- [OPEN] External rename/move forks the document — watcher polls dead path
  at 200ms forever; next autosave resurrects the old filename. #6.
- [OPEN] Undo/redo not serialized with the edit pipeline (echo gate). #7.
- [OPEN] Session edit failure wedges typing 2s then DISCARDS the queued
  keystrokes; error swallowed. Fix: unwedge + replay + banner. #8.
- [OPEN] Format commands + smart paste bypass the edit-echo gate — ⌘B
  right after a keystroke can wrap a stale range. #9.
- [OPEN] Fence healing on commit-while-broken (also embed brief tranche-2
  #1): deleting a closing fence swallows following blocks; commit keeps it.
  Scoped: bytes are honest, ⌘Z restores — panic risk, not byte loss. #10.
- [OPEN] Dead security-scope bookmark degrades to invisible global failure;
  library loss shows the first-run prompt with no explanation. #11.
- [OPEN] Same file can open as two live sessions (URL-equality keying;
  multi-window makes it trivial) — two autosavers ping-pong content. #12.
- [OPEN] First-H1 rename tears down the live editor mid-typing
  (`.id(activeTab)` recreation). #13.
- [OPEN] Clean external reload during an in-flight edit applies stale
  offsets; stamp edits with their sourceHash and reject mismatches. #14.
- [OPEN] Sole-block Delete Block can erase trailing non-rendered bytes. #15.

## HIGH — platform/UI (macOS audit)

- [OPEN] First-run detail pane: New Document button silently no-ops with no
  library; onboarding lives in the narrow sidebar. (Partially improved by
  the starter-library prompt; move CTA to the detail pane.) #3.
- [OPEN] Open tabs don't survive relaunch (@State only — workspace
  amnesia). Fix: @SceneStorage/defaults keyed by library. #4.
- [OPEN] ⌘N/⌘W shadow the default File-menu items — menu says New Window/
  Close, keys do New Document/Close Tab. Replace `.newItem`, add honest
  items, delete hidden buttons. #5.
- [OPEN] Undo/Redo menu items: no enablement, no-op with no document;
  sidebar move-undo stranded; ⌘Z steals from text fields. #6.
- [OPEN] Format/Export/View items enabled with nothing to act on —
  `.disabled` via @FocusedValues. #7.
- [OPEN] Library folder can never be changed after first choice. #8.
- [OPEN] Sidebar file management read-only: no Move to Trash, New Folder,
  folder rename, new-doc-in-folder. #9.
- [OPEN] Quick open: ↑/↓ dead (highlight machinery exists, unwired);
  no-results renders nothing; empty-recents state is a bare field. #10/#16.
- [OPEN] Feature set invisible in menus: Quick Open, Library Search, Daily
  Note, New Document, Find family, Back/Forward, Print — hidden shortcuts
  only. #12.
- [OPEN] View toggles lack checkmarks (Toggle bound to @AppStorage);
  Sentence Focus silently no-ops without Focus Mode. #13.
- [OPEN] No titlebar document proxy (`.navigationDocument`). #14.
- [OPEN] No File ▸ Open…/Open Recent; system recents never noted. #15.
- [OPEN] Empty-library sidebar is blank space + tiny footer. #17.
- [OPEN] Export sheet: dead DOCX card (cut it), Escape monitor eats the
  save panel's cancel, app-modal runModal → beginSheetModal. #18.
- [OPEN] Duplicate sidebar toggles (custom ⌘0 + system ⌃⌘S). #19.
- [OPEN] Icon-only buttons lack accessibilityLabels; tab bar items aren't
  accessible controls. #20.
- [OPEN] Drops from outside the library MOVE the source file (should
  copy); failures silent; no drop highlighting; .md drop on editor
  ignored. #21.
- [OPEN] Tab switches destroy scroll/caret state (`.id(activeTab)`). #22.
- [OPEN] Sidebar keyboard selection never opens documents. #23.
- [OPEN] Conveniences roll-up: Dock menu, Services, CFBundleTypeRole
  Viewer→Editor, progress hairline overlays find bar. #24.

## HIGH — performance (all currently unbudgeted; entries #1–#16)

- [OPEN] Preview render is synchronous in the per-keystroke projection pass
  (~10–25ms) — go async with generation token via the choreographer. #1.
- [OPEN] The existing preview budget test bypasses the expensive path
  (`block: nil`) — fix the test; it will fail until #1 lands. #2.
- [OPEN] Non-patchable active blocks (LIST/quote/callout/TOC) take 3–4
  stacked O(document) passes per keystroke — the "gets slow on big files"
  configuration. Extend the patch path or budget it in CI. #3.
- [OPEN] Focus dimming repaints O(blocks) rendering attributes per caret
  move (sentence mode defeats the dedupe entirely) — viewport-cull. #4.
- [OPEN] Active search rescans the whole document per keystroke. #5.
- [OPEN] Whole-document SHA-256 per keystroke in both fast paths. #6.
- [OPEN] Eager whole-doc layout per projection below 200k chars. #7.
- [OPEN] syncAttributesWhereDifferent walks all runs on every fallback
  splice — bound to changed∪active ranges. #8.
- [OPEN] Flip capture rasterizes viewport+overscan before knowing the plan
  is `.none` (most prose clicks) — pre-estimate delta; 1x capture. #9.
- [OPEN] Panel geometry callback dispatches per draw pass — dedupe. #10.
- [OPEN] blockID()/topVisibleBlockID are O(blocks) linear scans on
  caret/scroll paths (string alloc per key in the scroll path!). #11.
- [OPEN] Startup: only the parse half of "<1s to interactive" is budgeted;
  cold diagram rasterization is unmeasured. #13. Memory: AsyncImageStore
  count-limited not cost-limited (~1.5GB worst case). #14.
- [OPEN] One new RenderPathLatencyTests file enrolling focus/preview/list-
  typing/search/sync in the 25ms budget convention. #16.

## PRODUCT (PM track) — see agent report for full specs

- [PARTIAL] First-run: starter-library prompt + welcome/guide seeding
  SHIPPED; remaining: Examples/ folder seeds, detail-pane CTA, "What is a
  library?" popover. L1/L2.
- [SHIPPED] Welcome doc + in-app Markdown Guide + Help menu (Guide,
  Welcome, Report an Issue). L3/L5/L14 partial.
- [OPEN] Guide as conformance fixture in CI. L5-acceptance.
- [OPEN] Version/bundle: 0.1.0→1.0 story; Viewer→Editor role. L7.
- [DECISION] Crash reporting stance (recommend: none + privacy copy). L8.
- [OPEN] Licenses view in About (Apache attribution REQUIRED for
  swift-markdown; MermaidKit repo needs a LICENSE file). L11.
- [OPEN] Launch screenshots AFTER the visual token pass; 8-second live-
  diagram-edit screen recording is the marketing centerpiece. L12.
- [FIXED] README stale claims (double-click row; 23→30 diagram types). L13.
- [OPEN] "Where is Save?" reassurance: transient Saved whisper in status
  bar. (Delight/confusion analysis.)
- Launch gates from existing ledgers: fence healing (above), venn/C4
  MermaidKit engine session (#9/#10 rendering ledger).
