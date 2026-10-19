import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// Runs the real ChatView in a window and checks the scroll view itself:
/// where the content actually sits after SwiftUI and UIKit have laid it out.
@MainActor
final class ChatScrollHostedTests: XCTestCase {
    private var window: UIWindow?
    private var host: UIViewController?
    private var appState: AppState?

    override func tearDown() {
        // Stop streaming, remove the hosted view synchronously and drain
        // until SwiftUI has torn it down, so no deferred work from this
        // suite lands in the next one (the reason the deleted follow
        // correction suite tore down the same way).
        appState?.setStreamingTextForTesting("")
        if let window {
            window.isHidden = true
            window.rootViewController = nil
            host?.view.removeFromSuperview()
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                if let host, host.view.subviews.isEmpty { break }
            }
        }
        window = nil
        host = nil
        appState = nil
        super.tearDown()
    }

    private struct Mounted {
        let appState: AppState
        let host: UIViewController
        let scrollView: UIScrollView
        let engine: ChatScrollEngine
    }

    private static func transcript(_ range: Range<Int>) -> [ChatMessage] {
        range.map { index in
            ChatMessage(
                id: "hosted-\(index)",
                role: index % 2 == 0 ? .user : .assistant,
                content: index % 3 == 0
                    ? "Short message \(index)."
                    : String(repeating: "Message \(index) has a few lines of ordinary prose. ", count: 4 + index % 5),
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    private func mount(_ messages: [ChatMessage], sessionID: String? = nil) throws -> Mounted {
        let suiteName = "chat-scroll-hosted"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        if let sessionID {
            appState.sessions = [SessionSummary(
                id: sessionID,
                alternateIds: [],
                title: sessionID,
                model: "Hermes",
                updatedLabel: "now",
                profile: "default",
                source: .chat,
                isActive: false,
                isArchived: false,
                lineageRootId: nil
            )]
            appState.activeSessionId = sessionID
        }
        appState.messages = messages

        let host = UIHostingController(
            rootView: DormancyHarnessEnvironment.applying(
                ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize)
                    .environmentObject(appState)
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
        self.host = host
        self.appState = appState

        var locator: ChatScrollSurfaceLocatorView?
        XCTAssertTrue(
            PerformanceFixtureWait.eventually(pumpingLayoutOf: host.view) {
                locator = Self.find(ChatScrollSurfaceLocatorView.self, in: host.view)
                return locator?.surface?.scrollView != nil
            },
            "the locator must find the transcript's UIScrollView"
        )
        let found = try XCTUnwrap(locator)
        let scrollView = try XCTUnwrap(found.surface?.scrollView)
        let engine = try XCTUnwrap(found.engine)
        settle(host.view)
        return Mounted(appState: appState, host: host, scrollView: scrollView, engine: engine)
    }

    private static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    /// Pumps layout and the run loop long enough for lazy rows to measure.
    private func settle(_ view: UIView, seconds: TimeInterval = 0.6) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func maxOffset(_ scrollView: UIScrollView) -> CGFloat {
        max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        )
    }

    private func assertAtLatest(
        _ mounted: Mounted,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let distance = maxOffset(mounted.scrollView) - mounted.scrollView.contentOffset.y
        XCTAssertLessThanOrEqual(abs(distance), 1, "\(message) (distance \(distance))", file: file, line: line)
    }

    /// What a finger would do: begin a drag, move the content, let go.
    private func browse(_ mounted: Mounted, to offsetY: CGFloat) {
        mounted.engine.userDragBegan()
        mounted.scrollView.contentOffset.y = offsetY
        mounted.engine.userDragEnded()
        settle(mounted.host.view, seconds: 0.3)
    }

    /// Screen position (relative to the viewport top) of a laid-out row.
    private func screenY(of id: String, in mounted: Mounted) -> CGFloat? {
        guard let frame = mounted.engine.rowFrame(for: id),
              let surface = mounted.engine.surface else { return nil }
        return surface.transcriptOriginY + frame.minY - mounted.scrollView.contentOffset.y
    }

    /// Records every offset and content-size change the scroll view goes
    /// through, and whether the engine made the offset change, so a failure
    /// says which side moved the transcript.
    private final class ScrollRecorder {
        struct Change {
            let time: CFTimeInterval
            let text: String
            let isOffset: Bool
            let byEngine: Bool
            var distance: CGFloat = 0
        }

        private(set) var changes: [Change] = []
        private var observations: [NSKeyValueObservation] = []
        private let start = CACurrentMediaTime()

        init(_ scrollView: UIScrollView) {
            observations = [
                scrollView.observe(\.contentOffset, options: [.old, .new]) { [weak self] view, change in
                    guard let self, change.oldValue != change.newValue else { return }
                    let stack = Thread.callStackSymbols
                    let byEngine = stack.contains { $0.contains("ChatScrollEngine") }
                    let writer = byEngine ? "engine" : Self.writer(in: stack)
                    // Clamped like ChatScrollSurface.maxOffsetY.
                    let max = Swift.max(
                        -view.adjustedContentInset.top,
                        view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height
                    )
                    self.record(
                        String(
                            format: "offset %.1f -> %.1f (max %.1f) by %@",
                            change.oldValue?.y ?? .nan, change.newValue?.y ?? .nan, max, writer
                        ),
                        isOffset: true,
                        byEngine: byEngine,
                        distance: abs((change.newValue?.y ?? 0) - (change.oldValue?.y ?? 0))
                    )
                },
                scrollView.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                    guard let self, change.oldValue != change.newValue else { return }
                    self.record(
                        String(
                            format: "bounds y %.1f h %.1f -> y %.1f h %.1f",
                            change.oldValue?.origin.y ?? .nan, change.oldValue?.height ?? .nan,
                            change.newValue?.origin.y ?? .nan, change.newValue?.height ?? .nan
                        ),
                        isOffset: false,
                        byEngine: false
                    )
                },
                scrollView.observe(\.contentSize, options: [.old, .new]) { [weak self] _, change in
                    guard let self, change.oldValue != change.newValue else { return }
                    self.record(
                        String(
                            format: "contentSize %.1f -> %.1f",
                            change.oldValue?.height ?? .nan, change.newValue?.height ?? .nan
                        ),
                        isOffset: false,
                        byEngine: false
                    )
                },
            ]
        }

        private static func writer(in stack: [String]) -> String {
            // The first frame below the KVO machinery that is not UIKit's own
            // setter names who moved the scroll view.
            let frames = stack.dropFirst(1).filter {
                !$0.contains("NSKeyValue") && !$0.contains("Foundation")
                    && !$0.contains("ScrollRecorder") && !$0.contains("setContentOffset")
                    && !$0.contains("setBounds")
            }
            return frames.prefix(4)
                .map { frame -> String in
                    let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count > 3 else { return frame }
                    return "\(parts[1]):\(parts[3])"
                }
                .joined(separator: " < ")
        }

        private func record(_ text: String, isOffset: Bool, byEngine: Bool, distance: CGFloat = 0) {
            changes.append(Change(
                time: CACurrentMediaTime() - start,
                text: text,
                isOffset: isOffset,
                byEngine: byEngine,
                distance: distance
            ))
        }

        func mark() -> Int { changes.count }

        func offsetChanges(since mark: Int) -> [Change] {
            changes[mark...].filter(\.isOffset)
        }

        func dump(since mark: Int = 0) -> String {
            changes[mark...].map { String(format: "%7.3f %@", $0.time, $0.text) }.joined(separator: "\n")
        }

        deinit {
            observations.forEach { $0.invalidate() }
        }
    }

    /// Geometry read straight from the scroll view (no KVO), with the
    /// engine's view of it, for the CI log.
    private func checkpoint(_ label: String, _ mounted: Mounted, _ recorder: ScrollRecorder) {
        let view = mounted.scrollView
        print(String(
            format: "[ChatScrollHostedTests] %@: offset %.1f max %.1f content %.1f bounds %.1f insets %.1f/%.1f mode %@ layoutCallbacks %ld recorded %ld",
            label,
            view.contentOffset.y,
            maxOffset(view),
            view.contentSize.height,
            view.bounds.height,
            view.adjustedContentInset.top,
            view.adjustedContentInset.bottom,
            String(describing: mounted.engine.mode),
            TranscriptPerf.layoutMetricsChangedCalls,
            recorder.mark()
        ))
    }

    /// Rows whose real heights are far from LazyVStack's estimates: long
    /// code blocks and lists between ordinary prose.
    private static func uneven(_ range: Range<Int>) -> [ChatMessage] {
        range.map { index in
            let content: String
            switch index % 7 {
            case 2:
                content = "```swift\n" + (0..<(30 + index % 20)).map { "let value\($0) = compute(\($0))" }
                    .joined(separator: "\n") + "\n```"
            case 5:
                content = (0..<(12 + index % 9)).map { "- Item \($0) of a long list in message \(index)" }
                    .joined(separator: "\n")
            default:
                content = String(repeating: "Message \(index) is ordinary prose. ", count: 2 + index % 6)
            }
            return ChatMessage(
                id: "uneven-\(index)",
                role: index % 2 == 0 ? .user : .assistant,
                content: content,
                timestamp: "2026-01-01T00:00:00Z"
            )
        }
    }

    // MARK: - Tests

    func testOpensOnTheLatestMessage() throws {
        let mounted = try mount(Self.transcript(0..<120))
        XCTAssertGreaterThan(mounted.scrollView.contentSize.height, mounted.scrollView.bounds.height * 3)
        assertAtLatest(mounted, "a long chat opens on its latest message")
        XCTAssertTrue(mounted.engine.isFollowingLatest)
    }

    func testNewMessagesAndStreamingStayOnTheLatestMessage() throws {
        let mounted = try mount(Self.transcript(0..<120))

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<122))
        settle(mounted.host.view)
        assertAtLatest(mounted, "an appended reply is followed")

        for tick in 1...8 {
            mounted.appState.setStreamingTextForTesting(String(
                repeating: "Streaming line \(tick) grows the live bubble. ",
                count: tick * 3
            ))
            settle(mounted.host.view, seconds: 0.1)
            assertAtLatest(mounted, "streaming growth tick \(tick) is followed")
        }
    }

    func testAReaderScrolledUpIsNotMovedByNewMessages() throws {
        let mounted = try mount(Self.transcript(0..<120))
        browse(mounted, to: mounted.scrollView.contentOffset.y - 1500)
        XCTAssertEqual(mounted.engine.mode, .browsing)
        let topRow = try XCTUnwrap(mounted.engine.topVisibleMessageID)
        let before = try XCTUnwrap(screenY(of: topRow, in: mounted))

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<124))
        mounted.appState.setStreamingTextForTesting(String(repeating: "More streamed text. ", count: 40))
        settle(mounted.host.view)

        let after = try XCTUnwrap(screenY(of: topRow, in: mounted))
        XCTAssertEqual(after, before, accuracy: 1, "the row being read stays where it was")
        XCTAssertEqual(mounted.engine.mode, .browsing)
    }

    func testLoadingEarlierMessagesKeepsTheReaderInPlace() throws {
        try loadEarlierMessages(stall: .none)
    }

    /// A busy main thread between the transcript landing and the layout
    /// that shows the prepended page.
    func testLoadingEarlierMessagesHoldsThroughAStallBeforeTheLayout() throws {
        try loadEarlierMessages(stall: .beforeLayout)
    }

    /// A busy main thread right after the engine's first correction, before
    /// SwiftUI writes its own offset and the new row frames arrive.
    func testLoadingEarlierMessagesHoldsThroughAStallAfterTheLayout() throws {
        try loadEarlierMessages(stall: .afterLayout)
    }

    private enum Stall {
        case none
        case beforeLayout
        case afterLayout
    }

    private func loadEarlierMessages(
        stall: Stall,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let mounted = try mount(Self.transcript(40..<120))
        browse(mounted, to: mounted.scrollView.contentOffset.y - 1200)
        let topRow = try XCTUnwrap(mounted.engine.topVisibleMessageID)
        let before = try XCTUnwrap(screenY(of: topRow, in: mounted))
        let recorder = ScrollRecorder(mounted.scrollView)

        mounted.engine.olderPageBackfillRequested(sessionKey: mounted.engine.renderedSessionKey)
        var stalled = false
        var stallSubscription: AnyCancellable?
        var stallObservation: NSKeyValueObservation?
        switch stall {
        case .none:
            break
        case .beforeLayout:
            // The engine publishes its new rows right after the transcript
            // lands; SwiftUI lays them out in a later pass.
            stallSubscription = mounted.engine.objectWillChange.sink { [engine = mounted.engine] _ in
                guard !stalled, engine.prependAnchor?.landedAt != nil else { return }
                stalled = true
                Thread.sleep(forTimeInterval: 1)
            }
        case .afterLayout:
            // The first jump of more than a page is the engine moving the
            // reader down past the prepended page.
            let offsetBefore = mounted.scrollView.contentOffset.y
            let page = mounted.scrollView.bounds.height
            stallObservation = mounted.scrollView.observe(\.contentOffset, options: [.new]) { _, change in
                guard !stalled, let offset = change.newValue, offset.y > offsetBefore + page else { return }
                stalled = true
                Thread.sleep(forTimeInterval: 1)
            }
        }
        ChatViewportTrace.shared.reset()
        mounted.appState.messages = Self.transcript(0..<120)
        // The stall takes a second out of the settle; the rest still gets
        // the usual layout passes.
        settle(mounted.host.view, seconds: stall == .none ? 0.6 : 1.6)
        stallSubscription?.cancel()
        stallObservation?.invalidate()

        let trace = { "offsets:\n\(recorder.dump())\nengine:\n\(ChatViewportTrace.shared.dump())" }
        XCTAssertEqual(
            stalled, stall != .none, "the main thread stalled where the test meant it to",
            file: file, line: line
        )
        let after = try XCTUnwrap(
            screenY(of: topRow, in: mounted),
            "the reader's row \(topRow) has no frame after the prepend\n\(trace())",
            file: file, line: line
        )
        XCTAssertEqual(
            after, before, accuracy: 2, "the prepend lands above without moving the reader\n\(trace())",
            file: file, line: line
        )
    }

    func testScrollingDoesNotReevaluateTheChat() throws {
        let mounted = try mount(Self.transcript(0..<120))
        let start = mounted.scrollView.contentOffset.y
        let bodiesBefore = TranscriptPerf.chatViewBodyEvaluations

        mounted.engine.userDragBegan()
        for step in 1...20 {
            mounted.scrollView.contentOffset.y = start - CGFloat(step) * 90
            settle(mounted.host.view, seconds: 0.03)
        }
        mounted.engine.userDragEnded()
        settle(mounted.host.view, seconds: 0.3)
        XCTAssertTrue(mounted.engine.chrome.inputs.showsJumpToLatest)

        // Back down to the latest message, which follows again.
        mounted.engine.userDragBegan()
        for step in (0..<20).reversed() {
            mounted.scrollView.contentOffset.y = step == 0
                ? maxOffset(mounted.scrollView)
                : start - CGFloat(step) * 90
            settle(mounted.host.view, seconds: 0.03)
        }
        mounted.engine.userDragEnded()
        settle(mounted.host.view, seconds: 0.3)
        XCTAssertTrue(mounted.engine.chrome.inputs.isFollowingLatest)
        XCTAssertFalse(mounted.engine.chrome.inputs.showsJumpToLatest)

        // Leaving and returning to the latest message, and the jump button
        // coming and going, re-render only the button: a chat re-render
        // re-ran every row, a hitch at the start of each scroll.
        XCTAssertEqual(TranscriptPerf.chatViewBodyEvaluations - bodiesBefore, 0)
    }

    func testJumpToLatestReturnsToTheBottomAndFollowsAgain() throws {
        let mounted = try mount(Self.transcript(0..<120))
        // Within three viewports, so the jump animates and gets its final pin.
        browse(mounted, to: maxOffset(mounted.scrollView) - mounted.scrollView.bounds.height * 2)
        XCTAssertEqual(mounted.engine.mode, .browsing)
        mounted.engine.explicitLatestRequested(animated: true)
        XCTAssertTrue(mounted.engine.latestAnimationInFlight, "a short jump animates")
        settle(mounted.host.view, seconds: ChatScrollEngine.latestAnimationDuration + 0.2)
        mounted.engine.latestAnimationFinished()
        settle(mounted.host.view, seconds: 0.2)
        assertAtLatest(mounted, "the jump lands on the latest message")

        mounted.appState.messages.append(contentsOf: Self.transcript(120..<121))
        settle(mounted.host.view)
        assertAtLatest(mounted, "and following resumes")
    }

    /// Eric's report: send, leave the screen alone, and when the turn
    /// completes the transcript sits past its end. Completion removes the
    /// turn's partial rows and live tail and appends one settled reply, so
    /// the content shrinks under a pinned offset.
    func testTurnCompletionThatShrinksTheContentStaysOnTheLatestMessage() throws {
        let mounted = try mount(Self.uneven(0..<60))
        let recorder = ScrollRecorder(mounted.scrollView)
        let appState = mounted.appState

        appState.messages.append(ChatMessage(id: "turn-user", role: .user, content: "Do the thing.", timestamp: "2026-01-01T00:00:00Z"))
        settle(mounted.host.view, seconds: 0.2)
        for step in 0..<4 {
            appState.messages.append(ChatMessage(
                id: "turn-reasoning-\(step)",
                role: .reasoning,
                content: String(repeating: "Thinking about step \(step). ", count: 30),
                timestamp: "2026-01-01T00:00:00Z"
            ))
            appState.messages.append(ChatMessage(
                id: "turn-partial-\(step)",
                role: .partial,
                content: String(repeating: "Working on step \(step) of the task with plenty of detail. ", count: 12),
                timestamp: "2026-01-01T00:00:00Z"
            ))
            settle(mounted.host.view, seconds: 0.15)
        }
        appState.setStreamingTextForTesting(String(repeating: "The final answer streams in with several lines. ", count: 30))
        settle(mounted.host.view, seconds: 0.3)
        checkpoint("completion before", mounted, recorder)
        assertAtLatest(mounted, "the live turn is followed")

        let mark = recorder.mark()
        // finalizeStreamingCompletion: partials out, one settled reply in,
        // live text cleared, all in one update.
        appState.messages.removeAll { $0.role == .partial }
        appState.messages.append(ChatMessage(
            id: "turn-final",
            role: .assistant,
            content: "Done.",
            timestamp: "2026-01-01T00:00:00Z"
        ))
        appState.setStreamingTextForTesting("")
        checkpoint("completion published", mounted, recorder)
        settle(mounted.host.view, seconds: 0.6)
        checkpoint("completion after", mounted, recorder)
        print("[ChatScrollHostedTests] completion trace:\n\(recorder.dump(since: mark))")
        assertAtLatest(mounted, "a completed turn leaves no empty space under it\n\(recorder.dump(since: mark))")
        XCTAssertTrue(mounted.engine.isFollowingLatest)
    }

    /// A finished run of steps shows as one collapsed line. Its other
    /// steps draw nothing, so they must not add the transcript's row
    /// spacing each: the reply sits one spacing below the line, not seven.
    func testACollapsedRunOfStepsSitsOneRowSpacingAboveTheReply() throws {
        let steps = (0..<7).map { index in
            ChatMessage(
                id: "step-\(index)",
                role: .tool,
                content: "",
                timestamp: "2026-01-01T00:00:0\(index)Z",
                tool: ToolActivity(id: "step-\(index)", name: "web_search", input: #"{"query": "q\#(index)"}"#, output: "ok", status: .complete)
            )
        }
        let messages = [ChatMessage(id: "ask", role: .user, content: "Look it up.", timestamp: "2026-01-01T00:00:00Z")]
            + steps
            + [ChatMessage(id: "reply", role: .assistant, content: "Here it is.", timestamp: "2026-01-01T00:00:09Z")]
        let mounted = try mount(messages)
        settle(mounted.host.view, seconds: 0.4)

        let header = try XCTUnwrap(mounted.engine.rowFrame(for: "step-0"), "the run's line is laid out")
        let reply = try XCTUnwrap(mounted.engine.rowFrame(for: "reply"), "the reply is laid out")
        XCTAssertGreaterThan(header.maxY - header.minY, 1, "the run shows as one line")
        XCTAssertEqual(
            reply.minY - header.maxY,
            ChatStepStyle.transcriptRowSpacing,
            accuracy: 1,
            "one row spacing between the collapsed run and the reply"
        )
    }

    /// Eric's report: opening a Thinking or tool row at the bottom of the
    /// chat jumped far down. A row growing in place (as an opening one does)
    /// after the reader taps it keeps its top where it was.
    func testOpeningARowAtTheBottomKeepsItsTopStill() throws {
        let mounted = try mount(Self.uneven(0..<60))
        let recorder = ScrollRecorder(mounted.scrollView)
        assertAtLatest(mounted, "opens on the latest message")
        let lastID = "uneven-59"
        let before = try XCTUnwrap(screenY(of: lastID, in: mounted))

        let mark = recorder.mark()
        mounted.engine.userWillToggleRow()
        mounted.appState.messages[59] = ChatMessage(
            id: lastID,
            role: .assistant,
            content: String(repeating: "What the opened row reveals, line after line. ", count: 120),
            timestamp: "2026-01-01T00:00:00Z"
        )
        // Past the settle check, which must leave a reader this far from
        // the bottom where they are.
        settle(mounted.host.view, seconds: ChatScrollEngine.disclosureSettleDelay + 0.4)
        checkpoint("opened", mounted, recorder)

        let after = try XCTUnwrap(screenY(of: lastID, in: mounted))
        XCTAssertEqual(after, before, accuracy: 1, "the tapped row stays put\n\(recorder.dump(since: mark))")
        XCTAssertEqual(mounted.engine.mode, .browsing)
        XCTAssertTrue(mounted.engine.showsJumpToLatest)
    }

    /// Issue #302: the transcript bounced on its own until touched. With no
    /// input and nothing new arriving, the offset must not move at all.
    func testAnIdleTranscriptHoldsStill() throws {
        let mounted = try mount(Self.uneven(0..<90))
        let recorder = ScrollRecorder(mounted.scrollView)
        mounted.appState.messages.append(contentsOf: Self.uneven(90..<93))
        mounted.appState.setStreamingTextForTesting(String(repeating: "Streaming with ```code``` and *emphasis*. ", count: 20))
        settle(mounted.host.view)
        mounted.appState.setStreamingTextForTesting("")
        mounted.appState.messages.append(contentsOf: Self.uneven(93..<94))
        settle(mounted.host.view)
        assertAtLatest(mounted, "following after the burst\n\(recorder.dump())")

        checkpoint("idle before", mounted, recorder)
        let mark = recorder.mark()
        // Layout passes keep running, as frames do on a device; nothing new
        // arrives and nothing touches the screen.
        settle(mounted.host.view, seconds: 1.5)
        checkpoint("idle after", mounted, recorder)
        // A sub-point settle is not a bounce; #302 moved 100-250 pt.
        let moves = recorder.offsetChanges(since: mark).filter { $0.distance > 1 }
        print("[ChatScrollHostedTests] idle trace:\n\(recorder.dump())")
        XCTAssertTrue(moves.isEmpty, "the transcript moved on its own:\n\(recorder.dump(since: mark))")
    }

    // MARK: - Settle probe (temporary, #887 item 5)

    private enum ProbeReader {
        case following
        case smallDrag
        case farDrag
        case midDrag
        case dragBackToBottom
    }

    private func probeGeometry(_ label: String, _ mounted: Mounted) -> String {
        let view = mounted.scrollView
        let lastID = mounted.appState.messages.last?.id ?? "-"
        let origin = mounted.engine.surface?.transcriptOriginY ?? .nan
        let frame = mounted.engine.rowFrame(for: lastID)
        let viewportBottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
        let blank = frame.map { viewportBottom - (origin + $0.maxY) } ?? .nan
        let tail = frame.map { view.contentSize.height - (origin + $0.maxY) } ?? .nan
        return String(
            format: "SETTLE_PROBE %@: offset %.1f max %.1f dist %.1f content %.1f bounds %.1f insets %.1f/%.1f mode %@ last %@ lastMaxY %.1f blankBelowLast %.1f contentBelowLast %.1f",
            label, view.contentOffset.y, maxOffset(view), maxOffset(view) - view.contentOffset.y,
            view.contentSize.height, view.bounds.height, view.adjustedContentInset.top,
            view.adjustedContentInset.bottom, String(describing: mounted.engine.mode), lastID,
            frame.map { origin + $0.maxY } ?? .nan, blank, tail
        )
    }

    /// Rows with a frame inside the viewport, and a band map of the
    /// viewport as drawn: '#' a 40 pt band with ink, '.' a blank one.
    private func probeView(_ label: String, _ mounted: Mounted) -> String {
        let view = mounted.scrollView
        let origin = mounted.engine.surface?.transcriptOriginY ?? 0
        let top = view.contentOffset.y + view.adjustedContentInset.top
        let bottom = view.contentOffset.y + view.bounds.height - view.adjustedContentInset.bottom
        var rows: [(String, ChatScrollRowFrame)] = []
        for message in mounted.appState.messages {
            if let frame = mounted.engine.rowFrame(for: message.id),
               origin + frame.maxY > top, origin + frame.minY < bottom {
                rows.append((message.id, frame))
            }
        }
        let rowText = rows.map { String(format: "%@[%.0f-%.0f]", $0.0, origin + $0.1.minY, origin + $0.1.maxY) }
            .joined(separator: " ")
        var bands = ""
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        if let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            let scale = CGFloat(cg.height) / view.bounds.height
            let bandHeight: CGFloat = 40
            var y: CGFloat = 0
            while y < view.bounds.height {
                let y0 = Int(y * scale), y1 = min(cg.height, Int((y + bandHeight) * scale))
                var inked = false
                let reference = (Int(bytes[y0 * cg.bytesPerRow]), Int(bytes[y0 * cg.bytesPerRow + 1]), Int(bytes[y0 * cg.bytesPerRow + 2]))
                var row = y0
                while row < y1, !inked {
                    var column = Int(30 * scale)
                    while column < cg.width - Int(30 * scale) {
                        let index = row * cg.bytesPerRow + column * 4
                        let delta = abs(Int(bytes[index]) - reference.0) + abs(Int(bytes[index + 1]) - reference.1) + abs(Int(bytes[index + 2]) - reference.2)
                        if delta > 60 { inked = true; break }
                        column += 3
                    }
                    row += 2
                }
                bands += inked ? "#" : "."
                y += bandHeight
            }
        }
        return "SETTLE_PROBE \(label) view: bands \(bands) rows \(rowText)"
    }

    private func probeRemount(_ label: String, _ mounted: Mounted) throws -> String {
        let messages = mounted.appState.messages
        let lastID = messages.last?.id ?? "-"
        let before = mounted.engine.rowFrame(for: lastID).map { $0.maxY - $0.minY } ?? .nan
        let contentBefore = mounted.scrollView.contentSize.height
        let fresh = try mount(messages)
        settle(fresh.host.view, seconds: 0.6)
        let after = fresh.engine.rowFrame(for: lastID).map { $0.maxY - $0.minY } ?? .nan
        return String(
            format: "SETTLE_PROBE %@ remount: lastHeight %.1f -> %.1f content %.1f -> %.1f",
            label, before, after, contentBefore, fresh.scrollView.contentSize.height
        ) + "\n" + probeView("\(label) remounted", fresh)
    }

    private func runSettleProbe(_ name: String, reader: ProbeReader, tools: Int, chunks: Int) throws {
        let session = "probe-session"
        let mounted = try mount(Self.uneven(0..<40), sessionID: session)
        let appState = mounted.appState
        let view = mounted.host.view!
        settle(view, seconds: 0.4)
        var lines: [String] = [probeGeometry("\(name) mounted", mounted)]

        appState.messages.append(ChatMessage(id: "probe-user", role: .user, content: "Run the task and explain.", timestamp: "2026-01-01T00:00:00Z"))
        appState.handleStreamEvent(.messageStart(sessionId: session))
        settle(view, seconds: 0.2)
        for index in 0..<tools {
            appState.handleStreamEvent(.toolStart(sessionId: session, toolName: "web_search", toolInput: #"{"query": "q\#(index)"}"#, toolID: "probe-tool-\(index)"))
            settle(view, seconds: 0.08)
            appState.handleStreamEvent(.toolComplete(sessionId: session, toolName: "web_search", toolOutput: "ok", toolID: "probe-tool-\(index)"))
            settle(view, seconds: 0.08)
        }
        lines.append(probeGeometry("\(name) after tools", mounted))
        for chunk in 0..<chunks {
            appState.handleStreamEvent(.messageDelta(
                sessionId: session,
                text: "Paragraph \(chunk) of the streamed answer goes on for a while with ordinary words in it. " + String(repeating: "More words. ", count: 12) + "\n\n"
            ))
            settle(view, seconds: 0.06)
            if chunk == chunks - 3 {
                switch reader {
                case .following:
                    break
                case .smallDrag:
                    browse(mounted, to: mounted.scrollView.contentOffset.y - 90)
                case .farDrag:
                    browse(mounted, to: mounted.scrollView.contentOffset.y - 1600)
                case .midDrag:
                    browse(mounted, to: mounted.scrollView.contentOffset.y - 500)
                case .dragBackToBottom:
                    browse(mounted, to: mounted.scrollView.contentOffset.y - 90)
                    browse(mounted, to: maxOffset(mounted.scrollView))
                }
                lines.append(probeGeometry("\(name) after reader", mounted))
            }
        }
        settle(view, seconds: 0.3)
        lines.append(probeGeometry("\(name) before complete", mounted))
        let recorder = ScrollRecorder(mounted.scrollView)
        ChatViewportTrace.shared.reset()
        appState.handleStreamEvent(.messageComplete(sessionId: session, messageId: "probe-final", content: nil, reasoning: nil))
        settle(view, seconds: 0.1)
        lines.append(probeGeometry("\(name) complete+0.1", mounted))
        settle(view, seconds: 2.0)
        lines.append(probeGeometry("\(name) settled", mounted))
        lines.append(probeView("\(name) settled", mounted))
        // A nudge, as a touch would give.
        mounted.scrollView.contentOffset.y -= 1
        settle(view, seconds: 0.3)
        lines.append(probeGeometry("\(name) nudged", mounted))
        lines.append(probeView("\(name) nudged", mounted))
        settle(view, seconds: 1.2)
        lines.append(probeGeometry("\(name) later", mounted))
        lines.append(probeView("\(name) later", mounted))
        if reader == .following || reader == .dragBackToBottom || reader == .smallDrag {
            let lastID = appState.messages.last?.id ?? "-"
            let frame = mounted.engine.rowFrame(for: lastID)
            let origin = mounted.engine.surface?.transcriptOriginY ?? 0
            let below = frame.map { mounted.scrollView.contentSize.height - (origin + $0.maxY) } ?? .infinity
            XCTAssertLessThan(below, 160, "SETTLE_BLANK \(name): \(below) pt below the settled reply")
        }
        let changes = recorder.dump().split(separator: "\n").suffix(40).joined(separator: "\n    ")
        lines.append("SETTLE_PROBE \(name) changes:\n    \(changes)")
        lines.append("SETTLE_PROBE \(name) engine:\n    \(ChatViewportTrace.shared.dump().split(separator: "\n").suffix(20).joined(separator: "\n    "))")
        print(lines.joined(separator: "\n"))
        print(try probeRemount(name, mounted))
    }

    func testSettleProbeFollowing() throws {
        try runSettleProbe("following", reader: .following, tools: 7, chunks: 30)
    }

    func testSettleProbeSmallDrag() throws {
        try runSettleProbe("smallDrag", reader: .smallDrag, tools: 7, chunks: 30)
    }

    func testSettleProbeFarDrag() throws {
        try runSettleProbe("farDrag", reader: .farDrag, tools: 7, chunks: 30)
    }

    func testSettleProbeDragBack() throws {
        try runSettleProbe("dragBack", reader: .dragBackToBottom, tools: 7, chunks: 30)
    }

    func testSettleProbeSmallDragNoTools() throws {
        try runSettleProbe("smallDragNoTools", reader: .smallDrag, tools: 0, chunks: 30)
    }

    func testSettleProbeRepeats() throws {
        for round in 0..<8 {
            for (name, reader) in [("dragBack", ProbeReader.dragBackToBottom), ("following", .following)] {
                try runSettleProbe("\(name)#\(round)", reader: reader, tools: 7, chunks: 30)
                tearDown()
            }
        }
    }

    func testSettleProbeFarDragNoTools() throws {
        try runSettleProbe("farDragNoTools", reader: .farDrag, tools: 0, chunks: 30)
    }

    func testSettleProbeMidDrag() throws {
        try runSettleProbe("midDrag", reader: .midDrag, tools: 7, chunks: 30)
    }
}
