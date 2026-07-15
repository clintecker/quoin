# Docs map

Where to look, by question. (House rule: every doc names its evidence — an
invariant cites its test, an ADR cites its commit, a claim cites file:line.)

The tree is organized by audience:

```
docs/
  PRODUCT.md          capability spec (the source of truth for "what it does")
  guide/              user-facing: the feature tour + screenshot manifest
  reference/          contributor machinery: architecture, invariants, ADRs, budgets
  design/             design specs: handoff, editor modes, review loop, embeds, roadmap
  history/            historical records: ledgers, roadmaps, engine-extraction notes
  archive/            legacy specs superseded by the handoff (PRD, TRD)
  context/            code-verified feature packs for marketing/website work
  images/             the images the docs and README embed
```

## "What is Quoin, and what does it do?"
- **[PRODUCT.md](PRODUCT.md)** — the reference-grade capability spec: what
  Quoin is and does, every claim backed by a test, doc, or CI screenshot.
  The capability source of truth; downstream surfaces (marketing, website)
  lift from here. Stays at the top level because it is externally referenced.
- `../README.md` — the public overview + support matrix, leading with the
  review/commenting loop. Engine details defer to the engine repos.
- **[guide/features.md](guide/features.md)** — the user-facing feature tour,
  organized by what you *do* (write, review, organize, read). The "what's in
  my hands" complement to PRODUCT.md's data spec.

## "What are the rules?"
- **[reference/invariants.md](reference/invariants.md)** — the constitution:
  every rule the codebase enforces, each with its guarding test. Read this
  first.
- **[reference/adr/](reference/adr/README.md)** — why the non-obvious roads
  were chosen and which plausible roads were REJECTED (don't re-attempt
  keep-alive tabs; see 0005).
- `../CLAUDE.md` — working conventions, build/debug recipes, hard-won
  pitfalls (agent- and contributor-facing).

## "How does it work?"
- **[reference/architecture.md](reference/architecture.md)** — the contributor
  machinery map: parse → session → project → display, editing model, testing
  strategy.
- **[design/editor-modes.md](design/editor-modes.md)** +
  **[design/editor-modes-plan.md](design/editor-modes-plan.md)** — the
  presentation-state model (rendered + 3 editing flavors), its diagnosis
  history, and the shipped 4-phase implementation with as-built deviations.
- **[design/embed-editing-ux.md](design/embed-editing-ux.md)** — the embed
  editing interaction grammar (implemented).

## "How does the review / commenting loop work?"
- **[design/suggestions.md](design/suggestions.md)** — the differentiator:
  tracked changes, comments, and review as literal bytes in the file
  (CriticMarkup marks + RDFM metadata). Design, format decision, and the
  staged plan; **S1–S3 shipped**, S4 (replies, agent handoff) is next.
  The README's Review section is the user-facing summary.

## "What should it look like?"
- **[design/handoff.md](design/handoff.md)** (+ the `.dc.html` doc) — THE
  visual/interaction spec, canonical down to point sizes and alpha values.
- [archive/TRD.html](archive/TRD.html) / [archive/PRD.html](archive/PRD.html)
  — architecture + original product spec, superseded by the handoff (it wins
  on conflict); kept for the performance budgets and privacy stance.

## "What's the plan / what happened?"
- **[design/road-to-1.0.md](design/road-to-1.0.md)** — the single sequencing
  document from here to PUBLIC and 1.0 (license, docs overhaul, feature gaps,
  distribution, Swift 6, platform expansion, the 1.0 gate).
- **[design/platforms.md](design/platforms.md)** — the iPhone/iPad and Linux
  direction (five-squad-debated); post-1.0, gated by the dogfood experiment.
- [history/launch-ledger.md](history/launch-ledger.md) — pre-launch review
  ledger (BLOCKERs, statuses, war stories).
- [history/rendering-roadmap.md](history/rendering-roadmap.md) — COMPLETE;
  historical.
- [history/rendering-ledger.md](history/rendering-ledger.md),
  [reference/performance.md](reference/performance.md),
  [reference/dependencies.md](reference/dependencies.md) — supporting records.
- [guide/screenshots.md](guide/screenshots.md) — the screenshot manifest:
  every CI shot, its launch args, and the `docs/images/` path README/PRODUCT
  reference. Shots regenerate on every push (automated, never hand-captured).
- [history/math-extraction.md](history/math-extraction.md),
  [history/diagram-engine-handoff.md](history/diagram-engine-handoff.md) — how
  Vinculum and MermaidKit were extracted (historical stubs; the engine repos
  are the source of truth for capability).

## "What can it render?"
- `../README.md` — the public support matrix (summaries; engine details
  defer to the engines).
- **Engines:** [MermaidKit](https://github.com/clintecker/MermaidKit) and
  [Vinculum](https://github.com/clintecker/Vinculum) document themselves —
  Vinculum's `docs/COVERAGE.md` / `docs/COMMANDS.md` and both repos' CI
  galleries are the sources of truth. Quoin docs deliberately do NOT
  duplicate their matrices (they drift; see the 23-vs-30 lesson in
  [reference/adr/0003](reference/adr/0003-first-party-engines.md)).
- [history/diagram-gallery.md](history/diagram-gallery.md) — rendered examples
  from Quoin's own pipeline (a stub pointing at MermaidKit for the full type
  matrix).
- [context/quoin-features.md](context/quoin-features.md) /
  [context/mermaidkit-features.md](context/mermaidkit-features.md) —
  code-verified feature packs for marketing/website work.
