import XCTest

/// Drives the real app against the local test Gian (see build/live15/README.md):
/// server (identity verified, no account) → pairing → home → new chat with real catalog options →
/// one message → a mid-conversation `session.update`. Skipped unless a fresh
/// pairing link is passed:
///
///     TEST_RUNNER_GIAN_LIVE_SERVER=https://localhost:8444 \
///     TEST_RUNNER_GIAN_LIVE_PAIRING_LINK="$(build/live15/pair-host15.sh --no-wait | tail -1)" \
///       xcodebuild … -only-testing:GianUITests/LiveHostUITests test
@MainActor
final class LiveHostUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testConnectsToLocalHostAndChangesConversationSettings() throws {
        let environment = ProcessInfo.processInfo.environment
        let link = try XCTUnwrap(environment["GIAN_LIVE_PAIRING_LINK"].flatMap { $0.isEmpty ? nil : $0 },
                                 "Set TEST_RUNNER_GIAN_LIVE_PAIRING_LINK")
        let server = environment["GIAN_LIVE_SERVER"] ?? "https://localhost:8444"

        app = XCUIApplication()
        app.launch()

        let serverField = app.textFields.firstMatch
        XCTAssertTrue(serverField.waitForExistence(timeout: 15))
        serverField.tap()
        serverField.typeText(server)
        app.buttons["Continue"].tap()

        let pairing = app.textFields["Paste pairing link"]
        XCTAssertTrue(pairing.waitForExistence(timeout: 60), "The server was not verified")
        pairing.tap()
        pairing.typeText(link)
        app.buttons["Pair"].tap()

        let newChat = app.buttons["Start a new chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 60), "Pairing did not complete")
        sleep(2)
        snap("live-01-home")

        newChat.tap()
        choose(menu: "Agent", item: "Codex")
        choose(menu: "Task", item: "iOS live test")
        sleep(2)
        snap("live-02-new-chat")

        let more = app.buttons["More options"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap(); sleep(1)
        snap("live-03-new-chat-more")
        // Rows show the current values (Codex: default thinking, Ask for approval).
        for value in ["Default", "Ask for approval"] {
            XCTAssertTrue(app.buttons[value].exists, "\(value) missing for Codex")
        }
        dismissMenu()

        // Multi-line fields surface as text views.
        let field = app.textFields["Message"]
        let message = field.waitForExistence(timeout: 5) ? field : app.textViews["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        message.tap()
        message.typeText("ping")
        // Return inserts a line break now; Send is the button.
        app.buttons["Send"].tap()
        // Leaving New chat means the conversation was created and opened.
        let newChatTitle = app.staticTexts["New chat"]
        let deadline = Date().addingTimeInterval(45)
        while newChatTitle.exists, Date() < deadline { sleep(1) }
        XCTAssertFalse(newChatTitle.exists, "The first message did not create a conversation")

        // The created conversation opens; change approval mid-conversation.
        XCTAssertTrue(app.buttons["More options"].waitForExistence(timeout: 30))
        sleep(3)
        snap("live-04-conversation")
        app.buttons["More options"].tap(); sleep(1)
        // The Approval row shows its current value; switch to the other one.
        let ask = app.buttons["Ask for approval"], auto = app.buttons["Approve for me"]
        let current = ask.waitForExistence(timeout: 20) ? ask : auto
        XCTAssertTrue(current.exists, "Approval missing from ⋯ in the conversation")
        let target = current == ask ? "Approve for me" : "Ask for approval"
        current.tap(); sleep(1)
        snap("live-05-approval-choices")
        let choice = app.buttons[target]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        sleep(3)
        app.buttons["More options"].tap(); sleep(1)
        snap("live-06-after-update")
        XCTAssertTrue(app.buttons[target].waitForExistence(timeout: 10), "Host did not confirm the approval change")
        dismissMenu()
    }

    /// Add Host while signed in: pair the second test Host from the Hosts
    /// menu, land on it, and switch back. Needs two Hosts on the same Server
    /// and a link for each:
    ///
    ///     TEST_RUNNER_GIAN_LIVE_PAIRING_LINK=<link for "Gian-iOS Test Host"> \
    ///     TEST_RUNNER_GIAN_LIVE_PAIRING_LINK_2=<link for "Gian-iOS Test Host 2"> \
    ///       xcodebuild … -only-testing:GianUITests/LiveHostUITests/testAddsASecondHost test
    func testAddsASecondHost() throws {
        let environment = ProcessInfo.processInfo.environment
        let first = try XCTUnwrap(environment["GIAN_LIVE_PAIRING_LINK"].flatMap { $0.isEmpty ? nil : $0 },
                                  "Set TEST_RUNNER_GIAN_LIVE_PAIRING_LINK")
        let second = try XCTUnwrap(environment["GIAN_LIVE_PAIRING_LINK_2"].flatMap { $0.isEmpty ? nil : $0 },
                                   "Set TEST_RUNNER_GIAN_LIVE_PAIRING_LINK_2")
        try connect(server: environment["GIAN_LIVE_SERVER"] ?? "https://localhost:8444", pairing: first)

        let hostOne = hostTitle("Gian-iOS Test Host,")
        XCTAssertTrue(hostOne.waitForExistence(timeout: 30), "First Host not current")
        sleep(3)
        snap("live-10-first-host")
        hostOne.tap()
        app.buttons["Add Host"].tap()
        let link = app.textFields["Paste pairing link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Add Host sheet missing")
        link.tap()
        link.typeText(second)
        app.buttons["Pair"].tap()
        snap("live-11-add-host-waiting")
        XCTAssertTrue(link.waitForNonExistence(timeout: 60), "Second Host was not confirmed")

        let hostTwo = hostTitle("Gian-iOS Test Host 2,")
        XCTAssertTrue(hostTwo.waitForExistence(timeout: 30), "The new Host did not become current")
        // Its list loads by itself once it connects, like the first Host's.
        let notLoaded = app.staticTexts["Not loaded yet"]
        let deadline = Date().addingTimeInterval(30)
        while notLoaded.exists, Date() < deadline { sleep(1) }
        XCTAssertFalse(notLoaded.exists, "The new Host's list did not load")
        snap("live-12-second-host")
        hostTwo.tap(); sleep(1)
        snap("live-13-hosts-menu")
        let backToFirst = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Gian-iOS Test Host' AND NOT (label BEGINSWITH 'Gian-iOS Test Host 2')")).firstMatch
        XCTAssertTrue(backToFirst.waitForExistence(timeout: 5), "First Host missing from the Hosts menu")
        backToFirst.tap()
        XCTAssertTrue(hostTitle("Gian-iOS Test Host,").waitForExistence(timeout: 30), "Could not switch back")
        snap("live-14-back-to-first")
    }

    private func connect(server: String, pairing link: String) throws {
        app = XCUIApplication()
        app.launch()
        let serverField = app.textFields.firstMatch
        XCTAssertTrue(serverField.waitForExistence(timeout: 15))
        serverField.tap()
        serverField.typeText(server)
        app.buttons["Continue"].tap()
        let pairing = app.textFields["Paste pairing link"]
        XCTAssertTrue(pairing.waitForExistence(timeout: 60), "The server was not verified")
        pairing.tap()
        pairing.typeText(link)
        app.buttons["Pair"].tap()
        XCTAssertTrue(app.buttons["Start a new chat"].waitForExistence(timeout: 60), "Pairing did not complete")
    }

    /// The centered Host title reads "<name>, Online|Offline".
    private func hostTitle(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func choose(menu: String, item: String) {
        let button = app.buttons[menu]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "\(menu) menu missing")
        button.tap()
        let choice = app.buttons[item]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(item) missing from \(menu)")
        choice.tap()
        sleep(1)
    }

    private func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        sleep(1)
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
