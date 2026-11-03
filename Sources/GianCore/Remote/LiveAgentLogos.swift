import CryptoKit
import Foundation

extension LiveGianClientService {
    /// `proxy.logo`: the Agent's own logo from the Host, the asset the desktop
    /// app shows. A missing logo isn't a connection problem, so failures here
    /// leave the service's failure state alone.
    public func agentLogo(scope: ClientScope, pluginID: String, variant: AgentLogoVariant) async -> AgentLogoResponse {
        guard !pluginID.isEmpty, pluginID.utf8.count <= 256 else { return .notFound }
        do {
            let data = try await rpc(scope: scope, method: "proxy.logo",
                                     params: .object(["proxy": .string(pluginID), "variant": .string(variant.rawValue)]))
            return .logo(try RemoteMapping.agentLogo(data))
        } catch {
            let safe = error is CancellationError ? RemoteClientError.cancelled : (error as? RemoteClientError) ?? .transport
            switch safe {
            case .server(code: "RESOURCE_NOT_FOUND", retryAfter: _): return .notFound
            // Hosts that predate the method reject it as an unknown frame.
            case .server(code: "INVALID_FRAME", retryAfter: _), .unsupported: return .unsupported
            default: return .failed(safe.safeDescription)
            }
        }
    }
}

extension RemoteMapping {
    /// PNG or WebP only (what the Host validates), standard base64, and the
    /// bytes must match the Host's SHA-256.
    static func agentLogo(_ value: WireValue) throws -> Data {
        try value.closed(["media_type", "data_base64", "sha256"])
        let mediaType = try value.string("media_type", maximum: 32)
        guard mediaType == "image/png" || mediaType == "image/webp" else { throw RemoteClientError.invalidPayload }
        guard let bytes = Data(base64Encoded: try value.string("data_base64", maximum: RemoteWire.maxFrame)),
              !bytes.isEmpty, bytes.count <= 384 * 1024 else { throw RemoteClientError.invalidPayload }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == (try value.string("sha256", maximum: 64)).lowercased() else { throw RemoteClientError.integrity }
        return bytes
    }
}
