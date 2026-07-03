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

    func testCaptureMainWindow() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments = ["-QuoinLibraryPath", fixturesPath]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "main window should appear")
        capture(name: "01-library")

        // Open the showcase document from the sidebar.
        let row = app.staticTexts["showcase"]
        if row.waitForExistence(timeout: 5) {
            row.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "02-document")

            // The engines fixture leads with math + diagrams, so the
            // interesting content is in the first viewport — no synthetic
            // scrolling (which is unreliable on runner Macs).
            let engines = app.staticTexts["engines"]
            if engines.waitForExistence(timeout: 3) {
                engines.click()
                Thread.sleep(forTimeInterval: 2)
                capture(name: "03-native-engines")
            }

            captureChrome(app)
        }
        app.terminate()
    }

    /// Walks the window chrome: syntax reveal, find bar, export sheet,
    /// quick open, library search, stats popover. Each interaction is
    /// best-effort — a missed element skips its shot rather than failing
    /// the suite.
    private func captureChrome(_ app: XCUIApplication) {
        // Syntax reveal: click into the document body.
        let textView = app.textViews.firstMatch
        if textView.exists {
            textView.click()
            Thread.sleep(forTimeInterval: 1.5)
            capture(name: "07-syntax-reveal")
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Find bar (⌘F) with live matches.
        app.typeKey("f", modifierFlags: [.command])
        Thread.sleep(forTimeInterval: 0.7)
        app.typeText("math")
        Thread.sleep(forTimeInterval: 1)
        capture(name: "08-find-bar")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Export sheet (⇧⌘E).
        app.typeKey("e", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.2)
        capture(name: "09-export-sheet")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.7)

        // Quick open (⇧⌘O) with a query.
        app.typeKey("o", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.7)
        app.typeText("show")
        Thread.sleep(forTimeInterval: 1)
        capture(name: "10-quick-open")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Library search (⇧⌘F) with full-text hits.
        app.typeKey("f", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.7)
        app.typeText("engine")
        Thread.sleep(forTimeInterval: 1.2)
        capture(name: "11-library-search")
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Statistics popover from the status bar.
        let stats = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS 'words' OR label CONTAINS 'words'")
        ).firstMatch
        if stats.exists {
            stats.click()
            Thread.sleep(forTimeInterval: 1)
            capture(name: "12-stats-popover")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Dark-appearance pass: verifies the handoff rules (inverted ink/canvas,
    /// code surface constant) on a real render.
    func testCaptureDarkMode() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launchArguments = [
            "-QuoinLibraryPath", fixturesPath,
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let row = app.staticTexts["showcase"]
        if row.waitForExistence(timeout: 5) {
            row.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "05-dark-document")
        }
        let engines = app.staticTexts["engines"]
        if engines.waitForExistence(timeout: 3) {
            engines.click()
            Thread.sleep(forTimeInterval: 2)
            capture(name: "06-dark-engines")
        }
        app.terminate()
    }

    private func capture(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
