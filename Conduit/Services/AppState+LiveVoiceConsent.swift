//
//  AppState+LiveVoiceConsent.swift
//  Conduit
//
//  Asks once per provider before Gemini Live, GPT-Live or Grok Live send
//  the user's voice to Google, OpenAI or xAI (#827, App Review 5.1.2(i)).
//  The live controllers check before every call; the call screen asks when
//  the phone shows the call, and the phone's own sheet asks after a CarPlay
//  or Watch call stopped on it.
//

import Foundation

extension AppState {
    /// The mode itself while its provider still needs the user's OK, nil
    /// once a call may connect. A call the phone isn't showing leaves the
    /// question for the phone's consent sheet.
    func requestLiveVoiceConsentIfMissing(_ mode: LiveVoiceModeName) -> LiveVoiceModeName? {
        guard let missing = LiveVoiceProviderConsent.missing(mode) else { return nil }
        if !isLiveVoiceSheetShown(mode) { liveVoiceConsentRequest = missing }
        return missing
    }

    /// The user allowed (or took back) the mode's provider hearing them.
    func setLiveVoiceConsent(_ granted: Bool, for mode: LiveVoiceModeName) {
        objectWillChange.send()
        LiveVoiceProviderConsent.setGranted(granted, for: mode)
        if granted, liveVoiceConsentRequest == mode { liveVoiceConsentRequest = nil }
    }

    func isLiveVoiceSheetShown(_ mode: LiveVoiceModeName) -> Bool {
        switch mode {
        case .geminiLive: return showGeminiLiveSheet
        case .gptLive: return showGPTLiveSheet
        case .grokLive: return showGrokLiveSheet
        case .localLive: return showLocalLiveSheet
        }
    }
}
