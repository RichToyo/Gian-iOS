import CryptoKit
import Foundation
import Testing
@testable import GianCore

/// Add Host: pairing another Host while signed in keeps the current Host open
/// until the new one is confirmed, then switches to it. Agent logos: read once
/// per Host and appearance with `proxy.logo`.
@MainActor
struct AddHostAndLogoTests {
    private let lighthouse = HostSummary(id: PreviewFixtures.id("host-lighthouse", HostID.self), name: "Lighthouse",
                                         online: true, version: "0.6.9")
    private let pairing = PreviewFixtures.id("pairing-2", PairingID.self)

    private func harness() async throws -> (GianClientStore, ControlledService) {
        let service = ControlledService()
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: service, clock: clock, ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        service.extraHosts = [lighthouse]
        return (store, service)
    }

    @Test func pairingAnotherHostWaitsOnTheCurrentOneThenSwitches() async throws {
        let (store, service) = try await harness()
        let harbor = try #require(store.state.currentHostID)
        service.claimResponses = [.pendingConfirmation(pairing, lighthouse.id)]

        #expect(await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr)) == .applied)
        #expect(store.state.phase == .ready)
        #expect(store.state.currentHostID == harbor)
        #expect(store.state.pendingPairing == PendingHostPairing(pairingID: pairing, hostID: lighthouse.id))

        service.pairingRefreshResponses = [.confirmed(lighthouse, deviceID: PreviewFixtures.deviceID)]
        _ = await store.dispatch(.refreshHostPairing)
        #expect(store.state.phase == .ready)
        #expect(store.state.pendingPairing == nil)
        #expect(store.state.hosts.map(\.id) == [harbor, lighthouse.id])
        #expect(store.state.currentHostID == lighthouse.id)
        #expect(store.state.pairingOutcome == .paired(lighthouse.id))
        #expect(store.state.navigation == .home)
    }

    /// Pairing a Host that is already paired still reports success, so Add
    /// Host can close even though the Host list doesn't change.
    @Test func repairingAKnownHostReportsSuccess() async throws {
        let (store, _) = try await harness()
        let harbor = try #require(store.state.currentHostID)
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))
        #expect(store.state.hosts.map(\.id) == [harbor])
        #expect(store.state.pairingOutcome == .paired(harbor))
        #expect(await store.dispatch(.cancelHostPairing) == .applied)
        #expect(store.state.pairingOutcome == nil)
    }

    /// From Home, a Host switch (here: pairing the current Host again) lands
    /// on Home, not in the Host's untouched new-chat draft.
    @Test func switchingHostsFromHomeStaysHome() async throws {
        let clock = ManualGianClock(instant: PreviewFixtures.instant)
        let store = GianClientStore(service: PreviewGianClientService(script: .fullDirectory), clock: clock,
                                    ids: SequenceIDGenerator(), storage: InMemoryGianStorage())
        _ = try await signIn(store, clock: clock)
        #expect(store.state.navigation.destination == .home)
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))
        #expect(store.state.navigation.destination == .home)
    }

    @Test func cancelDropsALateConfirmation() async throws {
        let (store, service) = try await harness()
        let harbor = try #require(store.state.currentHostID)
        service.claimResponses = [.pendingConfirmation(pairing, lighthouse.id)]
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))

        service.holdNextPairingRefresh = true
        let pending = Task { await store.dispatch(.refreshHostPairing) }
        for _ in 0..<100 where service.pairingRefresh == nil { await Task.yield() }
        let reply = try #require(service.pairingRefresh)
        #expect(await store.dispatch(.cancelHostPairing) == .applied)
        reply.resume(returning: .confirmed(lighthouse, deviceID: PreviewFixtures.deviceID))

        #expect(await pending.value == .rejected(.staleOperation))
        #expect(store.state.pendingPairing == nil)
        #expect(store.state.hosts.map(\.id) == [harbor])
        #expect(store.state.currentHostID == harbor)
    }

    @Test func failedPairingKeepsTheCurrentHostAndSaysWhy() async throws {
        let (store, service) = try await harness()
        let harbor = try #require(store.state.currentHostID)

        service.claimResponses = [.expired]
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))
        #expect(store.state.phase == .ready)
        #expect(store.state.currentHostID == harbor)
        #expect(store.state.pairingOutcome == .expired)

        _ = await store.dispatch(.beginHostPairingFromQR("not a pairing link"))
        #expect(store.state.pairingOutcome == .invalidCode)
        #expect(store.state.phase == .ready)

        service.claimResponses = [.pendingConfirmation(pairing, lighthouse.id)]
        _ = await store.dispatch(.beginHostPairingFromQR(PreviewFixtures.qr))
        #expect(store.state.pairingOutcome == nil)
    }

    @Test func agentLogosAreReadOncePerAppearance() async throws {
        let (store, service) = try await harness()
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        service.logos = ["ada.plugin": .logo(png)]

        #expect(await store.dispatch(.loadAgentLogos) == .applied)
        #expect(store.state.agentLogos["ada.plugin"] == AgentLogoImages(light: png, dark: png))
        #expect(service.logoRequests == ["ada.plugin/light", "ada.plugin/dark"])

        _ = await store.dispatch(.loadAgentLogos)
        #expect(service.logoRequests.count == 2)
    }

    @Test func missingLogosAreNotAskedAgainAndOldHostsAreLeftAlone() async throws {
        let (store, service) = try await harness()
        _ = await store.dispatch(.loadAgentLogos)
        _ = await store.dispatch(.loadAgentLogos)
        #expect(service.logoRequests == ["ada.plugin/light", "ada.plugin/dark"])
        #expect(store.state.agentLogos.isEmpty)

        let (legacy, legacyService) = try await harness()
        legacyService.logos = ["ada.plugin": .unsupported]
        #expect(await legacy.dispatch(.loadAgentLogos) == .rejected(.capabilityUnsupported))
        _ = await legacy.dispatch(.loadAgentLogos)
        #expect(legacyService.logoRequests == ["ada.plugin/light"])
    }

    @Test func logoReplyMustMatchItsDigestAndType() throws {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        func reply(_ type: String, _ sha: String) -> WireValue {
            .object(["media_type": .string(type), "data_base64": .string(bytes.base64EncodedString()), "sha256": .string(sha)])
        }
        #expect(try RemoteMapping.agentLogo(reply("image/png", digest)) == bytes)
        #expect(try RemoteMapping.agentLogo(reply("image/webp", digest)) == bytes)
        #expect(throws: RemoteClientError.integrity) { try RemoteMapping.agentLogo(reply("image/png", String(repeating: "0", count: 64))) }
        #expect(throws: RemoteClientError.invalidPayload) { try RemoteMapping.agentLogo(reply("image/svg+xml", digest)) }
    }
}
