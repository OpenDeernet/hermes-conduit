//
//  MarkdownRichContentTests+OrderedListStart.swift
//  Conduit
//
//  An ordered list starts at the number written on its first item, as in
//  CommonMark and Hermes Desktop. Steps split by a code block ("1. Install",
//  the code, "2. Run") carry on 1, 2 rather than restarting at 1, and a
//  list written from "4." draws 4, 5, 6.
//

import SwiftUI
import XCTest
@testable import Conduit

extension MarkdownRichContentPolicyTests {
    func testOrderedListKeepsItsFirstNumber() {
        XCTAssertEqual(MarkdownParser.parse("4. four\n5. five"), [.orderedList(["four", "five"], start: 4)])
        XCTAssertEqual(MarkdownParser.parse("1. one\n2. two"), [.orderedList(["one", "two"])])
        XCTAssertEqual(MarkdownParser.parse("0) zero"), [.orderedList(["zero"], start: 0)])
    }

    func testOrderedListNumbersFollowTheFirstItemOnly() {
        // Later numbers don't matter, as in CommonMark: "1. 1. 1." counts up.
        XCTAssertEqual(MarkdownParser.parse("1. a\n1. b\n1. c"), [.orderedList(["a", "b", "c"])])
    }

    func testOverlongOrderedNumberIsText() {
        // CommonMark: a list marker has at most nine digits.
        XCTAssertEqual(MarkdownParser.parse("1234567890. far"), [.paragraph("1234567890. far")])
        XCTAssertEqual(MarkdownParser.parse("123456789. near"), [.orderedList(["near"], start: 123456789)])
        XCTAssertEqual(MarkdownParser.parse("٤. four"), [.paragraph("٤. four")])
    }

    func testStepsSplitByACodeBlockCarryOn() {
        let blocks = MarkdownParser.parse("1. Install:\n\n```sh\nmake install\n```\n\n2. Run:\n\n```sh\nmake run\n```")
        XCTAssertEqual(blocks, [
            .orderedList(["Install:"]),
            .code(language: "sh", source: "make install"),
            .orderedList(["Run:"], start: 2),
            .code(language: "sh", source: "make run")
        ])
    }

    func testOrderedListDrawsFromItsStart() {
        let drawn = MarkdownSelectionFormatter.attributedText(
            for: MarkdownParser.parse("7. seven\n8. eight"),
            foregroundStyle: .primary,
            usesAccentSurface: false,
            newestCharacterOpacities: []
        )?.string ?? ""
        XCTAssertEqual(drawn, "7. seven\n8. eight")
    }

    @MainActor
    func testProseRunDrawsAnOrderedListFromItsStart() {
        let run = MarkdownProseRun.attributedText(
            for: [MarkdownBlock.orderedList(["seven", "eight"], start: 7)][...],
            references: .empty,
            foregroundStyle: .primary,
            usesAccentSurface: false,
            chatTextSize: .default
        )
        XCTAssertTrue(run.string.hasPrefix("7.\tseven"), run.string)
        XCTAssertTrue(run.string.contains("8.\teight"), run.string)
    }
}
