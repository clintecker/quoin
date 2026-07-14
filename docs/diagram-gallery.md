# Diagram gallery

Every diagram below is drawn by **Quoin's own native Mermaid engine** —
no Mermaid.js, no JavaScript, no network. Each type is shown in a simple
and a complex form; the images adapt to your light/dark theme. Regenerate
with `QUOIN_DIAGRAM_GALLERY=$PWD swift test --filter DiagramGalleryDocTests`.

All 30 Mermaid diagram types Quoin recognises render natively. This page
shows the original 23; the seven newer types (venn, swimlane, tree view,
event modeling, ishikawa, wardley, cynefin) are exercised in
`Fixtures/renderer/10-diagrams.md` and documented exhaustively in
[MermaidKit's repository](https://github.com/clintecker/MermaidKit).

## Flowchart

Layered placement, fan-out attachment, back-edges routed around the band.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/flowchart-simple-dark.png">
  <img alt="Flowchart — simple" src="images/diagrams/flowchart-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
flowchart LR
    A[Start] --> B{OK?}
    B -->|yes| C[Done]
    B -->|no| A
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/flowchart-complex-dark.png">
  <img alt="Flowchart — complex" src="images/diagrams/flowchart-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
flowchart TD
    Start([Start]) --> Parse[Parse markdown]
    Parse --> Ready{Ready?}
    Ready -->|yes| Render[Process input]
    Ready -->|no| Wait[Wait]
    Wait --> Ready
    Render --> Store[(Store)]
    Store --> Done([Done])
```

</details>

## Sequence

Lifelines and self-message loops.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/sequence-simple-dark.png">
  <img alt="Sequence — simple" src="images/diagrams/sequence-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
sequenceDiagram
    Alice->>Bob: Hello
    Bob-->>Alice: Hi
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/sequence-complex-dark.png">
  <img alt="Sequence — complex" src="images/diagrams/sequence-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
sequenceDiagram
    participant U as User
    participant E as Editor
    participant S as Session
    U->>E: type keystroke
    E->>S: SourceEdit(range, text)
    S->>S: reparse block
    S-->>E: RenderedDocument
    E-->>U: reprojected view
```

</details>

## Class

Compartments, orthogonal routing, ▷ ◆ ◇ markers.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/class-simple-dark.png">
  <img alt="Class — simple" src="images/diagrams/class-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
classDiagram
    Animal <|-- Dog
    class Animal {
      +String name
      +eat()
    }
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/class-complex-dark.png">
  <img alt="Class — complex" src="images/diagrams/class-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
classDiagram
    class Document {
      +String source
      +[Block] blocks
      +render() RenderedDocument
    }
    class Block {
      +BlockID id
      +ByteRange range
    }
    class Renderer
    Document "1" *-- "many" Block
    Renderer ..> Document : projects
```

</details>

## State

Composite states, choice diamonds, fork/join bars.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/state-simple-dark.png">
  <img alt="State — simple" src="images/diagrams/state-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Running: start
    Running --> [*]: stop
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/state-complex-dark.png">
  <img alt="State — complex" src="images/diagrams/state-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
stateDiagram-v2
    [*] --> Editing
    state Editing {
      [*] --> Clean
      Clean --> Dirty: keystroke
      Dirty --> Clean: autosave
    }
    Editing --> Conflict: external change
    Conflict --> Editing: resolve
    Editing --> [*]: close
```

</details>

## Entity-Relationship

Crow's-foot cardinalities, identifying relationships.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/er-simple-dark.png">
  <img alt="Entity-Relationship — simple" src="images/diagrams/er-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
erDiagram
    FOLDER ||--o{ DOCUMENT : contains
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/er-complex-dark.png">
  <img alt="Entity-Relationship — complex" src="images/diagrams/er-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
erDiagram
    LIBRARY ||--o{ FOLDER : has
    FOLDER ||--o{ DOCUMENT : contains
    DOCUMENT ||--o{ BLOCK : "parses into"
    DOCUMENT {
      string path
      string title
      int wordCount
    }
    BLOCK {
      string kind
      int byteOffset
    }
```

</details>

## Pie

Slices with a legend.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/pie-simple-dark.png">
  <img alt="Pie — simple" src="images/diagrams/pie-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
pie title Coverage
    "Native" : 23
    "Fallback" : 0
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/pie-complex-dark.png">
  <img alt="Pie — complex" src="images/diagrams/pie-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
pie showData title Time in the render pipeline
    "Parse" : 18
    "Layout" : 27
    "Typeset math" : 15
    "Draw diagrams" : 22
    "Splice" : 18
```

</details>

## Gantt

Sections, dependencies, statuses, milestones.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/gantt-simple-dark.png">
  <img alt="Gantt — simple" src="images/diagrams/gantt-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
gantt
    title Release
    section Build
    Parser :done, a1, 2026-01-01, 5d
    Renderer :active, a2, after a1, 8d
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/gantt-complex-dark.png">
  <img alt="Gantt — complex" src="images/diagrams/gantt-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
gantt
    title Renderer roadmap
    dateFormat YYYY-MM-DD
    section Engine
    Incremental render :done, r1, 2026-01-01, 6d
    Diagram routing :done, r2, after r1, 8d
    section Diagrams
    Chart types :active, d1, after r2, 10d
    Graph types :crit, d2, after d1, 6d
    section Ship
    Gallery :milestone, m1, after d2, 0d
```

</details>

## Timeline

Vertical spine, section-tinted event cards.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/timeline-simple-dark.png">
  <img alt="Timeline — simple" src="images/diagrams/timeline-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
timeline
    2004 : Markdown
    2014 : CommonMark
    2026 : Quoin
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/timeline-complex-dark.png">
  <img alt="Timeline — complex" src="images/diagrams/timeline-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
timeline
    title Markdown milestones
    2004 : Markdown introduced
         : Plain-text authoring
    2014 : CommonMark begins
    section Modern era
        2017 : GFM published
             : Tables and task lists
        2026 : Native diagrams
```

</details>

## Mindmap

Tidy horizontal tree, per-branch tints, indentation hierarchy.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/mindmap-simple-dark.png">
  <img alt="Mindmap — simple" src="images/diagrams/mindmap-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
mindmap
  root((Quoin))
    Render
    Edit
    Store
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/mindmap-complex-dark.png">
  <img alt="Mindmap — complex" src="images/diagrams/mindmap-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
mindmap
  root((Quoin))
    Rendering
      TextKit 2
      Diagrams
        Mermaid
        Math
    Editing
      Syntax reveal
      Byte-lossless
    Storage
      Plain .md files
      Local-only
```

</details>

## User Journey

Sectioned task rows, 1–5 satisfaction badges.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/journey-simple-dark.png">
  <img alt="User Journey — simple" src="images/diagrams/journey-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
journey
    title Write a note
    section Draft
      Type: 5: Me
      Fix table: 2: Me
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/journey-complex-dark.png">
  <img alt="User Journey — complex" src="images/diagrams/journey-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
journey
    title Writing a note in Quoin
    section Capture
      Quick Open: 4: Writer
      Create doc: 5: Writer
    section Draft
      Type markdown: 5: Writer
      Insert diagram: 3: Writer, Reviewer
      Fix a table: 2: Writer
    section Publish
      Export HTML: 4: Writer
      Share: 5: Writer, Reviewer
```

</details>

## Quadrant

2×2 tinted matrix with plotted points.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/quadrant-simple-dark.png">
  <img alt="Quadrant — simple" src="images/diagrams/quadrant-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
quadrantChart
    x-axis Low --> High
    y-axis Low --> High
    "Tables": [0.3, 0.7]
    "Mermaid": [0.7, 0.8]
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/quadrant-complex-dark.png">
  <img alt="Quadrant — complex" src="images/diagrams/quadrant-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
quadrantChart
    title Feature risk matrix
    x-axis Low complexity --> High complexity
    y-axis Low impact --> High impact
    quadrant-1 High leverage
    quadrant-2 Strategic bets
    quadrant-3 Easy cleanup
    quadrant-4 Yak shave
    "Tables": [0.30, 0.68]
    "Mermaid": [0.74, 0.80]
    "Footnotes": [0.44, 0.32]
    "Sanitizer": [0.70, 0.90]
```

</details>

## Packet

32-bit grid, fields wrap across rows, rotated narrow labels.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/packet-simple-dark.png">
  <img alt="Packet — simple" src="images/diagrams/packet-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
packet-beta
    0-3: "Version"
    4-15: "Length"
    16-31: "Checksum"
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/packet-complex-dark.png">
  <img alt="Packet — complex" src="images/diagrams/packet-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
packet-beta
    title TCP Header
    0-15: "Source Port"
    16-31: "Destination Port"
    32-63: "Sequence Number"
    64-95: "Acknowledgment Number"
    96-99: "Data Offset"
    100-102: "Reserved"
    103: "NS"
    104: "CWR"
    105: "ECE"
    106: "URG"
    107: "ACK"
    108: "PSH"
    109: "RST"
    110: "SYN"
    111: "FIN"
    112-127: "Window"
    128-143: "Checksum"
    144-159: "Urgent Pointer"
```

</details>

## XY Chart

Grouped bars + line series over a value axis.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/xychart-simple-dark.png">
  <img alt="XY Chart — simple" src="images/diagrams/xychart-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
xychart-beta
    x-axis [Mon, Tue, Wed]
    bar [3, 5, 2]
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/xychart-complex-dark.png">
  <img alt="XY Chart — complex" src="images/diagrams/xychart-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
xychart-beta
    title "Render time by fixture size"
    x-axis ["1 KB", "10 KB", "50 KB", "100 KB", "250 KB", "1 MB"]
    y-axis "Milliseconds" 0 --> 1200
    bar [4, 18, 82, 140, 420, 1100]
    line [3, 12, 44, 90, 210, 760]
```

</details>

## Kanban

Tinted columns, word-wrapped cards, ticket chips.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/kanban-simple-dark.png">
  <img alt="Kanban — simple" src="images/diagrams/kanban-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
kanban
    todo[To Do]
      t1[Write docs]
    done[Done]
      t2[Ship gallery]
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/kanban-complex-dark.png">
  <img alt="Kanban — complex" src="images/diagrams/kanban-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
kanban
    backlog[Backlog]
      t1[Add all Mermaid diagram families]@{ ticket: MD-101, priority: 'High' }
      t2[Add MathJax matrices]@{ ticket: MD-102 }
    doing[In Progress]
      t3[Run the visual regression diff]@{ ticket: MD-103 }
    blocked[Blocked]
      t4[Renderer lacks beta support]@{ ticket: MD-104 }
    done[Done]
      t5[CommonMark baseline]@{ ticket: MD-001 }
```

</details>

## Radar

Spoked graticule, overlaid curve polygons, legend.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/radar-simple-dark.png">
  <img alt="Radar — simple" src="images/diagrams/radar-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
radar-beta
    axis A, B, C, D
    curve x["X"]{A: 80, B: 40, C: 90, D: 60}
    max 100
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/radar-complex-dark.png">
  <img alt="Radar — complex" src="images/diagrams/radar-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
radar-beta
    title Renderer capability
    axis CM["CommonMark"], GFM["GFM"], DIA["Diagrams"], MATH["Math"], A11Y["A11y"], PERF["Perf"]
    curve baseline["Baseline"]{CM: 90, GFM: 65, DIA: 10, MATH: 5, A11Y: 55, PERF: 88}
    curve extended["Extended"]{CM: 92, GFM: 82, DIA: 74, MATH: 79, A11Y: 70, PERF: 76}
    curve aspirational["Aspirational"]{CM: 98, GFM: 95, DIA: 92, MATH: 94, A11Y: 90, PERF: 90}
    max 100
    ticks 5
```

</details>

## Treemap

Squarified nested rectangles, area ∝ value.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/treemap-simple-dark.png">
  <img alt="Treemap — simple" src="images/diagrams/treemap-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
treemap-beta
    "Docs"
        "Native": 23
        "Fallback": 0
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/treemap-complex-dark.png">
  <img alt="Treemap — complex" src="images/diagrams/treemap-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
treemap-beta
    "Markdown Fixture"
        "CommonMark": 32
        "GFM"
            "Tables": 7
            "Task Lists": 4
            "Autolinks": 3
        "Mermaid"
            "Stable": 18
            "Beta": 14
        "MathJax"
            "Inline": 5
            "Display": 8
        "Edge Cases": 12
```

</details>

## GitGraph

Commit lanes, branch/merge curves, tags.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/gitgraph-simple-dark.png">
  <img alt="GitGraph — simple" src="images/diagrams/gitgraph-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
gitGraph
    commit
    branch dev
    commit
    checkout main
    merge dev
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/gitgraph-complex-dark.png">
  <img alt="GitGraph — complex" src="images/diagrams/gitgraph-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
gitGraph
    commit id: "init"
    commit id: "commonmark"
    branch gfm
    checkout gfm
    commit id: "tables"
    commit id: "tasks"
    checkout main
    merge gfm tag: "v0.2"
    branch extensions
    checkout extensions
    commit id: "mermaid"
    commit id: "mathjax"
    checkout main
    merge extensions tag: "v0.3"
```

</details>

## Requirement

UML requirement/element boxes, verb-labelled relations.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/requirement-simple-dark.png">
  <img alt="Requirement — simple" src="images/diagrams/requirement-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
requirementDiagram
    requirement core {
      id: 1
      text: render markdown
      risk: high
      verifymethod: test
    }
    element app { type: simulation }
    app - satisfies -> core
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/requirement-complex-dark.png">
  <img alt="Requirement — complex" src="images/diagrams/requirement-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
requirementDiagram
    requirement commonmark_core {
      id: R-CORE-001
      text: Preserve CommonMark semantics.
      risk: high
      verifymethod: test
    }
    functionalRequirement gfm_tables {
      id: R-GFM-002
      text: Support GFM tables and task lists.
      risk: medium
      verifymethod: inspection
    }
    element renderer { type: simulation }
    renderer - satisfies -> commonmark_core
    gfm_tables - derives -> commonmark_core
```

</details>

## Sankey

Depth-columned flow, bands proportional to value.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/sankey-simple-dark.png">
  <img alt="Sankey — simple" src="images/diagrams/sankey-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
sankey-beta
Source,Parse,10
Parse,Render,7
Parse,Sanitize,3
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/sankey-complex-dark.png">
  <img alt="Sankey — complex" src="images/diagrams/sankey-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
sankey-beta
Source Markdown,Parse Blocks,35
Source Markdown,Parse Inline,25
Parse Blocks,GFM Extensions,12
Parse Blocks,Mermaid Render,18
Parse Inline,MathJax Typeset,16
GFM Extensions,Sanitize,10
Mermaid Render,Sanitize,15
MathJax Typeset,Sanitize,13
Sanitize,DOM Commit,30
```

</details>

## C4 Context

Person / system / external boxes, tagged relations.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/c4-simple-dark.png">
  <img alt="C4 Context — simple" src="images/diagrams/c4-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
C4Context
    Person(user, "User")
    System(app, "Quoin")
    Rel(user, app, "Edits with")
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/c4-complex-dark.png">
  <img alt="C4 Context — complex" src="images/diagrams/c4-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
C4Context
    title System Context — Internet Banking
    Person(customer, "Banking Customer", "A customer of the bank")
    System(banking, "Internet Banking", "Lets customers view accounts")
    System_Ext(email, "E-mail System", "Sendmail")
    Rel(customer, banking, "Uses")
    Rel(banking, email, "Sends mail", "SMTP")
```

</details>

## Architecture

Grouped service boxes, side-anchored edges.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/architecture-simple-dark.png">
  <img alt="Architecture — simple" src="images/diagrams/architecture-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
architecture-beta
    group app(cloud)[App]
    service ui(server)[UI] in app
    service db(database)[DB] in app
    ui:R --> L:db
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/architecture-complex-dark.png">
  <img alt="Architecture — complex" src="images/diagrams/architecture-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
architecture-beta
    group app(cloud)[Renderer Application]
    group data(database)[Local Data]
    service ui(server)[Preview UI] in app
    service worker(server)[Parser Worker] in app
    service cache(database)[Preview Cache] in data
    service files(disk)[Markdown Files] in data
    ui:R --> L:worker
    worker:B --> T:cache
    files:T --> B:worker
```

</details>

## Block

Column grid, block shapes, connectors.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/block-simple-dark.png">
  <img alt="Block — simple" src="images/diagrams/block-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
block-beta
    columns 3
    a["A"] b["B"] c["C"]
    a --> b
    b --> c
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/block-complex-dark.png">
  <img alt="Block — complex" src="images/diagrams/block-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
block-beta
    columns 4
    source["Markdown source"] parser["Parser"] ast(("AST")) planner["Render planner"]
    mermaid["Mermaid"] mathjax["MathJax"] html["HTML"] css["CSS"]
    source --> parser
    parser --> ast
    ast --> planner
    planner --> mermaid
    planner --> mathjax
```

</details>

## ZenUML

UML sequence from the alternate zenuml syntax.

**Simple**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/zenuml-simple-dark.png">
  <img alt="ZenUML — simple" src="images/diagrams/zenuml-simple.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
zenuml
    Client->Server.get()
    Server->Client: 200 OK
```

</details>

**Complex**

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="images/diagrams/zenuml-complex-dark.png">
  <img alt="ZenUML — complex" src="images/diagrams/zenuml-complex.png" height="200">
</picture>

<details><summary>Source</summary>

```mermaid
zenuml
    title Order Service
    @Actor Client
    Client->OrderService.create()
    OrderService->DB.save()
    DB->OrderService: ok
    OrderService->Client: created
```

</details>
