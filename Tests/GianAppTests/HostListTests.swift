import XCTest
@testable import GianCore
@testable import Gian

@MainActor
final class HostListTests: XCTestCase {
    func testAllOfflineHostsRemainSelectableWithoutCurrentHost() {
        let work = HostID(rawValue: "host-work")!
        let home = HostID(rawValue: "host-home")!
        var selected: [HostID] = []
        let list = HostList(
            hosts: [
                HostItem(id: work, name: "Work", isReachable: false, isCurrent: false),
                HostItem(id: home, name: "Home", isReachable: false, isCurrent: false),
            ],
            onSelect: { selected.append($0) },
            onAddHost: {},
            onManage: {}
        )

        let rows = list.hostRows

        XCTAssertEqual(rows.map(\.isEnabled), [true, true])
        XCTAssertEqual(rows.map(\.isSelected), [false, false])
        XCTAssertEqual(rows.map(\.subtitle), ["Offline", "Offline"])
        rows.forEach { $0.action() }
        XCTAssertEqual(selected, [work, home])
    }

    func testOfflineCurrentHostRemainsSelectableForRetry() throws {
        let current = HostID(rawValue: "host-current")!
        var selected: HostID?
        let list = HostList(
            hosts: [HostItem(id: current, name: "Current", isReachable: false, isCurrent: true)],
            onSelect: { selected = $0 },
            onAddHost: {},
            onManage: {}
        )

        let row = try XCTUnwrap(list.hostRows.first)

        XCTAssertTrue(row.isEnabled)
        XCTAssertTrue(row.isSelected)
        XCTAssertEqual(row.subtitle, "Offline")
        row.action()
        XCTAssertEqual(selected, current)
    }

    func testOfflineHostCanBeSelectedWhileAnotherHostIsOnline() {
        let work = HostID(rawValue: "host-work")!
        let home = HostID(rawValue: "host-home")!
        var selected: HostID?
        let list = HostList(
            hosts: [
                HostItem(id: work, name: "Work", isReachable: true, isCurrent: true),
                HostItem(id: home, name: "Home", isReachable: false, isCurrent: false),
            ],
            onSelect: { selected = $0 },
            onAddHost: {},
            onManage: {}
        )

        let rows = list.hostRows
        XCTAssertEqual(rows.map(\.isEnabled), [true, true])
        XCTAssertEqual(rows.map(\.isSelected), [true, false])
        XCTAssertEqual(rows.map(\.subtitle), ["Online", "Offline"])
        rows[1].action()
        XCTAssertEqual(selected, home)
    }
}
