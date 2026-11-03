import XCTest

/// UI tests launch the app with the explicit `-previewScript` argument, which
/// selects the fictional PreviewGianClientService. Production bootstrap never
/// consults this; there is no silent preview fallback.
final class GianUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Full setup flow against the scripted preview service: server address
    /// and enrollment token (no account sign-in) → Host pairing with the
    /// one-time code → home directory with the scripted task and conversation.
    func testSetupFlowReachesHomeDirectory() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "legacyContract"]
        app.launch()

        // Server step: address and the enrollment token (no account sign-in).
        let serverField = app.textFields.firstMatch
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        serverField.tap()
        serverField.typeText("https://remote.example.test")
        let token = app.textFields["Enrollment token"]
        token.tap()
        token.typeText("preview-enrollment-token")
        app.buttons["Continue"].tap()

        // Pairing: QR scanning by default, the one-time code a tap away.
        let enterCode = app.buttons["Enter one-time code"]
        XCTAssertTrue(enterCode.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'GitHub'")).firstMatch.exists,
                       "There is no GitHub sign-in")
        enterCode.tap()
        let code = app.textFields["One-time code"]
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The code field should take focus by itself")
        // No hyphen to type; all 8 characters pair straight away.
        code.typeText("7k3mq9tx")

        // Home: scripted task group and its conversation appear; the new-chat
        // entry exists. No notification bell or inbox exists anywhere.
        XCTAssertTrue(app.buttons["Start a new chat"].waitForExistence(timeout: 15))
        let taskGroup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Paint the harbor'")).firstMatch
        XCTAssertTrue(taskGroup.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Mooring notes"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["bell"].exists)
    }
}
