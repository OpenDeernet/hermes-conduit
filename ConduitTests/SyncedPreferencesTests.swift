import XCTest
@testable import Conduit

/// Preferences shared through the plugin (#1089). An extension of an
/// existing class so the CI planner gets no new class to place.
extension ChatReadStateTests {
    private final class SyncedBox {
        var values: [String: Any] = [:]
        var holds = false

        func slot(_ key: String, merge: SyncedPreferenceSlot.Merge = .replace) -> SyncedPreferenceSlot {
            SyncedPreferenceSlot(
                key: key,
                read: { self.values[key] },
                write: { self.values[key] = $0 },
                merge: merge,
                canApply: { !self.holds }
            )
        }
    }

    private func syncedDefaults() -> UserDefaults {
        let name = "SyncedPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testSyncedFirstSyncTakesHostValuesAndFillsWhatHostLacks() {
        let box = SyncedBox()
        box.values = ["app.accent": "green", "app.haptics": false]
        let slots = [box.slot("app.accent"), box.slot("app.haptics"), box.slot("app.chat_text_size")]
        let host: [String: Any] = ["app.accent": "violet", "app.chat_text_size": 3]

        let changes = SyncedPreferencesEngine.changes(slots: slots, ledger: nil, host: host, start: .useHost)
        XCTAssertEqual(Set(changes.keys), ["app.haptics"])

        let entry = SyncedPreferencesEngine.apply(host: host.merging(changes) { $1 }, slots: slots,
                                                  uploaded: Set(changes.keys), ledger: nil)
        XCTAssertEqual(box.values["app.accent"] as? String, "violet")
        XCTAssertEqual(box.values["app.chat_text_size"] as? Int, 3)
        XCTAssertEqual(box.values["app.haptics"] as? Bool, false)
        XCTAssertEqual(entry.lastLocal["app.accent"], "\"violet\"")
    }

    func testSyncedUseDeviceUploadsEverythingAndClearsDefaults() {
        let box = SyncedBox()
        box.values = ["app.accent": "green"]
        let slots = [box.slot("app.accent"), box.slot("app.haptics")]
        let changes = SyncedPreferencesEngine.changes(slots: slots, ledger: nil, host: ["app.haptics": false], start: .useDevice)
        XCTAssertEqual(changes["app.accent"] as? String, "green")
        XCTAssertTrue(changes["app.haptics"] is NSNull)
    }

    func testSyncedLaterSyncUploadsOnlyWhatChangedHere() {
        let box = SyncedBox()
        box.values = ["app.accent": "green", "app.haptics": true]
        let slots = [box.slot("app.accent"), box.slot("app.haptics")]
        let ledger = SyncedPreferencesEngine.apply(host: box.values, slots: slots, uploaded: [], ledger: nil)
        XCTAssertTrue(SyncedPreferencesEngine.changes(slots: slots, ledger: ledger, host: nil, start: .useHost).isEmpty)

        box.values["app.haptics"] = false
        box.values["app.accent"] = nil
        let changes = SyncedPreferencesEngine.changes(slots: slots, ledger: ledger, host: nil, start: .useHost)
        XCTAssertEqual(changes["app.haptics"] as? Bool, false)
        XCTAssertTrue(changes["app.accent"] is NSNull)
    }

    func testSyncedHostChangesApplyExceptJustUploadedAndHeldKeys() {
        let box = SyncedBox()
        box.values = ["app.accent": "green", "voice.preferences": ["tone": "calm"]]
        let accent = box.slot("app.accent")
        let voice = box.slot("voice.preferences")
        let ledger = SyncedPreferencesEngine.apply(host: box.values, slots: [accent, voice], uploaded: [], ledger: nil)

        box.holds = true
        let host: [String: Any] = ["app.accent": "violet", "voice.preferences": ["tone": "lively"]]
        let entry = SyncedPreferencesEngine.apply(host: host, slots: [accent, voice], uploaded: ["app.accent"], ledger: ledger)
        XCTAssertEqual(box.values["app.accent"] as? String, "green")
        XCTAssertEqual((box.values["voice.preferences"] as? [String: String])?["tone"], "calm")
        // Held back, not changed here: the next sync tries again, uploads nothing.
        XCTAssertTrue(SyncedPreferencesEngine.changes(slots: [voice], ledger: entry, host: nil, start: .useHost).isEmpty)

        box.holds = false
        SyncedPreferencesEngine.apply(host: host, slots: [voice], uploaded: [], ledger: entry)
        XCTAssertEqual((box.values["voice.preferences"] as? [String: String])?["tone"], "lively")
    }

    func testSyncedHostClearingAKeyGoesBackToTheDefault() {
        let box = SyncedBox()
        box.values = ["app.accent": "green"]
        SyncedPreferencesEngine.apply(host: [:], slots: [box.slot("app.accent")], uploaded: [], ledger: SyncedPreferencesLedgerEntry())
        XCTAssertNil(box.values["app.accent"])
    }

    func testSyncedDashboardsOnlyGrowAndARemovalHereSticks() {
        let box = SyncedBox()
        box.values = ["app.dashboards": ["https://a", "https://b"]]
        let slot = box.slot("app.dashboards", merge: .addOnly)
        var ledger = SyncedPreferencesEngine.apply(host: ["app.dashboards": ["https://a", "https://b"]], slots: [slot],
                                                   uploaded: [], ledger: nil)

        // Another device added c and removed b.
        ledger = SyncedPreferencesEngine.apply(host: ["app.dashboards": ["https://a", "https://c"]], slots: [slot],
                                               uploaded: [], ledger: ledger)
        XCTAssertEqual(box.values["app.dashboards"] as? [String], ["https://a", "https://b", "https://c"])

        // Removed here: the host still listing it doesn't bring it back.
        box.values["app.dashboards"] = ["https://a", "https://c"]
        let changes = SyncedPreferencesEngine.changes(slots: [slot], ledger: ledger, host: nil, start: .useHost)
        XCTAssertEqual(changes["app.dashboards"] as? [String], ["https://a", "https://c"])
        ledger = SyncedPreferencesEngine.apply(host: ["app.dashboards": ["https://a", "https://b", "https://c"]],
                                               slots: [slot], uploaded: [], ledger: ledger)
        XCTAssertEqual(box.values["app.dashboards"] as? [String], ["https://a", "https://c"])
    }

    func testSyncedHostValuesSkipNullsAndMalformedEntries() {
        let response: [String: Any] = ["values": [
            "app.accent": ["value": "violet", "at": 1.0],
            "app.haptics": ["value": NSNull()],
            "app.bad": "not an entry",
        ]]
        let values = SyncedPreferencesEngine.hostValues(response)
        XCTAssertEqual(Set(values.keys), ["app.accent"])
    }

    func testSyncedDefaultsSlotsRoundTripEachKind() {
        let defaults = syncedDefaults()
        defaults.set(true, forKey: "b")
        defaults.set(3, forKey: "i")
        defaults.set(1.25, forKey: "d")
        defaults.set("violet", forKey: "s")
        defaults.set(["one", "two"], forKey: "l")
        defaults.set(try! JSONSerialization.data(withJSONObject: [["title": "Home"]]), forKey: "j")
        let slots: [(SyncedPreferenceSlot.Kind, String)] = [(.bool, "b"), (.int, "i"), (.double, "d"), (.string, "s"), (.strings, "l"), (.json, "j")]
        for (kind, key) in slots {
            let slot = SyncedPreferenceSlot.defaults(key, key, kind, in: defaults)
            let read = slot.read()
            XCTAssertNotNil(read, key)
            // Through JSON, as the host returns it.
            let wire = try! JSONSerialization.jsonObject(
                with: JSONSerialization.data(withJSONObject: ["v": read!]), options: []) as! [String: Any]
            slot.write(wire["v"])
            XCTAssertEqual(SyncedPreferencesEngine.canonical(slot.read()), SyncedPreferencesEngine.canonical(read), key)
            slot.write(nil)
            XCTAssertNil(defaults.object(forKey: key), key)
        }
    }

    @MainActor
    func testSyncedLedgerIsKeptPerScope() {
        let controller = SyncedPreferencesController(defaults: syncedDefaults())
        XCTAssertFalse(controller.isEnabled)
        controller.setLedger(SyncedPreferencesLedgerEntry(lastLocal: ["app.accent": "\"violet\""]), for: "a|default")
        XCTAssertEqual(controller.ledger(for: "a|default")?.lastLocal["app.accent"], "\"violet\"")
        XCTAssertNil(controller.ledger(for: "a|work"))
        XCTAssertTrue(controller.begin())
        XCTAssertFalse(controller.begin())
        XCTAssertTrue(controller.end())
        XCTAssertTrue(controller.begin())
        XCTAssertFalse(controller.end())
    }
}
