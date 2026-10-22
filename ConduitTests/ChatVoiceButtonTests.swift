//
//  ChatVoiceButtonTests.swift
//  ConduitTests
//
//  What the big button beside a chat's composer does (Chat voice button).
//  An extension of an existing class, so CI plans no new test class.
//

import XCTest
@testable import Conduit

extension ComposerFullEditorTests {
    func testChatVoiceButtonDefaultsToALiveCall() {
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: nil, app: nil), .liveCall)
    }

    func testChatVoiceButtonProfileChoiceWinsOverTheApps() {
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: nil, app: "dictation"), .dictation)
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "live_call", app: "dictation"), .liveCall)
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "dictation", app: "live_call"), .dictation)
    }

    func testChatVoiceButtonSkipsChoicesThisBuildCantDo() {
        // A newer build's value, or voice messages before they ship, read
        // as the next choice down.
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "telepathy", app: "dictation"), .dictation)
        XCTAssertEqual(ChatVoiceButtonAction.resolved(profile: "voice_message", app: nil), .liveCall)
        XCTAssertNil(ChatVoiceButtonAction.offeredChoice("voice_message"))
        XCTAssertNil(ChatVoiceButtonAction.offeredChoice(nil))
        XCTAssertEqual(ChatVoiceButtonAction.offeredChoice("dictation"), .dictation)
        XCTAssertEqual(ChatVoiceButtonAction.offered, [.liveCall, .dictation])
    }

    func testRestingComposerHidesItsMicWhenTheBigButtonDictates() {
        XCTAssertTrue(ComposerBar.showsRestingDictateButton(chatVoiceButton: .liveCall))
        XCTAssertFalse(ComposerBar.showsRestingDictateButton(chatVoiceButton: .dictation))
    }

    func testProfileVoicePreferencesKeepTheChatVoiceButton() throws {
        var preferences = VoiceProfilePreferences()
        preferences.chatVoiceButton = "dictation"
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(VoiceProfilePreferences.self, from: data).chatVoiceButton, "dictation")
        // Older blobs have no choice: the app's applies.
        let old = try JSONDecoder().decode(VoiceProfilePreferences.self, from: Data("{}".utf8))
        XCTAssertNil(old.chatVoiceButton)
    }
}
