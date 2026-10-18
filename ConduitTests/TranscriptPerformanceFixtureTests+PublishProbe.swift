import Combine
import Darwin
import ObjectiveC
import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import Conduit

/// PROBE ONLY (removed before merge): what an AppState publish costs an
/// open chat while the V2 Chats list sits under it, with a default
/// profile's catalog (600 chats, 2,000 cron runs). Prints PUBLISH_PROBE
/// lines; asserts only that the harness ran.
extension TranscriptPerformanceFixtureTests {
    func testPublishProbeReportsCoveredListCost() throws {
        let environment = ProcessInfo.processInfo.environment
        let config = environment["PROBE_CONFIG"] ?? "gated"
        let suiteName = "publish-probe"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let now = Date().timeIntervalSince1970
        func row(_ id: String, _ source: SessionSource, _ index: Int) -> SessionSummary {
            SessionSummary(
                id: id,
                alternateIds: [],
                title: "\(source.rawValue) \(index)",
                model: "Hermes",
                updatedLabel: "now",
                lastActivityAt: now - Double(index) * 1800,
                profile: "default",
                source: source,
                isActive: false,
                isArchived: false,
                lineageRootId: nil
            )
        }
        appState.sessions = (0..<600).map { row("chat-\($0)", $0 % 7 == 0 ? .voice : .chat, $0) }
        appState.cronSessions = (0..<2000).map { row("cron-\($0)", .cron, $0) }
        let transcript = environment["PROBE_TRANSCRIPT"] ?? "markdown"
        let switches = environment["PROBE_SWITCHES"] ?? ""
        ChatProbeSwitches.noBubbleShadow = switches.contains("noshadow")
        ChatProbeSwitches.stillBackdrop = switches.contains("stillbackdrop")
        defer {
            ChatProbeSwitches.noBubbleShadow = false
            ChatProbeSwitches.stillBackdrop = false
        }
        appState.messages = transcript == "rich" ? Self.publishProbeRichTranscript(turns: 30) : Self.markdownTranscript(count: 120)
        appState.activeSessionId = "chat-0"
        appState.showSidebar = false
        print("PUBLISH_PROBE setup config=\(config) switches=\(switches) transcript=\(transcript) messages=\(appState.messages.count) chats=\(appState.sessions.count) runs=\(appState.cronSessions.count)")

        let host = UIHostingController(rootView: DormancyHarnessEnvironment.applying(
            PublishProbeCoveredChat(appState: appState, showsList: config == "gated" || config == "ungated")
                .environmentObject(appState)
        ))
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let appWindows = scene.windows.filter { !$0.isHidden }
        appWindows.forEach { $0.isHidden = true }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            appWindows.forEach { $0.isHidden = false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        var locator: ChatScrollSurfaceLocatorView?
        XCTAssertTrue(PerformanceFixtureWait.eventually(pumpingLayoutOf: host.view) {
            locator = Self.publishProbeFind(ChatScrollSurfaceLocatorView.self, in: host.view)
            return locator?.surface?.scrollView != nil
        }, "the locator must find the transcript's UIScrollView")
        let scrollView = try XCTUnwrap(locator?.surface?.scrollView)
        let engine = try XCTUnwrap(locator?.engine)
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let awake = PublishProbeAwakeTime()
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            CFIndex.max
        ) { _, activity in awake.observe(activity) }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }

        let sampler = environment["PROBE_STACKS"] == "1" ? PublishProbeStackSampler() : nil
        sampler?.start()
        var sampledPublishFrames: [(index: Int, milliseconds: Double)] = []
        var sampling = false

        /// Each frame's awake time, publishing every `every` frames (0: never).
        /// `delta` gives each frame's scroll step; nil ends the run early.
        var allFrames: [(index: Int, milliseconds: Double)] = []
        var frameBase = 0
        func frames(_ count: Int, every: Int, delta: @escaping (Int) -> CGFloat?) -> (publish: [Double], other: [Double]) {
            var publish: [Double] = [], other: [Double] = []
            var index = 0
            var before = awake.mark
            var published = false
            let clock = PublishProbeClock()
            clock.tick = {
                let mark = awake.mark
                sampler?.tag = -1
                if index > 0 {
                    let ms = (mark - before) * 1000
                    if published { publish.append(ms) } else { other.append(ms) }
                    if published, sampling { sampledPublishFrames.append((index - 1, ms)) }
                    if sampling { allFrames.append((frameBase + index - 1, ms)) }
                }
                guard index < count, let step = delta(index) else { return false }
                before = awake.mark
                published = every > 0 && index % every == every - 1
                if sampling { sampler?.tag = frameBase + index }
                if published { appState.objectWillChange.send() }
                if step != 0 { scrollView.contentOffset.y = max(0, scrollView.contentOffset.y + step) }
                index += 1
                return true
            }
            var anchor = 0
            withUnsafeMutablePointer(to: &anchor) { sampler?.stackLimit = UInt(bitPattern: $0) }
            clock.run()
            frameBase += index + 1
            return (publish, other)
        }
        func frames(_ count: Int, delta: CGFloat, every: Int) -> (publish: [Double], other: [Double]) {
            frames(count, every: every) { _ in delta }
        }

        func report(_ phase: String, _ result: (publish: [Double], other: [Double])) {
            func line(_ name: String, _ values: [Double]) -> String {
                let sorted = values.sorted()
                func pct(_ f: Double) -> Double {
                    sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * f).rounded()))]
                }
                return String(
                    format: "%@ n=%ld median=%.2fms p90=%.2fms max=%.2fms over8=%ld over16=%ld",
                    name, sorted.count, pct(0.5), pct(0.9), sorted.last ?? 0,
                    sorted.filter { $0 > 8.3 }.count, sorted.filter { $0 > 16.7 }.count
                )
            }
            print("PUBLISH_PROBE \(config) \(phase) " + line("publishFrames", result.publish))
            print("PUBLISH_PROBE \(config) \(phase) " + line("otherFrames", result.other))
        }

        // Warm up once, then still. Then, with no publishes: flings up from
        // the bottom to the top as a thumb does (each starts at 60 pt a
        // frame and slows by 5% a frame), flings back down, flings up again
        // over rows seen once, and a slow 4 pt-a-frame drag up from the
        // bottom.
        _ = frames(60, delta: 0, every: 6)
        report("still", frames(360, delta: 0, every: 12))
        PublishProbeLayerCensus.install()
        engine.userDragBegan()
        func fling(_ name: String, up: Bool) {
            PublishProbeLayerCensus.reset()
            let start = allFrames.count
            var collected: [Double] = []
            let atEnd = { up ? scrollView.contentOffset.y <= 0
                : scrollView.contentOffset.y >= scrollView.contentSize.height - scrollView.bounds.height }
            for _ in 0..<60 where !atEnd() {
                var speed: CGFloat = 60
                collected += frames(90, every: 0) { _ in
                    guard !atEnd() else { return nil }
                    speed *= 0.95
                    let step = max(speed, 2)
                    return up ? -step : min(step, scrollView.contentSize.height - scrollView.bounds.height - scrollView.contentOffset.y)
                }.other
            }
            report(name, (publish: [], other: collected))
            let slow = allFrames[start...].filter { $0.milliseconds > 16.7 }
            print("PUBLISH_PROBE \(config) \(name) slowFrames=\(slow.count) " + slow.prefix(40).map { String(format: "%ld:%.0f", $0.index, $0.milliseconds) }.joined(separator: " "))
            PublishProbeLayerCensus.print(name)
        }
        sampling = true
        fling("fling-up-first", up: true)
        print(String(format: "PUBLISH_PROBE %@ after-fling contentHeight=%.0f offset=%.0f", config, scrollView.contentSize.height, scrollView.contentOffset.y))
        sampling = false
        fling("fling-down", up: false)
        fling("fling-up-again", up: true)
        fling("fling-down-again", up: false)
        PublishProbeLayerCensus.reset()
        let dragStart = allFrames.count
        sampling = true
        report("slow-drag-up", frames(600, delta: -4, every: 0))
        sampling = false
        print("PUBLISH_PROBE \(config) slow-drag-up slowFrames " + allFrames[dragStart...].filter { $0.milliseconds > 16.7 }.map { String(format: "%ld:%.0f", $0.index, $0.milliseconds) }.joined(separator: " "))
        PublishProbeLayerCensus.print("slow-drag-up")
        if let sampler {
            sampler.stop()
            sampler.printReport(phases: [(name: "scrolling", frames: allFrames, slowest: 5)])
        }
        engine.userDragEnded()
        XCTAssertGreaterThan(scrollView.contentSize.height, 0)
    }

    /// Turns as an agent chat has them: a question, reasoning, three tool
    /// calls, then a long answer.
    static func publishProbeRichTranscript(turns: Int) -> [ChatMessage] {
        let long = markdownTranscript(count: 6).filter { $0.role == .assistant }.map(\.content).joined(separator: "\n\n")
        return (0..<turns).flatMap { turn -> [ChatMessage] in
            let stamp = "2026-01-01T00:00:00Z"
            return [
                ChatMessage(id: "u\(turn)", role: .user, content: "Question \(turn): can you look into this and tell me what you find?", timestamp: stamp),
                ChatMessage(id: "r\(turn)", role: .reasoning, content: "Thinking about turn \(turn). " + String(repeating: "Weighing the options carefully. ", count: 12), timestamp: stamp),
                ChatMessage(id: "t\(turn)a", role: .tool, content: "", timestamp: stamp, tool: ToolActivity(name: "web_search", input: "{\"query\":\"turn \(turn)\"}", output: String(repeating: "result line\n", count: 20), status: .complete, duration: 2)),
                ChatMessage(id: "t\(turn)b", role: .tool, content: "", timestamp: stamp, tool: ToolActivity(name: "read_file", input: "{\"path\":\"notes.md\"}", output: String(repeating: "file line\n", count: 40), status: .complete, duration: 1)),
                ChatMessage(id: "t\(turn)c", role: .tool, content: "", timestamp: stamp, tool: ToolActivity(name: "terminal", input: "{\"command\":\"ls\"}", output: "a\nb\nc", status: .complete, duration: 1)),
                ChatMessage(id: "a\(turn)", role: .assistant, content: "Answer \(turn).\n\n" + long, timestamp: stamp),
            ]
        }
    }

    private static func publishProbeFind<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = publishProbeFind(type, in: subview) { return match }
        }
        return nil
    }
}

/// The V2 Chats list with a chat pushed over it, as the shell has it.
private struct PublishProbeCoveredChat: View {
    let appState: AppState
    let showsList: Bool
    @State private var path = [1]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if showsList {
                    V2ChatsView(appState: appState).equatable()
                } else {
                    Color.clear
                }
            }
            .transformEnvironment(\.v2Shell) { $0.isRootCovered = !path.isEmpty }
            .navigationDestination(for: Int.self) { _ in
                ZStack {
                    ConduitBackdrop(drifts: true)
                    ChatView(chatTextSizeOverride: DormancyHarnessEnvironment.pinnedChatTextSize)
                }
            }
        }
    }
}

/// Counts `-[RBLayer display]` calls (SwiftUI's drawn layers) by the views
/// that hold them, and the time each owner's displays take.
private enum PublishProbeLayerCensus {
    nonisolated(unsafe) static var entries: [String: (count: Int, ms: Double, maxArea: Double)] = [:]
    nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard let rbClass = NSClassFromString("RBLayer"),
              let method = class_getInstanceMethod(rbClass, #selector(CALayer.display)) else {
            Swift.print("PUBLISH_PROBE census no RBLayer display")
            return
        }
        typealias Display = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Display.self)
        let replacement: @convention(block) (AnyObject) -> Void = { object in
            let start = CACurrentMediaTime()
            original(object, #selector(CALayer.display))
            let ms = (CACurrentMediaTime() - start) * 1000
            guard let layer = object as? CALayer else { return }
            let key = describe(layer)
            var entry = entries[key] ?? (0, 0, 0)
            entry.count += 1
            entry.ms += ms
            entry.maxArea = max(entry.maxArea, Double(layer.bounds.width * layer.bounds.height))
            entries[key] = entry
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    static func reset() { entries = [:] }

    static func print(_ phase: String) {
        let total = entries.values.reduce(0) { $0 + $1.ms }
        let count = entries.values.reduce(0) { $0 + $1.count }
        Swift.print(String(format: "PUBLISH_PROBE census %@ displays=%ld totalMs=%.1f", phase, count, total))
        for (key, entry) in entries.sorted(by: { $0.value.ms > $1.value.ms }).prefix(12) {
            Swift.print(String(format: "PUBLISH_PROBE census %@ n=%ld ms=%.1f maxArea=%.0f %@", phase, entry.count, entry.ms, entry.maxArea, key))
        }
    }

    private static func describe(_ layer: CALayer) -> String {
        var current: CALayer? = layer
        var depth = 0
        while let candidate = current, !(candidate.delegate is UIView) {
            current = candidate.superlayer
            depth += 1
        }
        var names: [String] = []
        var inScroll = false
        var view = current?.delegate as? UIView
        while let shown = view {
            if shown is UIScrollView { inScroll = true }
            if names.count < 4 { names.append(String(String(describing: type(of: shown)).prefix(48))) }
            view = shown.superview
        }
        return (inScroll ? "inScroll " : "outside ") + "up\(depth) " + names.joined(separator: " < ")
    }
}

private final class PublishProbeAwakeTime: @unchecked Sendable {
    private var busy: CFTimeInterval = 0
    private var wokeAt = CACurrentMediaTime()
    private var awake = true

    var mark: CFTimeInterval { busy + (awake ? CACurrentMediaTime() - wokeAt : 0) }

    func observe(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity.rawValue == CFRunLoopActivity.afterWaiting.rawValue {
            wokeAt = now
            awake = true
        } else if awake {
            busy += now - wokeAt
            awake = false
        }
    }
}

@MainActor
private final class PublishProbeClock: NSObject {
    private var finished = false
    var tick: (() -> Bool)?

    func run() {
        finished = false
        let link = CADisplayLink(target: self, selector: #selector(fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        let deadline = Date().addingTimeInterval(60)
        while !finished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        link.invalidate()
    }

    @objc private func fire(_ link: CADisplayLink) {
        if tick?() != true {
            finished = true
            link.invalidate()
        }
    }
}

/// Samples the main thread's stack from a thread of its own about once a
/// millisecond, each sample tagged with the frame the probe is in, so the
/// slowest frames can say where their time went (macOS `sample` at that
/// rate slowed frames to seconds). Memory is allocated up front: the main
/// thread is suspended while its stack is read, and an allocation then
/// could wait on a lock it holds.
private final class PublishProbeStackSampler: @unchecked Sendable {
    /// A tag is `phase * phaseStride + frame`.
    static let phaseStride = 100_000
    private static let maxDepth = 192
    private static let capacity = 30_000
    /// ARM_THREAD_STATE64_COUNT: x0-x28, fp, lr, sp, pc, cpsr and pad.
    private static let stateWords = 68

    private let target: thread_act_t
    private let stackLow: UInt
    private let stackHigh: UInt
    private let state = UnsafeMutablePointer<natural_t>.allocate(capacity: PublishProbeStackSampler.stateWords)
    private let addresses = UnsafeMutablePointer<UInt>.allocate(capacity: PublishProbeStackSampler.capacity * PublishProbeStackSampler.maxDepth)
    private let depths = UnsafeMutablePointer<Int>.allocate(capacity: PublishProbeStackSampler.capacity)
    private let tags = UnsafeMutablePointer<Int>.allocate(capacity: PublishProbeStackSampler.capacity)
    /// 0: the current tag, 1: running, 2: samples taken, 3: the stack
    /// address a walk stops at.
    private let shared = UnsafeMutablePointer<Int>.allocate(capacity: 4)
    private let done = DispatchSemaphore(value: 0)

    /// Made on the main thread.
    init() {
        precondition(Thread.isMainThread)
        let main = pthread_self()
        target = pthread_mach_thread_np(main)
        stackHigh = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackLow = stackHigh - UInt(pthread_get_stacksize_np(main))
        shared[0] = -1
        shared[1] = 0
        shared[2] = 0
        shared[3] = 0
    }

    deinit {
        state.deallocate()
        addresses.deallocate()
        depths.deallocate()
        tags.deallocate()
        shared.deallocate()
    }

    /// The frame samples count toward; negative leaves them out.
    var tag: Int {
        get { shared[0] }
        set { shared[0] = newValue }
    }

    /// An address in the frame the probe's frame loop is called from: a
    /// walk stops there, so a sample holds only the loop's own frames.
    var stackLimit: UInt {
        get { UInt(bitPattern: shared[3]) }
        set { shared[3] = Int(bitPattern: newValue) }
    }

    func start() {
        shared[1] = 1
        let thread = Thread { [self] in
            while shared[1] != 0 {
                usleep(1000)
                let tag = shared[0]
                if tag >= 0, shared[2] < Self.capacity {
                    sample(tag: tag)
                }
            }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        shared[1] = 0
        done.wait()
    }

    private func sample(tag: Int) {
        #if arch(arm64)
        guard thread_suspend(target) == KERN_SUCCESS else { return }
        var count = mach_msg_type_number_t(Self.stateWords)
        if thread_get_state(target, thread_state_flavor_t(ARM_THREAD_STATE64), state, &count) == KERN_SUCCESS {
            let words = UnsafeRawPointer(state)
            let index = shared[2]
            let base = addresses + index * Self.maxDepth
            let linkRegister = UInt(words.loadUnaligned(fromByteOffset: 30 * 8, as: UInt64.self))
            base[0] = UInt(words.loadUnaligned(fromByteOffset: 32 * 8, as: UInt64.self))
            base[1] = linkRegister
            var depth = 2
            var framePointer = UInt(words.loadUnaligned(fromByteOffset: 29 * 8, as: UInt64.self))
            let limit = shared[3] == 0 ? stackHigh : min(stackHigh, UInt(bitPattern: shared[3]))
            while depth < Self.maxDepth, framePointer >= stackLow, framePointer + 16 <= limit,
                  framePointer & 7 == 0,
                  let record = UnsafePointer<UInt>(bitPattern: framePointer) {
                let returnAddress = record[1]
                if returnAddress == 0 { break }
                // A function that set up its frame saved the link register
                // there too: don't count its caller twice.
                if !(depth == 2 && returnAddress == linkRegister) {
                    base[depth] = returnAddress
                    depth += 1
                }
                let next = record[0]
                if next <= framePointer { break }
                framePointer = next
            }
            depths[index] = depth
            tags[index] = tag
            shared[2] = index + 1
        }
        thread_resume(target)
        #endif
    }

    private final class Node {
        var count = 0
        var children: [String: Node] = [:]
    }

    /// For each phase: what its frames' time went to, then its slowest
    /// frames one by one, as call trees.
    func printReport(phases: [(name: String, frames: [(index: Int, milliseconds: Double)], slowest: Int)]) {
        var names: [UInt: String] = [:]
        func name(_ address: UInt) -> String {
            if let known = names[address] { return known }
            var info = Dl_info()
            var result = String(format: "0x%lx", address)
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "" } ?? ""
                let symbol = info.dli_sname.map { Self.demangled(String(cString: $0)) } ?? "?"
                result = symbol + " [" + image.replacingOccurrences(of: ".dylib", with: "") + "]"
            }
            names[address] = result
            return result
        }
        // Each sample's frames outermost first, from the frame loop down;
        // samples where the run loop sleeps until its next event are idle.
        var stacks: [Int: [[String]]] = [:]
        var idle = 0
        for sample in 0..<shared[2] {
            let base = addresses + sample * Self.maxDepth
            var frames: [String] = []
            for depth in (0..<depths[sample]).reversed() {
                // Return addresses point past their call: look up the call.
                frames.append(name(depth == 0 ? base[depth] : base[depth] &- 1))
            }
            if frames.contains(where: { $0.hasPrefix("__CFRunLoopServiceMachPort") }) {
                idle += 1
                continue
            }
            if let loop = frames.lastIndex(where: { $0.contains("PublishProbeClock.run") }) {
                frames.removeFirst(loop + 1)
            }
            stacks[tags[sample], default: []].append(frames)
        }
        print("SCROLL_PROBE stacks samples=\(shared[2]) idle=\(idle) names=\(names.count)")

        func printTree(_ samples: [[String]], title: String, cutoff: Double, maxLines: Int) {
            let root = Node()
            for frames in samples {
                root.count += 1
                var node = root
                for frame in frames {
                    let child = node.children[frame] ?? Node()
                    node.children[frame] = child
                    child.count += 1
                    node = child
                }
            }
            print("SCROLL_PROBE stacks " + title + " busySamples=\(root.count)")
            guard root.count > 0 else { return }
            var lines = 0
            func walk(_ node: Node, depth: Int) {
                for (frame, child) in node.children.sorted(by: { $0.value.count > $1.value.count }) {
                    guard Double(child.count) >= cutoff * Double(root.count), lines < maxLines else { continue }
                    var chain = [Self.short(frame)]
                    var current = child
                    while chain.count < 4,
                          let next = current.children.max(by: { $0.value.count < $1.value.count }),
                          Double(next.value.count) >= 0.9 * Double(current.count) {
                        chain.append(Self.short(next.key))
                        current = next.value
                    }
                    lines += 1
                    print("SCROLL_PROBE stacks " + String(repeating: ". ", count: depth)
                        + String(format: "%.0f%% ", 100 * Double(child.count) / Double(root.count))
                        + chain.joined(separator: " > "))
                    walk(current, depth: depth + 1)
                }
            }
            walk(root, depth: 0)
        }

        for (number, phase) in phases.enumerated() {
            let base = number * Self.phaseStride
            let all = phase.frames.flatMap { stacks[base + $0.index] ?? [] }
            printTree(all, title: "\(phase.name) all frames", cutoff: 0.04, maxLines: 30)
            // Flat: share of samples with each app frame on the stack,
            // and which library each sample's leaf runs in.
            var inclusive: [String: Int] = [:]
            var leaves: [String: Int] = [:]
            for frames in all {
                for frame in Set(frames) where frame.contains("[Conduit") && !frame.contains("PublishProbe") {
                    inclusive[frame, default: 0] += 1
                }
                if let leaf = frames.last, let open = leaf.lastIndex(of: "[") {
                    leaves[String(leaf[open...]), default: 0] += 1
                }
            }
            let total = Double(max(all.count, 1))
            for (frame, count) in inclusive.sorted(by: { $0.value > $1.value }).prefix(45) {
                print("SCROLL_PROBE stacks flat " + String(format: "%.0f%% ", 100 * Double(count) / total) + String(frame.prefix(220)))
            }
            for (image, count) in leaves.sorted(by: { $0.value > $1.value }).prefix(12) {
                print("SCROLL_PROBE stacks leaf " + String(format: "%.0f%% ", 100 * Double(count) / total) + image)
            }
            for frame in phase.frames.sorted(by: { $0.milliseconds > $1.milliseconds }).prefix(phase.slowest) {
                printTree(
                    stacks[base + frame.index] ?? [],
                    title: String(format: "%@ frame=%ld %.1fms", phase.name, frame.index, frame.milliseconds),
                    cutoff: 0.07,
                    maxLines: 16
                )
            }
        }
    }

    private static func short(_ name: String) -> String {
        name.count <= 90 ? name : String(name.prefix(89)) + "…"
    }

    private static func demangled(_ symbol: String) -> String {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$S") else { return symbol }
        return symbol.withCString { pointer in
            guard let result = publishProbeSwiftDemangle(pointer, UInt(strlen(pointer)), nil, nil, 0) else { return symbol }
            defer { free(result) }
            return String(cString: result)
        }
    }
}

@_silgen_name("swift_demangle")
private func publishProbeSwiftDemangle(
    _ mangledName: UnsafePointer<CChar>?,
    _ mangledNameLength: UInt,
    _ outputBuffer: UnsafeMutablePointer<CChar>?,
    _ outputBufferSize: UnsafeMutablePointer<UInt>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?

