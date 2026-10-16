//
//  ChatsPullToRefreshUITests.swift
//  ConduitUITests
//
//  TEMPORARY probe: which part of the V2 Chats screen stops pull to refresh.
//

import XCTest

// Rides the smoke-run ProfilePickerUITests for the probe runs only.
extension ProfilePickerUITests {
    func testPTR1Baseline() { ptrProbe("baseline", []) }
    func testPTR2Bare() { ptrProbe("bare", ["-PTR_BARE"]) }
    func testPTR3Inset() { ptrProbe("inset", ["-PTR_INSET"]) }

    private func ptrProbe(_ name: String, _ flags: [String]) {
        let app = XCUIApplication()
        app.launchArguments += ["-CONDUIT_UI_TEST_CONNECTED_DASHBOARD", "https://conduit-ui-test.invalid"]
        app.launchArguments += ["-CONDUIT_UI_TEST_SLOW_REFRESH"] + flags
        app.launch()

        let workspace = app.buttons["sidebar.workspace"]
        guard workspace.waitForExistence(timeout: 20) else {
            print("PTR-RESULT \(name): no chats screen")
            return
        }
        let list = app.collectionViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            print("PTR-RESULT \(name): no list")
            return
        }
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = start.withOffset(CGVector(dx: 0, dy: 360))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)

        let shot = XCUIScreen.main.screenshot().image
        let refreshing = app.staticTexts["ptr.refreshing"].waitForExistence(timeout: 2)
        if let data = shot.jpegData(compressionQuality: 0.4) {
            let encoded = data.base64EncodedString()
            var index = encoded.startIndex
            var part = 0
            while index < encoded.endIndex {
                let next = encoded.index(index, offsetBy: 8000, limitedBy: encoded.endIndex) ?? encoded.endIndex
                print("PTR-SHOT \(name) \(part) \(encoded[index..<next])")
                index = next
                part += 1
            }
        }
        let spinners = app.activityIndicators.count
        let spinnerFrame = spinners > 0 ? "\(app.activityIndicators.firstMatch.frame)" : "-"
        print("PTR-RESULT \(name): refreshing=\(refreshing) spinners=\(spinners) spinner=\(spinnerFrame) bar=\(workspace.frame)")
        app.terminate()
    }
}
