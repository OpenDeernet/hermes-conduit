//
//  RoomLinks.swift
//  Conduit
//
//  Settings > People (designs/cross-owner-agents, C2): the Links between
//  this Hermes and other people's, which let two people bring their agents
//  into rooms together, and the invites that make them. The host's notifier
//  plugin keeps them for the whole installation (room_links.py) and talks to
//  the other side through the rooms mailbox. A Link grants nothing by
//  itself: what an agent may do is chosen for each room.
//

import Foundation

/// A Link as the plugin shows it: who's on the other side, whether their
/// Hermes has confirmed it, and their four fingerprint words.
struct RoomLink: Identifiable, Equatable {
    let id: String
    let name: String
    /// `waiting` (for the other side's Hermes to confirm it), `linked`, or
    /// `unanswered` (no confirmation came in time: link again). A status a
    /// newer plugin adds is kept as it is and shown with none.
    let status: String
    let words: [String]
    let createdAt: Date?
}

/// An invite this Hermes made that hasn't been used or run out.
struct RoomLinkInvite: Identifiable, Equatable {
    let id: String
    /// Who the invite says it's from, as the person opening it sees.
    let name: String
    let expiresAt: Date
}

struct RoomLinksList: Equatable {
    var links: [RoomLink]
    var invites: [RoomLinkInvite]
    /// False while nothing on the host reads the rooms mailbox. It reads
    /// only while there's an invite or a Link.
    var mailboxReading: Bool
}

/// This installation's four fingerprint words, which the other person's
/// Conduit shows when they open one of its invites.
struct RoomIdentity: Equatable {
    /// Nil before the host's first invite or accept made its keys.
    let words: [String]?
    /// False on a Hermes without Python's cryptography package, which
    /// can't make the keys a Link needs.
    let crypto: Bool
}

/// The plugin's links routes. They take no profile: Links are the
/// installation's. Unlinking and cancelling wait on the rooms mailbox,
/// which the plugin gives up to 50 seconds.
struct RoomLinksClient {
    static let capability = "room-links"
    static let path = "/api/plugins/conduit_push/rooms"
    /// Past the plugin's own 50 s for a call that waits on the mailbox.
    static let mailboxTimeoutMilliseconds = 55_000

    /// `timeoutMilliseconds` nil keeps the dashboard request's own.
    typealias Request = @MainActor (_ path: String, _ method: String, _ body: [String: Any]?, _ timeoutMilliseconds: Int?) async throws -> [String: Any]

    /// The dashboard the requests go to (nil in tests).
    var dashboardID: UUID?
    let request: Request

    init(dashboardID: UUID? = nil, request: @escaping Request) {
        self.dashboardID = dashboardID
        self.request = request
    }

    func identity() async throws -> RoomIdentity {
        try Self.parseIdentity(try await request("\(Self.path)/identity", "GET", nil, nil))
    }

    func list() async throws -> RoomLinksList {
        try Self.parseList(try await request("\(Self.path)/links", "GET", nil, nil))
    }

    /// False when the plugin had no such Link (already gone).
    func unlink(_ linkID: String) async throws -> Bool {
        guard let link = DashboardPath.encodedQueryComponent(linkID) else { throw HermesError.invalidResponse }
        let response = try await request("\(Self.path)/links?link_id=\(link)", "DELETE", nil, Self.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true, let removed = response["removed"] as? Bool else {
            throw HermesError.invalidResponse
        }
        return removed
    }

    /// False when the invite was already used, cancelled or run out.
    func cancel(inviteID: String) async throws -> Bool {
        guard let invite = DashboardPath.encodedQueryComponent(inviteID) else { throw HermesError.invalidResponse }
        let response = try await request("\(Self.path)/links/invites?invite_id=\(invite)", "DELETE", nil, Self.mailboxTimeoutMilliseconds)
        guard response["ok"] as? Bool == true, let cancelled = response["cancelled"] as? Bool else {
            throw HermesError.invalidResponse
        }
        return cancelled
    }

    static func parseIdentity(_ response: [String: Any]) throws -> RoomIdentity {
        guard response["ok"] as? Bool == true, let crypto = response["crypto"] as? Bool else {
            throw HermesError.invalidResponse
        }
        return RoomIdentity(words: words(response["words"]), crypto: crypto)
    }

    /// A Link or an invite the page can't show (no id, name or words) is
    /// left out rather than refusing the whole list.
    static func parseList(_ response: [String: Any]) throws -> RoomLinksList {
        guard response["ok"] as? Bool == true,
              let links = response["links"] as? [[String: Any]],
              let invites = response["invites"] as? [[String: Any]] else { throw HermesError.invalidResponse }
        let mailbox = response["mailbox"] as? [String: Any]
        return RoomLinksList(
            links: links.compactMap(link),
            invites: invites.compactMap(invite),
            mailboxReading: mailbox?["reading"] as? Bool ?? false
        )
    }

    static func link(_ object: [String: Any]) -> RoomLink? {
        guard let id = object["id"] as? String, !id.isEmpty,
              let name = object["name"] as? String,
              let status = object["status"] as? String,
              let words = words(object["words"]) else { return nil }
        return RoomLink(id: id, name: name, status: status, words: words, createdAt: date(object["created_at"]))
    }

    static func invite(_ object: [String: Any]) -> RoomLinkInvite? {
        guard let id = object["id"] as? String, !id.isEmpty,
              let name = object["name"] as? String,
              let expiresAt = date(object["expires_at"]) else { return nil }
        return RoomLinkInvite(id: id, name: name, expiresAt: expiresAt)
    }

    /// Four words, or nil.
    static func words(_ value: Any?) -> [String]? {
        guard let words = value as? [String], words.count == 4 else { return nil }
        return words
    }

    /// Unix seconds, as the plugin writes times.
    static func date(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// What a failed links or setup request says: the plugin's own words,
    /// as the bridge keeps them for a 400 or a 409. A 502, 503 or 504 the
    /// plugin answered (in JSON, with words of its own) is the rooms
    /// mailbox's answer or a call it gave up on, not a dashboard that
    /// couldn't reach Hermes, so its words are kept too.
    static func message(for error: Error) -> String {
        if case DashboardTicketBridgeError.http(let status, let detail) = error, (502...504).contains(status),
           let words = DashboardTicketBridgeError.meaningfulDetail(detail, status: status) {
            return words
        }
        return UserFacingError.message(for: error)
    }
}

extension AppState {
    /// Whether the host's plugin keeps Links. Not in `usedCapabilities`: an
    /// older plugin just doesn't offer Settings > People, with no update
    /// notice.
    var canLinkRooms: Bool {
        notifierPlugin.reports(RoomLinksClient.capability)
    }

    /// Requests stay with the dashboard they were made for.
    var roomLinksClient: RoomLinksClient {
        let dashboard = activeDashboardID
        return RoomLinksClient(dashboardID: dashboard) { [weak self] path, method, body, timeout in
            guard let self, self.activeDashboardID == dashboard,
                  let bridge = self.dashboardTicketBridge else { throw DashboardTicketBridgeError.notReady }
            if let timeout {
                return try await bridge.requestJSON(path: path, method: method, body: body, timeoutMilliseconds: timeout)
            }
            return try await bridge.requestJSON(path: path, method: method, body: body)
        }
    }
}
