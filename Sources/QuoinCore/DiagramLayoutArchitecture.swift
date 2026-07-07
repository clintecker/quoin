import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Geometry for an architecture diagram: service boxes packed into a grid
/// inside each tinted group container, top-level services in a borderless
/// cluster, and orthogonal wires routed between named sides. Pure geometry.
public struct ArchitectureLayout: Sendable {

    public struct ServiceBox: Sendable {
        public let frame: CGRect
        public let label: String
        public let icon: String
        public let isJunction: Bool
        /// Palette slot of the owning group (for a subtle tint).
        public let colorIndex: Int
    }

    public struct GroupBox: Sendable {
        public let frame: CGRect
        /// Header baseline anchor (left edge, vertical center of the title row).
        public let titleOrigin: CGPoint
        public let label: String
        public let icon: String
        public let colorIndex: Int
    }

    public struct Edge: Sendable {
        /// Orthogonal polyline, border anchor to border anchor.
        public let points: [CGPoint]
        public let arrow: Bool
    }

    public let size: CGSize
    public let groups: [GroupBox]
    public let services: [ServiceBox]
    public let edges: [Edge]
}

extension DiagramLayoutEngine {

    public static func layout(_ diagram: ArchitectureDiagram, measure: DiagramTextMeasurer) -> ArchitectureLayout {
        let margin: CGFloat = 16
        let groupGap: CGFloat = 24
        let groupPad: CGFloat = 14
        let headerHeight: CGFloat = 22
        let serviceGap: CGFloat = 18
        let boxH: CGFloat = 54
        let junctionSize: CGFloat = 16
        let maxRowWidth: CGFloat = 780

        // Per-service box width (junctions are fixed dots).
        func boxWidth(_ svc: ArchitectureDiagram.Service) -> CGFloat {
            if svc.isJunction { return junctionSize }
            let w = measure(svc.label, nodeFontSize).width + 22
            return min(max(w, 68), 168)
        }

        // Grid-place a list of services at a content origin; returns their
        // frames plus the content bounding size.
        func gridPlace(_ svcs: [ArchitectureDiagram.Service], originX: CGFloat, originY: CGFloat)
            -> (frames: [String: CGRect], width: CGFloat, height: CGFloat) {
            guard !svcs.isEmpty else { return ([:], 0, 0) }
            let count = svcs.count
            let cols = max(1, Int(ceil(Double(count).squareRoot())))
            let slotW = svcs.map(boxWidth).max() ?? junctionSize
            let slotH = boxH
            var frames: [String: CGRect] = [:]
            var maxCol = 0
            var rowsUsed = 0
            for (i, svc) in svcs.enumerated() {
                let col = i % cols
                let row = i / cols
                maxCol = max(maxCol, col)
                rowsUsed = max(rowsUsed, row)
                let bw = boxWidth(svc)
                let bh = svc.isJunction ? junctionSize : boxH
                let slotX = originX + CGFloat(col) * (slotW + serviceGap)
                let slotY = originY + CGFloat(row) * (slotH + serviceGap)
                frames[svc.id] = CGRect(
                    x: slotX + (slotW - bw) / 2,
                    y: slotY + (slotH - bh) / 2,
                    width: bw, height: bh)
            }
            let width = CGFloat(maxCol + 1) * slotW + CGFloat(maxCol) * serviceGap
            let height = CGFloat(rowsUsed + 1) * slotH + CGFloat(rowsUsed) * serviceGap
            return (frames, width, height)
        }

        var serviceFrames: [String: CGRect] = [:]
        var serviceBoxes: [ArchitectureDiagram.Service: Int] = [:] // service -> colorIndex
        var groupBoxes: [ArchitectureLayout.GroupBox] = []

        var cursorX = margin
        var cursorY = margin
        var rowMaxH: CGFloat = 0
        var maxX = margin
        let rootColorIndex = diagram.groups.count

        func wrapIfNeeded(_ width: CGFloat) {
            if cursorX + width > maxRowWidth + margin && cursorX > margin {
                cursorX = margin
                cursorY += rowMaxH + groupGap
                rowMaxH = 0
            }
        }

        // Declared groups (each with a tinted container).
        for (gi, group) in diagram.groups.enumerated() {
            let members = diagram.services.filter { $0.group == group.id }
            let probe = gridPlace(members, originX: 0, originY: 0)
            let contentW = max(probe.width, measure(group.label, labelFontSize).width + 20)
            let containerW = contentW + groupPad * 2
            let containerH = headerHeight + groupPad + probe.height + groupPad

            wrapIfNeeded(containerW)

            let contentOriginX = cursorX + groupPad
            let contentOriginY = cursorY + headerHeight + groupPad
            let placed = gridPlace(members, originX: contentOriginX, originY: contentOriginY)
            for (id, frame) in placed.frames { serviceFrames[id] = frame }
            for svc in members { serviceBoxes[svc] = gi }

            groupBoxes.append(ArchitectureLayout.GroupBox(
                frame: CGRect(x: cursorX, y: cursorY, width: containerW, height: containerH),
                titleOrigin: CGPoint(x: cursorX + groupPad, y: cursorY + headerHeight / 2 + 3),
                label: group.label,
                icon: group.icon,
                colorIndex: gi))

            cursorX += containerW + groupGap
            rowMaxH = max(rowMaxH, containerH)
            maxX = max(maxX, cursorX - groupGap)
        }

        // Top-level services (no group) as a borderless cluster.
        let rootMembers = diagram.services.filter { svc in
            svc.group == nil || !diagram.groups.contains(where: { $0.id == svc.group })
        }
        if !rootMembers.isEmpty {
            let probe = gridPlace(rootMembers, originX: 0, originY: 0)
            wrapIfNeeded(probe.width)
            let placed = gridPlace(rootMembers, originX: cursorX, originY: cursorY + headerHeight)
            for (id, frame) in placed.frames { serviceFrames[id] = frame }
            for svc in rootMembers { serviceBoxes[svc] = rootColorIndex }
            cursorX += probe.width + groupGap
            rowMaxH = max(rowMaxH, probe.height + headerHeight)
            maxX = max(maxX, cursorX - groupGap)
        }

        let contentBottom = cursorY + rowMaxH

        // Assemble service boxes in declaration order (stable draw order).
        var services: [ArchitectureLayout.ServiceBox] = []
        for svc in diagram.services {
            guard let frame = serviceFrames[svc.id] else { continue }
            services.append(ArchitectureLayout.ServiceBox(
                frame: frame,
                label: svc.label,
                icon: svc.icon,
                isJunction: svc.isJunction,
                colorIndex: serviceBoxes[svc] ?? rootColorIndex))
        }

        // Edges: route orthogonally between named border sides.
        func anchor(_ f: CGRect, _ side: ArchitectureDiagram.Side) -> CGPoint {
            switch side {
            case .left:   return CGPoint(x: f.minX, y: f.midY)
            case .right:  return CGPoint(x: f.maxX, y: f.midY)
            case .top:    return CGPoint(x: f.midX, y: f.minY)
            case .bottom: return CGPoint(x: f.midX, y: f.maxY)
            }
        }
        func out(_ p: CGPoint, _ side: ArchitectureDiagram.Side, _ d: CGFloat) -> CGPoint {
            switch side {
            case .left:   return CGPoint(x: p.x - d, y: p.y)
            case .right:  return CGPoint(x: p.x + d, y: p.y)
            case .top:    return CGPoint(x: p.x, y: p.y - d)
            case .bottom: return CGPoint(x: p.x, y: p.y + d)
            }
        }
        func isHorizontal(_ side: ArchitectureDiagram.Side) -> Bool {
            side == .left || side == .right
        }

        let stub: CGFloat = 16
        var edges: [ArchitectureLayout.Edge] = []
        for edge in diagram.edges {
            guard let fromFrame = serviceFrames[edge.from], let toFrame = serviceFrames[edge.to] else { continue }
            let a = anchor(fromFrame, edge.fromSide)
            let b = anchor(toFrame, edge.toSide)
            let aOut = out(a, edge.fromSide, stub)
            let bOut = out(b, edge.toSide, stub)

            var points: [CGPoint] = [a, aOut]
            if isHorizontal(edge.fromSide) == isHorizontal(edge.toSide) {
                if isHorizontal(edge.fromSide) {
                    let midX = (aOut.x + bOut.x) / 2
                    points.append(CGPoint(x: midX, y: aOut.y))
                    points.append(CGPoint(x: midX, y: bOut.y))
                } else {
                    let midY = (aOut.y + bOut.y) / 2
                    points.append(CGPoint(x: aOut.x, y: midY))
                    points.append(CGPoint(x: bOut.x, y: midY))
                }
            } else {
                // Mixed orientation: a single elbow.
                let corner = isHorizontal(edge.fromSide)
                    ? CGPoint(x: bOut.x, y: aOut.y)
                    : CGPoint(x: aOut.x, y: bOut.y)
                points.append(corner)
            }
            points.append(bOut)
            points.append(b)
            edges.append(ArchitectureLayout.Edge(points: points, arrow: edge.arrow))
        }

        let width = min(max(maxX + margin, 140), 3900)
        let height = min(max(contentBottom + margin, 100), 3900)
        return ArchitectureLayout(
            size: CGSize(width: width, height: height),
            groups: groupBoxes,
            services: services,
            edges: edges)
    }
}
