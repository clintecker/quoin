# Quoin diagram rendering engine — handoff brief

A fresh-context brief for continuing work on Quoin's native Mermaid diagram
engine. Read `CLAUDE.md` and `docs/architecture.md` first; this doc is the
diagram-engine-specific map, current state, and open problems.

## The goal (user's vision)

Build a **best-in-class, portable, standalone Mermaid rendering engine** in
Swift — high enough quality and cleanly enough separated that other projects
could eventually depend on it outside Quoin. It should render every common
Mermaid diagram type beautifully, using proven layout/routing algorithms
(Sugiyama/dagre family), not heuristics.

## Portability status

The whole engine — parsing, models, layout, **all routing geometry** — lives in
`Sources/QuoinCore`, which imports no UI framework and builds on Linux
(CoreGraphics types come from Foundation there). Only the final rasterization
(`Sources/QuoinRender/DiagramRenderer.swift`) is platform-specific (CoreText +
CGContext). A future clean split into a standalone `QuoinDiagrams` package is
feasible: it would be QuoinCore's diagram files + a thin render protocol.

## Key files

- `Sources/QuoinCore/MermaidParser.swift` — parses source → typed models:
  `Flowchart`, `SequenceDiagram`, `PieChart`, `ClassDiagram`, `ERDiagram`,
  `StateDiagram`, `GanttChart`. Unknown dialects return nil → source-card
  fallback. Never crashes; degrades.
- `Sources/QuoinCore/DiagramLayout.swift` — shared layout core:
  - `assignLayers` (longest-path), `barycenterOrder` (crossing min),
  - `layeredRoutes` — **dummy-node layered routing** for box diagrams
    (class/ER/state): layers → dummies for multi-layer edges → order → place →
    route through chains; near-aligned edges snap to a shared column.
  - `routePolyline` / `simplifyCollinear` — orthogonal polyline through
    waypoints (vertical runs at waypoint x, horizontal jogs at midpoints).
  - `brandesKoepfX` — **Brandes–Köpf horizontal coordinate assignment**
    (Brandes & Köpf, GD 2001, LNCS 2265, pp. 31–44): four biased alignment
    passes (up/down × left/right)
    with type-1 conflict marking so inner dummy→dummy segments win, block
    compaction, and per-node median balancing. Node adjacency is deduplicated
    so parallel/back edges don't skew the index-based median. Used by both the
    flowchart (`placeFlowchartFrames`) and box diagrams (`layeredRoutes`) for
    the cross-axis position; layers still stack by main-axis gap.
  - Layout result structs: `FlowchartLayout`, `SequenceLayout`, `PieLayout`,
    `ClassLayout`, `ERLayout`, `StateLayout`, `GanttLayout`.
    `FlowchartLayout.PlacedEdge` carries a `labelPoint`.
- `Sources/QuoinCore/DiagramLayoutFlowchart.swift` — flowchart layout:
  `layout(_:)` runs assignLayers → insert dummy nodes for multi-layer edges →
  barycenterOrder → `brandesKoepfX` → `placeFlowchartFrames` → `routeChains`.
  `routeChains` is the edge router; its pipeline and the invariants it enforces
  are in **"Flowchart edge routing"** below. `placeEdgeLabels` scores label
  positions vs. node frames + other labels. `routePolyline` (with `jogBias`),
  `simplifyCollinear`, `separateRuns`, `dummyBreadth`.
- `Sources/QuoinCore/DiagramLayoutBoxDiagrams.swift` — class / ER / state
  layouts. All three call `layeredRoutes`. State recurses for composite scopes.
- `Sources/QuoinRender/DiagramRenderer.swift` — CoreGraphics drawing:
  - `attachmentString` — rasterizes a layout into a canvas sized to the **tight
    content bbox** (`contentBounds`: the layout size unioned with every edge
    point inflated by the max marker reach), translated to that box's origin +
    a small pad. Caches by source+appearance.
  - per-type `draw(_ layout:…)` for flowchart/sequence/pie/class/ER/state/gantt.
  - `strokeEdgeShafts` — batches shafts by dash style, one composite stroke, so
    crossings don't stack translucent alpha into dark seams.
  - `appendRoundedPolyline` — rounds each bend with `addArc`, clamping the
    radius to half the shorter adjacent segment so short jogs can't pinch into a
    cusp.
  - `polylinePoint` / `labelAnchor` — arc-length label sampling; box-diagram
    labels are placed at several fractions along the edge (not just the
    midpoint) with strong sibling repulsion, so antiparallel edges' labels
    spread apart instead of merging into one phrase.
  - `drawArrowhead` — erase (canvas fill) then fill, so a translucent head
    doesn't double the shaft's alpha; small tip gap.
  - `drawCardinality` (ER crow's-foot/tick/circle), `drawRelationMarker`
    (UML triangle/diamond), `drawCylinder`, `categoricalPalette`,
    `labelAnchor` (draw-time label placement for box diagrams; clamps within
    canvas bounds), `fillStrokeShape`.

## The iteration tool (use this constantly)

```
QUOIN_RENDER_GALLERY=/tmp/gallery swift test --filter DiagramGalleryTests
```
`Tests/QuoinRenderTests/DiagramGalleryTests.swift` renders every diagram type
(simple + `*-complex`) in light and dark to PNGs in that dir. Gated on the env
var (skipped in normal runs). This is how to *observe* and iterate — render,
read the PNG, fix, re-render.

## Flowchart edge routing (`routeChains`) — strategy & invariants

The edge router evolved from a pile of independent heuristics into a small
pipeline. Understanding the *order* and *why* matters — several bugs came from
two stages disagreeing about where an edge should sit.

**Pipeline (per `layout(_:)` call):**
1. **Geometry pass** — per edge compute the dummy-chain waypoints, `firstNext`
   / `lastPrev`, exit/enter faces, and whether each end is a diamond.
2. **Port distribution** — every non-diamond edge-end that touches a node face
   is bucketed by `(node, face)`. Within a bucket, place each port **at the
   coordinate it actually wants** (its channel / the direction of its far
   endpoint), then push neighbours apart only enough to hold a minimum
   separation (`flowchartPortSep`). Do **not** evenly centre a crowd — that made
   a node's incoming edge and its outgoing back edge (which want opposite sides)
   squish together and curl into a "tuning-fork".
3. **Jog-track stagger** — edges entering the *same target* get distinct
   horizontal-jog tracks (`jogBias` fed into `routePolyline`), so their bend
   corners don't nest into a "double corner".
4. **Build** — decisions attach at a **vertex** (`diamondPort`: incoming → the
   main-axis face, i.e. top for TD; outgoing branches → the N/E/S/W vertex
   facing their target, with a short side stub); every other shape uses its
   distributed face port via `attach` (which insets off the corners).
5. **`separateRuns`** — a global post-pass: find main-axis runs from *different*
   edges that share a track (same cross coord, overlapping extent) and nudge the
   **movable** one (ends are interior bends, not anchored to a box) aside by
   `flowchartPortSep`. This is the guarantee that **no two edge runs coincide** —
   port separation alone can't do it, because a separated port immediately jogs
   back to its dummy channel, which may sit on another edge's column.

**Key invariants / rules learned (don't regress these):**
- A **target port aligns with where the edge descends** (`sourceExitCross` — the
  source's vertex/stub, or its face port), *not* the source's centre. Using the
  source centre clamps the target to the far side of its band and forces a
  wasteful right-then-back-left **S-jog**.
- **Decisions meet edges at vertices**, never a slanted face (that leaves the
  arrowhead stuck on a diamond's side). Incoming enters the top; branches leave
  the side/bottom vertex toward their target.
- **No doubled/touching lines** — `separateRuns` enforces it; if two lines still
  touch, it's a bug in that pass (movable-detection or relaxation count), fix it
  there rather than adding a per-case nudge.
- The **4-point orthogonal invariant** (`testOffsetFlowchartEdgesRouteOrthogonally`):
  an offset edge routes as exactly 4 axis-aligned points. Track/jog/separate
  changes may *move* a jog but must not *add* segments.
- BK adjacency must be **deduplicated** (the paper's neighbour *sets*): a
  parallel/back edge counted twice skews the index-based median and skews the
  whole layout.

**Diagnostic method that actually works:** do **not** judge routing from a
downsampled gallery PNG — it hides which of two near-coincident lines is which
and turns real bugs into vague "weirdness". Instead **dump the exact edge points**
(a throwaway test that prints `edge.points` for the fixture), and reason about
concrete coordinates ("target x is 457, should be 484"). Every routing bug this
engine had was found in seconds once the numbers were on screen, and lost hours
when guessed from pixels. Crop-zoom (`sips -c H W --cropOffset Y X`) for a close
look, but confirm the *cause* in the coordinates.

## What has been done

- Added native **Gantt**; polished pie (clean hub + saturated categorical
  palette), ER crow's-foot markers, **database cylinder** shape, arrowhead seam
  (erase-then-fill) + tip gap, removed drop shadows.
- **Alpha-stacking** fixed everywhere via batched shaft strokes.
- **Routing rewrite (core work):** researched Sugiyama/dagre/ELK/libavoid, then
  implemented **dummy-node layered routing** — flowcharts first (`routeChains`),
  then ported to class/ER/state via shared `layeredRoutes`. Long and back edges
  now route in reserved channels *between* nodes, not under them. Replaced an
  earlier heuristic `channelRoute` that created new problems.
- **Label placement:** flowchart `placeEdgeLabels` (layout-side) and box
  `labelAnchor` (draw-time, clamped to bounds).
- **Straightening:** near-aligned box edges snap to a shared column (removes the
  tiny S-hook when box x-ranges overlap).
- **Brandes–Köpf coordinate assignment** (`brandesKoepfX`) replaced the old
  center-each-layer placement in BOTH the flowchart and the box diagrams: long
  and back edges route as dead-straight vertical channels, decision spines and
  inheritance/relation columns line up, and decisions center over their
  children. Unit-tested (straight chain, sibling gap, inner-segment
  straightness). Adjacency is deduplicated so parallel/back edges don't skew
  the median heuristic.
- **Arc-cusp clamp:** `appendRoundedPolyline` clamps each corner radius to half
  its shorter adjacent segment (kills the pinch on short jogs).
- **Antiparallel label spreading:** `labelAnchor` samples along arc length with
  strong sibling repulsion ("connect"/"fail", "synced"/"stale" no longer merge).
- **Tight bounds:** `contentBounds` sizes/translates the canvas to the true
  drawn bbox (layout size ∪ edge points inflated by marker reach), so ER
  crow's-feet, UML markers, and overrunning routes can't clip.
- **Dead code removed:** `Placement`, `orderedLayers`, `layeredPlacement`,
  `BoxFace`, `RoutedBoxEdge`, `routeBoxEdges`, `borderPoint` are gone.
- **Flowchart router cleanup pass** (see "Flowchart edge routing"): decisions
  attach at vertices (`diamondPort`); ports placed at their **wanted side** with
  min-separation (not tight-centred); target ports align with the edge's
  **descent** (`sourceExitCross`, kills S-jogs); per-target **jog-track**
  stagger; **`separateRuns`** guarantees no two edge runs coincide; wider layer
  gaps for arrowhead/label room; relation markers stood off the box border. An
  expert-panel workflow framed A/B/D as one missing "routing-track" phase.
- 244 tests green throughout; commit + push to `main` per unit of work.

## Open problems

All six defects from the prior handoff (arc cusp, antiparallel label crowding,
marker/connector clipping, loose bounds, center-then-snap coordinates, dead
code) are **fixed** — see "What has been done". Verify any future change with
the gallery harness.

Possible future polish (not defects, lower priority):

- **Compactness on dense back-edge graphs.** `flowchart-complex` still drifts
  rightward as it descends, because several long back-edge dummy channels stack
  on one side and the barycenter *ordering* (not BK coordinate assignment)
  decides which side they take. BK straightened the channels but can't move
  them; improving this means better crossing-minimization / channel-side
  assignment in `barycenterOrder`, or a post-pass that balances channel sides.
- **Self-loops / edges within a composite crossing its border** are routed
  simply; libavoid-style obstacle-aware routing is the heavy alternative if
  hand-tuning stops paying off.

## What was tried and rejected

- **Heuristic `channelRoute`** (route-time obstacle avoidance): replaced by
  proper dummy nodes — it fixed one case but pushed lines through other boxes.
- **Box drop shadows:** removed; the user found them invisible / not worth the
  complexity in a flat design language.
- **Shared-column snap straightening:** kept, but only helps when box x-ranges
  overlap; genuine jogs still need Brandes–Köpf (#3).

## Conventions / workflow

- `swift build` / `swift test` at repo root = CI; keep the suite green (239).
- Commit and push each unit of work to `main` (user directive; session branch
  mirror was dropped).
- The **render golden** (`Tests/QuoinRenderTests/render-digests.json`) captures
  a deterministic digest of the *attributed string*, NOT diagram pixels — so
  diagram drawing/layout changes are golden-safe. Regenerate other snapshots
  with `QUOIN_UPDATE_SNAPSHOTS=1 swift test` only when intended.
- Diagram *layout* changes can affect `RendererConformanceTests`
  (size-non-degenerate assertions) — keep sizes sane (`< 20000`).

## Research references

- Layered graph drawing (Sugiyama): https://en.wikipedia.org/wiki/Layered_graph_drawing
- dagre wiki: https://github.com/dagrejs/dagre/wiki
- Brandes–Köpf coordinate assignment: Brandes & Köpf, "Fast and Simple
  Horizontal Coordinate Assignment", GD 2001, LNCS 2265, pp. 31–44. The
  `brandesKoepfX` implementation has been cross-checked against its Alg. 1–4,
  §4.3, and Lemma 1 (the average-median separation-preservation proof).
- ELK Layered: https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html
- libavoid / Adaptagrams (orthogonal obstacle-avoiding routing, the heavier
  alternative for hand-placed nodes): http://www.adaptagrams.org/documentation/libavoid.html
