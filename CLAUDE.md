# Quoin — project conventions

Quoin is a native WYSIWYG markdown editor for macOS (iOS/iPadOS later).
Swift/SwiftUI + TextKit 2, zero JavaScript at runtime, local-only.

## Canonical documents (in priority order)

1. `docs/design/handoff.md` + `docs/design/Markdown Editor Design Doc.dc.html`
   — the visual/interaction spec. High fidelity: colors, type ramp, spacing,
   and states are final. Canonical option choices: 1a Graphite, 1e classic
   tree sidebar, 1h ruled outline, 1k rounded text styling.
2. `docs/TRD.html` — architecture (native engines, session model). Where it
   conflicts with the handoff, the handoff wins; note the conflict.
3. `docs/PRD.html` — original viewer-scoped PRD, superseded by the handoff
   for scope but still valid for performance budgets and privacy stance.

## Non-negotiable architecture rules (from the handoff)

- Source of truth is the markdown string + AST (swift-markdown/cmark-gfm),
  NEVER attributed strings. The editor is a projection; edits mutate the
  source through `DocumentSession` and the renderer re-projects.
- Documents are plain `.md` files on disk. Folders = directories.
- View models are platform-free; only navigation containers differ.
- Never override system shortcuts: ⌘P print, ⌘E use-selection-for-find, ⌘H hide.
- Round-trip (open → edit → save) must be byte-lossless for untouched regions.

## Dependency policy

One code dependency: swift-markdown. Anything new requires written
justification in the TRD first; the default answer is no.

## Layout

- `Sources/QuoinCore` — platform-agnostic engine (parses, sessions, search,
  stats, exporters). Must build and test on Linux.
- `Sources/QuoinRender` — attributed-string projection + TextKit 2 views
  (Apple platforms, `#if canImport` guarded).
- `App/macOS` — app shell; project generated with XcodeGen (`project.yml`).
- `Tests/QuoinCoreTests` — every core feature gets tests here.

## Workflow

- Commit and push after every meaningful unit of work, to BOTH `main` and
  the active session branch (user directive).
- CI runs `swift test` on a macOS runner (`.github/workflows/ci.yml`).
  Cloud/Linux sessions have no Swift toolchain — CI is the compile feedback
  loop; keep it green.
- Design assets from the user land in `docs/design/`.
