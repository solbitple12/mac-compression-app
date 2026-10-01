import XCTest

/// Drives one compress and one extract through Tamp's window, the way a person
/// would after dropping a folder and then the archive it made. The drop itself
/// is replaced by a debug-only hook (App/Tamp/UITestHooks.swift).
///
/// CI's "UI smoke test" job runs this with TAMP_UI_FIXTURE set to a folder that
/// holds a copy of the test corpus named "Project", then checks the files on disk.
/// To run it yourself, pass the variable to xcodebuild as TEST_RUNNER_TAMP_UI_FIXTURE.
final class SmokeTests: XCTestCase {
    private static let defaultsSuite = "io.github.solbitple12.Tamp.uitests"

    private var fixture: URL!
    /// The latest launch, for a screenshot when a step fails.
    private var currentApp: XCUIApplication?

    override func setUpWithError() throws {
        // Keep going after a failed check, so one run shows everything that's wrong.
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["TAMP_UI_FIXTURE"] else {
            throw XCTSkip("Set TAMP_UI_FIXTURE to a folder that holds a folder named Project.")
        }
        fixture = URL(fileURLWithPath: path)
    }

    func testCompressThenExtract() throws {
        let project = fixture.appendingPathComponent("Project")
        let archive = fixture.appendingPathComponent("Project.tar.zst")

        // Compress the folder as TAR.ZST at Best.
        let app = launch(adding: project, resetSettings: true)
        let compress = app.buttons["Compress"]
        try waitUntilEnabled(compress, "the Compress button")

        let picker = app.popUpButtons["formatPicker"]
        picker.click()
        let tarZst = app.menuItems["TAR.ZST"]
        XCTAssertTrue(tarZst.waitForExistence(timeout: 5), "TAR.ZST isn't in the format menu")
        tarZst.click()
        XCTAssertEqual(picker.value as? String, "TAR.ZST")

        let slider = app.sliders["speedSlider"]
        slider.adjust(toNormalizedSliderPosition: 1)
        XCTAssertTrue(isAtBest(slider), "The slider reads \(slider.value ?? "nothing"), not Best")
        attachScreenshot(of: app, named: "1 Ready to compress")

        compress.click()
        try waitForExistence(app.buttons["Show in Finder"], "the finished compress job", timeout: 120)
        attachScreenshot(of: app, named: "2 Compressed")
        app.terminate()

        // Extract the archive it made, in a fresh launch that should remember the choice.
        let reopened = launch(adding: archive, resetSettings: false)
        let extract = reopened.buttons["Extract"]
        try waitUntilEnabled(extract, "the Extract button")
        XCTAssertEqual(reopened.popUpButtons["formatPicker"].value as? String, "TAR.ZST", "The format wasn't remembered")
        XCTAssertTrue(isAtBest(reopened.sliders["speedSlider"]), "The speed step wasn't remembered")
        attachScreenshot(of: reopened, named: "3 Ready to extract")

        extract.click()
        try waitForExistence(reopened.buttons["Show in Finder"], "the finished extract job", timeout: 120)
        attachScreenshot(of: reopened, named: "4 Extracted")
        reopened.terminate()
    }

    // MARK: Helpers

    private func launch(adding item: URL, resetSettings: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "TAMP_UI_TEST_DEFAULTS": Self.defaultsSuite,
            "TAMP_UI_TEST_RESET_DEFAULTS": resetSettings ? "1" : "0",
            "TAMP_UI_TEST_ADD": item.path,
        ]
        app.launch()
        currentApp = app
        return app
    }

    /// The slider reports its step as text ("Best, …"), or on some systems as its position (0 to 5).
    private func isAtBest(_ slider: XCUIElement) -> Bool {
        switch slider.value {
        case let text as String: text.hasPrefix("Best")
        case let number as NSNumber: number.doubleValue == 5
        default: false
        }
    }

    private func waitUntilEnabled(_ element: XCUIElement, _ description: String, timeout: TimeInterval = 15) throws {
        try waitForExistence(element, description, timeout: timeout)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        guard XCTWaiter().wait(for: [enabled], timeout: timeout) == .completed else {
            throw failure("\(description) never became enabled")
        }
    }

    private func waitForExistence(_ element: XCUIElement, _ description: String, timeout: TimeInterval = 15) throws {
        guard element.waitForExistence(timeout: timeout) else {
            throw failure("\(description) didn't appear within \(Int(timeout)) seconds")
        }
    }

    private func failure(_ description: String) -> TestFailure {
        if let currentApp { attachScreenshot(of: currentApp, named: "Failed: \(description)") }
        return TestFailure(description)
    }

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let window = app.windows.firstMatch
        let screenshot = window.exists ? window.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
