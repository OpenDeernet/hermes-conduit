import XCTest

@testable import Conduit

/// Settings > People (designs/cross-owner-agents, C2a): the Links this
/// installation keeps, its four words, and the host setup for rooms with
/// other people's agents. Notifier 0.83 (`room_links.py`, the links routes)
/// and 0.85 (`room_setup.py`, `/rooms/setup`). An extension, so no new class
/// to plan.
extension GroupChatModelsTests {
    private static let peopleWords = ["amber", "birch", "cedar", "delta"]

    private func peopleLink(
        _ id: String?,
        name: String? = "Mona",
        status: String = "linked",
        words: [String]? = GroupChatModelsTests.peopleWords,
        createdAt: Double? = nil
    ) -> [String: Any] {
        var link: [String: Any] = ["status": status]
        if let id { link["id"] = id }
        if let name { link["name"] = name }
        if let words { link["words"] = words }
        if let createdAt { link["created_at"] = createdAt }
        return link
    }

    private func peopleInvite(_ id: String, name: String = "Eric", expiresAt: Double?) -> [String: Any] {
        var invite: [String: Any] = ["id": id, "name": name]
        if let expiresAt { invite["expires_at"] = expiresAt }
        return invite
    }

    private func peopleList(
        links: [[String: Any]] = [],
        invites: [[String: Any]] = [],
        reading: Bool? = true
    ) -> [String: Any] {
        var answer: [String: Any] = ["ok": true, "links": links, "invites": invites]
        if let reading {
            let mailbox: [String: Any] = ["url": "https://mailbox.example", "reading": reading]
            answer["mailbox"] = mailbox
        }
        return answer
    }

    /// A Hermes that needs everything: notifier 0.85's answer for a named
    /// profile on a host whose API server was never on.
    private func peopleSetupAnswer() -> [String: Any] {
        let server: [String: Any] = [
            "enabled": false, "key_set": false, "profile_key_set": false,
            "address": "127.0.0.1:8642", "running": false, "error": NSNull(),
        ]
        let choices: [[String: Any]] = [
            ["id": "web", "label": "Web search", "description": "Search the web and read pages"],
            ["id": "vision", "label": "Vision", "description": "Look at images"],
            ["id": "x_search", "label": "X search", "description": "Search posts on X"],
        ]
        return [
            "ok": true,
            "ready": false,
            "needs": ["api_server", "ceiling", "plugin_tools", "restart"],
            "changes": ["api_server_key", "profile_key", "ceiling", "plugin_tools"],
            "blockers": [[String: Any]](),
            "profile": "furina",
            "api_server": server,
            "ceiling": ["vision", "web"],
            "choices": choices,
            "approvals": "manual",
            "policy": NSNull(),
        ]
    }

    // MARK: - Links

    @MainActor
    func testRoomLinksListReadsLinksInvitesAndTheMailbox() async throws {
        let client = RoomLinksClient { path, method, body, timeout in
            XCTAssertEqual(path, "/api/plugins/conduit_push/rooms/links")
            XCTAssertEqual(method, "GET")
            XCTAssertNil(body)
            XCTAssertNil(timeout)
            return self.peopleList(links: [
                self.peopleLink("lk1", createdAt: 1_790_000_000),
                self.peopleLink("lk2", name: "Laifu", status: "waiting", words: ["echo", "fable", "grove", "harbor"], createdAt: 1_790_000_100.5),
                // A status a newer plugin adds is kept as it is.
                self.peopleLink("lk3", name: "Kazuha", status: "paused"),
                // What the page can't show is left out: no id, no name, three words.
                self.peopleLink(nil, name: "Venti"),
                self.peopleLink("lk5", name: nil),
                self.peopleLink("lk6", name: "Xiao", words: ["echo", "fable", "grove"]),
            ], invites: [
                self.peopleInvite("inv1", expiresAt: 1_790_086_400),
                self.peopleInvite("inv2", expiresAt: nil),
            ])
        }
        let list = try await client.list()
        XCTAssertEqual(list.links, [
            RoomLink(id: "lk1", name: "Mona", status: "linked", words: Self.peopleWords,
                     createdAt: Date(timeIntervalSince1970: 1_790_000_000)),
            RoomLink(id: "lk2", name: "Laifu", status: "waiting", words: ["echo", "fable", "grove", "harbor"],
                     createdAt: Date(timeIntervalSince1970: 1_790_000_100.5)),
            RoomLink(id: "lk3", name: "Kazuha", status: "paused", words: Self.peopleWords, createdAt: nil),
        ])
        XCTAssertEqual(list.invites, [
            RoomLinkInvite(id: "inv1", name: "Eric", expiresAt: Date(timeIntervalSince1970: 1_790_086_400)),
        ])
        XCTAssertTrue(list.mailboxReading)

        // Nothing reading the mailbox, or no mailbox in the answer, reads as
        // not reading.
        XCTAssertFalse(try RoomLinksClient.parseList(peopleList(reading: false)).mailboxReading)
        XCTAssertEqual(try RoomLinksClient.parseList(peopleList(reading: nil)), RoomLinksList(links: [], invites: [], mailboxReading: false))
    }

    @MainActor
    func testRoomLinksRoutesTakeNoProfileAndMailboxCallsWaitLonger() async throws {
        var asked: [(path: String, method: String, timeout: Int?)] = []
        let client = RoomLinksClient { path, method, body, timeout in
            XCTAssertNil(body)
            asked.append((path, method, timeout))
            if path.hasSuffix("/identity") { return ["ok": true, "crypto": true, "words": NSNull()] }
            if path.contains("invite_id=") { return ["ok": true, "cancelled": true] }
            if method == "DELETE" { return ["ok": true, "removed": false] }
            return self.peopleList()
        }
        _ = try await client.identity()
        _ = try await client.list()
        let removed = try await client.unlink("lk 1&x")
        let cancelled = try await client.cancel(inviteID: "inv/1")
        // Already gone reads as false, not as a failure.
        XCTAssertFalse(removed)
        XCTAssertTrue(cancelled)
        XCTAssertEqual(asked.map(\.path), [
            "/api/plugins/conduit_push/rooms/identity",
            "/api/plugins/conduit_push/rooms/links",
            "/api/plugins/conduit_push/rooms/links?link_id=lk%201%26x",
            "/api/plugins/conduit_push/rooms/links/invites?invite_id=inv%2F1",
        ])
        XCTAssertEqual(asked.map(\.method), ["GET", "GET", "DELETE", "DELETE"])
        // Unlink and cancel wait on the rooms mailbox, past the plugin's own
        // 50 s; the reads keep the dashboard request's 12 s.
        XCTAssertEqual(asked.map(\.timeout), [nil, nil, 55_000, 55_000])
        XCTAssertEqual(RoomLinksClient.mailboxTimeoutMilliseconds, 55_000)
        // Links are the installation's: no route names a profile.
        XCTAssertFalse(asked.contains { $0.path.contains("profile=") })
    }

    func testRoomLinksRefusalsShowThePluginsWords() {
        // The plugin's answers for the rooms mailbox, in its own words.
        let timedOut = "The rooms mailbox didn't answer in time; look at the Links again in a minute"
        XCTAssertEqual(RoomLinksClient.message(for: DashboardTicketBridgeError.http(status: 504, detail: timedOut)), timedOut)
        let kept = "The mailbox is busy. This Hermes keeps the accept and tries it again while the invite lasts"
        XCTAssertEqual(RoomLinksClient.message(for: DashboardTicketBridgeError.http(status: 503, detail: "  \(kept)\n")), kept)
        let refused = "The rooms mailbox refused it (bad_url)"
        XCTAssertEqual(RoomLinksClient.message(for: DashboardTicketBridgeError.http(status: 502, detail: refused)), refused)
        // A 409 keeps them as every dashboard refusal does.
        let linked = "This Hermes is already linked with Mona; unlink first to link again"
        XCTAssertEqual(RoomLinksClient.message(for: DashboardTicketBridgeError.http(status: 409, detail: linked)), linked)

        // Without words of its own, a 502 is still the dashboard not reaching
        // Hermes, as everywhere else.
        for detail in ["Bad Gateway", "", AppLocalization.string("Dashboard request failed (\(String(502))).")] {
            let error = DashboardTicketBridgeError.http(status: 502, detail: detail)
            XCTAssertEqual(RoomLinksClient.message(for: error), UserFacingError.message(for: error))
            XCTAssertNil(DashboardTicketBridgeError.meaningfulDetail(detail, status: 502))
        }
        XCTAssertEqual(RoomLinksClient.message(for: HermesError.invalidResponse), UserFacingError.message(for: HermesError.invalidResponse))
    }

    func testRoomIdentityReadsWordsAndCrypto() throws {
        let words = Self.peopleWords
        XCTAssertEqual(try RoomLinksClient.parseIdentity(["ok": true, "crypto": true, "words": words]),
                       RoomIdentity(words: words, crypto: true))
        // Before the first invite or accept made the keys.
        XCTAssertEqual(try RoomLinksClient.parseIdentity(["ok": true, "crypto": true, "words": NSNull()]),
                       RoomIdentity(words: nil, crypto: true))
        // A Hermes without Python's cryptography package.
        XCTAssertEqual(try RoomLinksClient.parseIdentity(["ok": true, "crypto": false]),
                       RoomIdentity(words: nil, crypto: false))
        // Anything but four words is none.
        XCTAssertNil(try RoomLinksClient.parseIdentity(["ok": true, "crypto": true, "words": ["amber", "birch", "cedar"]]).words)
        XCTAssertThrowsError(try RoomLinksClient.parseIdentity(["ok": true, "words": words]))
    }

    func testALinksStatusSaysWhatToDo() {
        let mona = RoomLink(id: "lk1", name: "Mona", status: "linked", words: Self.peopleWords, createdAt: nil)
        XCTAssertEqual(PeopleSettingsText.status(of: mona), AppLocalization.string("Linked"))
        let waiting = RoomLink(id: "lk2", name: "Laifu", status: "waiting", words: Self.peopleWords, createdAt: nil)
        XCTAssertEqual(PeopleSettingsText.status(of: waiting), AppLocalization.string("Waiting for \("Laifu")'s Hermes to confirm"))
        let unanswered = RoomLink(id: "lk3", name: "Kazuha", status: "unanswered", words: Self.peopleWords, createdAt: nil)
        XCTAssertEqual(PeopleSettingsText.status(of: unanswered),
                       AppLocalization.string("\("Kazuha")'s Hermes never confirmed. Ask them for a new invite."))
        // A status this build doesn't know shows none.
        let paused = RoomLink(id: "lk4", name: "Venti", status: "paused", words: Self.peopleWords, createdAt: nil)
        XCTAssertNil(PeopleSettingsText.status(of: paused))
        XCTAssertEqual(PeopleSettingsText.words(Self.peopleWords), "amber · birch · cedar · delta")
    }

    // MARK: - Host setup

    func testRoomSetupStateReadsWhatThePageShows() throws {
        let state = try RoomSetupClient.parseState(peopleSetupAnswer())
        XCTAssertFalse(state.ready)
        XCTAssertEqual(state.needs, ["api_server", "ceiling", "plugin_tools", "restart"])
        XCTAssertEqual(state.changes, ["api_server_key", "profile_key", "ceiling", "plugin_tools"])
        XCTAssertEqual(state.blockers, [])
        XCTAssertEqual(state.profile, "furina")
        XCTAssertEqual(state.apiServer, RoomSetupState.APIServer(
            enabled: false, keySet: false, profileKeySet: false, address: "127.0.0.1:8642", running: false, error: nil
        ))
        XCTAssertEqual(state.ceiling, ["vision", "web"])
        XCTAssertEqual(state.choices.map(\.id), ["web", "vision", "x_search"])
        XCTAssertEqual(state.label(of: "web"), "Web search")
        // A toolset Hermes gave no choice for shows by its id.
        XCTAssertEqual(state.label(of: "browser"), "browser")
        XCTAssertEqual(state.approvals, "manual")

        // Blockers carry the plugin's words; one without them is left out.
        // An API server's error is trimmed, and a blank one is none.
        var blocked = peopleSetupAnswer()
        let blockers: [[String: Any]] = [
            ["code": "yolo", "message": "HERMES_YOLO_MODE is on for this Hermes, which turns approvals off"],
            ["code": "managed"],
        ]
        blocked["blockers"] = blockers
        var server = blocked["api_server"] as? [String: Any] ?? [:]
        server["error"] = "  port 8642 is taken \n"
        blocked["api_server"] = server
        let read = try RoomSetupClient.parseState(blocked)
        XCTAssertEqual(read.blockers, [RoomSetupState.Blocker(
            code: "yolo", message: "HERMES_YOLO_MODE is on for this Hermes, which turns approvals off"
        )])
        XCTAssertEqual(read.apiServer.error, "port 8642 is taken")
        server["error"] = "   "
        blocked["api_server"] = server
        XCTAssertNil(try RoomSetupClient.parseState(blocked).apiServer.error)
    }

    @MainActor
    func testRoomSetupPostsTheCeilingAndInterruptToTheProfile() async throws {
        var asked: [(path: String, method: String, body: [String: Any]?)] = []
        let client = RoomSetupClient { path, method, body in
            asked.append((path, method, body))
            return self.peopleSetupAnswer()
        }
        _ = try await client.state(profile: "furina")
        _ = try await client.setUp(profile: "furina", ceiling: ["web", "vision"])
        _ = try await client.setUp(profile: "default", ceiling: [], interrupt: true)
        _ = try await client.setUp(profile: "furina", ceiling: nil)
        XCTAssertEqual(asked.map(\.path), [
            "/api/plugins/conduit_push/rooms/setup?profile=furina",
            "/api/plugins/conduit_push/rooms/setup?profile=furina",
            // The default profile asks the bare path, as every profile route.
            "/api/plugins/conduit_push/rooms/setup",
            "/api/plugins/conduit_push/rooms/setup?profile=furina",
        ])
        XCTAssertEqual(asked.map(\.method), ["GET", "POST", "POST", "POST"])
        XCTAssertNil(asked[0].body)
        XCTAssertEqual(asked[1].body?["ceiling"] as? [String], ["web", "vision"])
        XCTAssertEqual(asked[1].body?["interrupt"] as? Bool, false)
        // No tools at all is a ceiling too: the agent only talks.
        XCTAssertEqual(asked[2].body?["ceiling"] as? [String], [])
        XCTAssertEqual(asked[2].body?["interrupt"] as? Bool, true)
        // None keeps the one the profile has.
        XCTAssertNotNil(asked[3].body)
        XCTAssertNil(asked[3].body?["ceiling"])
        XCTAssertEqual(asked[3].body?["interrupt"] as? Bool, false)
    }

    func testSetUpPostsTheToolsPickedOnlyWhenTheyChange() throws {
        // A saved ceiling can name a toolset Hermes no longer has, which a
        // POST naming it is refused for.
        var answer = peopleSetupAnswer()
        answer["ceiling"] = ["browser", "web"]
        let state = try RoomSetupClient.parseState(answer)
        XCTAssertNil(state.ceilingToSave(picking: ["web", "browser"]))
        // Otherwise the tools picked that the plugin lists, in its order.
        XCTAssertEqual(state.ceilingToSave(picking: ["x_search", "web", "browser"]), ["web", "x_search"])
        XCTAssertEqual(state.ceilingToSave(picking: ["browser"]), [])
        XCTAssertEqual(state.ceilingToSave(picking: []), [])
    }

    func testSetUpAsksFirstWhenItChangesACeilingTheSetupSaved() throws {
        // A first setup saves a ceiling whatever is picked.
        let first = try RoomSetupClient.parseState(peopleSetupAnswer())
        XCTAssertFalse(first.changesSavedCeiling(picking: ["web"]))
        XCTAssertFalse(first.changesSavedCeiling(picking: ["vision", "web"]))

        // Once the setup saved one, other tools change it: from Ready, and
        // from Set up when something else needs doing again.
        var answer = peopleSetupAnswer()
        answer["ready"] = true
        answer["needs"] = [String]()
        answer["changes"] = [String]()
        let ready = try RoomSetupClient.parseState(answer)
        XCTAssertTrue(ready.changesSavedCeiling(picking: ["web"]))
        XCTAssertTrue(ready.changesSavedCeiling(picking: ["vision", "web", "x_search"]))
        XCTAssertFalse(ready.changesSavedCeiling(picking: ["web", "vision"]))
        answer["ready"] = false
        answer["needs"] = ["approvals"]
        answer["changes"] = ["approvals"]
        let again = try RoomSetupClient.parseState(answer)
        XCTAssertTrue(again.changesSavedCeiling(picking: []))
        XCTAssertFalse(again.changesSavedCeiling(picking: ["vision", "web"]))
    }

    @MainActor
    func testRoomSetupResultReadsTheRestart() async throws {
        var answer = peopleSetupAnswer()
        answer["changed"] = ["api_server_key", "ceiling"]
        let busy: [String: Any] = ["started": false, "busy": true, "error": "  2 chats are running on this gateway. \n"]
        answer["restart"] = busy
        let client = RoomSetupClient { _, _, _ in answer }

        let waits = try await client.setUp(profile: "furina", ceiling: ["web"])
        XCTAssertEqual(waits.changed, ["api_server_key", "ceiling"])
        XCTAssertEqual(waits.restart, RoomSetupResult.Restart(started: false, busy: true, error: "2 chats are running on this gateway."))
        XCTAssertEqual(waits.state.profile, "furina")

        let started: [String: Any] = ["started": true, "busy": false, "error": NSNull()]
        answer["restart"] = started
        let restarts = try await client.setUp(profile: "furina", ceiling: ["web"], interrupt: true)
        XCTAssertEqual(restarts.restart, RoomSetupResult.Restart(started: true, busy: false, error: nil))

        // The API server already ran: no restart, and nothing was changed.
        answer.removeValue(forKey: "restart")
        answer.removeValue(forKey: "changed")
        let quiet = try await client.setUp(profile: "furina", ceiling: ["web"])
        XCTAssertNil(quiet.restart)
        XCTAssertEqual(quiet.changed, [])
    }

    func testSetUpSaysWhatItChanges() throws {
        let state = try RoomSetupClient.parseState(peopleSetupAnswer())
        XCTAssertEqual(PeopleSettingsText.setupLines(state, profileName: "Furina"), [
            AppLocalization.string("Turn on Hermes' API server at \("127.0.0.1:8642"), with a new key that stays on your Hermes"),
            AppLocalization.string("Give \("Furina") its own key for the API server, which serves a profile's agent only with that profile's key"),
            AppLocalization.string("Save the tools rooms may let \("Furina") use"),
            AppLocalization.string("Keep tools that plugins and Hermes updates add out of rooms until you add them here"),
            AppLocalization.string("Restart the gateway, which starts the API server"),
        ])

        // A key it has, a port that moved, approvals that were off, and an
        // API server already running.
        var answer = peopleSetupAnswer()
        answer["changes"] = ["api_server_port", "approvals"]
        answer["needs"] = ["api_server", "approvals"]
        let other = try RoomSetupClient.parseState(answer)
        XCTAssertEqual(PeopleSettingsText.setupLines(other, profileName: "Furina"), [
            AppLocalization.string("Turn on Hermes' API server at \("127.0.0.1:8642"), with the key it has"),
            AppLocalization.string("Turn \("Furina")'s approvals back on, since rooms refuse an agent that runs tools without asking"),
        ])

        XCTAssertEqual(PeopleSettingsText.tools(state, profileName: "Furina"), AppLocalization.string(
            "Rooms may let \("Furina") use \(["Vision", "Web search"].formatted(.list(type: .and).locale(AppLocalization.formattingLocale)))."
        ))
        answer["ceiling"] = [String]()
        XCTAssertEqual(PeopleSettingsText.tools(try RoomSetupClient.parseState(answer), profileName: "Furina"),
                       AppLocalization.string("Rooms can't let \("Furina") use tools: it only talks there."))
    }

    // MARK: - Refusals

    @MainActor
    func testRoomLinksAndSetupRefuseAnAnswerThatIsntOk() async throws {
        var list = peopleList()
        list.removeValue(forKey: "ok")
        XCTAssertThrowsError(try RoomLinksClient.parseList(list))
        list["ok"] = false
        XCTAssertThrowsError(try RoomLinksClient.parseList(list))
        list["ok"] = true
        XCTAssertNoThrow(try RoomLinksClient.parseList(list))
        // Without what the page shows.
        list.removeValue(forKey: "invites")
        XCTAssertThrowsError(try RoomLinksClient.parseList(list))
        XCTAssertThrowsError(try RoomLinksClient.parseIdentity(["ok": false, "crypto": true]))

        var setup = peopleSetupAnswer()
        setup["ok"] = false
        XCTAssertThrowsError(try RoomSetupClient.parseState(setup))
        setup["ok"] = true
        setup.removeValue(forKey: "api_server")
        XCTAssertThrowsError(try RoomSetupClient.parseState(setup))
        var unready = peopleSetupAnswer()
        unready.removeValue(forKey: "ready")
        XCTAssertThrowsError(try RoomSetupClient.parseState(unready))

        // An unlink or a cancel whose answer doesn't say how it went isn't
        // read as done.
        let vague = RoomLinksClient { _, _, _, _ in ["ok": true] }
        do {
            _ = try await vague.unlink("lk1")
            XCTFail("An unlink without removed read as done")
        } catch HermesError.invalidResponse {}
        do {
            _ = try await vague.cancel(inviteID: "inv1")
            XCTFail("A cancel without cancelled read as done")
        } catch HermesError.invalidResponse {}
        let refused = RoomSetupClient { _, _, _ in ["ok": false] }
        do {
            _ = try await refused.setUp(profile: "furina", ceiling: ["web"])
            XCTFail("A setup that wasn't ok read as saved")
        } catch HermesError.invalidResponse {}
    }
}
