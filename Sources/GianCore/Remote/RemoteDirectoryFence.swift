import Foundation

/// Local producer provenance only. Neither counter is a canonical Host sequence.
struct RemoteDirectoryReadFence {
    let epoch: Int
    let read: Int
    let invalidation: Int
}

extension LiveGianClientService {
    func beginDirectoryRead() -> RemoteDirectoryReadFence {
        directoryReadGeneration += 1
        snapshot = nil
        catalog = nil
        return RemoteDirectoryReadFence(epoch: epoch, read: directoryReadGeneration, invalidation: directoryInvalidationGeneration)
    }

    func directoryReadIsCurrent(_ fence: RemoteDirectoryReadFence) -> Bool {
        fence.epoch == epoch && fence.read == directoryReadGeneration && fence.invalidation == directoryInvalidationGeneration
    }

    func checkDirectoryRead(_ fence: RemoteDirectoryReadFence) throws {
        try Task.checkCancellation()
        guard directoryReadIsCurrent(fence) else { throw RemoteClientError.cancelled }
    }

    func invalidateDirectoryRead() {
        directoryInvalidationGeneration += 1
        snapshot = nil
        catalog = nil
        stagedSnapshot = nil
    }
}
