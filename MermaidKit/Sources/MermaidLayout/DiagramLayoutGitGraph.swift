import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramLayoutEngine {

    /// Lays out a git graph left-to-right: commits advance along x in history
    /// order, each branch occupies a horizontal lane, and edges connect every
    /// commit to its parents (a curve when it crosses lanes — a branch point or
    /// a merge). Pure geometry — the renderer only draws.
    public static func layout(_ graph: GitGraph, measure: DiagramTextMeasurer) -> GitGraphLayout {
        let margin: CGFloat = 14
        let commitGap: CGFloat = 46
        let laneGap: CGFloat = 46
        let dotRadius: CGFloat = 7

        // Lane label gutter sized to the widest branch name.
        let labelWidth = graph.branches.map { measure($0, labelFontSize).width }.max() ?? 40
        let gutter = margin + min(max(labelWidth, 30), 120) + 10
        let topMargin = margin + 14   // room for a tag above the first lane

        func lane(_ branch: String) -> Int { graph.branches.firstIndex(of: branch) ?? 0 }
        func x(_ order: Int) -> CGFloat { gutter + CGFloat(order) * commitGap + commitGap / 2 }
        func y(_ branch: String) -> CGFloat { topMargin + CGFloat(lane(branch)) * laneGap }

        var commits: [GitGraphLayout.Commit] = []
        for (order, commit) in graph.commits.enumerated() {
            commits.append(GitGraphLayout.Commit(
                center: CGPoint(x: x(order), y: y(commit.branch)),
                colorIndex: lane(commit.branch),
                id: commit.id, tag: commit.tag, isMerge: commit.isMerge))
        }

        // Edges from each commit to its parents, coloured by the child's lane.
        //
        // A same-lane edge is a straight horizontal run. A cross-lane edge (a
        // branch point or a merge) must NOT be drawn as a naive diagonal: that
        // line cuts straight through any commit dot sitting in an intermediate
        // lane at the midpoint column (e.g. the develop→feature/search branch
        // passing through feature/auth's dot). Instead we route it orthogonally
        // with a single right-angle corner, splitting the edge into two
        // collinear legs. Emitting them separately keeps the drawn path
        // identical to the geometry the linter checks: the renderer strokes a
        // same-y leg straight, and its cross-lane curve collapses to a straight
        // line when the two endpoints share an x.
        //
        // Two corner placements are possible; both keep the VERTICAL leg on a
        // commit's own (unique, otherwise-empty) column, so the only occlusion
        // risk is the HORIZONTAL leg running along an occupied lane:
        //   • source route — turn at the PARENT's column: vertical along the
        //     parent's column, then horizontal along the CHILD's lane. Preferred
        //     (a branch visibly leaves its source), and only its final leg lands
        //     on the child's column.
        //   • dest route — turn at the CHILD's column: horizontal along the
        //     PARENT's lane, then vertical up the child's column.
        // Prefer the source route; fall back to the dest route only when the
        // source route's horizontal leg (along the child's lane) would pass over
        // an intervening commit — e.g. a merge landing on a lane that has commits
        // between the two endpoints.
        func laneIsClear(betweenX ax: CGFloat, _ bx: CGFloat, onLaneY laneY: CGFloat) -> Bool {
            let lo = min(ax, bx), hi = max(ax, bx)
            for c in commits where abs(c.center.y - laneY) < 1 {
                if c.center.x > lo + 0.5 && c.center.x < hi - 0.5 { return false }
            }
            return true
        }

        var edges: [GitGraphLayout.Edge] = []
        for (order, commit) in graph.commits.enumerated() {
            let color = lane(commit.branch)
            for parent in commit.parents where parent < commits.count {
                let from = commits[parent].center
                let to = commits[order].center
                if abs(from.y - to.y) < 0.5 {
                    edges.append(GitGraphLayout.Edge(from: from, to: to, colorIndex: color))
                    continue
                }
                // Source route corners at (from.x, to.y); its horizontal leg
                // runs along the child's lane from from.x to to.x.
                let corner = laneIsClear(betweenX: from.x, to.x, onLaneY: to.y)
                    ? CGPoint(x: from.x, y: to.y)   // source route
                    : CGPoint(x: to.x, y: from.y)   // dest route
                edges.append(GitGraphLayout.Edge(from: from, to: corner, colorIndex: color))
                edges.append(GitGraphLayout.Edge(from: corner, to: to, colorIndex: color))
            }
        }

        let laneLabels = graph.branches.enumerated().map { index, name in
            GitGraphLayout.LaneLabel(
                name: name,
                point: CGPoint(x: margin, y: topMargin + CGFloat(index) * laneGap),
                colorIndex: index)
        }

        let width = x(max(graph.commits.count - 1, 0)) + commitGap / 2 + margin
        let height = topMargin + CGFloat(max(graph.branches.count - 1, 0)) * laneGap + dotRadius + 22 + margin
        return GitGraphLayout(
            size: CGSize(width: width, height: height),
            commits: commits,
            edges: edges,
            laneLabels: laneLabels
        )
    }
}
