import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A platform-free, LLM/computer-readable description of what a laid-out
/// diagram *is* — its boxes, its edge routes, and its free-standing labels —
/// independent of how it's painted. Every diagram type lowers to a
/// `DiagramScene`; the `DiagramLayoutLinter` then reasons over the geometry to
/// find layout problems (edges behind nodes, overlaps, clipping) exactly,
/// where staring at a rendered PNG is unreliable.
public struct DiagramScene: Sendable, Codable {
    public struct Node: Sendable, Codable {
        public let id: String
        public let frame: CGRect
        /// A group / subgraph / composite container legitimately *contains*
        /// other nodes, so it is exempt from overlap and occlusion checks.
        public let isContainer: Bool
        public init(id: String, frame: CGRect, isContainer: Bool = false) {
            self.id = id
            self.frame = frame
            self.isContainer = isContainer
        }
    }

    public struct Edge: Sendable, Codable {
        /// The routed polyline, endpoint to endpoint.
        public let polyline: [CGPoint]
        public let label: String?
        public init(polyline: [CGPoint], label: String? = nil) {
            self.polyline = polyline
            self.label = label
        }
    }

    /// A *free-standing* label only — an edge label, axis label, legend entry,
    /// section title. A node's own centred label is implicit in its Node and
    /// must NOT be listed here (it can never "collide" with its own box).
    public struct Label: Sendable, Codable {
        public let text: String
        public let frame: CGRect
        public init(text: String, frame: CGRect) {
            self.text = text
            self.frame = frame
        }
    }

    public let name: String
    public let size: CGSize
    public let nodes: [Node]
    public let edges: [Edge]
    public let labels: [Label]

    public init(name: String, size: CGSize, nodes: [Node],
                edges: [Edge] = [], labels: [Label] = []) {
        self.name = name
        self.size = size
        self.nodes = nodes
        self.edges = edges
        self.labels = labels
    }
}

public struct LayoutViolation: Sendable, Equatable {
    public enum Severity: String, Sendable { case error, warning }
    public let severity: Severity
    public let kind: String
    public let detail: String
    public init(_ severity: Severity, _ kind: String, _ detail: String) {
        self.severity = severity
        self.kind = kind
        self.detail = detail
    }
}

/// Checks a `DiagramScene` against invariants of good layout. Errors are
/// unambiguous geometric defects (a line through a box, overlapping boxes,
/// clipped content); warnings are quality smells (colliding labels, crossings,
/// cramped spacing).
public enum DiagramLayoutLinter {

    public static func lint(_ scene: DiagramScene) -> [LayoutViolation] {
        var out: [LayoutViolation] = []
        let occlusionInset: CGFloat = 3
        let overlapTolerance: CGFloat = 2

        // 1. Edge–node occlusion: a segment crossing a node that isn't its
        //    endpoint and isn't a container.
        for (ei, edge) in scene.edges.enumerated() {
            let segs = Array(zip(edge.polyline, edge.polyline.dropFirst()))
            for node in scene.nodes where !node.isContainer && !isEndpoint(node, of: edge) {
                let inner = node.frame.insetBy(dx: occlusionInset, dy: occlusionInset)
                guard inner.width > 0, inner.height > 0 else { continue }
                if segs.contains(where: { segmentIntersectsRect($0.0, $0.1, inner) }) {
                    out.append(.init(.error, "edge-occludes-node",
                        "edge #\(ei)\(edge.label.map { " (\"\($0)\")" } ?? "") passes through node \"\(node.id)\""))
                }
            }
        }

        // 2. Node–node overlap (excluding intentional containment).
        let boxes = scene.nodes.filter { !$0.isContainer }
        for i in boxes.indices {
            for j in boxes.indices where j > i {
                let a = boxes[i].frame, b = boxes[j].frame
                let ov = a.intersection(b)
                if !ov.isNull, ov.width > overlapTolerance, ov.height > overlapTolerance,
                   !a.contains(b), !b.contains(a) {
                    out.append(.init(.error, "nodes-overlap",
                        "\"\(boxes[i].id)\" and \"\(boxes[j].id)\" overlap by \(Int(ov.width))×\(Int(ov.height))pt"))
                }
            }
        }

        // 3. Off-canvas content.
        let canvas = CGRect(origin: .zero, size: scene.size).insetBy(dx: -1, dy: -1)
        for node in scene.nodes where !canvas.contains(node.frame) {
            out.append(.init(.error, "off-canvas", "node \"\(node.id)\" extends outside the canvas"))
        }
        for label in scene.labels where !canvas.contains(label.frame) {
            out.append(.init(.error, "off-canvas", "label \"\(label.text)\" extends outside the canvas"))
        }

        // 4. Label collisions (warnings): label vs label, and label vs a node.
        for i in scene.labels.indices {
            for j in scene.labels.indices where j > i {
                if overlapArea(scene.labels[i].frame, scene.labels[j].frame) > 4 {
                    out.append(.init(.warning, "labels-overlap",
                        "labels \"\(scene.labels[i].text)\" and \"\(scene.labels[j].text)\" overlap"))
                }
            }
            for node in boxes {
                let a = scene.labels[i].frame
                if overlapArea(a, node.frame) > 0.5 * a.width * a.height {
                    out.append(.init(.warning, "label-over-node",
                        "label \"\(scene.labels[i].text)\" sits on node \"\(node.id)\""))
                }
            }
        }

        // 5. Marks escaping the plot: when a container bounds the data region
        //    (a chart plot covering most of the canvas), no edge may leave it —
        //    catches a line/series running off the chart.
        if let plot = scene.nodes.filter({ $0.isContainer })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
           plot.frame.width * plot.frame.height > 0.35 * scene.size.width * scene.size.height {
            let bounds = plot.frame.insetBy(dx: -2, dy: -2)
            for (ei, edge) in scene.edges.enumerated() where edge.polyline.contains(where: { !bounds.contains($0) }) {
                out.append(.init(.error, "mark-escapes-plot", "edge #\(ei) runs outside the plot area"))
            }
        }

        // 6. Edge crossings (warning) beyond a modest budget.
        var crossings = 0
        for i in scene.edges.indices {
            for j in scene.edges.indices where j > i {
                if edgesCross(scene.edges[i], scene.edges[j]) { crossings += 1 }
            }
        }
        let budget = max(2, scene.edges.count / 3)
        if crossings > budget {
            out.append(.init(.warning, "edge-crossings", "\(crossings) edge crossings (budget \(budget))"))
        }

        // Dedup while preserving order.
        var seen = Set<String>()
        return out.filter { seen.insert($0.severity.rawValue + $0.kind + $0.detail).inserted }
    }

    /// A one-line-per-violation report, or a clean bill.
    public static func report(_ scene: DiagramScene) -> String {
        let v = lint(scene)
        let header = "\(scene.name): \(scene.nodes.count) nodes, \(scene.edges.count) edges, \(scene.labels.count) labels"
        guard !v.isEmpty else { return "\(header)\n  ✓ clean" }
        let errors = v.filter { $0.severity == .error }.count
        let warns = v.filter { $0.severity == .warning }.count
        let lines = v.map { "  \($0.severity == .error ? "✗" : "⚠") [\($0.kind)] \($0.detail)" }
        return "\(header)  (\(errors) errors, \(warns) warnings)\n" + lines.joined(separator: "\n")
    }

    // MARK: - Geometry

    static func isEndpoint(_ node: DiagramScene.Node, of edge: DiagramScene.Edge, margin: CGFloat = 6) -> Bool {
        guard let first = edge.polyline.first, let last = edge.polyline.last else { return false }
        let padded = node.frame.insetBy(dx: -margin, dy: -margin)
        return padded.contains(first) || padded.contains(last)
    }

    static func segmentsCross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
        }
        let o1 = cross(a, b, c), o2 = cross(a, b, d), o3 = cross(c, d, a), o4 = cross(c, d, b)
        return (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0)
    }

    static func segmentIntersectsRect(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> Bool {
        if r.contains(a) || r.contains(b) { return true }
        let tl = CGPoint(x: r.minX, y: r.minY), tr = CGPoint(x: r.maxX, y: r.minY)
        let bl = CGPoint(x: r.minX, y: r.maxY), br = CGPoint(x: r.maxX, y: r.maxY)
        return segmentsCross(a, b, tl, tr) || segmentsCross(a, b, tr, br)
            || segmentsCross(a, b, br, bl) || segmentsCross(a, b, bl, tl)
    }

    static func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let ov = a.intersection(b)
        return ov.isNull ? 0 : ov.width * ov.height
    }

    static func edgesCross(_ e1: DiagramScene.Edge, _ e2: DiagramScene.Edge) -> Bool {
        for s1 in zip(e1.polyline, e1.polyline.dropFirst()) {
            for s2 in zip(e2.polyline, e2.polyline.dropFirst()) {
                if segmentsCross(s1.0, s1.1, s2.0, s2.1) { return true }
            }
        }
        return false
    }
}
