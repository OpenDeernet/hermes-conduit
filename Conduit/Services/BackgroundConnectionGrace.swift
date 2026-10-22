import UIKit

/// Keeps Conduit running for a short while after it leaves the screen, so
/// the chat socket keeps answering Hermes' pings through a quick trip to
/// another app (notifier #296). Hermes pings every 20 s and gives up after
/// 20 s more; once iOS suspends the app nothing answers, and a return after
/// that has to reconnect. With the hold, a switch away of up to about a
/// minute comes back to the same open socket.
///
/// iOS grants about 30 s of background time and nothing longer for a plain
/// socket: there is no background mode that keeps a chat connection open.
@MainActor
final class BackgroundConnectionGrace {
    /// Under iOS's ~30 s allowance, so the hold always ends on our side
    /// rather than at iOS's deadline.
    static let window: TimeInterval = 25

    private let beginTask: (_ expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    private let endTask: (UIBackgroundTaskIdentifier) -> Void
    private let sleep: (TimeInterval) async -> Void
    private let window: TimeInterval
    private var taskID = UIBackgroundTaskIdentifier.invalid
    private var timer: Task<Void, Never>?

    init(
        window: TimeInterval = BackgroundConnectionGrace.window,
        beginTask: ((_ expired: @escaping () -> Void) -> UIBackgroundTaskIdentifier)? = nil,
        endTask: ((UIBackgroundTaskIdentifier) -> Void)? = nil,
        sleep: ((TimeInterval) async -> Void)? = nil
    ) {
        self.window = window
        self.beginTask = beginTask ?? { expired in
            UIApplication.shared.beginBackgroundTask(
                withName: "conduit.chatSocket.grace",
                expirationHandler: expired
            )
        }
        self.endTask = endTask ?? { UIApplication.shared.endBackgroundTask($0) }
        self.sleep = sleep ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    var isHolding: Bool { taskID != .invalid }

    /// Conduit left the screen with an open socket. A hold already running
    /// starts over.
    func begin() {
        end()
        // iOS calls the expiration handler on the main queue.
        let id = beginTask { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
        guard id != .invalid else { return }
        taskID = id
        let window = window
        let sleep = sleep
        timer = Task { @MainActor [weak self] in
            await sleep(window)
            guard !Task.isCancelled, let self, self.taskID == id else { return }
            self.end()
        }
    }

    /// Back on screen, signed out, or the window ran out.
    func end() {
        timer?.cancel()
        timer = nil
        guard taskID != .invalid else { return }
        let id = taskID
        taskID = .invalid
        endTask(id)
    }
}
