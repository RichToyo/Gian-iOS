import XCTest

/// UI tests launch the app with the explicit `-previewScript` argument, which
/// selects the fictional PreviewGianClientService. Production bootstrap never
/// consults this; there is no silent preview fallback.
final class GianUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Full setup flow against the scripted preview service: server address
    /// (its identity is verified; no account sign-in) → Host pairing via
    /// manual payload → home directory with the scripted task and conversation.
    func testSetupFlowReachesHomeDirectory() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "legacyContract"]
        app.launch()

        // Server address step.
        let serverField = app.textFields.firstMatch
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        serverField.tap()
        serverField.typeText("https://remote.example.test")
        app.buttons["Continue"].tap()

        // Pairing step straight away: paste the scripted QR payload manually.
        let pairingField = app.textFields["Paste pairing link"]
        XCTAssertTrue(pairingField.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'GitHub'")).firstMatch.exists,
                       "There is no GitHub sign-in")
        pairingField.tap()
        pairingField.typeText("https://remote.example.test/pair#nonce=abcdefghijklmnop")
        app.buttons["Pair"].tap()

        // Home: scripted task group and its conversation appear; the new-chat
        // entry exists. No notification bell or inbox exists anywhere.
        XCTAssertTrue(app.buttons["Start a new chat"].waitForExistence(timeout: 15))
        let taskGroup = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Paint the harbor'")).firstMatch
        XCTAssertTrue(taskGroup.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Mooring notes"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["bell"].exists)
    }
}
