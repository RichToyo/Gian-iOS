import SwiftUI
import UIKit
import XCTest
@testable import GianCore
@testable import Gian

/// List rows draw each Agent's logo once at its display size, already
/// rounded, instead of scaling and clipping a large image every frame.
@MainActor
final class AgentAvatarTests: XCTestCase {
    func testHostLogoIsDrawnOnceAtItsDisplaySize() throws {
        let large = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        let logo = AgentLogo(pluginID: "test.plugin", agentName: "Test")
        let logos = ["test.plugin": AgentLogoImages(light: large)]
        let avatar = try XCTUnwrap(AgentLogoArt.avatar(for: logo, in: logos, scheme: .light, side: 16, scale: 3))
        XCTAssertEqual(avatar.size, CGSize(width: 16, height: 16))
        XCTAssertEqual(avatar.scale, 3)
        XCTAssertTrue(avatar === AgentLogoArt.avatar(for: logo, in: logos, scheme: .light, side: 16, scale: 3),
                      "drawn once, then reused")
    }

    func testBundledLogoIsDrawnAtItsDisplaySize() throws {
        let logo = AgentLogo(pluginID: "claude-code", agentName: "Claude Code")
        let avatar = try XCTUnwrap(AgentLogoArt.avatar(for: logo, in: [:], scheme: .dark, side: 20, scale: 2))
        XCTAssertEqual(avatar.size, CGSize(width: 20, height: 20))
    }

    func testAgentWithoutALogoHasNoAvatarImage() {
        let logo = AgentLogo(pluginID: "unknown.plugin", agentName: "Ada")
        XCTAssertNil(AgentLogoArt.avatar(for: logo, in: [:], scheme: .light, side: 16, scale: 3))
    }
}
