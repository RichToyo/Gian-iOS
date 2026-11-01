import XCTest
@testable import GianCore
@testable import Gian

final class RestorationHintSelectionTests: XCTestCase {
    func testReadySelectionTracksSamePhaseHostServerAndAccountChanges() {
        var state = GianClientState.signedOut()
        state.phase = .ready
        state.server = ServerAddress(parsing: "https://one.example.test")
        state.account = AccountAuthorization(
            status: .signedIn,
            accountID: AccountID(provider: .github, id: "10001"),
            login: "fixture-user"
        )
        state.currentHostID = HostID(rawValue: "host-one")

        let original = RestorationHintSelection(state)
        state.currentHostID = HostID(rawValue: "host-two")
        let hostChange = RestorationHintSelection(state)
        XCTAssertEqual(hostChange.phase, .ready)
        XCTAssertNotEqual(hostChange, original)
        XCTAssertEqual(hostChange.host, HostID(rawValue: "host-two"))

        state.server = ServerAddress(parsing: "https://two.example.test")
        let serverChange = RestorationHintSelection(state)
        XCTAssertEqual(serverChange.phase, .ready)
        XCTAssertNotEqual(serverChange, hostChange)
        XCTAssertEqual(serverChange.server?.absoluteString, "https://two.example.test")

        state.account.accountID = AccountID(provider: .github, id: "10002")
        let accountChange = RestorationHintSelection(state)
        XCTAssertEqual(accountChange.phase, .ready)
        XCTAssertNotEqual(accountChange, serverChange)
        XCTAssertEqual(accountChange.account, AccountID(provider: .github, id: "10002"))
        XCTAssertEqual(accountChange.host, HostID(rawValue: "host-two"))
    }
}
