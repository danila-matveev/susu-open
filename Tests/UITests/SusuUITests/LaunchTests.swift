import XCTest

/// Smoke walk of the real build/Susu.app: it starts and its menu-bar icon is there.
final class LaunchTests: XCTestCase {
    func testLaunchesWithMenuBarIcon() throws {
        let app = XCUIApplication(url: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../build/Susu.app").standardizedFileURL)
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning, "Susu did not start")

        // Since macOS 26 status items are hosted by the system MenuBarAgent, not by the app's own AX tree.
        // ponytail: opening the menu from a test fails on macOS 27 (AXPress -25204, click opens nothing);
        // the menu walk comes with M3, when the app has real windows to drive.
        let icon = XCUIApplication(bundleIdentifier: "com.apple.MenuBarAgent").buttons["Susu"]
        XCTAssertTrue(icon.waitForExistence(timeout: 5), "menu-bar icon not found")
        app.terminate()
    }
}
