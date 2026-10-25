//
//  ChatCardHeight.swift
//  Conduit
//
//  The height a card drawn in a web page takes in its message (an HTML
//  preview, a diagram, a formula), and when it takes it.
//
//  A card mounts at the room it reserves (the height it measured on this
//  phone before, else a placeholder) and its page reports its real height a
//  moment later. Taking that height moves everything under the card, and
//  when the card is above what the reader is looking at, the reader with
//  it: UIKit keeps the distance from the top (#1238). So the card hands the
//  measurement to the chat's scroll engine, which lets the card take it once
//  the reader's scrolling has rested and moves the offset by the growth
//  above the viewport in the same layout pass (ChatScrollEngine.cardMeasured).
//  Outside a chat (a job sheet, the saved copy) there is no engine and the
//  card takes its height at once.
//
//  A picture arriving in its row (ChatPictureArrival) goes the same way:
//  the loading line stays until the reader's scrolling rests, and the row's
//  growth above the viewport is made good in the pass that lands it.
//

import SwiftUI

@MainActor
final class ChatCardHeight: ObservableObject, ChatScrollMeasuredCard {
    /// The height the card draws at once taken; nil while it holds the room
    /// it reserved.
    @Published private(set) var taken: CGFloat?
    /// The page the taken height came from. A page being replaced (a
    /// reload, another document) hides until it reports again, in the same
    /// room.
    @Published private(set) var drawnPage: AnyHashable?
    /// The room the card took when it was first laid out, fixed for its
    /// lifetime so a height remembered after the first frame never resizes
    /// it unannounced.
    private(set) var reserved: CGFloat?
    /// The card's frame in the transcript stack's space (`cardStackFrame`),
    /// nil before its first layout. The first one fixes the room; a change
    /// in height is a growth landing, which the engine waits for.
    var stackFrame: CGRect? {
        didSet {
            guard let stackFrame else { return }
            if reserved == nil, stackFrame.height > 0 { reserved = stackFrame.height }
            if stackFrame.height != oldValue?.height { engine?.cardFrameChanged(self) }
        }
    }
    /// The engine the last measurement went through.
    private weak var engine: ChatScrollEngine?
    private var measured: (height: CGFloat, page: AnyHashable)?

    /// The height the card's frame takes now: the taken one, else the room
    /// it reserved when first laid out, else `height`, which the first
    /// layout then reserves (`stackFrame`). Reading it changes nothing, so a
    /// body can call it.
    func frameHeight(reserving height: CGFloat) -> CGFloat {
        taken ?? reserved ?? height
    }

    /// Whether `page` has reported and shows.
    func isDrawn(_ page: AnyHashable) -> Bool {
        drawnPage == page
    }

    /// Whether `page` has reported, shown yet or not.
    func hasMeasured(_ page: AnyHashable) -> Bool {
        measured?.page == page || drawnPage == page
    }

    /// The page reported its height: through the engine when there is one.
    func pageMeasured(_ height: CGFloat, page: AnyHashable, engine: ChatScrollEngine?) {
        measured = (height, page)
        self.engine = engine
        if let engine {
            engine.cardMeasured(self)
        } else {
            takeMeasuredHeight()
        }
    }

    /// Another page is loading in the card's frame: it keeps its height and
    /// hides until that page reports.
    func pageReplaced() {
        measured = nil
        if drawnPage != nil { drawnPage = nil }
    }

    // MARK: - ChatScrollMeasuredCard

    var pendingGrowth: CGFloat {
        let current = taken ?? reserved ?? stackFrame?.height ?? 0
        return (measured?.height ?? current) - current
    }

    func takeMeasuredHeight() {
        guard let measured else { return }
        if taken != measured.height { taken = measured.height }
        if drawnPage != measured.page { drawnPage = measured.page }
    }
}

extension View {
    /// Keeps `card` told where this view is in the transcript stack's space
    /// and how tall it is, which change with layout, never with a scroll
    /// tick.
    func cardStackFrame(_ card: ChatCardHeight) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: CoordinateSpace.named(ChatScrollEngine.coordinateSpaceName))
        } action: { frame in
            // Layout callbacks arrive on the main thread; said so, whatever
            // isolation the SDK gives this closure.
            MainActor.assumeIsolated { card.stackFrame = frame }
        }
    }
}

/// A picture row's growth when its picture arrives (#1238). The row shows a
/// loading line until then, and a reply picture's height follows the row's
/// width, so the growth is known only once both are: the view keeps the
/// row's frame here (`chatRowFrame`), and when the picture is decoded hands
/// over the height the row will take and what shows it. The engine lets it
/// show like a card taking its height (ChatScrollEngine.cardMeasured); a
/// row already at that height, or one outside a chat, shows it at once.
@MainActor
final class ChatPictureArrival: ObservableObject, ChatScrollMeasuredCard {
    /// The row's frame in the transcript stack's space (`chatRowFrame`),
    /// nil before its first layout.
    var stackFrame: CGRect? {
        didSet {
            if stackFrame?.height != oldValue?.height { engine?.cardFrameChanged(self) }
        }
    }
    /// The engine the waiting picture went through.
    private weak var engine: ChatScrollEngine?
    private var pending: (delta: CGFloat, show: () -> Void)?

    /// A reply picture's height in its row: scaled to the row's width, up
    /// to `maxHeight` (`Image.resizable().scaledToFit().frame(maxHeight:)`).
    /// Zero before the row has a width.
    static func fittedHeight(of size: CGSize, inWidth width: CGFloat, maxHeight: CGFloat) -> CGFloat {
        guard size.width > 0, size.height > 0, width > 0 else { return 0 }
        return min(maxHeight, width * size.height / size.width)
    }

    /// The picture is decoded: `show` puts it in the row, which then takes
    /// `rowHeight`; nil when the row already holds the picture's size (its
    /// placeholder took the remembered one). A row not laid out yet (no
    /// height to grow from), or one that keeps its height, shows it at once.
    func arrive(rowHeight: CGFloat?, engine: ChatScrollEngine?, show: @escaping () -> Void) {
        var delta: CGFloat = 0
        if let rowHeight, rowHeight > 0, let height = stackFrame?.height, height > 0 {
            delta = rowHeight - height
        }
        pending = (delta, show)
        self.engine = engine
        if let engine, abs(delta) > 0.5 {
            engine.cardMeasured(self)
        } else {
            takeMeasuredHeight()
        }
    }

    /// The row left the screen: a picture still waiting is dropped (the
    /// row's task loads it again when the row is back), and with it the
    /// view `show` wrote to, so nothing keeps the decoded picture.
    func rowDisappeared() {
        pending = nil
    }

    // MARK: - ChatScrollMeasuredCard

    var pendingGrowth: CGFloat {
        pending?.delta ?? 0
    }

    func takeMeasuredHeight() {
        guard let pending else { return }
        self.pending = nil
        pending.show()
    }
}

extension View {
    /// Keeps `arrival` told where this row is in the transcript stack's
    /// space and how tall it is, which change with layout, never with a
    /// scroll tick.
    func chatRowFrame(_ arrival: ChatPictureArrival) -> some View {
        onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: CoordinateSpace.named(ChatScrollEngine.coordinateSpaceName))
        } action: { frame in
            MainActor.assumeIsolated { arrival.stackFrame = frame }
        }
    }
}
