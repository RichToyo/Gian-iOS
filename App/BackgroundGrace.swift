import UIKit

/// Keeps the Host connection through a short trip away from the app (a
/// glance at another app, the app switcher). The app used to disconnect the
/// moment it stopped being active — even for Notification Center, Control
/// Center or a Face ID sheet — and every return then rebuilt the connection
/// and re-read the directory ("Syncing…", controls grayed out). Now it lets go
/// only after `grace`, or as soon as iOS says background time is up.
@MainActor
final class BackgroundGrace {
    static let grace: Duration = .seconds(25)

    private var timer: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var letGo: (@MainActor () async -> Void)?

    var isPending: Bool { timer != nil }

    func begin(letGo: @escaping @MainActor () async -> Void) {
        guard timer == nil else { return }
        self.letGo = letGo
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Keep the Host connection") { [weak self] in
            // iOS is about to suspend the app: let go now, and hand the
            // background time back at once (it must end before returning;
            // storage was already saved when the app left the screen).
            MainActor.assumeIsolated {
                self?.expire()
                self?.endBackgroundTask()
            }
        }
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.grace) } catch { return }
            self?.expire()
        }
    }

    /// Back in front within the grace: the connection never dropped.
    func cancel() {
        timer?.cancel(); timer = nil
        letGo = nil
        endBackgroundTask()
    }

    private func expire() {
        guard timer != nil, let letGo else { return }
        timer?.cancel(); timer = nil
        self.letGo = nil
        Task { @MainActor [weak self] in
            await letGo()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
