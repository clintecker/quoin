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
- **[FIXED×2] No termination flush** — ⌘Q inside the 400ms autosave debounce
  dropped the last keystrokes. v1 (MainActor Task in terminateLater) STILL
  lost data — that runloop mode isn't guaranteed to run main-actor tasks;
  Clint hit it live. v2: snapshot sessions on main, flush on a DETACHED
  task, reply on main, 3s watchdog.
- **[FIXED] ⌘N not typeable until click** — no first responder on open;
  one-shot focus claim in updateNSView once the window exists.
- **[FIXED] Welcome/Guide buttons dead** — XcodeGen folder-type resources
  nest under Resources/ in the bundle; lookup now falls back to the
  subdirectory.
- **[FIXED] Menu commands broadcast to every window** — every menu-driven
  observer now guards on `controlActiveState == .key`; with two windows,
  ⌘Z/Export/⌘N act in the key window only. (Trash-tab-close deliberately
  stays broadcast — a dead tab must close everywhere.)
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

- [FIXED] First-run onboarding moved to the detail pane; sidebar stays
  quiet until a library exists. #3.
- [FIXED] Open tabs survive relaunch (@SceneStorage per window; only
  library-scoped files restore — panel one-offs need bookmarks). #4.
- [FIXED] Honest File menu: New Document ⌘N / New Window ⇧⌘N / Open… ⌘O /
  Open Recent / Close Tab ⌘W; system Close retitled Close Window ⇧⌘W via
  delegate menu surgery; hidden buttons deleted. #5.
- [PARTIAL] Undo/Redo disabled without a document. Remaining: sidebar
  move-undo only works with no tab open; ⌘Z still routes to the document
  while a text field (find bar) is focused. #6.
- [FIXED] Format/Export/Print/Find/Go/Close Tab enablement via
  `quoinHasDocument` focused value; format items need an active block. #7.
- [FIXED] File ▸ Change Library Folder…. #8.
- [FIXED] Sidebar file management: Move to Trash (files/folders,
  recoverable, closes tabs everywhere), New Folder, New Document in
  folder, folder rename, empty-area menu. #9.
- [FIXED] Quick open ↑/↓ + scroll-into-view + no-matches/empty-recents
  states. #10/#16.
- [FIXED] Real menus for everything: Go menu (Back/Forward/Quick Open/
  Daily Note), Edit ▸ Find family + Search Library, File ▸ Print…. #12.
- [FIXED] View toggles are checkmarked @AppStorage Toggles (+ Status
  Bar); Sentence Focus disabled without Focus Mode. #13.
- [FIXED] Titlebar document proxy (`navigationDocument`). #14.
- [FIXED] File ▸ Open… + Open Recent (+ Clear); system recents noted on
  every open; Dock menu shows recents. #15.
- [FIXED] Empty-library null state in sidebar. #17.
- [FIXED] Export sheet: DOCX card cut; window-modal save panel; Escape
  monitor suspends while the panel runs. #18.
- [FIXED] System sidebar-toggle duplicate removed (replacing: .sidebar). #19.
- [PARTIAL] a11y labels on new-document button + tab-bar tabs (button
  trait + selected). Full VoiceOver audit still owed. #20.
- [PARTIAL] External drops now COPY (intra-library drops move with ⌘Z).
  Remaining: drop failures silent, no drop-target highlighting, .md drop
  on editor ignored. #21.
- [OPEN] Tab switches destroy scroll/caret state (`.id(activeTab)`). #22.
- [FIXED] Sidebar keyboard selection opens documents. #23.
- [PARTIAL] Dock menu ✓, CFBundleTypeRole Editor ✓. Remaining: Services,
  progress hairline overlaps find bar. #24.

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
