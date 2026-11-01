import Foundation

public struct RemoteHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let retryAfterSeconds: Int?
    public init(status: Int, body: Data, retryAfterSeconds: Int? = nil) {
        self.status = status; self.body = body; self.retryAfterSeconds = retryAfterSeconds
    }
}

@MainActor
public protocol RemoteWebSocket: AnyObject {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

@MainActor
public protocol RemoteTransport: AnyObject {
    func request(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RemoteHTTPResponse
    func openWebSocket(_ request: URLRequest) async throws -> any RemoteWebSocket
}

private final class RemoteSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Authenticated endpoints must never redirect, even within one origin.
        completionHandler(nil)
    }
}

/// Uses system TLS trust. No cookies, shared credentials, disk cache or redirect forwarding.
@MainActor
public final class URLSessionRemoteTransport: RemoteTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: RemoteSessionDelegate(), delegateQueue: nil)
    }
    public func request(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RemoteHTTPResponse {
        guard request.url?.scheme == "https", maximumResponseBytes > 0 else { throw RemoteClientError.invalidServer }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url,
              response.expectedContentLength <= maximumResponseBytes else { throw RemoteClientError.bufferLimit }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else { throw RemoteClientError.bufferLimit }
            data.append(byte)
        }
        return RemoteHTTPResponse(status: http.statusCode, body: data,
            retryAfterSeconds: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
    }
    public func openWebSocket(_ request: URLRequest) async throws -> any RemoteWebSocket {
        guard request.url?.scheme == "wss" else { throw RemoteClientError.invalidServer }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = RemoteWire.maxFrame
        task.resume()
        return URLSessionRemoteSocket(task: task)
    }
}

@MainActor
private final class URLSessionRemoteSocket: RemoteWebSocket {
    let task: URLSessionWebSocketTask
    private var heartbeat: Task<Void, Never>?
    init(task: URLSessionWebSocketTask) {
        self.task = task
        heartbeat = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(20))
                    guard let self else { return }
                    try await self.ping()
                }
            } catch { self?.close() }
        }
    }
    private func ping() async throws {
        let watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)); self?.close() } catch {}
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    func send(_ data: Data) async throws {
        guard data.count <= RemoteWire.maxFrame, let text = String(data: data, encoding: .utf8) else {
            throw RemoteClientError.bufferLimit
        }
        try Task.checkCancellation()
        try await task.send(.string(text))
    }
    func receive() async throws -> Data {
        try Task.checkCancellation()
        let message = try await task.receive()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw RemoteClientError.invalidPayload
        }
        guard data.count <= RemoteWire.maxFrame else { close(); throw RemoteClientError.bufferLimit }
        return data
    }
    func close() {
        heartbeat?.cancel(); heartbeat = nil
        task.cancel(with: .goingAway, reason: nil)
    }
}
