import Foundation

/// Single-consumer bounded inbox, registered before the corresponding send.
@MainActor
final class RemoteMailbox {
    var queue: [WireValue] = []
    var waiter: CheckedContinuation<WireValue, any Error>?
    var failure: RemoteClientError?
    let limit: Int
    init(limit: Int = 8) { self.limit = limit }
    func push(_ value: WireValue) throws {
        guard failure == nil else { return }
        if let continuation = waiter { waiter = nil; continuation.resume(returning: value) }
        else {
            guard queue.count < limit else { fail(.bufferLimit); throw RemoteClientError.bufferLimit }
            queue.append(value)
        }
    }
    func fail(_ error: RemoteClientError) {
        failure = error; queue.removeAll()
        if let continuation = waiter { waiter = nil; continuation.resume(throwing: error) }
    }
    func next(timeout: Duration = .seconds(20)) async throws -> WireValue {
        try Task.checkCancellation()
        if let failure { throw failure }
        if !queue.isEmpty { return queue.removeFirst() }
        guard waiter == nil else { throw RemoteClientError.invalidPayload }
        let timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout); self?.fail(.timeout) } catch {}
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(.cancelled) }
        }
    }
}

@MainActor
struct RemoteCommandWaiter {
    let attempt: String
    let method: String
    let mailbox: RemoteMailbox
}

struct RemoteSnapshotAssembly {
    let id: String
    let generation: String
    let revision: String
    let sequence: Int
    let total: Int
    let size: Int
    let hash: String
    var parts: [Int: Data] = [:]
    var bytes = 0
}

@MainActor
struct RemoteTransfer {
    let mailbox: RemoteMailbox
}
