import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramScene {

    /// Lowers any parsed diagram to its scene by laying it out and delegating
    /// to the per-type `from(_:)` overload (one per `DiagramScene+<Type>.swift`).
    public static func lower(_ diagram: MermaidDiagram, measure: DiagramTextMeasurer) -> DiagramScene {
        switch diagram {
        case .flowchart(let d):   return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .sequence(let d):    return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .pie(let d):         return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .classDiagram(let d):return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .er(let d):          return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .state(let d):       return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .gantt(let d):       return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .timeline(let d):    return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .mindmap(let d):     return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .journey(let d):     return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .quadrant(let d):    return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .packet(let d):      return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .xychart(let d):     return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .kanban(let d):      return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .radar(let d):       return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .treemap(let d):     return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .gitGraph(let d):    return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .requirement(let d): return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .sankey(let d):      return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .c4(let d):          return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .architecture(let d):return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .block(let d):       return .from(DiagramLayoutEngine.layout(d, measure: measure))
        case .zenuml(let d):      return .from(DiagramLayoutEngine.layout(d, measure: measure))
        }
    }

    /// Lint report for a Mermaid source string, or nil if it doesn't parse.
    public static func lintReport(source: String, measure: DiagramTextMeasurer) -> String? {
        guard let diagram = MermaidParser.parse(source) else { return nil }
        return DiagramLayoutLinter.report(lower(diagram, measure: measure))
    }
}
