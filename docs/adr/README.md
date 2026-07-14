# Architecture Decision Records

One page per decision that a future developer would otherwise re-litigate or
re-attempt. Each record cites its evidence (commit, test, screenshot, or
war story) — an ADR without evidence is a vibe. Add a record whenever a
non-obvious road is chosen, and especially when a plausible road is REJECTED.

Format: Context → Decision → Consequences → Evidence. Status is one of
Accepted / Superseded-by-NNNN.

| # | Decision |
|---|---|
| [0001](0001-source-string-truth.md) | The markdown string is the source of truth, never attributed strings |
| [0002](0002-textkit2.md) | TextKit 2, drawn-ink decorations, no HTML/web view |
| [0003](0003-first-party-engines.md) | Math and diagrams are first-party packages consumed from GitHub |
| [0004](0004-side-panel-preview.md) | The live embed preview is a side panel, not an inline run |
| [0005](0005-no-keep-alive-tabs.md) | Keep-alive tab views REJECTED; sessions live in an app-level store |
| [0006](0006-cosmetic-flip.md) | The flip transition is cosmetic by construction |
| [0007](0007-no-flaky-tests.md) | There are no flaky tests, only bad tests |
| [0008](0008-drift-by-guards.md) | Projection-path drift is prevented by CI equivalence, not code unification |
