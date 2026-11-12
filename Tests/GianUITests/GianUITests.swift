import XCTest

/// UI tests launch the app with the explicit `-previewScript` argument, which
/// selects the fictional PreviewGianClientService. Production bootstrap never
/// consults this; there is no silent preview fallback.
final class GianUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Run on an unfolded Duo in portrait with the software keyboard enabled.
    func testExpandedPortraitComposerKeepsKeyboardAndDraft() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chat"]
        app.launch()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 600, "Run this test with the Duo unfolded")

        let field = app.textFields["Message"]
        let message = field.waitForExistence(timeout: 30) ? field : app.textViews["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The composer should show the software keyboard")
        message.typeText("Fictional draft")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The keyboard should remain visible while editing")
        let typed = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue((typed.value as? String ?? "").contains("Fictional draft"))
    }

    /// Run on an expanded display (an unfolded Duo, or an iPad). Rotating to
    /// landscape — even mid-typing, keyboard up — brings the list in beside the
    /// conversation.
    func testRotatingExpandedPortraitToLandscapeShowsTheListBesideTheChat() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady", "-previewDestination", "chat"]
        app.launch()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 600, "Run this test on an expanded display")
        let message = app.textFields["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        let listRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Old quiet")).firstMatch
        XCTAssertFalse(listRow.exists && listRow.isHittable, "Expanded portrait shows the conversation full page")
        message.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let beside = expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: listRow)
        wait(for: [beside], timeout: 10)
        XCTAssertTrue(app.textFields["Message"].exists, "The conversation stays open beside the list")
        XCUIDevice.shared.orientation = .portrait
    }

    func testExpandedPortraitUsesFullPageConversationNavigation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady", "-previewHostName"]
        app.launch()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 600, "Run this test with the Duo unfolded")
        let host = app.buttons["Work Gian, Online"]
        XCTAssertTrue(host.waitForExistence(timeout: 30))
        let search = app.buttons["Search conversations"]
        let options = app.buttons["Directory views"]
        let newChat = app.buttons["Start a new chat"]
        let settings = app.buttons["Settings"]
        XCTAssertTrue(search.exists && options.exists && newChat.exists && settings.exists)
        // The Host title on the leading edge; list and global actions after it.
        let width = app.windows.firstMatch.frame.width
        XCTAssertLessThan(host.frame.minX, width / 4)
        XCTAssertGreaterThan(search.frame.minX, host.frame.maxX)
        XCTAssertGreaterThan(options.frame.minX, host.frame.maxX)
        XCTAssertGreaterThan(newChat.frame.minX, host.frame.maxX)
        XCTAssertGreaterThan(settings.frame.minX, host.frame.maxX)
        XCTAssertFalse(app.textFields["Message"].exists, "The directory should use the whole page")
        let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Mooring notes")).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Show sidebar"].exists)
        let title = app.descendants(matching: .any)["conversation-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertLessThan(title.frame.minX, width / 4, "the title sits on the leading edge, after Back")
        XCTAssertGreaterThan(app.buttons["Start a new chat"].frame.minX, title.frame.maxX)
        XCTAssertGreaterThan(app.buttons["Settings"].frame.minX, title.frame.maxX)
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(host.waitForExistence(timeout: 10))
    }

    func testSentTranslationBubbleIsRightAlignedAndContentSized() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chat", "-previewSentTranslation"]
        app.launch()
        let translated = app.staticTexts["Hello there."]
        XCTAssertTrue(translated.waitForExistence(timeout: 30))
        let original = app.staticTexts["Hello."]
        let label = app.staticTexts["sent-translation-label"]
        let box = app.descendants(matching: .any)["sent-translation"]
        let bubble = app.descendants(matching: .any).matching(identifier: "user-message-bubble")
            .containing(.staticText, identifier: "Hello.").firstMatch
        XCTAssertTrue(bubble.exists && original.exists && label.exists && box.exists)
        XCTAssertLessThan(bubble.frame.width, app.windows.firstMatch.frame.width * 0.8)
        // As on the desktop: the translation sits beneath the bubble, labelled,
        // and both hug the trailing edge.
        XCTAssertGreaterThan(box.frame.minY, bubble.frame.maxY)
        XCTAssertLessThan(label.frame.midY, box.frame.minY)
        XCTAssertLessThan(abs(box.frame.maxX - bubble.frame.maxX), 4)
        XCTAssertLessThanOrEqual(abs(label.frame.maxX - box.frame.maxX), 5)
    }

    /// As on the desktop: Send empties the composer at once and the message
    /// shows, dimmed, with "Translating" and Send original beneath it.
    func testTranslatedSendShowsThePendingMessageUntilSent() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatTranslate", "-previewSlowTranslation"]
        app.launch()
        let pending = app.descendants(matching: .any)["pending-user-message"]
        XCTAssertTrue(pending.waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["Translating"].exists)
        let message = app.textFields["Message"].exists ? app.textFields["Message"] : app.textViews["Message"]
        XCTAssertFalse((message.value as? String ?? "").contains("amarre"), "The composer is empty while the message is on its way")
        app.buttons["Send original"].tap()
        XCTAssertTrue(pending.waitForNonExistence(timeout: 10))
    }

    /// A failed translation sends nothing; the user retries, sends the
    /// original, or takes the text back into the composer.
    func testFailedTranslationOffersTakeTextBack() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatTranslate", "-previewFailedTranslation"]
        app.launch()
        XCTAssertTrue(app.staticTexts["The translation Agent is offline."].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Retry translation"].exists)
        XCTAssertTrue(app.buttons["Send original"].exists)
        app.buttons["Take text back"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["pending-user-message"].waitForNonExistence(timeout: 10))
        let restored = app.descendants(matching: .any).matching(NSPredicate(format: "value CONTAINS 'amarre'")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5), "The text is back in the composer")
    }

    /// Gian's accents, Plum by default; the choice tints bubbles and status.
    func testAccentPickerDefaultsToPlumAndChanges() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady", "-previewDestination", "settings"]
        app.launch()
        let plum = app.buttons["Plum"]
        XCTAssertTrue(plum.waitForExistence(timeout: 30))
        for _ in 0..<4 where !plum.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(plum.isSelected, "Plum is the default accent")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "accent-picker"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Ink"].tap()
        XCTAssertTrue(app.buttons["Ink"].isSelected)
        XCTAssertFalse(plum.isSelected)
        // Leave the default for the next run (the choice persists).
        plum.tap()
        XCTAssertTrue(plum.isSelected)
    }

    func testBannerOpensItsConversationInExpandedPortrait() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatWithBanner"]
        app.launch()
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, 600, "Run this test with the Duo unfolded")

        let banner = app.buttons["transient-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        // Once it has slid in.
        let settled = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: banner)
        wait(for: [settled], timeout: 3)
        banner.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)).tap()
        let target = app.descendants(matching: .any).matching(identifier: "conversation-title").matching(
            NSPredicate(format: "label == %@", "Night watch")
        ).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "The banner should open its own conversation. \(app.debugDescription)")
    }

    func testSwipingTheBannerUpDismissesItInPlace() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatWithBanner"]
        app.launch()
        let banner = app.buttons["transient-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Dismiss notification"].exists, "no close button: a swipe up dismisses")
        XCTAssertTrue(banner.label.contains("Turn complete"))
        banner.swipeUp()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 3))
        let title = app.descendants(matching: .any).matching(identifier: "conversation-title").matching(
            NSPredicate(format: "label == %@", "Mooring notes")
        ).firstMatch
        XCTAssertTrue(title.exists, "Dismissing the banner should not navigate")
    }

    func testKeyboardKeepsLatestMessageVisibleAndSendDismissesIt() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatLong"]
        app.launch()
        let message = app.textFields["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        let latest = app.staticTexts["Preview message 30"]
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        message.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Keyboard did not remain visible. \(app.debugDescription)")
        XCTAssertTrue(latest.isHittable, "The latest message must stay visible above the keyboard")
        XCTAssertLessThanOrEqual(latest.frame.maxY, message.frame.minY, "The composer must not cover the latest message")
        message.typeText("Fictional draft")
        app.buttons["Send"].tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Sending should dismiss the keyboard")
    }

    func testRunningConversationQueuesAndCanSendQueueNow() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chat", "-previewQueue"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Fictional queued message"].waitForExistence(timeout: 30))
        let message = app.textFields["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.tap()
        message.typeText("Second fictional message")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Second fictional message"].waitForExistence(timeout: 10))
        app.buttons["Send queue now"].tap()
        let confirm = app.buttons["Send now"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Second fictional message"].waitForNonExistence(timeout: 10))
    }

    func testFocusingComposerReturnsFromHistoryToLatest() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatLong"]
        app.launch()
        let latest = app.staticTexts["Preview message 30"]
        XCTAssertTrue(latest.waitForExistence(timeout: 30))
        let history = app.scrollViews.firstMatch
        history.swipeDown()
        history.swipeDown()
        XCTAssertFalse(latest.isHittable, "The user should be reading earlier messages")
        let message = app.textFields["Message"]
        message.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertTrue(latest.isHittable, "Focusing the composer should return to the latest message")
    }

    func testStreamingDoesNotPullReaderOutOfHistory() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatLongStream"]
        app.launch()
        let latest = app.staticTexts["Preview message 30"]
        XCTAssertTrue(latest.waitForExistence(timeout: 30))
        let history = app.scrollViews.firstMatch
        history.swipeDown()
        history.swipeDown()
        let jump = app.buttons["Jump to latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        sleep(2)
        XCTAssertTrue(jump.exists, "Streaming updates should not force the reader to the bottom")
        XCTAssertFalse(latest.isHittable)
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
    }

    func testHistoryPositionSurvivesRotation() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatLong"]
        app.launch()
        let latest = app.staticTexts["Preview message 30"]
        XCTAssertTrue(latest.waitForExistence(timeout: 30))
        let history = app.scrollViews.firstMatch
        history.swipeDown()
        history.swipeDown()
        XCTAssertTrue(app.buttons["Jump to latest"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Jump to latest"].waitForExistence(timeout: 5), "Rotation should preserve the reading position")
        XCTAssertFalse(latest.isHittable)
        XCUIDevice.shared.orientation = .portrait
    }

    func testKeyboardKeepsFocusWhileMessagesStream() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chatStream"]
        app.launch()
        let message = app.textFields["Message"]
        XCTAssertTrue(message.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["Hide sidebar"].exists, "The sidebar should not cover the composer. \(app.debugDescription)")
        message.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "The keyboard should open while updates arrive. \(app.debugDescription)")
        message.typeText("Draft during updates")
        XCTAssertTrue(keyboard.exists, "Streaming updates should not dismiss the keyboard")
        let typed = app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.textViews.firstMatch
        XCTAssertTrue((typed.value as? String ?? "").contains("Draft during updates"))
    }

    func testQueuedMessageCanBeEditedAndRemoved() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-previewScript", "fullDirectory", "-previewReady",
                                "-previewDestination", "chat", "-previewQueue"]
        app.launch()
        let edit = app.buttons["Edit queued message"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        edit.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(" revised")
        let edited = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(edited.contains("revised"))
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[edited].waitForExistence(timeout: 10))
        app.buttons["Remove queued message"].tap()
        XCTAssertTrue(app.staticTexts[edited].waitForNonExistence(timeout: 10))
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
