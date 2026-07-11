#if canImport(AppKit)
import XCTest
import AppKit
import QuoinCore
@testable import QuoinRender

/// The math VERIFICATION HARNESS (launch prep): every fixture equation
/// renders to a PNG and is compared against a reference image checked
/// into the repo (Tests/fixtures/math-golden/). Regenerate goldens with
/// `QUOIN_UPDATE_SNAPSHOTS=1 swift test --filter MathGolden` and inspect
/// the PNGs by eye — they ARE the review artifact.
///
/// The fixture list is ALSO the coverage ledger: `.mustRender` fixtures
/// failing to render is a regression; a `.knownUnsupported` fixture that
/// STARTS rendering means coverage improved — move it up and regenerate.
/// On comparison failure the actual render lands in /tmp/math-actual-*.png
/// for side-by-side inspection.
final class MathGoldenRenderTests: XCTestCase {

    // Goldens are LIGHT-appearance renders, but `Theme()` follows
    // NSApp.effectiveAppearance — and any earlier test that touches an
    // NSView boots AppKit, after which the SYSTEM appearance leaks in
    // (dark-mode machines rendered white-ink actuals depending on test
    // order). Pin Aqua for the duration of this suite.
    private var savedAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        savedAppearance = NSApp?.appearance
        NSApp?.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() {
        NSApp?.appearance = savedAppearance
        super.tearDown()
    }

    enum Expectation { case mustRender, knownUnsupported }

    struct Fixture {
        let name: String
        let latex: String
        let expectation: Expectation
    }

    // Coverage map: CommonMark-adjacent MathJax/LaTeX users actually write.
    static let fixtures: [Fixture] = [
        // Core constructs
        .init(name: "fraction-nested", latex: #"\frac{1}{1+\frac{1}{x}}"#, expectation: .mustRender),
        .init(name: "compound-interest", latex: #"A = P\left(1 + \frac{r}{n}\right)^{nt}"#, expectation: .mustRender),
        .init(name: "quadratic", latex: #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#, expectation: .mustRender),
        .init(name: "sqrt-index", latex: #"\sqrt[3]{x^2 + y^2}"#, expectation: .mustRender),
        .init(name: "sub-super", latex: #"x_i^2 + y_{i+1}^{n-1}"#, expectation: .mustRender),
        // Big operators
        .init(name: "sum-limits", latex: #"\sum_{i=1}^{n} i^2 = \frac{n(n+1)(2n+1)}{6}"#, expectation: .mustRender),
        .init(name: "integral", latex: #"\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}"#, expectation: .mustRender),
        .init(name: "product-union", latex: #"\prod_{k=1}^n a_k \quad \bigcup_{i} S_i"#, expectation: .mustRender),
        .init(name: "limit", latex: #"\lim_{x \to 0} \frac{\sin x}{x} = 1"#, expectation: .mustRender),
        // Environments
        .init(name: "pmatrix", latex: #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#, expectation: .mustRender),
        .init(name: "bmatrix-vector", latex: #"\begin{bmatrix} x \\ y \\ z \end{bmatrix}"#, expectation: .mustRender),
        .init(name: "cases", latex: #"f(x) = \begin{cases} x^2 & x \ge 0 \\ -x & x < 0 \end{cases}"#, expectation: .mustRender),
        .init(name: "aligned", latex: #"\begin{aligned} a &= b + c \\ &= d + e \end{aligned}"#, expectation: .mustRender),
        .init(name: "vmatrix-det", latex: #"\det = \begin{vmatrix} a & b \\ c & d \end{vmatrix}"#, expectation: .mustRender),
        // Greek, blackboard, calligraphic
        .init(name: "greek", latex: #"\alpha + \beta = \gamma \cdot \Delta \Omega"#, expectation: .mustRender),
        .init(name: "mathbb", latex: #"x \in \mathbb{R}, \mathcal{L}(f)"#, expectation: .mustRender),
        // Relations / arrows / logic
        .init(name: "relations", latex: #"a \le b \ne c \approx d \equiv e"#, expectation: .mustRender),
        .init(name: "arrows", latex: #"f: A \to B, x \mapsto x^2, P \Rightarrow Q"#, expectation: .mustRender),
        .init(name: "set-logic", latex: #"A \cup B \subseteq C \cap D, \forall x \exists y"#, expectation: .mustRender),
        // Text + spacing
        .init(name: "text-mode", latex: #"v = 3\,\text{m/s} \quad \mathrm{const}"#, expectation: .mustRender),
        // Delimiter sizing
        .init(name: "big-delimiters", latex: #"\left( \frac{a}{b} \right) \left[ \sum_i x_i \right]"#, expectation: .mustRender),
        .init(name: "angle-norm", latex: #"\left\langle u, v \right\rangle \le \left\lVert u \right\rVert"#, expectation: .mustRender),
        // Advanced — expectation set empirically; promote as coverage grows.
        .init(name: "accents", latex: #"\hat{x} + \vec{v} + \bar{y} + \dot{z}"#, expectation: .mustRender),
        .init(name: "binomial", latex: #"\binom{n}{k} = \frac{n!}{k!(n-k)!}"#, expectation: .mustRender),
        .init(name: "overbrace", latex: #"\overbrace{a + b + c}^{\text{sum}}"#, expectation: .knownUnsupported),
        .init(name: "underset", latex: #"\underset{x \to 0}{\mathrm{argmin}}\; f(x)"#, expectation: .knownUnsupported),
        .init(name: "partial-derivative", latex: #"\frac{\partial^2 u}{\partial x^2}"#, expectation: .mustRender),
        .init(name: "prime-derivative", latex: #"f'(x) = \lim_{h\to 0}\frac{f(x+h)-f(x)}{h}"#, expectation: .mustRender),
        .init(name: "operatorname-custom", latex: #"\operatorname{softmax}(z)_i = \frac{e^{z_i}}{\sum_j e^{z_j}}"#, expectation: .mustRender),
        .init(name: "stacked-substack", latex: #"\sum_{\substack{i < n \\ i \text{ odd}}} i"#, expectation: .knownUnsupported),
        // Phase 1 — math alphabets, direct Unicode, operators, \big
        .init(name: "alphabets", latex: #"\mathbb{RCQ}\ \mathcal{ABL}\ \mathfrak{gH}\ \mathsf{sf}\ \mathtt{tt}"#, expectation: .mustRender),
        .init(name: "unicode-direct", latex: #"∫_0^∞ e^{-x} dx ≤ α + β"#, expectation: .mustRender),
        .init(name: "big-manual", latex: #"\big( x \big) + \bigl[ y \bigr]"#, expectation: .mustRender),
        .init(name: "operators-more", latex: #"\Pr(X) = \operatorname{argmax}_\theta L(\theta)"#, expectation: .mustRender),
        // Phase 2 — accents & generalized fractions
        .init(name: "accents-wide", latex: #"\widehat{abc} + \tilde{n} + \ddot{u} + \overline{AB} + \underline{x}"#, expectation: .mustRender),
        .init(name: "binom-nested", latex: #"\dbinom{n}{k} + \cfrac{1}{1 + \cfrac{1}{x}}"#, expectation: .mustRender),
    ]

    private var goldenDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/fixtures/math-golden")
    }

    private var updating: Bool {
        ProcessInfo.processInfo.environment["QUOIN_UPDATE_SNAPSHOTS"] == "1"
    }

    /// Deterministic 2× rasterization of the attachment image.
    private func pngData(for latex: String) -> Data? {
        guard let attributed = MathImageRenderer.attachmentString(
            latex: latex, display: true, theme: Theme(), baseSize: 15),
              let image = Self.attachmentImage(in: attributed),
              image.size.width > 0, image.size.height > 0
        else { return nil }
        let scale: CGFloat = 2
        let width = Int(ceil(image.size.width * scale))
        let height = Int(ceil(image.size.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private static func attachmentImage(in attributed: NSAttributedString) -> NSImage? {
        var image: NSImage?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if let attachment = value as? NSTextAttachment, let found = attachment.image {
                image = found
                stop.pointee = true
            }
        }
        return image
    }

    /// Pixel mismatch ratio between two same-size PNGs (1.0 when sizes differ).
    private func mismatchRatio(_ a: Data, _ b: Data) -> Double {
        guard let imageA = NSBitmapImageRep(data: a), let imageB = NSBitmapImageRep(data: b),
              imageA.pixelsWide == imageB.pixelsWide, imageA.pixelsHigh == imageB.pixelsHigh,
              let bytesA = imageA.bitmapData, let bytesB = imageB.bitmapData
        else { return 1 }
        let count = imageA.bytesPerPlane
        var mismatched = 0
        var sampled = 0
        var i = 0
        while i < count {
            sampled += 1
            if abs(Int(bytesA[i]) - Int(bytesB[i])) > 24 { mismatched += 1 }
            i += 4 // first channel of each pixel
        }
        return Double(mismatched) / Double(max(1, sampled))
    }

    func testEquationFixturesMatchGoldenRenders() throws {
        try FileManager.default.createDirectory(at: goldenDirectory, withIntermediateDirectories: true)
        var failures: [String] = []
        var coverageChanges: [String] = []

        for fixture in Self.fixtures {
            let rendered = pngData(for: fixture.latex)
            switch (fixture.expectation, rendered) {
            case (.mustRender, nil):
                failures.append("\(fixture.name): REGRESSION — no longer renders")
                continue
            case (.knownUnsupported, nil):
                continue // expected gap, tracked
            case (.knownUnsupported, .some):
                coverageChanges.append(fixture.name)
                continue // improvement! promote to .mustRender + regenerate
            case (.mustRender, .some(let png)):
                let goldenURL = goldenDirectory.appendingPathComponent("\(fixture.name).png")
                if updating {
                    try png.write(to: goldenURL)
                    continue
                }
                guard let golden = try? Data(contentsOf: goldenURL) else {
                    failures.append("\(fixture.name): missing golden — run with QUOIN_UPDATE_SNAPSHOTS=1")
                    continue
                }
                let ratio = mismatchRatio(png, golden)
                if ratio > 0.02 {
                    let actualURL = URL(fileURLWithPath: "/tmp/math-actual-\(fixture.name).png")
                    try? png.write(to: actualURL)
                    failures.append("\(fixture.name): \(Int(ratio * 100))% pixels differ from golden "
                        + "(actual saved to \(actualURL.path))")
                }
            }
        }

        XCTAssertTrue(failures.isEmpty, "math golden failures:\n" + failures.joined(separator: "\n"))
        if !coverageChanges.isEmpty {
            XCTFail("COVERAGE IMPROVED — promote to .mustRender and regenerate goldens: "
                + coverageChanges.joined(separator: ", "))
        }
    }
}
#endif
