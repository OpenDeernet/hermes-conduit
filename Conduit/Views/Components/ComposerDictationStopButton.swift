import SwiftUI

/// Send's place while a dictation runs (#1309): a wide Stop, so the words
/// land in the draft to be looked over before anything goes. Send comes
/// back once they're in. Both composers and the full editor show it.
struct ComposerDictationStopButton: View {
    @ObservedObject var dictation: ComposerDictationService
    var identifier = "composer.dictation.stop"

    var body: some View {
        let face = ComposerDictation.slotFace(
            isCapturing: dictation.isCapturing,
            isStarting: dictation.isStarting
        )
        let waits = face == .settling
        Button {
            switch ComposerDictation.tap(
                isCapturing: dictation.isCapturing,
                isStarting: dictation.isStarting,
                canDictate: false,
                isTranscribing: dictation.isTranscribing
            ) {
            case .stop: dictation.stop()
            case .cancelStart: dictation.cancel()
            case .start, .nothing: break
            }
        } label: {
            HStack(spacing: 6) {
                switch face {
                case .stop:
                    Image(systemName: "stop.fill")
                case .cancelStart:
                    Image(systemName: "xmark")
                case .settling:
                    ProgressView()
                        .controlSize(.small)
                }
                title(face)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(waits ? Color.secondary : Color.white)
            .frame(minWidth: 86, minHeight: ComposerBar.controlSize)
            .padding(.horizontal, 4)
            .contentShape(ComposerBar.controlHitShape)
        }
        .buttonStyle(.plain)
        // Its words are on their way: nothing to stop.
        .disabled(waits)
        .conduitGlassControl(
            cornerRadius: ComposerBar.controlSize / 2,
            tint: waits ? Color.primary.opacity(0.025) : Color.red,
            prominent: !waits,
            interactive: !waits
        )
        .accessibilityShowsLargeContentViewer {
            Label {
                accessibilityTitle(face)
            } icon: {
                Image(systemName: face == .cancelStart ? "xmark" : "stop.fill")
            }
        }
        .accessibilityLabel(accessibilityTitle(face))
        .accessibilityHint(face == .stop
            ? AppLocalization.string("Stops dictating; the words stay in the message")
            : "")
        .accessibilityIdentifier(identifier)
    }

    private func title(_ face: ComposerDictation.SlotFace) -> Text {
        switch face {
        case .stop: return Text(AppLocalization.string("Stop"))
        case .cancelStart: return Text(AppLocalization.string("Cancel"))
        case .settling: return Text(AppLocalization.string("Transcribing"))
        }
    }

    private func accessibilityTitle(_ face: ComposerDictation.SlotFace) -> Text {
        switch face {
        case .stop: return Text(AppLocalization.string("Stop dictation"))
        case .cancelStart: return Text(AppLocalization.string("Cancel dictation"))
        case .settling: return Text(AppLocalization.string("Transcribing"))
        }
    }
}
