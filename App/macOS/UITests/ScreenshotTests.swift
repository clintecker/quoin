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
