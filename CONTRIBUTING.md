# Contributing to Quoin

Quoin is a native Swift/SwiftUI plus TextKit 2 WYSIWYG Markdown editor for
macOS, with iOS/iPadOS reader work following the same engine boundaries. It is
local-only at runtime: no JavaScript, no web views, no telemetry, and no
network dependency for editing local notes.

Before changing behavior, read these project sources in order:

1. `docs/design/handoff.md` and `docs/design/Markdown Editor Design Doc.dc.html`
2. `docs/TRD.html`
3. `docs/PRD.html`
4. `docs/architecture.md`

The handoff wins on visual and interaction details. If it conflicts with the
TRD, keep the handoff behavior and note the conflict in the implementation or
follow-up issue.

## Setup

Requirements:

- macOS 14 or newer
- Xcode 16 or newer
- Swift 5.10 or newer
- XcodeGen for app projects: `brew install xcodegen`
- GitHub CLI for tracker hygiene checks: `brew install gh`

Package checks run from the repository root:

```sh
swift build
swift test
bash scripts/check-dependency-policy.sh
```

The app projects are generated with XcodeGen:

```sh
cd App/macOS
xcodegen
xcodebuild -project Quoin.xcodeproj -scheme Quoin -configuration Debug build

cd ../iOS
xcodegen
xcodebuild -project QuoinIOS.xcodeproj -scheme QuoinIOS \
  -destination 'generic/platform=iOS Simulator' build
```

## Branch and Worktree Workflow

Keep work scoped to one issue bundle. A typical flow is:

```sh
git fetch --prune origin
git pull --ff-only
git worktree add ../quoin-my-branch -b codex/my-branch origin/main
cd ../quoin-my-branch
```

Commit meaningful units of work and push the branch for CI. Do not mix
unrelated issue work into the same pull request.

## Architecture Invariants

These are not style preferences; changes must preserve them:

- The markdown source string plus AST are the only source of truth.
  Attributed strings are projections, never document data.
- Edits flow through `DocumentSession` as source edits and the renderer
  re-projects the result.
- Opening, editing, and saving must keep untouched regions byte-lossless.
- Documents are plain `.md` files on disk; folders are directories.
- `QuoinCore` stays platform-free and must keep building on Linux in
  principle.
- View models stay platform-free; only navigation containers differ.
- Runtime stays local-only with zero JavaScript and no embedded web view.
- System shortcuts are not overridden: `Cmd-P`, `Cmd-E`, and `Cmd-H` keep
  their system meanings.
- Block chrome is drawn from geometry in `QuoinTextView`, not with per-glyph
  background attributes.
- Unknown or unsupported input degrades to a labelled source card rather than
  crashing or half-rendering.

## Dependency Policy

Quoin has one direct code dependency: `swift-markdown`. New code dependencies
require written TRD justification before `Package.swift`, `Package.resolved`,
or the dependency guard is changed. Run:

```sh
bash scripts/check-dependency-policy.sh
```

## Tests, Fixtures, and Snapshots

Every core behavior should have coverage under `Tests/QuoinCoreTests`.
Rendering changes usually need `Tests/QuoinRenderTests`, fixture updates, or
both. Pathological input belongs in torture tests, and performance-sensitive
work should preserve the PRD budgets enforced by `PerformanceTests`.

Renderer fixture modules live under `Fixtures/renderer/` and feed conformance
and digest snapshots. Regenerate snapshots only for intentional behavior
changes:

```sh
QUOIN_UPDATE_SNAPSHOTS=1 swift test
```

Screenshot automation uses the macOS app UI tests and publishes PNGs from CI.
Use screenshots for layout-sensitive UI changes, especially colors, rules,
spacing, decorations, and rendered math or diagrams.

## Issue and PR Hygiene

Open issues should be triaged with:

- `status:triaged`
- exactly one `priority:*` label
- at least one `area:*` label
- a milestone

Check tracker metadata with:

```sh
bash scripts/check-issue-triage.sh
```

Pull requests should link the issue they close, list tests run, call out UI
screenshots when relevant, and confirm the dependency policy.
