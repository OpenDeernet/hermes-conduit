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
    /// The room the card took when it mounted, fixed for its lifetime so a
    /// height remembered after the first frame never resizes it unannounced.
    private(set) var reserved: CGFloat?
    /// The card's top in the transcript stack's space (`cardStackPosition`).
    var stackMinY: CGFloat = 0
    private var measured: (height: CGFloat, page: AnyHashable)?

    /// The height the card's frame takes now, reserving `height` on the
    /// first call.
    func frameHeight(reserving height: CGFloat) -> CGFloat {
        if reserved == nil { reserved = height }
        return taken ?? reserved ?? height
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

    var pendingGrowth: ChatScrollCardGrowth {
        let current = taken ?? reserved ?? 0
        return ChatScrollCardGrowth(delta: (measured?.height ?? current) - current, minY: stackMinY)
    }

    func takeMeasuredHeight() {
        guard let measured else { return }
        if taken != measured.height { taken = measured.height }
        if drawnPage != measured.page { drawnPage = measured.page }
    }
}

extension View {
    /// Keeps `card` told where this view's top is in the transcript stack's
    /// space, which changes with layout, never with a scroll tick.
    func cardStackPosition(_ card: ChatCardHeight) -> some View {
        onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: CoordinateSpace.named(ChatScrollEngine.coordinateSpaceName)).minY
        } action: { minY in
            // Layout callbacks arrive on the main thread; said so, whatever
            // isolation the SDK gives this closure.
            MainActor.assumeIsolated { card.stackMinY = minY }
        }
    }
}
