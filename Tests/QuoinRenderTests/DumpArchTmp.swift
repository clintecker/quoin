#if canImport(AppKit)
import XCTest
import CoreGraphics
@testable import QuoinRender
import QuoinCore
final class DumpArchTmp: XCTestCase {
    func testDump() throws {
        guard ProcessInfo.processInfo.environment["DUMP_ARCH"] != nil else { throw XCTSkip("") }
        let src = try String(contentsOf: URL(fileURLWithPath: "Fixtures/diagrams/architecture.mmd"), encoding: .utf8)
        guard let d = MermaidParser.parse(src) else { return XCTFail("parse") }
        let real: DiagramTextMeasurer = { t,s in DiagramRenderer.measure(t, size: CGFloat(s)) }
        let scene = DiagramScene.lower(d, measure: real)
        guard let waf = scene.nodes.first(where: { $0.id.contains("Firewall") }) else { return }
        let f = waf.frame
        print("ARCHDUMP WAF x\(Int(f.minX))-\(Int(f.maxX)) y\(Int(f.minY))-\(Int(f.maxY))")
        for (ei, e) in scene.edges.enumerated() {
            for (a,b) in zip(e.polyline, e.polyline.dropFirst()) {
                // segment horizontally spanning inside WAF's x-range at a y within WAF
                let yIn = (a.y > f.minY+2 && a.y < f.maxY-2) || (b.y > f.minY+2 && b.y < f.maxY-2)
                let xOverlap = max(min(a.x,b.x), f.minX) < min(max(a.x,b.x), f.maxX)
                if yIn && xOverlap {
                    print("ARCHDUMP edge#\(ei) seg (\(Int(a.x)),\(Int(a.y)))->(\(Int(b.x)),\(Int(b.y))) inside WAF band")
                }
            }
        }
    }
}
#endif
