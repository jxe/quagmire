import Foundation
import Testing
@testable import QuagmireExtras

@Suite("Voice recording")
struct VoiceRecordingTests {
    @Test func storeKeepsAudioUntilExplicitRemovalAndSortsOldestFirst() throws {
        let directory = temporaryDirectory("voice-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory)
        let later = try store.begin(destination: "later", now: Date(timeIntervalSince1970: 20))
        let earlier = try store.begin(destination: "earlier", now: Date(timeIntervalSince1970: 10))

        #expect(try store.pendingRecordings().isEmpty)
        try Data([1]).write(to: store.audioURL(for: later))
        try Data([2]).write(to: store.audioURL(for: earlier))
        #expect(try store.pendingRecordings().map(\.destination) == ["earlier", "later"])

        try store.remove(earlier)
        #expect(try store.pendingRecordings() == [later])
    }

    @Test func noContentFailuresDiscardButRetryableFailuresPreserve() {
        #expect(VoiceRecordingFailureDisposition(error: VoiceRecorderError.noAudioCaptured) == .discard)
        #expect(VoiceRecordingFailureDisposition(error: VoiceRecorderError.noTranscribableSpeech) == .discard)
        #expect(VoiceRecordingFailureDisposition(error: VoiceRecordingSessionError.emptyTranscript) == .discard)
        #expect(VoiceRecordingFailureDisposition(error: VoiceRecorderError.transcriptionUnavailable) == .preserve)
        #expect(VoiceRecordingFailureDisposition(error: CancellationError()) == .preserve)
    }

    @MainActor
    @Test func sessionDeliversTranscriptAndRemovesRecovery() async throws {
        let directory = temporaryDirectory("voice-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = StubVoiceRecorder(transcript: "  hello there  ")
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory)
        var deliveries: [(String, String)] = []
        let session = VoiceRecordingSession(
            recorder: recorder,
            recoveryStore: store,
            recoveryDelivery: { transcript, destination in
                deliveries.append((transcript, destination))
            }
        )

        await session.start(destination: "inbox")
        await session.stopAndDeliver()

        #expect(deliveries.map { [$0.0, $0.1] } == [["hello there", "inbox"]])
        #expect(try store.pendingRecordings().isEmpty)
        #expect(session.errorMessage == nil)
    }

    @MainActor
    @Test func deliveryFailurePreservesAudioForRecovery() async throws {
        let directory = temporaryDirectory("voice-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory)
        let session = VoiceRecordingSession(
            recorder: StubVoiceRecorder(transcript: "hello"),
            recoveryStore: store,
            recoveryDelivery: { _, _ in throw StubError.delivery }
        )

        await session.start(destination: "inbox")
        await session.stopAndDeliver()

        #expect(try store.pendingRecordings().map(\.destination) == ["inbox"])
        #expect(session.pendingRecovery?.destination == "inbox")
        #expect(session.errorMessage?.contains("preserved") == true)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quagmire-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    enum StubError: LocalizedError {
        case delivery
        var errorDescription: String? { "Delivery failed." }
    }
}

@MainActor
private final class StubVoiceRecorder: VoiceRecording {
    var state: VoiceRecordingState = .idle
    var unexpectedStopHandler: ((String) -> Void)?
    private let transcript: String
    private var recordingURL: URL?

    init(transcript: String) {
        self.transcript = transcript
    }

    func start(recordingAt url: URL) async throws {
        try Data([1]).write(to: url)
        recordingURL = url
        state = .recording
    }

    func stopAndTranscribe() async throws -> String {
        state = .idle
        return transcript
    }

    func transcribeSavedRecording(at url: URL) async throws -> String {
        transcript
    }

    func cancel(discardingAudio: Bool) {
        if discardingAudio, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        state = .idle
    }

    func cancelTranscription() {
        state = .idle
    }
}
