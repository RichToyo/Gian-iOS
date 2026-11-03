import XCTest

/// Walks every primary surface against the scripted preview service and
/// attaches a screenshot of each, for design review. Export with
/// `xcrun xcresulttool export attachments --path <result.xcresult> --output-path <dir>`.
final class ScreenshotTourUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testAppTourLight() throws { try appTour(appearance: "light") }
    func testAppTourDark() throws { try appTour(appearance: "dark") }

    /// Setup screens need typed input, so they run as a separate tour.
    func testSetupTour() throws {
        let app = launch(appearance: "light", ready: false)

        let serverField = app.textFields.firstMatch
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        snap(app, "01-setup-server", "light")
        serverField.tap()
        serverField.typeText("https://remote.example.test")
        app.buttons["Continue"].tap()

        let signIn = app.buttons["Continue with GitHub"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        snap(app, "03-setup-github", "light")
        signIn.tap()
        let code = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'ABCD-EFGH'")).firstMatch
        if code.waitForExistence(timeout: 10) {
            snap(app, "04-setup-device-code", "light")
        }
        if app.textFields["Paste pairing link"].waitForExistence(timeout: 30) {
            snap(app, "05-setup-pairing", "light")
        }
    }

    /// The composer's ⋯ holds only options that can change mid-run (model,
    /// thinking, fast, approval, translate); Repository/Agent/Task are toolbar
    /// menus. XCTest screenshots are black on an unfolded Duo; run this folded.
    func testComposerMoreMenus() throws {
        for destination in ["newChat", "chat"] {
            let app = XCUIApplication()
            app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                    "-previewDestination", destination, "-gian.appearance", "Light"]
            app.launch()
            let more = app.buttons["More options"]
            XCTAssertTrue(more.waitForExistence(timeout: 30), "⋯ missing in \(destination)")
            XCTAssertTrue(app.buttons["Add attachment"].exists, "+ missing in \(destination)")
            XCTAssertTrue(app.buttons["Send"].exists, "Send missing in \(destination)")
            if destination == "newChat" {
                XCTAssertTrue(app.buttons["Task"].exists, "Task should be a toolbar menu")
            }
            more.tap(); sleep(1)
            snap(app, "13-more-\(destination)", "light")
            // Rows are an icon plus the current value: model, thinking, approval.
            for value in ["Ada Large", "Default", "Ask for approval"] {
                XCTAssertTrue(app.buttons[value].exists, "\(value) missing from ⋯ in \(destination)")
            }
            XCTAssertFalse(app.staticTexts["Applies from the next turn"].exists, "⋯ needs no explanations")
            if destination == "chat" {
                // The preview Host has no translation set up: one grayed-out row.
                XCTAssertTrue(app.buttons["Translate"].exists, "Translate missing")
                XCTAssertFalse(app.buttons["Translate"].isEnabled, "Unavailable Translate should be grayed out")
            }
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Repository'")).firstMatch.isHittable,
                           "Repository must not be in ⋯")
            app.terminate()
        }
    }

    /// The centered Host (status dot + name) opens the Hosts menu; List
    /// options holds grouping and Refresh; the composer grows with line breaks
    /// and keeps Send on the bottom line.
    func testHostMenuListOptionsAndMultilineComposer() throws {
        var app = launch(appearance: "light", ready: true)
        XCTAssertTrue(app.buttons["Start a new chat"].waitForExistence(timeout: 30))
        app.buttons["Harbor, Online"].firstMatch.tap(); sleep(1)
        snap(app, "14-host-title-menu", "light")
        XCTAssertTrue(app.buttons["Manage in Settings"].exists, "Host title menu missing")
        XCTAssertTrue(app.buttons["Add Host"].exists, "Add Host missing from the Hosts menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap(); sleep(1)
        app.buttons["Directory views"].tap(); sleep(1)
        snap(app, "15-list-options", "light")
        XCTAssertTrue(app.buttons["Refresh"].exists, "Refresh missing from list options")
        app.terminate()

        app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chat", "-gian.appearance", "Light"]
        app.launch()
        let field = app.textFields["Message"]
        let message = field.waitForExistence(timeout: 30) ? field : app.textViews["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        let singleLineHeight = message.frame.height
        message.tap()
        message.typeText("First line\nSecond line\nThird line")
        sleep(1)
        snap(app, "16-multiline-composer", "light")
        // The placeholder (its identifier) is gone once there is text.
        let typed = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertGreaterThan(typed.frame.height, singleLineHeight * 2, "Composer did not grow")
        XCTAssertTrue((typed.value as? String ?? "").contains("\n"), "Return did not insert a line break")
    }

    /// Add Host explains a bad link, Cancel keeps the current Host, and a
    /// confirmed pairing closes the sheet (the preview pairs Harbor again).
    func testAddHostExplainsBadLinksAndCloses() throws {
        let app = launch(appearance: "light", ready: true)
        let host = app.buttons["Harbor, Online"].firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 30))
        host.tap()
        let add = app.buttons["Add Host"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let link = app.textFields["Paste pairing link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Add Host sheet missing")
        link.tap()
        link.typeText("not a pairing link")
        app.buttons["Pair"].tap()
        let notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'pairing link or QR code'")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "A bad link needs an explanation")
        snap(app, "19-add-host", "light")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(link.waitForNonExistence(timeout: 5), "Cancel must close Add Host")
        XCTAssertTrue(host.exists, "Cancel must keep the current Host")

        host.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertFalse(notice.exists, "Cancel must clear the last notice")
        link.tap()
        link.typeText("https://remote.example.test/pair#nonce=abcdefghijklmnop")
        app.buttons["Pair"].tap()
        XCTAssertTrue(link.waitForNonExistence(timeout: 15), "A confirmed pairing must close Add Host")
        XCTAssertTrue(host.waitForExistence(timeout: 15))
    }

    /// Sign out and Change server can both be backed out of: nothing signs
    /// out until the user confirms.
    func testSignOutAndChangeServerCanBeCancelled() throws {
        let app = launch(appearance: "light", ready: true)
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()

        let change = app.buttons["Change server…"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        change.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Change server needs a Cancel")
        snap(app, "17-change-server-sheet", "light")
        cancel.tap(); sleep(1)
        XCTAssertTrue(app.buttons["Change server…"].waitForExistence(timeout: 5), "Cancel must keep Settings and the session")

        app.buttons["Sign out"].firstMatch.tap(); sleep(1)
        snap(app, "18-sign-out-confirmation", "light")
        // iOS 26 shows the confirmation as a popover; tapping outside cancels.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Sign out of'")).firstMatch
            .waitForExistence(timeout: 5), "Sign out needs confirmation")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap(); sleep(1)
        XCTAssertFalse(app.staticTexts["Connect to your Gian server"].exists, "Cancelled sign-out still signed out")
        XCTAssertTrue(app.buttons["Change server…"].exists)
    }

    /// Starts from home via `-previewReady`; taps only, no typing.
    private func appTour(appearance: String) throws {
        let app = launch(appearance: appearance, ready: true)

        XCTAssertTrue(app.buttons["Start a new chat"].waitForExistence(timeout: 30))
        sleep(1)
        snap(app, "06-home-tasks", appearance)

        let repos = app.buttons["Repos"]
        if repos.exists {
            repos.tap(); sleep(1)
            snap(app, "07-home-repos", appearance)
            app.buttons["Tasks"].tap(); sleep(1)
        }

        let row = app.staticTexts["Mooring notes"]
        if row.waitForExistence(timeout: 10) {
            row.tap(); sleep(2)
            snap(app, "08-chat", appearance)
            let back = app.buttons["Back"].firstMatch
            if back.exists { back.tap(); sleep(1) }
        }

        let newChat = app.buttons["Start a new chat"]
        if newChat.waitForExistence(timeout: 5) {
            newChat.tap(); sleep(1)
            snap(app, "10-new-chat", appearance)
            let close = app.buttons["Close"].firstMatch
            if close.exists { close.tap(); sleep(1) }
        }

        let search = app.buttons["Search conversations"]
        if search.waitForExistence(timeout: 5) {
            search.tap(); sleep(1)
            snap(app, "11-search", appearance)
            app.swipeDown(velocity: .fast); sleep(1)
        }

        let avatar = app.buttons["Settings"].firstMatch
        if avatar.waitForExistence(timeout: 5) {
            avatar.tap(); sleep(1)
            snap(app, "12-settings", appearance)
        }
    }

    private func launch(appearance: String, ready: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-gian.appearance", appearance.capitalized]
        if ready { app.launchArguments.append("-previewReady") }
        app.launch()
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String, _ appearance: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(name)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
