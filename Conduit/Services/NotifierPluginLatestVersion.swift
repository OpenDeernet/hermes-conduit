import Foundation

/// The newest Conduit plugin: the version on its repository's main branch,
/// which is what a one-tap update installs. Conduit offers the update
/// whenever the host is below it, so a plugin release reaches users without
/// waiting for a Conduit build. `NotifierPluginStatus.recommendedVersion`
/// stays the floor this build needs when GitHub can't be reached.
enum NotifierPluginLatestVersion {
    static let url = URL(string: "https://raw.githubusercontent.com/\(NotifierPluginStatus.repository)/main/plugin.yaml")!
    static let versionKey = "conduit.notifierPlugin.latestVersion"
    static let checkedKey = "conduit.notifierPlugin.latestVersionCheckedAt"
    /// GitHub is asked at most this often; connects in between use the
    /// saved answer.
    static let interval: TimeInterval = 60 * 60

    static func cached(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: versionKey)
    }

    /// The `version:` line of a plugin.yaml, when it's a dotted number.
    static func version(fromPluginYAML yaml: String) -> String? {
        for line in yaml.split(whereSeparator: \.isNewline) where line.hasPrefix("version:") {
            let value = line.dropFirst("version:".count)
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else {
                return nil
            }
            return trimmed
        }
        return nil
    }

    /// Asks GitHub when the saved answer is older than `interval` and saves
    /// what it says. Nil when it wasn't asked or didn't answer.
    static func refresh(
        defaults: UserDefaults,
        now: Date = Date(),
        fetch: (URL) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(from: $0) }
    ) async -> String? {
        if let checked = defaults.object(forKey: checkedKey) as? Date, now.timeIntervalSince(checked) < interval,
           cached(in: defaults) != nil {
            return nil
        }
        guard let answer = try? await fetch(url),
              (answer.1 as? HTTPURLResponse)?.statusCode == 200,
              let version = version(fromPluginYAML: String(decoding: answer.0, as: UTF8.self)) else { return nil }
        defaults.set(version, forKey: versionKey)
        defaults.set(now, forKey: checkedKey)
        return version
    }
}
