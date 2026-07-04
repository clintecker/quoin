import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Class, ER, and state diagram engines — the "layered boxes" family. They
/// share layeredPlacement (cycle-safe longest-path layering) and
/// routeBoxEdges (orthogonal fan-out routing) from DiagramLayout.swift.
extension DiagramLayoutEngine {

    // MARK: Class

    static let compartmentNameHeight: CGFloat = 26
    static let compartmentRowHeight: CGFloat = 17
    static let compartmentPadX: CGFloat = 12

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

        let placement = layeredPlacement(
            ids: diagram.classes.map(\.name),
            sizes: boxSizes,
            edges: layeringEdges,
            layerGap: 52, nodeGap: 30, margin: 14
        )

        let boxes = diagram.classes.compactMap { cls -> ClassLayout.Box? in
            guard let frame = placement.frames[cls.name] else { return nil }
            return ClassLayout.Box(
                name: cls.name, attributes: cls.attributes, methods: cls.methods,
                frame: frame, nameHeight: compartmentNameHeight, rowHeight: compartmentRowHeight
            )
        }

        // Route relations as orthogonal elbows with per-face fan-out, sharing
        // the layered-box router with the ER diagram.
        let valid = diagram.relations.filter {
            placement.frames[$0.from] != nil && placement.frames[$0.to] != nil
        }
        var frameList: [CGRect] = []
        var frameIndex: [String: Int] = [:]
        for cls in diagram.classes {
            guard let frame = placement.frames[cls.name] else { continue }
            frameIndex[cls.name] = frameList.count
            frameList.append(frame)
        }
        let pairs = valid.map { (from: frameIndex[$0.from]!, to: frameIndex[$0.to]!) }
        let routes = routeBoxEdges(frames: frameList, pairs: pairs)
        let edges = zip(valid, routes).map { relation, route in
            ClassLayout.Edge(
                start: route.points.first!,
                end: route.points.last!,
                points: route.points,
                kind: relation.kind,
                label: relation.label
            )
        }

        return ClassLayout(size: placement.size, boxes: boxes, edges: edges)
    }

    // MARK: ER

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

        let placement = layeredPlacement(
            ids: diagram.entities.map(\.name),
            sizes: boxSizes,
            // Tighter vertical gap: the crow's-foot markers reach ~21pt off
            // each box, so 52 leaves room for them plus the relationship label
            // without the loose air the old 64 left.
            edges: diagram.relations.map { ($0.from, $0.to) },
            layerGap: 52, nodeGap: 30, margin: 14
        )

        let boxes = diagram.entities.compactMap { entity -> ERLayout.Box? in
            guard let frame = placement.frames[entity.name] else { return nil }
            return ERLayout.Box(
                name: entity.name, attributes: entity.attributes,
                frame: frame, nameHeight: compartmentNameHeight, rowHeight: compartmentRowHeight
            )
        }

        let valid = diagram.relations.filter {
            placement.frames[$0.from] != nil && placement.frames[$0.to] != nil
        }
        var frameList: [CGRect] = []
        var frameIndex: [String: Int] = [:]
        for entity in diagram.entities {
            guard let frame = placement.frames[entity.name] else { continue }
            frameIndex[entity.name] = frameList.count
            frameList.append(frame)
        }
        let pairs = valid.map { (from: frameIndex[$0.from]!, to: frameIndex[$0.to]!) }
        let routes = routeBoxEdges(frames: frameList, pairs: pairs)
        let edges = zip(valid, routes).map { relation, route in
            ERLayout.Edge(
                start: route.points.first!,
                end: route.points.last!,
                points: route.points,
                fromCard: relation.fromCard,
                toCard: relation.toCard,
                label: relation.label,
                identifying: relation.identifying
            )
        }

        return ERLayout(size: placement.size, boxes: boxes, edges: edges)
    }

    // MARK: State

    static let stateTitleHeight: CGFloat = 22
    static let stateInset: CGFloat = 14

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

        let placement = layeredPlacement(
            ids: diagram.nodes.map(\.id),
            sizes: sizes,
            edges: diagram.edges.map { ($0.from, $0.to) },
            layerGap: 40, nodeGap: 26, margin: 6
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
            guard let frame = placement.frames[node.id] else { continue }
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

        // Route this scope's own transitions with the shared fan-out router.
        var frameList: [CGRect] = []
        var frameIndex: [String: Int] = [:]
        for node in diagram.nodes {
            guard let frame = placement.frames[node.id] else { continue }
            frameIndex[node.id] = frameList.count
            frameList.append(frame)
        }
        let valid = diagram.edges.filter { frameIndex[$0.from] != nil && frameIndex[$0.to] != nil }
        let pairs = valid.map { (from: frameIndex[$0.from]!, to: frameIndex[$0.to]!) }
        let routes = routeBoxEdges(frames: frameList, pairs: pairs)
        for (edge, route) in zip(valid, routes) {
            outEdges.append(StateLayout.Edge(
                start: route.points.first!, end: route.points.last!,
                points: route.points, label: edge.label
            ))
        }

        return StateScopeResult(
            nodes: outNodes, containers: outContainers,
            edges: outEdges, size: placement.size
        )
    }

}
