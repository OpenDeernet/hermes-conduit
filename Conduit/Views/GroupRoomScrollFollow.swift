import SwiftUI
import UIKit

/// Whether a group room's transcript follows the latest event, by the chat
/// screen's rules (ChatScrollEngine): only the user's own scrolling leaves
/// following, and only bringing the transcript back near the bottom (or an
/// explicit jump or send) returns to it. Events arriving below never change
/// it, so reading history while a member works stays put.
enum GroupRoomFollow {
    /// The chat screen's tolerance (ChatScrollEngine.nearBottomTolerance).
    static let nearBottomTolerance: CGFloat = 40

    /// The follow state after a scroll-offset change. A change the user
    /// didn't drive (new rows, a programmatic scroll) keeps `current`.
    static func following(
        current: Bool,
        userScrolling: Bool,
        distanceFromBottom: CGFloat
    ) -> Bool {
        guard userScrolling else { return current }
        return distanceFromBottom <= nearBottomTolerance
    }
}

/// Placed behind the room's transcript stack inside its ScrollView. Finds
/// the UIScrollView SwiftUI renders it with and reports follow changes from
/// the user's drags (iOS 17 has no SwiftUI API for scroll geometry).
struct GroupRoomScrollLocator: UIViewRepresentable {
    @Binding var isFollowing: Bool

    func makeUIView(context: Context) -> GroupRoomScrollLocatorView {
        GroupRoomScrollLocatorView()
    }

    func updateUIView(_ view: GroupRoomScrollLocatorView, context: Context) {
        view.isFollowing = isFollowing
        let binding = $isFollowing
        view.onChange = { following in
            // KVO can land mid-update; write the binding after it.
            DispatchQueue.main.async { binding.wrappedValue = following }
        }
    }

    static func dismantleUIView(_ view: GroupRoomScrollLocatorView, coordinator: ()) {
        view.disconnect()
    }
}

final class GroupRoomScrollLocatorView: UIView {
    var isFollowing = true
    var onChange: ((Bool) -> Void)?

    private weak var scrollView: UIScrollView?
    private var observation: NSKeyValueObservation?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            disconnect()
        } else {
            connectIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        connectIfNeeded()
    }

    func disconnect() {
        observation?.invalidate()
        observation = nil
        scrollView = nil
    }

    private func connectIfNeeded() {
        guard window != nil else { return }
        var candidate = superview
        while let view = candidate, !(view is UIScrollView) {
            candidate = view.superview
        }
        guard let found = candidate as? UIScrollView, found !== scrollView else { return }
        disconnect()
        scrollView = found
        observation = found.observe(\.contentOffset, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.scrolled() }
            } else {
                DispatchQueue.main.async { self?.scrolled() }
            }
        }
    }

    private func scrolled() {
        guard let scrollView else { return }
        let distance = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
            - (scrollView.contentOffset.y + scrollView.bounds.height)
        let next = GroupRoomFollow.following(
            current: isFollowing,
            userScrolling: scrollView.isTracking || scrollView.isDecelerating,
            distanceFromBottom: distance
        )
        guard next != isFollowing else { return }
        isFollowing = next
        onChange?(next)
    }
}
