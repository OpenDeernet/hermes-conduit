//
//  AppState+PresentedScreens.swift
//  Conduit
//
//  When Conduit exchanges confirmations with the host (on connect, coming
//  to the foreground, a push, after an answer), how an answer by tap is
//  recorded, and the live call's voice tool for them.
//  (PresentedScreens.swift, designs/v2-phase4-presented-screens.md)
//

import Combine
import CoreLocation
import Foundation
import UIKit

extension AppState {
    /// Exchanges when the host's plugin serves it; silent otherwise.
    func syncPresentedScreens() async {
        guard notifierPlugin.reports(PresentedScreensSync.capability),
              let scope = agentSettingsScope,
              let bridge = dashboardTicketBridge else { return }
        let profile = activeProfile
        await presentedScreens.sync(
            scope: scope, profile: profile, installationID: agentSettings.installationID,
            isCurrent: { [weak self] in bridge === self?.dashboardTicketBridge && profile == self?.activeProfile }
        ) { [weak self] path, body in
            guard let self, bridge === self.dashboardTicketBridge, profile == self.activeProfile else {
                throw DashboardTicketBridgeError.notReady
            }
            return try await bridge.requestJSON(path: path, method: "POST", body: body)
        }
        await openExpectedPresentedMaps()
    }

    /// Hermes was seen asking to open Apple Maps (`conduit_maps` navigate)
    /// in the chat on screen: that Go confirmation opens Maps without a tap.
    func noteMapsNavigateExpected(_ promptID: String) {
        mapsNavigateExpected = (promptID, Date().addingTimeInterval(120))
        // Stored before the tool returned: fetch it now.
        Task { [weak self] in await self?.syncPresentedScreens() }
    }

    /// The Go confirmation a `conduit_maps` result sent, read from the
    /// tool's JSON answer: only a navigate that was sent.
    nonisolated static func mapsNavigatePromptID(_ output: String?) -> String? {
        guard let data = output?.data(using: .utf8),
              let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              answer["action"] as? String == "navigate", answer["status"] as? String == "sent",
              let promptID = answer["prompt_id"] as? String, !promptID.isEmpty else { return nil }
        return promptID
    }

    /// A Go confirmation for the chat the user is in, with Conduit in front,
    /// opens Apple Maps at once; anywhere else it waits for a tap or a
    /// spoken go.
    private func openExpectedPresentedMaps() async {
        guard UIApplication.shared.applicationState == .active else { return }
        let expected = mapsNavigateExpected.flatMap { $0.until > Date() ? $0.promptID : nil }
        guard let prompt = presentedScreens.prompts.last(where: { prompt in
            prompt.maps != nil && !prompt.isExpired()
                && (prompt.id == expected || (prompt.sessionID != nil && prompt.sessionID == activeSessionId))
        }) else { return }
        if prompt.id == expected { mapsNavigateExpected = nil }
        presentedScreens.answer(prompt, outcome: .confirmed, via: .auto)
        // Answered once: never opened again by the sync below.
        guard !presentedScreens.prompts.contains(where: { $0.id == prompt.id }) else { return }
        await openPresentedMaps(prompt)
        await syncPresentedScreens()
    }

    /// Opens Apple Maps for a confirmed Go confirmation.
    func openPresentedMaps(_ prompt: PresentedConfirm) async {
        guard let target = prompt.maps else { return }
        let location = LocationSharingController.shared
        // On this phone only: saved places and where the user is help MapKit
        // find "the nearest Boots", as in Apple Maps itself.
        let places = location.places
        guard let place = MapsVoiceTool.ref(target.to, places: places), place != .me else { return }
        let hint = await location.fixes.currentFix(accuracy: kCLLocationAccuracyKilometer, maxAge: 600, timeout: .seconds(2))
        let outcome = await MapsNavigator.open(place, mode: target.mode, places: places, near: hint?.coordinate)
        if case .failed = outcome {
            errorMessage = AppLocalization.string("Couldn't find that place in Apple Maps.")
        }
    }

    /// The user's answer; reported to the host right away.
    func answerPresentedConfirm(_ prompt: PresentedConfirm, outcome: PresentedConfirmOutcome,
                                via source: PresentedConfirmAnswerSource) async {
        presentedScreens.answer(prompt, outcome: outcome, via: source)
        if outcome == .confirmed { await openPresentedMaps(prompt) }
        await syncPresentedScreens()
    }

    /// Edit: Hermes hears the user wants changes, and the chat it came from
    /// opens with the preview in the composer to rework and send.
    func editPresentedConfirm(_ prompt: PresentedConfirm) async {
        presentedScreens.answer(prompt, outcome: .edit, via: .tap)
        Task { await syncPresentedScreens() }
        if let session = prompt.sessionID {
            dismissSidebarDrawer()
            guard await openSession(session) else {
                // Hermes already knows; say why the draft didn't appear.
                if errorMessage == nil {
                    errorMessage = AppLocalization.string("Couldn't open the chat to edit it. Hermes knows you want changes.")
                }
                return
            }
        }
        prefillComposer(Self.plainText(fromMarkdown: prompt.preview))
    }

    private static func plainText(fromMarkdown markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: markdown, options: options) else { return markdown }
        return String(attributed.characters)
    }

    /// The user's last turn in the running live call.
    func liveCallLastUserTurn() -> (id: UUID?, text: String) {
        let transcript: [VoiceConversationTranscriptEntry]
        if isGeminiLiveActive {
            transcript = geminiLiveController.transcript
        } else if isGrokLiveActive {
            transcript = grokLiveController.transcript
        } else if isGPTLiveActive {
            transcript = gptLiveController.transcript
        } else {
            return (nil, "")
        }
        let turn = transcript.last(where: { $0.speaker == .user })
        return (turn?.id, turn?.text ?? "")
    }

    /// The live call's confirmation tool, when the host serves them.
    var presentVoiceTools: [VoiceHostTool] {
        notifierPlugin.reports(PresentedScreensSync.capability) ? [PresentVoiceTool.tool] : []
    }

    func callPresentVoiceTool(_ arguments: [String: Any]) async -> [String: String] {
        await PresentVoiceTool.run(
            arguments, sync: presentedScreens,
            lastUserTurn: { [weak self] in self?.liveCallLastUserTurn() ?? (nil, "") }
        ) { prompt, outcome in
            presentedScreens.answer(prompt, outcome: outcome, via: .voice)
            // Reported in the background: the call hears the outcome now.
            Task {
                if outcome == .confirmed { await self.openPresentedMaps(prompt) }
                await self.syncPresentedScreens()
            }
        }
    }

    /// Tells the running call about each confirmation that arrives while it
    /// runs, so the user can answer it out loud.
    func watchPresentedConfirms(for mode: LiveVoiceModeName) -> AnyCancellable {
        var known = Set(presentedScreens.prompts.map(\.id))
        let turnAtStart = liveCallLastUserTurn().id
        for id in known { presentedScreens.noteShown(id, userTurn: turnAtStart) }
        return presentedScreens.$prompts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] prompts in
                guard let self else { return }
                let supervisor = self.voiceBackgroundJobSupervisor
                let fresh = prompts.filter { !known.contains($0.id) }
                known = Set(prompts.map(\.id))
                let turn = self.liveCallLastUserTurn().id
                for prompt in fresh { self.presentedScreens.noteShown(prompt.id, userTurn: turn) }
                guard !fresh.isEmpty, supervisor.hostToolsMode == mode,
                      self.isGeminiLiveActive || self.isGPTLiveActive || self.isGrokLiveActive else { return }
                for prompt in fresh { supervisor.notePhoneChange(PresentVoiceTool.note(for: prompt)) }
            }
    }
}
