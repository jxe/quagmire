import Foundation
import Quagmire
import QuagmireExtras
import Testing

@MainActor
@Suite("QuagmireExtras public API consumer")
struct PublicAPIConsumerTests {
    @Test func hostCanConstructEveryFeatureBoundary() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quagmire-extras-public-api", isDirectory: true)
        _ = LinkPreviewService(cacheDirectory: directory.appendingPathComponent("links"))

        let store = PendingVoiceRecordingStore<String>(
            directoryURL: directory.appendingPathComponent("voice")
        )
        let session = VoiceRecordingSession(
            recoveryStore: store,
            recoveryDelivery: { _, _ in }
        )
        _ = VoiceRecordingButton(session: session) {}
        _ = TranscriptPolishingActions.actions(polisher: UnavailablePolisher())
        _ = StartVoiceRecordingIntent()
        _ = QuagmireExtrasAppIntents()
    }

    private struct UnavailablePolisher: TranscriptPolishing {
        let isAvailable = false
        func polish(_ transcript: String) async throws -> String { transcript }
    }
}
