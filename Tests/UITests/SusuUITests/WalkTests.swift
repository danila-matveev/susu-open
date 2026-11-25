import XCTest

/// XCUITest walk (BUILD-PLAN «Тестирование»): every main-window section and every settings section opens.
/// Screenshots are attachments in the .xcresult, for the visual check against the prototype.
final class WalkTests: XCTestCase {
    private let mainSections = ["history", "calls", "notes", "dictionary", "snippets", "styles", "skills", "stats"]
    private let settingsSections = ["keys", "mic", "lang", "models", "calls", "agent", "account", "data", "misc"]

    private func launch(_ env: [String: String]) throws -> XCUIApplication {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("susu-walk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(#"{"onboardingDone":true}"#.utf8).write(to: data.appendingPathComponent("settings.json"))
        let app = XCUIApplication(url: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../build/Susu.app").standardizedFileURL)
        app.launchEnvironment = env.merging(["SUSU_DATA_DIR": data.path, "SUSU_TRIGGER": "f18"]) { $1 }
        app.launch()
        return app
    }

    /// Kept in the .xcresult; `tools/ui/walk` exports them (the test runner cannot write outside its sandbox).
    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testMainWindowSections() throws {
        let app = try launch(["SUSU_OPEN_MAIN": "1"])
        let window = app.windows["Susu"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "main window did not open")
        for s in mainSections {
            let row = window.buttons["nav.\(s)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "no sidebar row \(s)")
            row.click()
            sleep(1)
            XCTAssertTrue(window.exists, "window gone after \(s)")
            shot("main-\(s)")
        }
        app.terminate()
    }

    func testSettingsSections() throws {
        let app = try launch(["SUSU_OPEN_SETTINGS": "1"])
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "settings window did not open")
        for s in settingsSections {
            let row = window.buttons["nav.\(s)"]
            XCTAssertTrue(row.waitForExistence(timeout: 3), "no settings row \(s)")
            row.click()
            sleep(1)
            XCTAssertTrue(window.exists, "window gone after \(s)")
            shot("settings-\(s)")
        }
        app.terminate()
    }
}
