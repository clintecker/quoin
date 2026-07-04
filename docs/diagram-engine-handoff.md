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
  - Layout result structs: `FlowchartLayout`, `SequenceLayout`, `PieLayout`,
    `ClassLayout`, `ERLayout`, `StateLayout`, `GanttLayout`.
    `FlowchartLayout.PlacedEdge` carries a `labelPoint`.
  - **DEAD CODE to remove**: `Placement`, `orderedLayers`, `layeredPlacement`,
    `BoxFace`, `RoutedBoxEdge`, `routeBoxEdges`, `borderPoint` — all now unused
    (every caller moved to `assignLayers`/`barycenterOrder`/`layeredRoutes`).
- `Sources/QuoinCore/DiagramLayoutFlowchart.swift` — flowchart layout:
  `layout(_:)` runs assignLayers → insert dummy nodes for multi-layer edges →
  barycenterOrder → `placeFlowchartFrames` → `routeChains`. `placeEdgeLabels`
  scores label positions vs. node frames + other labels. `routePolyline`,
  `simplifyCollinear`, `dummyBreadth`.
- `Sources/QuoinCore/DiagramLayoutBoxDiagrams.swift` — class / ER / state
  layouts. All three call `layeredRoutes`. State recurses for composite scopes.
- `Sources/QuoinRender/DiagramRenderer.swift` — CoreGraphics drawing:
  - `attachmentString` — rasterizes a layout into a **padded** canvas (pad=10)
    and caches by source+appearance.
  - per-type `draw(_ layout:…)` for flowchart/sequence/pie/class/ER/state/gantt.
  - `strokeEdgeShafts` — batches shafts by dash style, one composite stroke, so
    crossings don't stack translucent alpha into dark seams.
  - `appendRoundedPolyline` — rounds each bend with `addArc(…, radius: 5)`
    (**artifact source**, see below).
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
- **Anti-clipping:** uniform padded canvas; labels clamped to bounds.
- 239 tests green throughout; commit + push to `main` per unit of work.

## Open problems (CURRENT — all visible in the latest gallery renders; NOT fixed)

These are live defects in `er-complex`, `state-complex`, etc. Verify each with
the gallery harness before and after any change.

1. **Rounded-corner artifact (the "odd artifact on a routed-around line").**
   `appendRoundedPolyline` rounds every bend with a fixed radius-5 arc
   (`addArc(tangent1End:tangent2End:radius:5)`). When a jog's middle segment is
   shorter than ~2×radius, the two arcs overlap and pinch into a cusp/notch.
   Most visible on edges that jog to reach a **centered box between two
   columns** — e.g. `ORDER→LINE_ITEM` and `PRODUCT→LINE_ITEM` in `er-complex`,
   which must jog inward. The column-snap straightening does NOT help these
   (the boxes' x-ranges don't overlap). → **Fix:** clamp each corner's radius to
   `min(5, halfOfShorterAdjacentSegment)`; and/or reduce short jogs upstream via
   Brandes–Köpf (#3).
2. **Antiparallel-edge label crowding.** Two edges between the same pair of
   boxes in opposite directions (Idle→Connecting "connect" and
   Connecting→Idle "fail") put both label midpoints in the same gap; the labels
   land side-by-side and read as one phrase ("connect fail"), and can crowd a
   nearby channel edge (the "disconnect" line). → **Fix:** detect
   antiparallel/sibling edges and bias their labels to opposite sides, or offset
   labels a fixed fraction along the edge instead of at the midpoint; stronger
   inter-label repulsion in `labelAnchor`.
3. **Cardinality / relation markers clip, and connectors can clip.** ER
   crow's-foot / tick / circle markers (`drawCardinality`) reach ~15–18pt off a
   box border; UML markers (`drawRelationMarker`) reach ~14pt. The layout `size`
   and the uniform pad=10 don't always cover a marker on a box near the canvas
   edge, or a connector segment routed to the boundary — so markers/connectors
   clip (e.g. the markers at `LINE_ITEM`'s top edge). → **Fix:** include marker
   reach and route extents in the content bounds (#4), or raise the pad, but the
   real fix is tight bounds.
4. **Bounds via uniform pad, not tight bbox.** pad=10 in `attachmentString`;
   layouts don't account for renderer-side marker/label extents. → **Fix:**
   compute the true bounding box of everything drawn (boxes + route points +
   marker reach + label rects) and size/translate the canvas to it. This
   subsumes #3.
5. **Coordinate assignment is center-then-snap, not Brandes–Köpf.** Layers are
   centered independently, then near-aligned edges are snapped straight. This
   leaves avoidable jogs (which feed artifact #1) and looser layouts.
   → **Fix (biggest quality lever):** implement Brandes–Köpf horizontal
   coordinate assignment (linear time, ≤2 bends/edge, aligns dummy chains into
   straight runs). Paper: arXiv:2008.01252. dagre uses exactly this.
6. **Dead code** in DiagramLayout.swift (list above) should be removed.

### Suggested order of attack
Quick wins first: (1) clamp arc radius — kills the artifact immediately; (4)
tight bounds — kills marker/connector clipping (#3) too. Then the big lever:
(5) Brandes–Köpf, which straightens layouts and removes most jogs so #1/#2
largely disappear. Then (2) label spreading polish, (6) dead-code cleanup.

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
- Brandes–Köpf coordinate assignment: https://arxiv.org/pdf/2008.01252
- ELK Layered: https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html
- libavoid / Adaptagrams (orthogonal obstacle-avoiding routing, the heavier
  alternative for hand-placed nodes): http://www.adaptagrams.org/documentation/libavoid.html
