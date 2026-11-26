import XCTest
import UniformTypeIdentifiers
import ImageIO
@testable import GianCore
@testable import Gian

@MainActor
final class LinkDestinationTests: XCTestCase {
    func testWebLinksOpenInTheBrowser() {
        XCTAssertEqual(LinkDestination(URL(string: "https://example.com/a")!), .web)
        XCTAssertEqual(LinkDestination(URL(string: "mailto:a@example.com")!), .web)
    }

    func testRelativeAndFileLinksAreRepositoryFiles() {
        XCTAssertEqual(LinkDestination(URL(string: "src/foo.ts")!), .file("src/foo.ts"))
        XCTAssertEqual(LinkDestination(URL(string: "./README.md#setup")!), .file("README.md#setup"))
        XCTAssertEqual(LinkDestination(URL(string: "src/My%20File.swift")!), .file("src/My File.swift"))
        XCTAssertEqual(LinkDestination(URL(string: "file:///repo/a.swift")!), .file("/repo/a.swift"))
    }

    func testOtherSchemesGoNowhere() {
        XCTAssertEqual(LinkDestination(URL(string: "javascript:alert(1)")!), .blocked)
        XCTAssertEqual(LinkDestination(URL(string: "data:text/html,hi")!), .blocked)
        XCTAssertEqual(LinkDestination(URL(string: "#anchor")!), .blocked)
    }
}

final class CodeHighlighterTests: XCTestCase {
    private func kinds(_ code: String, _ language: String?) -> [CodeHighlighter.Token] {
        CodeHighlighter.tokens(code, language: language).map(\.1)
    }

    func testSwiftKeywordsStringsNumbersAndComments() {
        let tokens = CodeHighlighter.tokens("let x = \"hi\" // note\nreturn 42", language: "swift")
        XCTAssertTrue(tokens.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(tokens.contains { $0 == ("\"hi\"", .string) })
        XCTAssertTrue(tokens.contains { $0 == ("// note", .comment) })
        XCTAssertTrue(tokens.contains { $0 == ("42", .number) })
        // Nothing is lost or reordered.
        XCTAssertEqual(tokens.map(\.0).joined(), "let x = \"hi\" // note\nreturn 42")
    }

    func testShellCommentsAndIdentifiersWithDigits() {
        let tokens = CodeHighlighter.tokens("echo $HOME2 # done", language: "sh")
        XCTAssertTrue(tokens.contains { $0 == ("# done", .comment) })
        XCTAssertFalse(tokens.contains { $0.1 == .number })
    }

    func testVeryLongCodeStaysPlain() {
        let code = String(repeating: "let a = 1\n", count: 4_000)
        XCTAssertEqual(CodeHighlighter.highlight(code, language: "swift").runs.count, 1)
    }
}

@MainActor
final class ActionRejectionNoticeTests: XCTestCase {
    func testUserCommandsExplainWhyTheyDidNothing() {
        XCTAssertEqual(ActionRejectionNotice.message(for: .send, code: .missingAgent), "Choose an Agent first.")
        XCTAssertEqual(ActionRejectionNotice.message(for: .send, code: .mutationsDisabled),
                       "Still syncing with the Host. Try again in a moment.")
        XCTAssertNotNil(ActionRejectionNotice.message(for: .addDraftAttachment(AttachmentDraftInput(filename: "a", mime: "b", bytes: Data())),
                                                     code: .attachmentRejected))
    }

    func testBackgroundReadsAndAlreadyShownReasonsStayQuiet() {
        XCTAssertNil(ActionRejectionNotice.message(for: .refreshDirectory, code: .mutationsDisabled))
        XCTAssertNil(ActionRejectionNotice.message(for: .send, code: .offlineDraftRetained))
        XCTAssertNil(ActionRejectionNotice.message(for: .send, code: .emptyDraft))
    }
}

@MainActor
final class ListConnectionNoticeTests: XCTestCase {
    private func state(_ connection: ConnectionProjection, connectivity: LocalConnectivity = .available) -> GianClientState {
        var state = GianClientState.signedOut()
        let host = HostID(rawValue: "host-mac")!
        state.phase = .ready
        state.hosts = [HostSummary(id: host, name: "Studio Mac", online: true, version: "1")]
        state.currentHostID = host
        state.connection = connection
        state.localConnectivity = connectivity
        return state
    }

    func testTheListSaysWhenItIsNotLive() {
        XCTAssertNil(StoreProjection.listConnectionNotice(state(.online)))
        XCTAssertNil(StoreProjection.listConnectionNotice(state(.resyncing)))
        XCTAssertEqual(StoreProjection.listConnectionNotice(state(.hostOffline)), .hostOffline("Studio Mac"))
        XCTAssertEqual(StoreProjection.listConnectionNotice(state(.offline)), .serverUnreachable)
        XCTAssertEqual(StoreProjection.listConnectionNotice(state(.online, connectivity: .unavailable)), .noNetwork)
        XCTAssertEqual(StoreProjection.listConnectionNotice(state(.deviceRevoked)), .revoked)
    }
}

@MainActor
final class PickedImageTests: XCTestCase {
    private func image(width: Int, height: Int, type: UTType) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil),
              let cgImage = image.cgImage else { throw XCTSkip("Can't encode \(type.identifier) here") }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("Can't encode \(type.identifier) here") }
        return data as Data
    }

    func testReadableSmallImagesStayAsTheyAre() throws {
        let png = try image(width: 40, height: 30, type: .png)
        let prepared = try XCTUnwrap(PickedImage.prepare(png, type: .png))
        XCTAssertEqual(prepared.data, png)
        XCTAssertEqual(prepared.mime, "image/png")
    }

    func testCameraFormatsBecomeJPEG() throws {
        let heic = try image(width: 40, height: 30, type: .heic)
        let prepared = try XCTUnwrap(PickedImage.prepare(heic, type: .heic))
        XCTAssertEqual(prepared.mime, "image/jpeg")
        XCTAssertEqual(prepared.fileExtension, "jpg")
        XCTAssertNotNil(UIImage(data: prepared.data))
    }

    func testPhotoNamesAreSafeFilenames() {
        let name = "Photo \(PickedImage.stamp.string(from: Date())) 2.jpg"
        XCTAssertTrue(AttachmentRules.safeFilename(name))
    }
}
