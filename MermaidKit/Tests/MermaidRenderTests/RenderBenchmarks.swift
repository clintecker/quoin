#if canImport(AppKit)
import XCTest
import CoreGraphics
@testable import MermaidRender
import MermaidLayout

/// End-to-end timings (parse → layout → render to image) for every fixture.
/// Guards the "renders in interactive time" claim; run with BENCH_TABLE=1 to
/// print the markdown table the README's numbers come from.
final class RenderBenchmarks: XCTestCase {

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/diagrams")
    }

    /// Every dense fixture must render cold in under 250ms — an order of
    /// magnitude inside "feels instant", and the fixtures are deliberately
    /// dense (real-world diagrams are smaller).
    func testColdRenderStaysInteractive() throws {
        let theme = DiagramTheme(prefersDark: false)
        let files = try FileManager.default.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mmd" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(files.count, 20)

        var rows: [(String, Double, Double)] = []
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let name = url.deletingPathExtension().lastPathComponent

            var parseBest = Double.infinity, totalBest = Double.infinity
            for run in 0..<3 {
                // A run-unique comment busts the render cache so every
                // measurement is a true cold parse+layout+render.
                let src = source + "\n%% bench-\(name)-\(run)"
                var t0 = CFAbsoluteTimeGetCurrent()
                let parsed = MermaidParser.parse(src)
                parseBest = min(parseBest, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                XCTAssertNotNil(parsed, name)

                t0 = CFAbsoluteTimeGetCurrent()
                let image = MermaidRenderer.image(source: src, theme: theme)
                // Force rasterization: a handler-backed NSImage defers drawing
                // until first use, so timing image() alone would flatter the
                // numbers by excluding the actual CoreGraphics work.
                let rasterized = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                totalBest = min(totalBest, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
                XCTAssertNotNil(image, name)
                XCTAssertNotNil(rasterized, name)
            }
            rows.append((name, parseBest, totalBest))
            XCTAssertLessThan(totalBest, 250, "\(name): cold render must stay interactive")
        }

        if ProcessInfo.processInfo.environment["BENCH_TABLE"] != nil {
            print("BENCH | Diagram | Parse | Parse + layout + render |")
            print("BENCH |---|---:|---:|")
            for (name, parse, total) in rows {
                print(String(format: "BENCH | %@ | %.2f ms | %.2f ms |", name, parse, total))
            }
            let worst = rows.map(\.2).max() ?? 0
            print(String(format: "BENCH worst: %.1f ms", worst))
        }
    }
}
#endif
