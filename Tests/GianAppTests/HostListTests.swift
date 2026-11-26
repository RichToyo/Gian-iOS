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

/// The Host dot used to show the last snapshot's "online" forever: a Mac that
/// went to sleep stayed green, and Hosts never visited stayed red.
@MainActor
final class HostStatusProjectionTests: XCTestCase {
    private func state(_ connection: ConnectionProjection, connectivity: LocalConnectivity = .available) -> GianClientState {
        var state = GianClientState.signedOut()
        let current = HostID(rawValue: "host-current")!
        state.hosts = [HostSummary(id: current, name: "Mac", online: true, version: "1"),
                       HostSummary(id: HostID(rawValue: "host-other")!, name: "Other", online: true, version: "1")]
        state.currentHostID = current
        state.connection = connection
        state.localConnectivity = connectivity
        return state
    }

    func testCurrentHostFollowsTheLiveConnection() {
        XCTAssertEqual(StoreProjection.hosts(state(.online)).map(\.status), [.online, .notConnected])
        XCTAssertEqual(StoreProjection.hosts(state(.reconnecting)).first?.status, .connecting)
        XCTAssertEqual(StoreProjection.hosts(state(.resyncing)).first?.status, .connecting)
        XCTAssertEqual(StoreProjection.hosts(state(.hostOffline)).first?.status, .offline)
        XCTAssertEqual(StoreProjection.hosts(state(.offline)).first?.status, .offline)
        XCTAssertEqual(StoreProjection.hosts(state(.online, connectivity: .unavailable)).first?.status, .offline)
    }
}
