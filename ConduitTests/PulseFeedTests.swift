//
//  PulseFeedTests.swift
//  Conduit
//
//  The Pulse screen reads the notifier plugin's /pulse/feed and
//  /pulse/learned as pulse_learning.py writes them: cards, the unseen
//  count, each kind's loudness and the lessons ratings made, what
//  learning holds, and what the reports left out (/pulse/left_out).
//

import XCTest
@testable import Conduit

@MainActor
final class PulseFeedTests: XCTestCase {
    private func appState() throws -> AppState {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppState(defaults: defaults, loadSavedConnection: false, clearSessionPresentationCache: {})
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testFeedDecodesThePluginsPayload() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"ok": true, "unseen": 2, "levels": {"followup": "brief", "other": "loud", "bad": 3},
         "cards": [
          {"id": 7, "kind": "followup", "level": "brief", "title": "Check the flight", "quote": "I'll check back",
           "news": "Flight is on time", "why": "Hermes said it would check", "profile": "work",
           "chat_id": "20261021_080000_abc", "chat_title": "Trip", "message_id": 42, "item_id": 11, "done_at": 1761040000, "done_by": "pulse",
           "created_at": 1761033600.5, "seen_at": null, "briefed_at": null, "rating": "", "reason": ""},
          {"id": 3, "kind": "followup", "level": "push", "title": "", "quote": "", "news": "Done",
           "why": "", "profile": "", "chat_id": "", "chat_title": "", "message_id": null,
           "created_at": 1761030000, "seen_at": 1761031000, "briefed_at": null, "rating": "down",
           "reason": "too_late"},
          {"kind": "followup"}, "junk"]}
        """)))

        XCTAssertEqual(page.unseen, 2)
        XCTAssertEqual(page.levels, ["followup": .brief])
        XCTAssertEqual(page.cards.map(\.id), [7, 3])

        let held = page.cards[0]
        XCTAssertEqual(held.chatID, "20261021_080000_abc")
        XCTAssertEqual(held.chatTitle, "Trip")
        XCTAssertEqual(held.messageID, 42)
        XCTAssertEqual(held.createdAt, Date(timeIntervalSince1970: 1761033600.5))
        XCTAssertNil(held.seenAt)
        XCTAssertTrue(held.isHeld)

        // A follow-up from a chat can be acted on there, with its news.
        XCTAssertTrue(held.isActionable)
        XCTAssertTrue(held.actionMessage.contains("Flight is on time"))
        // A follow-up about a promise can be marked done; the feed says when.
        XCTAssertEqual(held.itemID, 11)
        XCTAssertTrue(held.canBeDone)
        XCTAssertEqual(held.doneAt, Date(timeIntervalSince1970: 1761040000))
        XCTAssertEqual(held.doneBy, "pulse")

        let rated = page.cards[1]
        XCTAssertFalse(rated.isActionable)  // no chat to act in
        XCTAssertFalse(rated.canBeDone)  // no promise to close
        XCTAssertNil(rated.doneAt)
        XCTAssertEqual(rated.doneBy, "")
        XCTAssertNil(rated.messageID)
        XCTAssertFalse(rated.isHeld)
        XCTAssertEqual(rated.rating, "down")
        XCTAssertEqual(PulseDownReason(rawValue: rated.reason), .tooLate)
    }

    func testFeedNamesPulsesChatAndItsTurnCards() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": " pulse_chat ", "cards": [
          {"id": 2, "kind": "brief", "level": "push", "news": "**Morning.**\\n- Flight on time", "chat_id": "pulse_chat"},
          {"id": 1, "kind": "report", "level": "screen", "news": "Nothing new"}]}
        """)))

        XCTAssertEqual(page.homeChatID, "pulse_chat")
        XCTAssertFalse(page.cards[0].isRatable)
        XCTAssertFalse(page.cards[0].isHeld)
        XCTAssertEqual(String(page.cards[0].formattedNews.characters), "Morning.\n- Flight on time")
        XCTAssertEqual(PulseCardKind.title("report"), AppLocalization.string("Reports"))
        XCTAssertEqual(PulseCardKind.title("brief"), AppLocalization.string("Morning brief"))

        let older = try XCTUnwrap(PulseFeedPage(json: json(#"{"home_chat_id": "", "cards": []}"#)))
        XCTAssertNil(older.homeChatID)
    }

    func testFeedWithoutCardsIsInvalid() throws {
        XCTAssertNil(PulseFeedPage(json: try json(#"{"ok": true, "unseen": 1}"#)))
    }

    func testSourcesMapMessagesToTheirNewestCard() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "chat_id": "a", "message_id": 5},
          {"id": 8, "chat_id": "b", "message_id": 1},
          {"id": 4, "chat_id": "a", "message_id": 5},
          {"id": 2, "chat_id": "a", "message_id": 6},
          {"id": 1, "chat_id": "", "message_id": 7},
          {"id": 0, "chat_id": "c"}]}
        """)))

        XCTAssertEqual(page.sources, ["a": [5: 9, 6: 2], "b": [1: 8]])
    }

    func testLearnedDecodesLessonsAndTheirText() throws {
        let learned = try XCTUnwrap(PulseLearned(json: json("""
        {"ok": true, "levels": {"followup": "screen"},
         "lessons": [
          {"id": 1, "kind": "followup", "what": "level", "value": "screen", "cause": "2 thumbs down",
           "created_at": 1761033600},
          {"id": 2, "kind": "followup", "what": "rule", "value": "the weather", "cause": "not relevant"},
          {"id": 3, "kind": "followup", "what": "sooner", "value": "", "cause": "too late"},
          {"id": 4, "kind": "followup", "what": "seen", "value": "", "cause": "already knew"},
          {"id": 5, "kind": "followup", "what": "level", "value": "off", "cause": "set"},
          {"id": 6, "kind": "followup"},
          {"id": 7, "kind": "commitment", "what": "level", "value": "brief", "cause": "too often"},
          {"id": 8, "kind": "date", "what": "sooner", "value": "", "cause": "too late"},
          {"id": 9, "kind": "fact", "what": "seen", "value": "", "cause": "already knew"},
          {"id": 10, "kind": "noticed", "what": "rule", "value": "Send the deck", "cause": "not relevant"}]}
        """)))

        XCTAssertEqual(learned.levels, ["followup": .screen])
        XCTAssertEqual(learned.lessons.map(\.id), [1, 2, 3, 4, 5, 7, 8, 9, 10])
        let lessons = learned.lessons

        XCTAssertEqual(lessons[0].text, AppLocalization.string("\(PulseCardKind.title("followup")): \(PulseLevel.screen.title)"))
        XCTAssertEqual(lessons[0].causeText, AppLocalization.string("After thumbs down"))
        XCTAssertEqual(lessons[0].createdAt, Date(timeIntervalSince1970: 1761033600))

        XCTAssertEqual(lessons[1].text, AppLocalization.string("No updates about “\("the weather")”"))
        XCTAssertEqual(lessons[1].causeText, AppLocalization.string("You said not relevant"))
        XCTAssertEqual(lessons[2].text, AppLocalization.string("Check on promises sooner"))
        XCTAssertEqual(lessons[2].causeText, AppLocalization.string("You said too late"))
        XCTAssertEqual(lessons[3].text, AppLocalization.string("Skip news you already saw in the chat"))
        XCTAssertEqual(lessons[3].causeText, AppLocalization.string("You said you already knew"))
        XCTAssertEqual(lessons[4].text, AppLocalization.string("\(PulseCardKind.title("followup")): \(PulseLevel.off.title)"))
        XCTAssertNil(lessons[4].causeText)
        // A report card's reasons teach about its topic (0.81.1), and its lessons say which.
        XCTAssertEqual(lessons[5].text, AppLocalization.string("\(PulseCardKind.topic("commitment")): \(PulseLevel.brief.title)"))
        XCTAssertEqual(lessons[5].causeText, AppLocalization.string("You said too often"))
        XCTAssertEqual(lessons[6].text, AppLocalization.string("\(PulseCardKind.topic("date")): Bring up sooner"))
        XCTAssertEqual(lessons[7].text, AppLocalization.string("\(PulseCardKind.topic("fact")): Skip what you already know"))
        XCTAssertEqual(lessons[8].text, AppLocalization.string("No updates about “\("Send the deck")”"))
        XCTAssertEqual(PulseCardKind.name("followup"), PulseCardKind.title("followup"))
        XCTAssertEqual(PulseCardKind.name("noticed"), PulseCardKind.title("noticed"))
        XCTAssertEqual(PulseCardKind.name("other"), PulseCardKind.topic("other"))

        // Before 0.81.1 thumbs move the levels; a plugin that learns says the level is the loudest Pulse gets.
        XCTAssertEqual(PulseLearned.levelsFooter(learns: false),
                       AppLocalization.string("Thumbs move these too: two down make it quieter, two up louder."))
        XCTAssertEqual(PulseLearned.levelsFooter(learns: true), AppLocalization.string(
            "The loudest Pulse gets for each. Within that, your thumbs, Do it and Done teach it what to bring up and how loudly."))
        XCTAssertEqual(PulseLearned.noLessons(learns: false),
                       AppLocalization.string("Nothing yet. Rate Pulse's cards and what it learns shows up here."))
        XCTAssertEqual(PulseLearned.noLessons(learns: true), AppLocalization.string(
            "Nothing yet. When you give a reason with a thumbs down, what it changes shows up here."))
        XCTAssertEqual(PulseClient.learnsCapability, "pulse_learns")
    }

    func testLearnedListsWhatLearningHoldsAndResetsSayWhatTheyForgot() throws {
        let learned = try XCTUnwrap(PulseLearned(json: json("""
        {"ok": true, "levels": {},
         "lessons": [
          {"id": 11, "kind": "place", "what": "reset", "value": "chat::c1", "cause": "reset", "chat_title": "Deploy"},
          {"id": 12, "kind": "everything", "what": "reset", "value": "", "cause": "reset"},
          {"id": 13, "kind": "timely", "what": "reset", "value": "yes", "cause": "reset"}],
         "preferences": [
          {"scope": "place", "value": "chat::c1", "effect": -1.8, "useful": 0, "votes": 2,
           "profile": "", "chat_id": "c1", "chat_title": "Deploy"},
          {"scope": "loud", "value": "followup", "effect": 0.6, "pushes": 3},
          {"scope": "kind", "value": "promise", "effect": 0.7, "useful": 2.5, "votes": 3},
          {"scope": "place", "value": "area:health", "effect": -0.3, "useful": 1, "votes": 4},
          {"scope": "place", "value": "source:calendar", "effect": 0.2, "useful": 1, "votes": 1},
          {"scope": "timely", "value": "no", "effect": -0.2, "useful": 0, "votes": 0},
          {"scope": "all", "value": "", "effect": 0.4, "useful": 3, "votes": 5},
          {"scope": "place", "value": "chat::c2", "effect": 0.2, "useful": 1, "votes": 1},
          {"scope": "everything", "value": "", "effect": 1},
          {"scope": "kind", "value": "date"}]}
        """)))

        let found = learned.preferences
        XCTAssertEqual(found.map(\.id), [
            "place|chat::c1", "loud|followup", "kind|promise", "place|area:health", "place|source:calendar",
            "timely|no", "all|", "place|chat::c2"
        ])
        // Every vote leans over Pulse's cards in general: only Start over forgets that.
        XCTAssertEqual(found.map(\.canReset), [true, true, true, true, true, true, false, true])
        XCTAssertEqual(found.map(\.subject), [
            AppLocalization.string("Things from “\("Deploy")”"),
            AppLocalization.string("How loudly “\(PulseCardKind.title("followup"))” cards come up"),
            AppLocalization.string("“\(PulseCardKind.topic("promise"))” cards"),
            AppLocalization.string("Things about “\(AppLocalization.string("Health and wellbeing"))”"),
            AppLocalization.string("Things from “\(AppLocalization.string("Calendar"))”"),
            AppLocalization.string("What isn't due within a day"),
            AppLocalization.string("Pulse's cards in general"),
            AppLocalization.string("Things from a chat")
        ])
        let dot = " · "
        XCTAssertEqual(found[0].detail, [
            AppLocalization.string("Brings up less"), AppLocalization.string("Strong effect"),
            AppLocalization.string("Useful \(PulsePreference.number(0)) out of \(PulsePreference.number(2)) lately")
        ].joined(separator: dot))
        let pushCount = 3
        XCTAssertEqual(found[1].detail, AppLocalization.string("Louder") + dot
            + AppLocalization.string("After \(pushCount) notifications you acted on within the hour"))
        XCTAssertEqual(found[2].detail, [
            AppLocalization.string("Brings up more"), AppLocalization.string("Moderate effect"),
            AppLocalization.string("Useful \(PulsePreference.number(2.5)) out of \(PulsePreference.number(3)) lately")
        ].joined(separator: dot))
        XCTAssertEqual(found[3].strength, AppLocalization.string("Slight effect"))
        // No votes left in the window: which way, and how strongly.
        XCTAssertEqual(found[5].detail, AppLocalization.string("Brings up less") + dot + AppLocalization.string("Slight effect"))
        XCTAssertEqual(PulsePlace.area("travel"), AppLocalization.string("Trips and travel"))
        XCTAssertEqual(PulsePlace.area("something new"), AppLocalization.string("Other matters"))
        XCTAssertEqual(PulsePlace.source("notes"), AppLocalization.string("Hermes' notes"))
        XCTAssertEqual(PulsePlace.source("chat"), AppLocalization.string("Chats"))

        // A reset says what it forgot; Undo takes it back like any lesson.
        let lessons = learned.lessons
        XCTAssertEqual(lessons.map(\.id), [11, 12, 13])
        XCTAssertEqual(lessons[0].text, AppLocalization.string("Reset: \(AppLocalization.string("Things from “\("Deploy")”"))"))
        XCTAssertNil(lessons[0].causeText)
        XCTAssertEqual(lessons[1].text, AppLocalization.string("Forgot everything learned before this"))
        XCTAssertEqual(lessons[2].text, AppLocalization.string("Reset: \(AppLocalization.string("What's overdue or due within a day"))"))
        XCTAssertEqual(PulseLearned.noPreferences, AppLocalization.string(
            "Nothing stands out yet. The more you use thumbs, Do it and Done, the more Pulse learns what to bring up."))
        // A plugin from before lists none.
        let older = try XCTUnwrap(PulseLearned(json: json(#"{"lessons": []}"#)))
        XCTAssertEqual(older.preferences, [])
        XCTAssertEqual(PulseClient.explainsCapability, "pulse_explains")
    }

    func testPulseCardsForChatFindsTheOpenChat() throws {
        let state = try appState()
        state.pulseSources = ["a": [5: 9]]

        XCTAssertEqual(state.pulseCards(forChat: "a"), [5: 9])
        XCTAssertEqual(state.pulseCards(forChat: "b"), [:])
        XCTAssertEqual(state.pulseCards(forChat: nil), [:])
    }

    func testApplyingAFeedSetsTheBadgeAndMarks() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"unseen": 3, "cards": [{"id": 9, "chat_id": "a", "message_id": 5}]}
        """)))

        state.applyPulseFeed(page)

        XCTAssertEqual(state.pulseUnseen, 3)
        XCTAssertEqual(state.pulseSources, ["a": [5: 9]])
        XCTAssertNil(state.pulseHomeChatID)

        state.applyPulseFeed(try XCTUnwrap(PulseFeedPage(json: json(#"{"home_chat_id": "p", "cards": []}"#))))
        XCTAssertEqual(state.pulseHomeChatID, "p")
    }

    func testPulseKeepsItsButtonAndHiddenChatUntilThePluginReportsAgain() throws {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let dashboard = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let registry = SavedDashboardRegistry(activeDashboardID: dashboard.id, dashboards: [dashboard])
        let first = AppState(defaults: defaults, loadSavedConnection: false, dashboardRegistry: registry,
                             clearSessionPresentationCache: {})
        first.applyPulseFeed(try XCTUnwrap(PulseFeedPage(json: json(#"{"home_chat_id": "p", "cards": []}"#))))

        // The next launch: the plugin hasn't answered yet.
        let next = AppState(defaults: defaults, loadSavedConnection: false, dashboardRegistry: registry,
                            clearSessionPresentationCache: {})
        XCTAssertNil(next.pulseHomeChatID)
        XCTAssertEqual(next.pulseHomeChat, "p")
        XCTAssertTrue(next.showsPulseScreen)

        // It answers with Pulse before the feed is read: still hidden.
        next.setNotifierPluginStateForTesting(.reported(version: "0.74.0",
                                                        capabilities: [PulseClient.capability, PulseClient.feedCapability]))
        XCTAssertEqual(next.pulseHomeChat, "p")
        XCTAssertTrue(next.showsPulseScreen)

        // It answers without Pulse, or predates reporting: gone, and forgotten.
        next.setNotifierPluginStateForTesting(.reported(version: "0.40.0", capabilities: []))
        XCTAssertNil(next.pulseHomeChat)
        XCTAssertFalse(next.showsPulseScreen)
        let later = AppState(defaults: defaults, loadSavedConnection: false, dashboardRegistry: registry,
                             clearSessionPresentationCache: {})
        XCTAssertNil(later.pulseHomeChat)

        later.applyPulseFeed(try XCTUnwrap(PulseFeedPage(json: json(#"{"home_chat_id": "p", "cards": []}"#))))
        let older = AppState(defaults: defaults, loadSavedConnection: false, dashboardRegistry: registry,
                             clearSessionPresentationCache: {})
        older.setNotifierPluginStateForTesting(.predatesCapabilities)
        XCTAssertNil(older.pulseHomeChat)
        XCTAssertFalse(older.showsPulseScreen)
    }

    func testARemovedDashboardTakesItsRememberedPulseChatWithIt() throws {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let active = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let other = SavedDashboard(id: UUID(), label: "Office", normalizedURL: "http://127.0.0.1:2")
        defaults.set([active.id.uuidString: "p", other.id.uuidString: "q"], forKey: AppState.pulseHomesKey)
        let appState = AppState(defaults: defaults, loadSavedConnection: false,
                                dashboardRegistry: SavedDashboardRegistry(activeDashboardID: active.id,
                                                                          dashboards: [active, other]),
                                clearSessionPresentationCache: {})

        appState.removeDashboard(other.id)

        XCTAssertEqual(defaults.dictionary(forKey: AppState.pulseHomesKey) as? [String: String],
                       [active.id.uuidString: "p"])
        XCTAssertEqual(appState.pulseHomeChat, "p")
    }

    func testDoneAndActedPostTheCardToThePlugin() async throws {
        var calls: [(path: String, method: String, body: [String: Any]?)] = []
        var answer: [String: Any] = ["ok": true, "changed": true]
        let client = PulseClient { path, method, body in
            calls.append((path, method, body))
            return answer
        }

        let changed = try await client.markDone(card: 7, done: true)
        XCTAssertTrue(changed)
        answer = ["ok": true, "changed": false]
        let unchanged = try await client.markDone(card: 7, done: false)
        XCTAssertFalse(unchanged)
        try await client.acted(card: 9)

        XCTAssertEqual(calls.map(\.path), [
            "\(PulseClient.path)/done", "\(PulseClient.path)/done", "\(PulseClient.path)/acted"
        ])
        XCTAssertEqual(calls.map(\.method), ["POST", "POST", "POST"])
        XCTAssertEqual(calls[0].body?["card"] as? Int, 7)
        XCTAssertEqual(calls[0].body?["done"] as? Bool, true)
        XCTAssertEqual(calls[1].body?["done"] as? Bool, false)
        XCTAssertEqual(calls[2].body?["card"] as? Int, 9)
    }

    func testReportItemsAreTheirOwnRatableCards() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "noticed", "topic": "promise", "item_id": 4, "level": "screen", "news": "Send the deck",
           "chat_id": "work", "title": "Send the deck to Mara"},
          {"id": 2, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "chat_id": "pulse"},
          {"id": 3, "kind": "report", "level": "screen", "news": "Here's your report."}
        ]}
        """)))
        let owed = page.cards[0], date = page.cards[1], report = page.cards[2]
        XCTAssertTrue(owed.isNoticed && owed.isRatable && owed.canBeDone && owed.isActionable)
        XCTAssertEqual(owed.topic, "promise")
        XCTAssertEqual(owed.heading, PulseCardKind.topic("promise"))
        XCTAssertTrue(date.isRatable)
        XCTAssertFalse(date.canBeDone || date.isActionable)  // nothing remembered behind it
        XCTAssertTrue(date.isFound)
        XCTAssertFalse(owed.isFound || report.isFound)
        XCTAssertFalse(report.isRatable)
        XCTAssertEqual(report.heading, PulseCardKind.title("report"))
        XCTAssertEqual(PulseCardKind.topic("something new"), PulseCardKind.topic(""))  // unknown topics read "Noticed"
    }

    func testWhyShowsOnAReportCardOnceThePluginGivesItsReason() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "push", "news": "The deploy is still waiting.",
           "why": "You said you would check it."},
          {"id": 2, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday",
           "why": "Your calendar has it for Friday."},
          {"id": 3, "kind": "noticed", "topic": "fact", "level": "screen", "news": "Ana is in town", "why": ""},
          {"id": 4, "kind": "brief", "level": "screen", "news": "Your morning brief",
           "why": "Your morning brief: what's still outstanding."},
          {"id": 5, "kind": "report", "level": "push", "news": "Pulse noticed 2 things",
           "why": "Your Pulse report: what Hermes saw in your chats since the last one."},
          {"id": 6, "kind": "report", "level": "push", "news": "Pulse noticed 2 things", "why": ""}
        ]}
        """)))
        let followup = page.cards[0], dated = page.cards[1], plain = page.cards[2]
        let brief = page.cards[3], whole = page.cards[4], wholeNow = page.cards[5]
        // A plugin from before gave report and brief cards stock lines: only a follow-up's reason shows.
        state.setNotifierPluginStateForTesting(.reported(version: "0.80.0", capabilities: [PulseClient.feedCapability]))
        XCTAssertTrue(state.explainsPulseCard(followup))
        XCTAssertFalse(state.explainsPulseCard(dated))
        XCTAssertFalse(state.explainsPulseCard(plain))
        XCTAssertFalse(state.explainsPulseCard(brief))
        XCTAssertFalse(state.explainsPulseCard(whole))
        // One that gives each report item its candidate's reason (0.80.1): Why? where there is one.
        state.setNotifierPluginStateForTesting(.reported(version: "0.80.1", capabilities: [
            PulseClient.feedCapability, PulseClient.cardWhyCapability
        ]))
        XCTAssertTrue(state.explainsPulseCard(followup))
        XCTAssertTrue(state.explainsPulseCard(dated))
        XCTAssertTrue(state.explainsPulseCard(brief))
        // Such a plugin clears the old stock lines, so a whole report's card has no why;
        // one that had a why would show it.
        XCTAssertFalse(state.explainsPulseCard(wholeNow))
        XCTAssertTrue(state.explainsPulseCard(whole))
        XCTAssertFalse(state.explainsPulseCard(plain))
    }

    func testWhyNamesWhatLearningDidOnceThePluginSays() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "brief", "news": "The deploy is still waiting.", "why": "",
           "profile": "", "chat_id": "c1", "chat_title": "Deploy",
           "learned": {"scope": "place", "value": "chat::c1", "effect": -0.9, "useful": 0, "votes": 2}},
          {"id": 2, "kind": "noticed", "topic": "promise", "level": "screen", "news": "Send the deck",
           "why": "You said you'd send it.",
           "learned": {"scope": "kind", "value": "promise", "effect": 0.6, "useful": 2, "votes": 2}},
          {"id": 3, "kind": "noticed", "topic": "fact", "level": "screen", "news": "Ana is in town", "why": "",
           "learned": null},
          {"id": 4, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist", "why": "",
           "chat_id": "c1", "chat_title": "Deploy",
           "learned": {"scope": "place", "value": "chat::c2", "effect": 0.5}},
          {"id": 5, "kind": "noticed", "topic": "date", "level": "screen", "news": "Flight", "why": "",
           "learned": {"scope": "bogus", "value": "x", "effect": 1}}
        ]}
        """)))
        let held = page.cards[0], promised = page.cards[1], plain = page.cards[2]
        let elsewhere = page.cards[3], odd = page.cards[4]
        state.setNotifierPluginStateForTesting(.reported(version: "0.84.0", capabilities: [
            PulseClient.feedCapability, PulseClient.cardWhyCapability, PulseClient.learnsCapability,
            PulseClient.explainsCapability
        ]))
        XCTAssertTrue(state.pulseExplainsLearning)
        // Held for the brief by what thumbs taught about its chat: Why? says so, by the card's chat title.
        XCTAssertEqual(held.learned?.subject, AppLocalization.string("Things from “\("Deploy")”"))
        XCTAssertTrue(state.explainsPulseCard(held))
        XCTAssertFalse(state.explainsPulseCardReason(held))
        XCTAssertEqual(promised.learned?.subject, AppLocalization.string("“\(PulseCardKind.topic("promise"))” cards"))
        XCTAssertTrue(state.explainsPulseCardReason(promised))
        XCTAssertNil(plain.learned)
        XCTAssertFalse(state.explainsPulseCard(plain))
        // Another chat's title isn't the card's to give.
        XCTAssertEqual(elsewhere.learned?.subject, AppLocalization.string("Things from a chat"))
        XCTAssertNil(odd.learned)
        // A plugin from before has no What Pulse left out and no Reset, and
        // its Why? says nothing about learning even if a card carries it.
        state.setNotifierPluginStateForTesting(.reported(version: "0.82.0", capabilities: [
            PulseClient.feedCapability, PulseClient.cardWhyCapability, PulseClient.learnsCapability
        ]))
        XCTAssertFalse(state.pulseExplainsLearning)
        XCTAssertFalse(state.explainsPulseCard(held))
        XCTAssertTrue(state.explainsPulseCard(promised))  // its own reason, which 0.80.1 on gives
    }

    func testAReportCardsThumbsDownAsksWhyOnceThePluginActsOnIt() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "push", "news": "The deploy is still waiting."},
          {"id": 2, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday"},
          {"id": 3, "kind": "report", "level": "push", "news": "Pulse noticed 2 things"}
        ]}
        """)))
        let followup = page.cards[0], dated = page.cards[1], whole = page.cards[2]
        // Before 0.81.1 a report card's reason changed nothing: its thumbs down is enough.
        state.setNotifierPluginStateForTesting(.reported(version: "0.81.0", capabilities: [PulseClient.feedCapability]))
        XCTAssertTrue(state.asksPulseDownReason(followup))
        XCTAssertFalse(state.asksPulseDownReason(dated) || state.asksPulseDownReason(whole))
        // A plugin that learns acts on a report card's reason too.
        state.setNotifierPluginStateForTesting(.reported(version: "0.81.1", capabilities: [
            PulseClient.feedCapability, PulseClient.learnsCapability
        ]))
        XCTAssertTrue(state.asksPulseDownReason(followup) && state.asksPulseDownReason(dated))
        XCTAssertFalse(state.asksPulseDownReason(whole))  // a whole report has no thumbs
    }

    func testDoItsMessageFitsWhatTheCardIsAbout() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "followup", "level": "push", "news": "The backup is still on the server", "chat_id": "work"},
          {"id": 2, "kind": "noticed", "topic": "promise", "item_id": 4, "level": "screen", "news": "I still owe you the build check", "chat_id": "work"},
          {"id": 3, "kind": "noticed", "topic": "commitment", "item_id": 5, "level": "screen", "news": "Renew your passport", "chat_id": "work"},
          {"id": 4, "kind": "noticed", "topic": "reminder", "level": "screen", "news": "Send the release notes", "chat_id": ""},
          {"id": 5, "kind": "noticed", "topic": "date", "level": "screen", "news": "Ana lands at 18:00", "chat_id": ""},
          {"id": 6, "kind": "noticed", "topic": "watch", "level": "screen", "news": "The deploy is still flaky", "chat_id": "work"},
          {"id": 7, "kind": "noticed", "topic": "interest", "level": "screen", "news": "A new Swift release is out", "chat_id": "work"},
          {"id": 8, "kind": "noticed", "topic": "fact", "level": "screen", "news": "", "title": "Your sister is Ana", "chat_id": "work"},
          {"id": 9, "kind": "noticed", "topic": "", "level": "screen", "news": "Something else", "chat_id": "work"}
        ]}
        """)))
        let message = Dictionary(uniqueKeysWithValues: page.cards.map { ($0.id, $0.actionMessage) })
        // What Hermes said it would do gets a go-ahead, whether the card is a
        // follow-up or a remembered promise.
        XCTAssertEqual(message[1], "Pulse reminded me: The backup is still on the server\n\nGo ahead with it now.")
        XCTAssertEqual(message[2], "Pulse reminded me: I still owe you the build check\n\nGo ahead with it now.")
        // What the user meant to do gets taken care of.
        XCTAssertEqual(message[3], "Pulse reminded me: Renew your passport\n\nLet's take care of it now.")
        XCTAssertEqual(message[4], "Pulse reminded me: Send the release notes\n\nLet's take care of it now.")
        XCTAssertEqual(message[5], "Pulse brought this up: Ana lands at 18:00\n\nHelp me get ready for it.")
        XCTAssertEqual(message[6], "Pulse brought this up: The deploy is still flaky\n\nWhere does that stand now?")
        XCTAssertEqual(message[7], "Pulse brought this up: A new Swift release is out\n\nTell me more.")
        // The title stands in for empty news; a fact or an unknown topic gets a look.
        XCTAssertEqual(message[8], "Pulse brought this up: Your sister is Ana\n\nLet's look into it.")
        XCTAssertEqual(message[9], "Pulse brought this up: Something else\n\nLet's look into it.")
    }

    func testACardPointingAtPulsesOwnChatOpensNoChat() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "brief", "level": "push", "news": "Morning", "chat_id": "pulse_chat"},
          {"id": 2, "kind": "followup", "level": "push", "news": "Deck", "chat_id": "work"}
        ]}
        """)))
        state.applyPulseFeed(page)
        XCTAssertFalse(state.pulseCardHasChat(page.cards[0]))
        XCTAssertTrue(state.pulseCardHasChat(page.cards[1]))
    }

    func testDoneAndDoItReachReportItemsPulseFoundOnItsOwnWhereThePluginTakesThem() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "chat_id": "pulse_chat"},
          {"id": 2, "kind": "noticed", "topic": "fact", "level": "screen", "news": "The repo moved", "chat_id": "work"},
          {"id": 3, "kind": "noticed", "topic": "promise", "item_id": 4, "level": "screen", "news": "Send the deck",
           "chat_id": "work"},
          {"id": 4, "kind": "report", "level": "screen", "news": "Here's your report.", "chat_id": "pulse_chat"}
        ]}
        """)))
        let date = page.cards[0], fact = page.cards[1], owed = page.cards[2], report = page.cards[3]
        // A plugin that takes Done and Do it only on what Pulse remembers (0.64.0).
        state.setNotifierPluginStateForTesting(.reported(version: "0.76.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability
        ]))
        state.applyPulseFeed(page)
        XCTAssertTrue(state.canMarkPulseCardDone(owed) && state.canActOnPulseCard(owed))
        XCTAssertFalse(state.canMarkPulseCardDone(date) || state.canActOnPulseCard(date))
        XCTAssertFalse(state.canMarkPulseCardDone(fact) || state.canActOnPulseCard(fact))
        // One that takes them on every report item (0.77.0).
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability,
            PulseClient.foundActionsCapability
        ]))
        XCTAssertTrue(state.canMarkPulseCardDone(date) && state.canActOnPulseCard(date))
        XCTAssertTrue(state.canMarkPulseCardDone(fact) && state.canActOnPulseCard(fact))
        XCTAssertFalse(state.canMarkPulseCardDone(report) || state.canActOnPulseCard(report))
        // Found in a chat, Do it opens that chat; from no chat, Pulse's own is
        // no chat to open, so it starts a new one.
        XCTAssertTrue(state.pulseCardHasChat(fact))
        XCTAssertFalse(state.pulseCardHasChat(date))
        XCTAssertNil(state.pulseNewChatRefusal(for: fact))  // its own chat opens, connected or not
        // A plugin without Done takes it on no card.
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.foundActionsCapability
        ]))
        XCTAssertFalse(state.canMarkPulseCardDone(date) || state.canMarkPulseCardDone(owed))
    }

    func testDoItOnAReportItemFromNoChatFillsOnlyTheChatItsNewChatMade() async throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "chat_id": "pulse_chat"}
        ]}
        """)))
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability,
            PulseClient.foundActionsCapability
        ]))
        state.applyPulseFeed(page)
        let date = try XCTUnwrap(page.cards.first)
        // Offline, Do it says so at once instead of waiting for a chat.
        XCTAssertEqual(state.pulseNewChatRefusal(for: date),
                       AppLocalization.string("Couldn't start a new chat. Check your connection and try again."))
        let refused = await state.actOnPulseCard(date)
        XCTAssertFalse(refused)
        // Connecting, it says so too: New Chat would make a chat that waits.
        state.isConnecting = true
        XCTAssertEqual(state.pulseNewChatRefusal(for: date),
                       AppLocalization.string("Conduit is still connecting to your dashboard. Try again in a moment."))
        state.isConnecting = false
        state.isConnected = true
        state.client = HermesClient(connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
                                    profile: "default")
        XCTAssertNil(state.pulseNewChatRefusal(for: date))
        // A chat an earlier New Chat made is still open, under the chat list.
        state.activeSessionId = "earlier"
        state.newChatOpenedSessionID = "earlier"
        state.showSidebar = true
        // A new chat that doesn't start gets nothing, and the earlier one isn't taken for it.
        state.widgetSessionCreatorOverride = { _, _ in throw URLError(.timedOut) }
        let failed = await state.actOnPulseCard(date)
        XCTAssertFalse(failed)
        XCTAssertEqual(state.activeSessionId, "earlier")
        XCTAssertEqual(state.composerPrefillText, "")
        XCTAssertTrue(state.showSidebar, "the Pulse screen stays up to say why")
        // The chat its New Chat made gets the reminder, uncovered.
        state.showSidebar = true
        state.widgetSessionCreatorOverride = { _, _ in ("fresh", "fresh", "default") }
        let opened = await state.actOnPulseCard(date)
        XCTAssertTrue(opened)
        XCTAssertEqual(state.activeSessionId, "fresh")
        XCTAssertFalse(state.showSidebar)
        XCTAssertEqual(state.composerPrefillText, date.actionMessage)
        XCTAssertEqual(state.composerPrefillDraftKey, ComposerBar.composerDraftKey(for: "fresh", profile: "default"))
    }

    func testDoItNeverFillsAChatAnotherCreateOpenedWhileItsOwnWasStarting() async throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist Friday", "chat_id": "pulse_chat"}
        ]}
        """)))
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability,
            PulseClient.foundActionsCapability
        ]))
        state.applyPulseFeed(page)
        let date = try XCTUnwrap(page.cards.first)
        state.isConnected = true
        state.client = HermesClient(connection: HermesConnection(baseUrl: "https://one.example", ticket: "ticket"),
                                    profile: "default")
        // Another create (a call's chat, Ask Hermes About) starts while Do
        // it's own is on its way, and opens its chat first.
        var creates = 0
        state.widgetSessionCreatorOverride = { [weak state] _, _ in
            creates += 1
            guard creates == 1 else { return ("other", "other", "default") }
            _ = await state?.createNewSession()
            return ("mine", "mine", "default")
        }
        let opened = await state.actOnPulseCard(date)
        XCTAssertEqual(creates, 2)
        XCTAssertFalse(opened)
        XCTAssertEqual(state.activeSessionId, "other")
        XCTAssertEqual(state.composerPrefillText, "", "the reminder never goes into a chat Do it didn't start")
        XCTAssertFalse(state.isStartingNewChat)
    }

    func testDoItOnAnItemFoundInAChatFillsThatChat() async throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 2, "kind": "noticed", "topic": "fact", "level": "screen", "news": "The repo moved", "chat_id": "work",
           "message_id": 42}
        ]}
        """)))
        state.setNotifierPluginStateForTesting(.reported(version: "0.77.0", capabilities: [
            PulseClient.feedCapability, PulseClient.doneCapability, PulseClient.actedCapability,
            PulseClient.foundActionsCapability
        ]))
        state.applyPulseFeed(page)
        let fact = try XCTUnwrap(page.cards.first)
        var creates = 0
        state.widgetSessionCreatorOverride = { _, _ in
            creates += 1
            return ("fresh", "fresh", "default")
        }
        state.activeSessionId = "work"
        let opened = await state.actOnPulseCard(fact)
        XCTAssertTrue(opened)
        XCTAssertEqual(creates, 0, "an item found in a chat starts no new one")
        XCTAssertEqual(state.pendingArtifactReveal?.messageID, 42)
        XCTAssertEqual(state.composerPrefillText, fact.actionMessage)
        XCTAssertEqual(state.composerPrefillDraftKey, ComposerBar.composerDraftKey(for: "work", profile: "default"))
    }

    func testOpeningACardsChatShowsTheMessageItCameFrom() throws {
        let state = try appState()
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"home_chat_id": "pulse_chat", "cards": [
          {"id": 1, "kind": "followup", "level": "push", "news": "Deck", "chat_id": "work", "message_id": 42},
          {"id": 2, "kind": "followup", "level": "push", "news": "Call", "chat_id": "home"},
          {"id": 3, "kind": "brief", "level": "push", "news": "Morning", "chat_id": "pulse_chat", "message_id": 7}
        ]}
        """)))
        state.applyPulseFeed(page)
        state.openPulseCardChat(page.cards[0])
        XCTAssertEqual(state.pendingArtifactReveal?.messageID, 42)
        XCTAssertEqual(state.pendingArtifactReveal?.opening, "work")
        // No message: the chat lands where it would, not at an older card's.
        state.openPulseCardChat(page.cards[1])
        XCTAssertNil(state.pendingArtifactReveal)
        // Pulse's own chat opens nothing, so nothing waits to scroll.
        state.openPulseCardChat(page.cards[2])
        XCTAssertNil(state.pendingArtifactReveal)
    }

    func testABriefShowsWithTheCardsItBroughtAndFoldsOnceHandled() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "kind": "noticed", "topic": "date", "level": "screen", "news": "New", "created_at": 300},
          {"id": 8, "kind": "brief", "level": "push", "news": "Two things waited.", "brief": "b2", "created_at": 200},
          {"id": 7, "kind": "followup", "level": "brief", "news": "Deck", "brief": "b2", "created_at": 120, "item_id": 1},
          {"id": 6, "kind": "followup", "level": "brief", "news": "Gym", "brief": "b2", "created_at": 110,
           "dismissed_at": 250},
          {"id": 5, "kind": "brief", "level": "push", "news": "Old", "brief": "b1", "created_at": 100},
          {"id": 4, "kind": "followup", "level": "brief", "news": "Paid", "brief": "b1", "created_at": 50,
           "done_at": 90, "item_id": 2},
          {"id": 3, "kind": "brief", "level": "push", "news": "From an older plugin", "created_at": 40},
          {"id": 2, "kind": "noticed", "topic": "fact", "level": "screen", "news": "Gone", "dismissed_at": 60,
           "created_at": 30}
        ]}
        """)))
        let layout = PulseLayout(cards: page.cards)
        XCTAssertEqual(layout.briefs.map(\.id), [8])
        let brief = try XCTUnwrap(layout.briefs.first)
        XCTAssertEqual(brief.items.map(\.id), [6, 7], "oldest first")
        XCTAssertEqual(brief.left, 1)
        XCTAssertFalse(brief.isHandled)
        XCTAssertEqual(layout.open.map(\.id), [9, 3], "an untagged brief is a card of its own")
        XCTAssertEqual(layout.cleared.map(\.id), [2])
        XCTAssertEqual(layout.clearedBriefs.map(\.id), [5], "an older brief all handled folds into Done and cleared")
        XCTAssertEqual(layout.clearedCount, 2)
        XCTAssertEqual(page.cards.first { $0.id == 6 }?.dismissedAt, Date(timeIntervalSince1970: 250))

        // The newest brief stays at the top, folded, once everything in it is handled.
        var handled = page
        if let index = handled.cards.firstIndex(where: { $0.id == 7 }) { handled.cards[index].doneAt = Date() }
        XCTAssertEqual(PulseLayout(cards: handled.cards).briefs.map(\.isHandled), [true])
        XCTAssertFalse(layout.isCaughtUp)
        XCTAssertTrue(PulseLayout(cards: handled.cards.filter { [8, 7, 6].contains($0.id) }).isCaughtUp)
        // The card a push opened stays where it is, though cleared.
        XCTAssertEqual(PulseLayout(cards: page.cards, keeping: [2]).open.map(\.id), [9, 3, 2])
    }

    func testABriefThatBroughtNoCardsShowsAsItsSummary() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "kind": "brief", "level": "push", "news": "A calm day.", "brief": "b3", "created_at": 300},
          {"id": 8, "kind": "noticed", "topic": "date", "level": "screen", "news": "New", "created_at": 250},
          {"id": 5, "kind": "brief", "level": "push", "news": "Yesterday", "brief": "b2", "created_at": 200}
        ]}
        """)))
        let layout = PulseLayout(cards: page.cards)
        XCTAssertEqual(layout.briefs.map(\.id), [9], "the newest brief stays at the top")
        XCTAssertEqual(layout.briefs.first?.isSummary, true)
        XCTAssertEqual(layout.open.map(\.id), [8])
        XCTAssertEqual(layout.clearedBriefs.map(\.id), [5], "older ones fold into Done and cleared")
        XCTAssertEqual(layout.clearedCount, 1)
        // The one a push opened stays where it is.
        XCTAssertEqual(PulseLayout(cards: page.cards, keeping: [5]).briefs.map(\.id), [9, 5])
        let alone = PulseLayout(cards: page.cards.filter { $0.kind == "brief" })
        XCTAssertTrue(alone.open.isEmpty)
        XCTAssertFalse(alone.isCaughtUp, "the summary lists what's still open")
    }

    /// A brief folds to one row once the user folds it, a summary alone and
    /// one with cards left too, and stays folded until it's opened again;
    /// one all handled folds by itself unless opened on this visit. A push
    /// or a Pulse mark pointing into it opens it, and so does a card that
    /// came back into it from Not now after the fold.
    func testABriefFoldsOnceTheUserFoldsItOrOnceItIsAllHandled() throws {
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 9, "kind": "brief", "level": "push", "news": "A calm day.", "brief": "b3", "created_at": 300},
          {"id": 8, "kind": "brief", "level": "push", "news": "Two things waited.", "brief": "b2", "created_at": 200},
          {"id": 7, "kind": "followup", "level": "brief", "news": "Deck", "brief": "b2", "created_at": 120, "item_id": 1},
          {"id": 6, "kind": "followup", "level": "brief", "news": "Gym", "brief": "b2", "created_at": 110,
           "done_at": 250}
        ]}
        """)))
        let layout = PulseLayout(cards: page.cards)
        let summary = try XCTUnwrap(layout.briefs.first { $0.id == 9 })
        let open = try XCTUnwrap(layout.briefs.first { $0.id == 8 })
        XCTAssertEqual(open.newest, Date(timeIntervalSince1970: 200))
        XCTAssertFalse(summary.isFolded(foldedThrough: nil, opened: false, focused: nil), "open until it's folded")
        XCTAssertTrue(summary.isFolded(foldedThrough: summary.newest, opened: false, focused: nil))
        XCTAssertFalse(open.isFolded(foldedThrough: nil, opened: false, focused: nil), "a card in it is left")
        XCTAssertTrue(open.isFolded(foldedThrough: open.newest, opened: false, focused: nil))
        XCTAssertFalse(open.isFolded(foldedThrough: open.newest, opened: false, focused: 7),
                       "a push pointed at one of its cards")
        XCTAssertFalse(summary.isFolded(foldedThrough: summary.newest, opened: false, focused: 9),
                       "or at the brief itself")

        // Gym, put off until later, comes back as new after the fold: the brief opens to show it.
        let back = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 8, "kind": "brief", "level": "push", "news": "Two things waited.", "brief": "b2", "created_at": 200},
          {"id": 7, "kind": "followup", "level": "brief", "news": "Deck", "brief": "b2", "created_at": 120, "item_id": 1,
           "done_at": 260},
          {"id": 6, "kind": "followup", "level": "brief", "news": "Gym", "brief": "b2", "created_at": 400}
        ]}
        """)))
        let returned = try XCTUnwrap(PulseLayout(cards: back.cards).briefs.first { $0.id == 8 })
        XCTAssertFalse(returned.isFolded(foldedThrough: open.newest, opened: false, focused: nil))
        XCTAssertTrue(returned.isFolded(foldedThrough: returned.newest, opened: false, focused: nil), "folded again")

        var handled = page
        if let index = handled.cards.firstIndex(where: { $0.id == 7 }) { handled.cards[index].doneAt = Date() }
        let done = try XCTUnwrap(PulseLayout(cards: handled.cards).clearedBriefs.first { $0.id == 8 })
        XCTAssertTrue(done.isFolded(foldedThrough: nil, opened: false, focused: nil), "all handled")
        XCTAssertFalse(done.isFolded(foldedThrough: nil, opened: true, focused: nil), "opened again on this visit")
    }

    /// A folded brief stays folded across a relaunch, on its own dashboard
    /// only. Opening it forgets the fold, only the newest folds are kept,
    /// and a removed dashboard's go with it.
    func testFoldedBriefsAreKeptPerDashboardAcrossLaunches() throws {
        let suite = "PulseFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let active = SavedDashboard(id: UUID(), label: "Home", normalizedURL: "http://127.0.0.1:1")
        let other = SavedDashboard(id: UUID(), label: "Office", normalizedURL: "http://127.0.0.1:2")
        func launch(_ dashboard: SavedDashboard) -> AppState {
            AppState(defaults: defaults, loadSavedConnection: false,
                     dashboardRegistry: SavedDashboardRegistry(activeDashboardID: dashboard.id,
                                                               dashboards: [active, other]),
                     clearSessionPresentationCache: {})
        }
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        launch(other).foldPulseBrief(3, through: morning)
        let appState = launch(active)
        appState.foldPulseBrief(8, through: morning)
        XCTAssertEqual(launch(active).pulseBriefFoldedThrough(8), morning, "kept across a relaunch")
        XCTAssertNil(launch(other).pulseBriefFoldedThrough(8), "another dashboard's card 8 is another brief")
        appState.foldPulseBrief(8, through: nil)
        XCTAssertNil(launch(active).pulseBriefFoldedThrough(8), "opened again")

        let kept = AppState.pulseFoldedBriefsKept
        for brief in 1...(kept + 5) { appState.foldPulseBrief(brief, through: morning) }
        XCTAssertNil(appState.pulseBriefFoldedThrough(5), "only the newest are kept")
        XCTAssertEqual(appState.pulseBriefFoldedThrough(kept + 5), morning)
        XCTAssertEqual(launch(other).pulseBriefFoldedThrough(3), morning)

        appState.removeDashboard(other.id)
        let stored = defaults.dictionary(forKey: AppState.pulseFoldedBriefsKey) as? [String: [String: Double]]
        XCTAssertEqual(stored?.keys.sorted(), [active.id.uuidString])
    }

    func testFeedSaysWhenPulseIsQuiet() throws {
        let quiet = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [], "quiet_now": "day", "quiet_ends_at": 1800000000}
        """)))
        XCTAssertEqual(quiet.quietNow, .day)
        XCTAssertEqual(quiet.quietEndsAt, Date(timeIntervalSince1970: 1_800_000_000))
        // Not quiet, a plugin from before quiet times, or a reason this build doesn't know.
        for body in [#"{"cards": [], "quiet_now": "", "quiet_ends_at": null}"#, #"{"cards": []}"#,
                     #"{"cards": [], "quiet_now": "later", "quiet_ends_at": 5}"#] {
            let page = try XCTUnwrap(PulseFeedPage(json: json(body)))
            XCTAssertNil(page.quietNow)
            XCTAssertNil(page.quietEndsAt)
        }
        XCTAssertEqual(PulseClient.quietCapability, "pulse_quiet")
    }

    func testNotNowPostsTheCardToThePlugin() async throws {
        var calls: [(path: String, body: [String: Any]?)] = []
        let client = PulseClient { path, _, body in
            calls.append((path, body))
            return ["ok": true, "changed": true]
        }
        let answer = try await client.dismiss(card: 4, dismissed: true)
        XCTAssertTrue(answer.changed)
        XCTAssertNil(answer.restUntil)
        XCTAssertEqual(calls.first?.path, "\(PulseClient.path)/dismiss")
        XCTAssertEqual(calls.first?.body?["card"] as? Int, 4)
        XCTAssertEqual(calls.first?.body?["dismissed"] as? Bool, true)
        XCTAssertNil(calls.first?.body?["until"])
    }

    func testNotNowUntilATimeSendsTheChoiceAndReadsWhenItComesBack() async throws {
        var calls: [(path: String, body: [String: Any]?)] = []
        let client = PulseClient { path, _, body in
            calls.append((path, body))
            return ["ok": true, "changed": true, "rest_until": 1_800_000_000]
        }
        let answer = try await client.dismiss(card: 4, dismissed: true, until: .tomorrow)
        XCTAssertEqual(answer, PulseDismissal(changed: true, restUntil: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(calls.first?.body?["until"] as? String, "tomorrow")
        XCTAssertEqual(PulseRest.allCases.map(\.rawValue), ["later_today", "tomorrow", "next_week"])
        // A card put off carries when it comes back; one swiped away for good doesn't.
        let page = try XCTUnwrap(PulseFeedPage(json: json("""
        {"cards": [
          {"id": 1, "kind": "noticed", "topic": "date", "level": "screen", "news": "Dentist", "created_at": 30,
           "dismissed_at": 60, "rest_until": 90},
          {"id": 2, "kind": "noticed", "topic": "fact", "level": "screen", "news": "Gone", "dismissed_at": 60,
           "created_at": 30}
        ]}
        """)))
        XCTAssertEqual(page.cards.map(\.restUntil), [Date(timeIntervalSince1970: 90), nil])
        XCTAssertTrue(page.cards.allSatisfy(\.isCleared))
    }

    func testTheClearedRowSaysWhenAPutOffCardComesBack() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = Date(timeIntervalSince1970: 1_800_014_400)  // 2027-01-15 12:00 UTC
        let back = { (hours: Double) in
            PulseRest.backText(noon.addingTimeInterval(hours * 3600), now: noon, calendar: calendar)
        }
        // In whatever language the test host's app is in.
        XCTAssertEqual(back(3), AppLocalization.string("Back later today"))
        XCTAssertEqual(back(-1), AppLocalization.string("Back later today"))  // its time came; the plugin brings it back on its next pass
        XCTAssertEqual(back(19), AppLocalization.string("Back tomorrow"))
        let weekday = back(3 * 24)
        XCTAssertFalse(weekday.contains("%@"))
        XCTAssertFalse([back(3), back(19), back(7 * 24)].contains(weekday))
        XCTAssertEqual(back(7 * 24), AppLocalization.string("Back next week"))
        // The Undo bar says the time the plugin set, not the one asked for:
        // later today asked for at 22:40 comes back tomorrow.
        let returning = { (hours: Double) in
            PulseRest.returning(noon.addingTimeInterval(hours * 3600), now: noon, calendar: calendar)
        }
        XCTAssertEqual([returning(3), returning(19), returning(7 * 24 - 1)], [.laterToday, .tomorrow, .nextWeek])
        // Later today isn't offered once the plugin would make it tomorrow.
        XCTAssertEqual(PulseRest.choices(now: noon, calendar: calendar), PulseRest.allCases)
        XCTAssertEqual(PulseRest.choices(now: noon.addingTimeInterval(10.5 * 3600), calendar: calendar), [.tomorrow, .nextWeek])
        XCTAssertEqual(PulseRest.choices(now: noon.addingTimeInterval(10.4 * 3600), calendar: calendar), PulseRest.allCases)
    }

    func testWhatPulseLeftOutSaysWhyEachStayedOut() throws {
        let entries = try XCTUnwrap(json("""
        {"left_out": [
          {"id": 1, "kind": "watch", "text": "The gym at 7", "decision": "quieted", "skip": "", "profile": "",
           "chat_id": "c1", "chat_title": "Deploy", "created_at": 1761033600, "card_id": null,
           "learned": {"scope": "place", "value": "chat::c1", "effect": -0.8, "useful": 0, "votes": 3}},
          {"id": 2, "kind": "date", "text": "Dinner", "decision": "muted"},
          {"id": 3, "kind": "date", "text": "Flight", "decision": "off"},
          {"id": 4, "kind": "fact", "text": "Ana's birthday", "decision": "over_limit", "card_id": 40},
          {"id": 5, "text": "Book the dentist", "decision": "not_picked"},
          {"id": 6, "text": "Water the plants", "decision": "unanswered"},
          {"id": 7, "text": "Call Sam", "decision": "resting", "skip": "rated"},
          {"id": 8, "text": "Pay the rent", "decision": "resting", "skip": "put away"},
          {"id": 9, "text": "Renew the passport", "decision": "skipped", "skip": "done"},
          {"id": 10, "text": "Standup at 9", "decision": "skipped", "skip": "covered"},
          {"id": 11, "text": "The release", "decision": "skipped", "skip": "raised"},
          {"id": 12, "text": "The weather", "decision": "skipped", "skip": "rated"},
          {"id": 13, "text": "A typo", "decision": "skipped", "skip": "minor"},
          {"id": 14, "text": "Something else", "decision": "skipped", "skip": "other"},
          {"id": 15, "text": "", "decision": "not_picked"},
          {"text": "No id", "decision": "not_picked"}]}
        """)["left_out"] as? [Any])

        let found = entries.compactMap(PulseLeftOut.init(json:))
        XCTAssertEqual(found.map(\.id), Array(1...14))
        // What the user taught or set kept these out, so they're listed first.
        XCTAssertEqual(found.filter(\.isKeptOut).map(\.id), [1, 2, 3])
        XCTAssertEqual(found.map(\.reason), [
            AppLocalization.string("What you did with cards like this kept it out"),
            AppLocalization.string("You said things from this chat aren't relevant"),
            AppLocalization.string("You turned this kind off"),
            AppLocalization.string("Picked, but the report was full"),
            AppLocalization.string("Not picked for the report"),
            AppLocalization.string("The report passed over it"),
            AppLocalization.string("Resting after your thumbs down"),
            AppLocalization.string("Resting after you said Not now"),
            AppLocalization.string("Already done"),
            AppLocalization.string("Your calendar, reminders or a scheduled job covers it"),
            AppLocalization.string("Brought up lately, and nothing changed since"),
            AppLocalization.string("You said before that it wasn't useful"),
            AppLocalization.string("Too minor to bring up"),
            AppLocalization.string("Pulse chose to leave it out")
        ])
        let gym = found[0]
        XCTAssertEqual(gym.kind, "watch")
        XCTAssertEqual(gym.chatTitle, "Deploy")
        XCTAssertEqual(gym.createdAt, Date(timeIntervalSince1970: 1761033600))
        XCTAssertEqual(gym.learned?.subject, AppLocalization.string("Things from “\("Deploy")”"))
        XCTAssertNil(gym.cardID)
        // One already brought up says which card it became.
        XCTAssertEqual(found[3].cardID, 40)
        XCTAssertNil(found[1].learned)
    }

    func testResetLeftOutAndBringUpReachThePlugin() async throws {
        var calls: [(path: String, method: String, body: [String: Any]?)] = []
        var answer = try json(#"{"ok": true, "levels": {}, "lessons": [], "preferences": []}"#)
        let client = PulseClient { path, method, body in
            calls.append((path, method, body))
            return answer
        }
        let raw = try json(#"{"scope": "place", "value": "chat::c1", "effect": -1.0}"#)
        let chat = try XCTUnwrap(PulsePreference(json: raw))

        _ = try await client.reset(chat)
        _ = try await client.reset(nil)
        answer = try json(#"{"ok": true, "left_out": [{"id": 3, "text": "The gym at 7", "decision": "not_picked"}, {"id": 4}]}"#)
        let left = try await client.leftOut()
        XCTAssertEqual(left.map(\.id), [3])
        answer = try json(#"{"ok": true, "card": {"id": 21, "kind": "noticed", "topic": "watch", "level": "screen", "news": "The gym at 7"}}"#)
        let card = try await client.bringUp(3)
        XCTAssertEqual(card.id, 21)

        XCTAssertEqual(calls.map(\.path), [
            "\(PulseClient.path)/learned/reset", "\(PulseClient.path)/learned/reset",
            "\(PulseClient.path)/left_out", "\(PulseClient.path)/left_out/bring_up"
        ])
        XCTAssertEqual(calls.map(\.method), ["POST", "POST", "GET", "POST"])
        XCTAssertEqual(calls[0].body?["scope"] as? String, "place")
        XCTAssertEqual(calls[0].body?["value"] as? String, "chat::c1")
        // Start over forgets everything.
        XCTAssertEqual(calls[1].body?["scope"] as? String, "everything")
        XCTAssertEqual(calls[1].body?["value"] as? String, "")
        XCTAssertNil(calls[2].body)
        XCTAssertEqual(calls[3].body?["id"] as? Int, 3)

        // An answer without its list or card is no answer.
        answer = try json(#"{"ok": true}"#)
        do {
            _ = try await client.leftOut()
            XCTFail("an answer without left_out")
        } catch {}
        do {
            _ = try await client.bringUp(3)
            XCTFail("an answer without a card")
        } catch {}
    }
}
