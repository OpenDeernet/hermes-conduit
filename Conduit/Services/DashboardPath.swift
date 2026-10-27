import Foundation

enum DashboardPath {
    static func encodedQueryComponent(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: queryComponentAllowedCharacters)
    }

    /// Hermes 0.22.3+ runs a plugin request whose `?profile=` names a
    /// profile other than the one the dashboard started with in that
    /// profile's own plugin host, which carries no WebSockets and none of the
    /// dashboard's state. A plugin that reports `dashboard-profiles` takes
    /// the profile as `?conduit_profile=` on its voice and Watch routes
    /// instead, so they stay in the dashboard: a workaround until Hermes
    /// carries them (#1336).
    static let conduitProfileParameter = "conduit_profile"
    static let dashboardProfilesCapability = "dashboard-profiles"

    static func withProfile(_ path: String, profile: String, parameter: String = "profile") -> String {
        guard profile != "default" else { return path }
        return withExplicitProfile(path, profile: profile, parameter: parameter)
    }

    /// Hermes' `PATCH /api/sessions/{id}` reads the owning profile from the
    /// JSON body, not the `?profile=` query, so a named profile's rename or
    /// archive must carry it there too or the server looks in the default
    /// profile's database and the change silently reverts.
    static func bodyWithProfile(_ body: [String: Any], profile: String) -> [String: Any] {
        guard profile != "default", !profile.isEmpty else { return body }
        var scoped = body
        scoped["profile"] = profile
        return scoped
    }

    static func withExplicitProfile(_ path: String, profile: String, parameter: String = "profile") -> String {
        guard !profile.isEmpty,
              let encoded = encodedQueryComponent(profile) else {
            return path
        }
        return "\(path)\(path.contains("?") ? "&" : "?")\(parameter)=\(encoded)"
    }

    private static let queryComponentAllowedCharacters: CharacterSet = {
        var characters = CharacterSet.alphanumerics
        characters.insert(charactersIn: "-._~")
        return characters
    }()
}
