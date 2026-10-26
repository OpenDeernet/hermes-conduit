//
//  RoomChoices.swift
//  Conduit
//
//  An agent's choices for one group room with other people's agents
//  (designs/cross-owner-agents): what it can do, what it may share, past-chat
//  search and a private note. The host's notifier plugin keeps them per
//  profile (room_choices.py) and holds the agent to them (room_rules.py);
//  Group Info reads and changes them.
//

import Foundation

/// What the plugin holds an agent to in one room. How it takes part and its
/// turns a day aren't here: nothing holds an agent to them until the room
/// bridge does.
struct RoomChoices: Equatable {
    /// `talk`, `look`, `data` or `custom`.
    var tools: String
    /// The tools `custom` allows.
    var customTools: [String]
    /// `helps`, `ask` or `nothing`.
    var share: String
    var searchChats: Bool
    var note: String
    /// False while the room has none of its own: these are the agent's
    /// defaults, and the first change saves the room a copy.
    var saved: Bool
}

/// The plugin's `GET`/`PUT /rooms/choices`, each request to the agent's own
/// profile. A refusal (400) carries the plugin's reason.
struct RoomChoicesClient {
    static let capability = "room-rules"
    static let path = "/api/plugins/conduit_push/rooms/choices"
    /// room_choices.MAX_NOTE_CHARS, in code points as the plugin counts.
    static let noteLimit = 1000

    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?) async throws -> [String: Any]

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    func choices(roomID: String, profile: String) async throws -> RoomChoices {
        guard let room = DashboardPath.encodedQueryComponent(roomID) else { throw HermesError.invalidResponse }
        let path = DashboardPath.withProfile("\(Self.path)?room_id=\(room)", profile: profile)
        return try Self.parse(try await request(path, "GET", nil), roomID: roomID)
    }

    /// Changes only the choices `changes` names; the plugin keeps the rest
    /// and answers with all of them.
    func set(_ changes: [String: Any], roomID: String, profile: String) async throws -> RoomChoices {
        let path = DashboardPath.withProfile(Self.path, profile: profile)
        return try Self.parse(try await request(path, "PUT", ["room_id": roomID, "choices": changes]), roomID: roomID)
    }

    /// The note cut to the plugin's limit, which counts code points, after
    /// the last whole character that fits.
    static func clippedNote(_ text: String) -> String {
        guard text.unicodeScalars.count > noteLimit else { return text }
        var scalars = 0
        var end = text.startIndex
        for character in text {
            scalars += character.unicodeScalars.count
            if scalars > noteLimit { break }
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    /// A `PUT`'s answer has no `saved`: once a choice is set, the room has
    /// its own. An answer that isn't `ok`, or names another room, is refused.
    static func parse(_ response: [String: Any], roomID: String) throws -> RoomChoices {
        guard response["ok"] as? Bool == true,
              response["room_id"] == nil || response["room_id"] as? String == roomID,
              let choices = response["choices"] as? [String: Any],
              let tools = choices["tools"] as? String,
              let share = choices["share"] as? String,
              let searchChats = choices["search_chats"] as? Bool
        else { throw HermesError.invalidResponse }
        return RoomChoices(
            tools: tools,
            customTools: choices["custom_tools"] as? [String] ?? [],
            share: share,
            searchChats: searchChats,
            note: choices["note"] as? String ?? "",
            saved: response["saved"] as? Bool ?? true
        )
    }
}

extension AppState {
    /// Whether the host's plugin keeps an agent's room choices and holds it
    /// to them. Not in `usedCapabilities`: an older plugin just doesn't
    /// offer them, with no update notice.
    var canSetRoomChoices: Bool {
        notifierPlugin.reports(RoomChoicesClient.capability)
    }

    /// Requests stay with the dashboard they were made for.
    var roomChoicesClient: RoomChoicesClient {
        let dashboard = activeDashboardID
        return RoomChoicesClient(dashboardID: dashboard) { [weak self] path, method, body in
            guard let self, self.activeDashboardID == dashboard,
                  let bridge = self.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            return try await bridge.requestJSON(path: path, method: method, body: body)
        }
    }
}
