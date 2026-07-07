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
        var edges: [GitGraphLayout.Edge] = []
        for (order, commit) in graph.commits.enumerated() {
            for parent in commit.parents where parent < commits.count {
                edges.append(GitGraphLayout.Edge(
                    from: commits[parent].center,
                    to: commits[order].center,
                    colorIndex: lane(commit.branch)))
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
