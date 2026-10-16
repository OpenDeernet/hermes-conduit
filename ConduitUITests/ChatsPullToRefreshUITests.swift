//
//  ChatsPullToRefreshUITests.swift
//  ConduitUITests
//
//  Pulling the V2 Chats list down refreshes it, with the spinner showing
//  under the top bar.
//

import XCTest

final class ChatsPullToRefreshUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testPullingTheChatsListShowsTheRefreshSpinner() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-ui-test.invalid"]
        app.launchArguments += ["-CONDUIT_UI_TEST_SLOW_REFRESH"]
        app.launch()

        let workspace = app.buttons["sidebar.workspace"]
        app.returnToV2Tabs(revealing: workspace)
        XCTAssertTrue(workspace.waitForExistence(timeout: 15), "Chats did not appear. Tree:\n\(app.debugDescription)")

        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "No list. Tree:\n\(app.debugDescription)")
        print("PTR-PROBE list=\(list.frame) bar=\(workspace.frame) window=\(app.windows.firstMatch.frame)")

        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = start.withOffset(CGVector(dx: 0, dy: 320))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)

        let spinners = app.activityIndicators
        let appeared = spinners.firstMatch.waitForExistence(timeout: 3)
        for index in 0..<spinners.count {
            let spinner = spinners.element(boundBy: index)
            print("PTR-PROBE spinner[\(index)] frame=\(spinner.frame) label=\(spinner.label) hittable=\(spinner.isHittable)")
        }
        print("PTR-PROBE tree:\n\(app.debugDescription)")
        XCTAssertTrue(appeared, "Pulling the Chats list showed no refresh spinner")
        guard appeared else { return }
        let spinner = spinners.firstMatch
        XCTAssertGreaterThanOrEqual(
            spinner.frame.minY, workspace.frame.maxY,
            "The refresh spinner sits under the top bar: spinner \(spinner.frame), bar \(workspace.frame)"
        )
    }
}
