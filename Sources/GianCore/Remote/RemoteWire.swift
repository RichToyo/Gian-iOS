import Foundation
import CryptoKit

enum RemoteWire {
    static let relay = "gian.relay/1"
    static let maxFrame = 512 * 1024
    static let maxSnapshot = 4 * 1024 * 1024
    // Leaves ample room for base64 expansion and the JSON framing bound.
    static let chunkBytes = 128 * 1024
    static let supportedFeatures: [KnownWireFeature] = [.snapshotParts, .transcriptPage, .hostLocale, .conversationTranslation, .sessionDirectoryV1]
    static let knownErrors: Set<String> = [
        "AUTH_REQUIRED", "DEVICE_NOT_PAIRED", "DEVICE_REVOKED", "HOST_OFFLINE",
        "HOST_RESTARTED", "REMOTE_CAPABILITY_DENIED", "PROTOCOL_VERSION_UNSUPPORTED",
        "PRECONDITION_FAILED", "COMMAND_EXPIRED", "SNAPSHOT_REQUIRED", "INVALID_FRAME",
        "FRAME_TOO_LARGE", "RATE_LIMITED", "ATTACHMENT_NOT_FOUND", "ATTACHMENT_HASH_MISMATCH",
        "UPLOAD_EXPIRED", "TRANSFER_CONFLICT", "FILE_REFERENCE_EXPIRED", "FILE_TOO_LARGE",
        "RESOURCE_NOT_FOUND", "UNKNOWN_OUTCOME",
    ]

    static func error(_ value: WireValue, retryAfter: Int? = nil) -> RemoteClientError {
        let code = (try? value.string("code")) ?? "UNKNOWN_OUTCOME"
        guard knownErrors.contains(code) else { return .invalidPayload }
        switch code {
        case "DEVICE_REVOKED": return .deviceRevoked
        case "AUTH_REQUIRED": return .notAuthorized
        case "FILE_REFERENCE_EXPIRED", "UPLOAD_EXPIRED", "COMMAND_EXPIRED", "ATTACHMENT_NOT_FOUND": return .expired
        case "REMOTE_CAPABILITY_DENIED": return .capabilityDenied
        case "PROTOCOL_VERSION_UNSUPPORTED": return .versionMismatch
        default: return .server(code: code, retryAfter: retryAfter)
        }
    }

    static func origin(_ server: ServerAddress) throws -> URL {
        guard let checked = ServerAddress(parsing: server.absoluteString), checked == server,
              let host = server.origin.host, !host.isEmpty,
              server.origin.port.map({ (1...65535).contains($0) }) ?? true else {
            throw RemoteClientError.invalidServer
        }
        return checked.origin
    }

    static func id(_ value: String) throws -> String {
        guard value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                          options: .regularExpression) != nil else { throw RemoteClientError.invalidPayload }
        return value
    }

    static func commandDate(_ id: String) throws -> Int {
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        guard id.range(of: pattern, options: .regularExpression) != nil,
              let milliseconds = Int(id.prefix(13).replacingOccurrences(of: "-", with: ""), radix: 16) else {
            throw RemoteClientError.invalidPayload
        }
        return milliseconds
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func unbase64(_ string: String, maximum: Int = maxFrame) throws -> Data {
        guard !string.isEmpty, string.utf8.count <= maximum * 4 / 3 + 4,
              string.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw RemoteClientError.invalidPayload }
        let standard = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)),
              data.count <= maximum, base64(data) == string else { throw RemoteClientError.invalidPayload }
        return data
    }
}

/// A bounded JSON tree keeps wire decoding independent of persistence Codable additions.
indirect enum WireValue: Codable, Sendable, Equatable {
    case object([String: WireValue]), array([WireValue]), string(String), int(Int), bool(Bool), null

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count < 40 else { throw RemoteClientError.bufferLimit }
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self), (-9_007_199_254_740_991...9_007_199_254_740_991).contains(i) { self = .int(i) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([WireValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: WireValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> WireValue {
        if case .object(let values) = self { return values[key] ?? .null }
        return .null
    }
    var isNull: Bool { self == .null }
    func string(_ key: String, maximum: Int = 16_384) throws -> String {
        guard case .string(let s) = self[key], s.utf16.count <= maximum else { throw RemoteClientError.invalidPayload }
        return s
    }
    func optionalString(_ key: String, maximum: Int = 16_384) throws -> String? {
        self[key].isNull ? nil : try string(key, maximum: maximum)
    }
    func integer(_ key: String, range: ClosedRange<Int> = 0...9_007_199_254_740_991) throws -> Int {
        guard case .int(let i) = self[key], range.contains(i) else { throw RemoteClientError.invalidPayload }
        return i
    }
    func boolean(_ key: String) throws -> Bool {
        guard case .bool(let b) = self[key] else { throw RemoteClientError.invalidPayload }
        return b
    }
    func array(_ key: String, maximum: Int = 256) throws -> [WireValue] {
        guard case .array(let a) = self[key], a.count <= maximum else { throw RemoteClientError.invalidPayload }
        return a
    }
    func closed(_ required: Set<String>, optional: Set<String> = []) throws {
        guard case .object(let values) = self, required.isSubset(of: Set(values.keys)),
              Set(values.keys).isSubset(of: required.union(optional)) else { throw RemoteClientError.invalidPayload }
    }
    func identifier(_ key: String) throws -> String { try RemoteWire.id(string(key, maximum: 64)) }
    func scoped<K>(_ key: String, as: K.Type = K.self) throws -> ScopedID<K> {
        guard let id = ScopedID<K>(rawValue: try identifier(key)) else { throw RemoteClientError.invalidPayload }
        return id
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    static func decode(_ data: Data, maximum: Int = RemoteWire.maxFrame) throws -> WireValue {
        guard data.count <= maximum else { throw RemoteClientError.bufferLimit }
        do { return try JSONDecoder().decode(Self.self, from: data) }
        catch { throw RemoteClientError.invalidPayload }
    }
}

extension WireValue {
    static func strings(_ values: [String]) -> WireValue { .array(values.map { .string($0) }) }
}
