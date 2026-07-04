import XCTest

/// Launches the app against a fixture library and captures window
/// screenshots. On CI the PNGs are uploaded as artifacts — this is how a
/// cloud session (no macOS GUI) gets eyes on the real app.
final class ScreenshotTests: XCTestCase {

    private var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["QUOIN_SCREENSHOT_DIR"]
            ?? "/tmp/quoin-shots"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private var fixturesPath: String {
        ProcessInfo.processInfo.environment["QUOIN_FIXTURES"] ?? "/tmp/quoin-fixtures"
    }

    override func setUp() {
        // A single failed event synthesis must skip one shot, not kill the
        // whole gallery.
        continueAfterFailure = true
    }

    func testCaptureMainWindow() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments = ["-QuoinLibraryPath", fixturesPath]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "main window should appear")
        capture(name: "01-library", window: window)

        // Open the showcase document from the sidebar.
        let row = app.staticTexts["showcase"]
        if row.waitForExistence(timeout: 5) {
            row.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "02-document", window: window)

            // The engines fixture leads with math + diagrams, so the
            // interesting content is in the first viewport — no synthetic
            // scrolling (which is unreliable on runner Macs).
            let engines = app.staticTexts["engines"]
            if engines.waitForExistence(timeout: 3) {
                engines.click()
                Thread.sleep(forTimeInterval: 2)
                capture(name: "03-native-engines", window: window)
            }

            // Structure fixture: state, class, and ER diagrams.
            let structure = app.staticTexts["structure"]
            if structure.waitForExistence(timeout: 3) {
                structure.click()
                Thread.sleep(forTimeInterval: 2)
                capture(name: "04-structure-diagrams", window: window)
            }

            // Syntax reveal: click into the document body.
            let textView = app.textViews.firstMatch
            if textView.exists {
                textView.click()
                Thread.sleep(forTimeInterval: 1.5)
                capture(name: "07-syntax-reveal", window: window)
            }
        }
        app.terminate()
    }

    /// Chrome states are driven by launch arguments (deterministic) rather
    /// than synthetic keyboard events (flaky on headless runners): one
    /// short launch per state.
    func testCaptureChromeStates() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let states: [(state: String, open: String?, shot: String)] = [
            ("find", "engines.md", "08-find-bar"),
            ("export", "engines.md", "09-export-sheet"),
            ("quickopen", nil, "10-quick-open"),
            ("libsearch", nil, "11-library-search"),
        ]

        for entry in states {
            let app = XCUIApplication()
            var arguments = ["-QuoinLibraryPath", fixturesPath, "-QuoinShotState", entry.state]
            if let open = entry.open {
                arguments += ["-QuoinShotOpen", open]
            }
            app.launchArguments = arguments
            app.launch()
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 3.5)
            capture(name: entry.shot, window: window)
            app.terminate()
        }
    }

    /// Dark-appearance pass: verifies the handoff rules (inverted ink/canvas,
    /// code surface constant) on a real render.
    func testCaptureDarkMode() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments = [
            "-QuoinLibraryPath", fixturesPath,
            "-QuoinForceDarkMode", "YES",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let row = app.staticTexts["showcase"]
        if row.waitForExistence(timeout: 5) {
            row.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "05-dark-document", window: window)
        }
        let engines = app.staticTexts["engines"]
        if engines.waitForExistence(timeout: 3) {
            engines.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "06-dark-engines", window: window)
        }
        app.terminate()
    }

    /// Captures the app's window (cropped — README/CI quality) when
    /// available, falling back to the full screen.
    private func capture(name: String, window: XCUIElement? = nil) {
        let screenshot: XCUIScreenshot
        if let window, window.exists {
            screenshot = window.screenshot()
        } else {
            screenshot = XCUIScreen.main.screenshot()
        }
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// README feature gallery: each gallery fixture leads with its feature
    /// so the first viewport is the shot — no synthetic scrolling.
    func testCaptureFeatureGallery() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let shots: [(fixture: String, name: String)] = [
            ("gallery-diagrams", "12-gallery-diagrams"),
            ("gallery-math", "13-gallery-math"),
            ("gallery-blocks", "14-gallery-blocks"),
        ]
        for entry in shots {
            let app = XCUIApplication()
            app.launchArguments = [
                "-QuoinLibraryPath", fixturesPath,
                "-QuoinShotOpen", "\(entry.fixture).md",
            ]
            app.launch()
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 3)
            capture(name: entry.name, window: window)
            app.terminate()
        }
    }
}
