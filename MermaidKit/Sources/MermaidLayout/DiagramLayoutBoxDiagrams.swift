import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Class, ER, and state diagram engines — the "layered boxes" family. They
/// share `layeredRoutes` (cycle-safe longest-path layering with dummy-node
/// channel routing) from DiagramLayout.swift.
extension DiagramLayoutEngine {

    // MARK: Class

    static let compartmentNameHeight: CGFloat = 26
    static let compartmentRowHeight: CGFloat = 17
    static let compartmentPadX: CGFloat = 12

    /// Lays out a class diagram: boxes sized to their name/member rows,
    /// layered so parents sit above children (inheritance/realization edges
    /// are flipped for layering only; relations route in their real
    /// direction so markers land on the parent), routed via `layeredRoutes`.
    /// Pure geometry — the renderer only draws.
    public static func layout(_ diagram: ClassDiagram, measure: DiagramTextMeasurer) -> ClassLayout {
        // Layer by the relation graph so hierarchies read top-down: for
        // inheritance/realization the parsed edge points child → parent;
        // flip those so parents sit above their children.
        let layeringEdges: [(String, String)] = diagram.relations.map { relation in
            switch relation.kind {
            case .inheritance, .realization: return (relation.to, relation.from)
            default: return (relation.from, relation.to)
            }
        }

        var boxSizes: [String: CGSize] = [:]
        for cls in diagram.classes {
            let members = cls.attributes + cls.methods
            var width = measure(cls.name, nodeFontSize).width + compartmentPadX * 2 + 8
            for member in members {
                width = max(width, measure(member, labelFontSize).width + compartmentPadX * 2)
            }
            var height = compartmentNameHeight
            if !cls.attributes.isEmpty { height += 5 + CGFloat(cls.attributes.count) * compartmentRowHeight }
            if !cls.methods.isEmpty { height += 5 + CGFloat(cls.methods.count) * compartmentRowHeight }
            if members.isEmpty { height += 6 } // a sliver of empty body
            boxSizes[cls.name] = CGSize(width: max(width, 96), height: height)
        }

        // Dummy-node layered layout + routing (parents above children via the
        // flipped layering edges; relations routed in their real direction so
        // the inheritance marker lands on the parent).
        let (frames, size, routes) = layeredRoutes(
            ids: diagram.classes.map(\.name),
            sizes: boxSizes,
            layeringEdges: layeringEdges,
            routingEdges: diagram.relations.map { (from: $0.from, to: $0.to) },
            layerGap: 66, nodeGap: 30, margin: 14
        )

        let boxes = diagram.classes.compactMap { cls -> ClassLayout.Box? in
            guard let frame = frames[cls.name] else { return nil }
            return ClassLayout.Box(
                name: cls.name, attributes: cls.attributes, methods: cls.methods,
                frame: frame, nameHeight: compartmentNameHeight, rowHeight: compartmentRowHeight
            )
        }

        let edges = zip(diagram.relations, routes).compactMap { relation, points -> ClassLayout.Edge? in
            guard points.count >= 2, frames[relation.from] != nil, frames[relation.to] != nil else { return nil }
            return ClassLayout.Edge(
                start: points.first!, end: points.last!, points: points,
                kind: relation.kind, label: relation.label
            )
        }

        return ClassLayout(size: size, boxes: boxes, edges: edges)
    }

    // MARK: ER

    /// Lays out an ER diagram: entity boxes sized to their attribute rows,
    /// layered by relation direction and routed via `layeredRoutes`, with the
    /// canvas grown so route-midpoint relationship labels never clip. Pure
    /// geometry — the renderer only draws.
    public static func layout(_ diagram: ERDiagram, measure: DiagramTextMeasurer) -> ERLayout {
        var boxSizes: [String: CGSize] = [:]
        for entity in diagram.entities {
            var width = measure(entity.name, nodeFontSize).width + compartmentPadX * 2 + 8
            for attribute in entity.attributes {
                let row = "\(attribute.type)  \(attribute.name)"
                width = max(width, measure(row, labelFontSize).width + compartmentPadX * 2)
            }
            var height = compartmentNameHeight
            if !entity.attributes.isEmpty {
                height += 5 + CGFloat(entity.attributes.count) * compartmentRowHeight
            }
            boxSizes[entity.name] = CGSize(width: max(width, 96), height: height)
        }

        // Tighter vertical gap (52): the crow's-foot markers reach ~21pt off
        // each box, so this leaves room for them plus the relationship label.
        let (frames, size, routes) = layeredRoutes(
            ids: diagram.entities.map(\.name),
            sizes: boxSizes,
            layeringEdges: diagram.relations.map { ($0.from, $0.to) },
            routingEdges: diagram.relations.map { (from: $0.from, to: $0.to) },
            layerGap: 66, nodeGap: 30, margin: 14
        )

        let boxes = diagram.entities.compactMap { entity -> ERLayout.Box? in
            guard let frame = frames[entity.name] else { return nil }
            return ERLayout.Box(
                name: entity.name, attributes: entity.attributes,
                frame: frame, nameHeight: compartmentNameHeight, rowHeight: compartmentRowHeight
            )
        }

        let edges = zip(diagram.relations, routes).compactMap { relation, points -> ERLayout.Edge? in
            guard points.count >= 2, frames[relation.from] != nil, frames[relation.to] != nil else { return nil }
            return ERLayout.Edge(
                start: points.first!, end: points.last!, points: points,
                fromCard: relation.fromCard, toCard: relation.toCard,
                label: relation.label, identifying: relation.identifying
            )
        }

        // Grow the canvas to fit edge labels sitting at each route's midpoint —
        // a self-loop's label rides outside the rightmost box and would clip.
        var canvas = size
        for edge in edges where !edge.label.isEmpty {
            let mid = DiagramScene.polylineMidpoint(edge.points)
            let w = measure(edge.label, labelFontSize).width
            canvas.width = max(canvas.width, mid.x + w / 2 + 8)
            canvas.height = max(canvas.height, mid.y + labelFontSize + 8)
        }
        return ERLayout(size: canvas, boxes: boxes, edges: edges)
    }


    // MARK: State

    static let stateTitleHeight: CGFloat = 22
    static let stateInset: CGFloat = 14

    /// Lays out a state diagram, recursing into composite states (each is
    /// laid out first and becomes a fixed-size box in its parent's layered
    /// layout) and flattening everything into absolute coordinates. Pure
    /// geometry — the renderer only draws.
    public static func layout(_ diagram: StateDiagram, measure: DiagramTextMeasurer) -> StateLayout {
        let result = layoutStateScope(diagram, depth: 0, measure: measure)
        return StateLayout(
            size: result.size, nodes: result.nodes,
            containers: result.containers, edges: result.edges
        )
    }

    private struct StateScopeResult {
        var nodes: [StateLayout.Node]
        var containers: [StateLayout.Container]
        var edges: [StateLayout.Edge]
        var size: CGSize
    }

    /// Lays out one state scope, recursing into composites first so each one
    /// becomes a fixed-size box in its parent's layout. Interior placements
    /// are offset into the composite's frame, so the whole thing is flattened
    /// into absolute coordinates for the renderer.
    private static func layoutStateScope(
        _ diagram: StateDiagram, depth: Int, measure: DiagramTextMeasurer
    ) -> StateScopeResult {
        var sizes: [String: CGSize] = [:]
        var childResults: [String: StateScopeResult] = [:]

        for node in diagram.nodes {
            switch node.kind {
            case .composite(let sub):
                let child = layoutStateScope(sub, depth: depth + 1, measure: measure)
                childResults[node.id] = child
                let titleWidth = measure(node.label, nodeFontSize).width + 28
                let width = max(child.size.width + stateInset * 2, titleWidth, 96)
                let height = child.size.height + stateInset * 2 + stateTitleHeight
                sizes[node.id] = CGSize(width: width, height: height)
            case .start:
                sizes[node.id] = CGSize(width: 14, height: 14)
            case .end:
                sizes[node.id] = CGSize(width: 18, height: 18)
            case .choice:
                sizes[node.id] = CGSize(width: 26, height: 26)
            case .fork, .join:
                sizes[node.id] = CGSize(width: 64, height: 10)
            case .simple:
                let text = measure(node.label, nodeFontSize)
                sizes[node.id] = CGSize(width: max(text.width + 28, 56), height: text.height + 18)
            }
        }

        let (frames, scopeSize, routes) = layeredRoutes(
            ids: diagram.nodes.map(\.id),
            sizes: sizes,
            layeringEdges: diagram.edges.map { ($0.from, $0.to) },
            routingEdges: diagram.edges.map { (from: $0.from, to: $0.to) },
            layerGap: 54, nodeGap: 26, margin: 6
        )

        var outNodes: [StateLayout.Node] = []
        var outContainers: [StateLayout.Container] = []
        var outEdges: [StateLayout.Edge] = []

        func mapKind(_ kind: StateDiagram.Kind) -> StateLayout.NodeKind {
            switch kind {
            case .simple, .composite: return .simple
            case .start: return .start
            case .end: return .end
            case .choice: return .choice
            case .fork: return .fork
            case .join: return .join
            }
        }

        for node in diagram.nodes {
            guard let frame = frames[node.id] else { continue }
            if case .composite = node.kind, let child = childResults[node.id] {
                outContainers.append(StateLayout.Container(
                    label: node.label, frame: frame,
                    titleHeight: stateTitleHeight, depth: depth
                ))
                let dx = frame.minX + stateInset
                let dy = frame.minY + stateTitleHeight + stateInset
                for n in child.nodes {
                    outNodes.append(StateLayout.Node(
                        id: n.id, label: n.label, kind: n.kind,
                        frame: n.frame.offsetBy(dx: dx, dy: dy)
                    ))
                }
                for c in child.containers {
                    outContainers.append(StateLayout.Container(
                        label: c.label, frame: c.frame.offsetBy(dx: dx, dy: dy),
                        titleHeight: c.titleHeight, depth: c.depth
                    ))
                }
                for e in child.edges {
                    outEdges.append(StateLayout.Edge(
                        start: CGPoint(x: e.start.x + dx, y: e.start.y + dy),
                        end: CGPoint(x: e.end.x + dx, y: e.end.y + dy),
                        points: e.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) },
                        label: e.label
                    ))
                }
            } else {
                outNodes.append(StateLayout.Node(
                    id: node.id, label: node.label,
                    kind: mapKind(node.kind), frame: frame
                ))
            }
        }

        // This scope's own transitions, routed through their dummy-node chains.
        for (edge, points) in zip(diagram.edges, routes) {
            guard points.count >= 2, frames[edge.from] != nil, frames[edge.to] != nil else { continue }
            outEdges.append(StateLayout.Edge(
                start: points.first!, end: points.last!, points: points, label: edge.label
            ))
        }

        return StateScopeResult(
            nodes: outNodes, containers: outContainers,
            edges: outEdges, size: scopeSize
        )
    }

}
