import Foundation

/// Hermes' Tool Search bridge. With Tool Search on, plugin and MCP tools
/// (every `conduit_*` tool among them) are deferred: the model calls the
/// `tool_call` wrapper, which runs the real tool. Saved history keeps the
/// wrapper's name and envelope on the call and the real tool's name on its
/// result, while live events already name the real tool. Conduit shows the
/// real tool either way, so its cards, icons and result views still apply.
/// Only what Conduit displays changes: saved rows are never rewritten.
enum ToolSearchBridge {
    static let callName = "tool_call"

    /// The bridge's own tools, which `tool_call` can never run.
    private static let bridgeNames: Set<String> = ["tool_call", "tool_search", "tool_describe"]

    /// Connector tools run as one batch that keeps the wrapper's name.
    private static let connectorPrefix = "connectors__"

    static func isWrapper(_ name: String?) -> Bool {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == callName
    }

    /// A tool's own name: not empty and not one of the bridge's.
    static func isConcrete(_ name: String?) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return false
        }
        return !bridgeNames.contains(name.lowercased())
    }

    struct Call: Equatable {
        let name: String
        /// The tool's own arguments as JSON, nil when it took none.
        let arguments: String?
    }

    /// The one tool a `tool_call` envelope runs, as Hermes resolves it:
    /// `{"calls": [{name, arguments}]}` or the legacy `{name, arguments}`,
    /// either level possibly a JSON string. Nil for a batch, a connector
    /// call (Hermes keeps the wrapper for those) or a malformed envelope.
    static func underlyingCall(_ envelope: Any?) -> Call? {
        guard let object = jsonObject(envelope) as? [String: Any] else { return nil }
        let entry: [String: Any]
        if let calls = object["calls"], !(calls is NSNull) {
            switch jsonObject(calls) {
            case let list as [Any]:
                guard list.count == 1, let only = list[0] as? [String: Any] else { return nil }
                entry = only
            case let only as [String: Any]:
                entry = only
            default:
                return nil
            }
        } else {
            entry = object
        }
        guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isConcrete(name), !name.hasPrefix(connectorPrefix) else { return nil }
        return Call(name: name, arguments: argumentsText(entry["arguments"]))
    }

    private static func argumentsText(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        case let object as [String: Any]:
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    /// A value as parsed JSON: strings holding JSON are decoded once.
    private static func jsonObject(_ value: Any?) -> Any? {
        guard let text = value as? String else { return value }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
