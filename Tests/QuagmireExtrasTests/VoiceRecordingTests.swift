import AVFoundation
import Foundation
import Testing
@testable import QuagmireExtras

@Suite("Voice recording")
struct VoiceRecordingTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func liveConversionPreservesTailWhenMicrophoneEnds(sampleRate: Double) throws {
        let inputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let outputFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: inputFormat, to: outputFormat))
        let inputFrames = Int(sampleRate / 10)
        var convertedFrames = 0
        var offset = 0
        while offset < inputFrames {
            let count = min(1_024, inputFrames - offset)
            let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(count)))
            input.frameLength = AVAudioFrameCount(count)
            let samples = try #require(input.floatChannelData)[0]
            for index in 0..<count {
                samples[index] = Float(sin(Double(offset + index) * 0.1))
            }
            convertedFrames += Int(try VoiceRecorder.convert(input, to: outputFormat, using: converter).frameLength)
            offset += count
        }
        let framesBeforeFinish = convertedFrames
        try VoiceRecorder.finishConversion(using: converter) { buffer in
            #expect(buffer.frameLength > 0)
            convertedFrames += Int(buffer.frameLength)
        }
        #expect(convertedFrames > framesBeforeFinish)
        #expect(abs(convertedFrames - 1_600) <= 1)
    }

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
    @Test func liveSessionStreamsDraftsThenDeliversAndEndsTheDraft() async throws {
        let directory = temporaryDirectory("voice-live-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory)
        var deliveries: [String] = []
        var drafts: [String] = []
        let session = VoiceRecordingSession(
            recorder: StubVoiceRecorder(transcript: "hello there"),
            recoveryStore: store,
            recoveryDelivery: { transcript, _ in deliveries.append(transcript) }
        )

        await session.start(destination: "inbox", onDraft: { drafts.append($0) })
        #expect(drafts == ["draft words"])
        #expect(try store.pendingRecordings().map(\.destination) == ["inbox"])
        await session.stopAndDeliver()

        #expect(deliveries == ["hello there"])
        #expect(drafts == ["draft words", ""])
        #expect(try store.pendingRecordings().isEmpty)
    }

    @MainActor
    @Test func liveSessionDeliveryFailureKeepsItsAudioForRecovery() async throws {
        let directory = temporaryDirectory("voice-live-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory)
        var drafts: [String] = []
        let session = VoiceRecordingSession(
            recorder: StubVoiceRecorder(transcript: "hello"),
            recoveryStore: store,
            recoveryDelivery: { _, _ in throw StubError.delivery }
        )

        await session.start(destination: "inbox", onDraft: { drafts.append($0) })
        await session.stopAndDeliver()

        #expect(session.pendingRecovery?.destination == "inbox")
        #expect(drafts.last == "")
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

    @MainActor
    @Test func inlineTranscriptionReturnsTextWithoutDelivering() async throws {
        let directory = temporaryDirectory("voice-inline")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory)
        var delivered = false
        let session = VoiceRecordingSession(
            recorder: StubVoiceRecorder(transcript: "  captured inline  "),
            recoveryStore: store,
            recoveryDelivery: { _, _ in delivered = true }
        )

        await session.start(destination: "inbox")
        let result = await session.stopAndReturnTranscript()

        #expect(result == .transcript("captured inline"))
        #expect(!delivered)
        #expect(try store.pendingRecordings().isEmpty)
        #expect(session.errorMessage == nil)
    }

    @MainActor
    @Test func inlineSilenceIsNormalAndDiscarded() async throws {
        let directory = temporaryDirectory("voice-inline-silence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory)
        let session = VoiceRecordingSession(
            recorder: StubVoiceRecorder(transcript: "   "),
            recoveryStore: store,
            recoveryDelivery: { _, _ in }
        )

        await session.start(destination: "inbox")
        let result = await session.stopAndReturnTranscript()

        #expect(result == .noSpeech)
        #expect(try store.pendingRecordings().isEmpty)
        #expect(session.pendingRecovery == nil)
        #expect(session.errorMessage == nil)
    }

    @MainActor
    @Test func liveTranscriptionPublishesDraftWithoutCreatingRecovery() async throws {
        let directory = temporaryDirectory("voice-live")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory)
        let session = VoiceRecordingSession(
            recorder: StubVoiceRecorder(transcript: "final words"),
            recoveryStore: store,
            recoveryDelivery: { _, _ in }
        )
        var drafts: [String] = []

        let began = await session.startLiveTranscription { drafts.append($0) }
        let result = await session.stopAndReturnTranscript()

        #expect(began)
        #expect(drafts == ["draft words"])
        #expect(result == .transcript("final words"))
        #expect(try store.pendingRecordings().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    @Test func sessionKeepsTranscribedAudio() async throws {
        let directory = temporaryDirectory("voice-keep")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingVoiceRecordingStore<String>(directoryURL: directory.appending(path: "pending"))
        let kept = TranscribedVoiceRecordingStore(directoryURL: directory.appending(path: "kept"))
        let session = VoiceRecordingSession(
            recorder: StubVoiceRecorder(transcript: " hello there "),
            recoveryStore: store,
            transcribedStore: kept,
            pageKey: { "page-\($0)" },
            recoveryDelivery: { _, _ in }
        )

        await session.start(destination: "inbox")
        await session.stopAndDeliver()
        _ = await session.startLiveTranscription { _ in }
        _ = await session.stopAndReturnTranscript(pageKey: "pinch-page")

        #expect(try store.pendingRecordings().isEmpty)
        let transcripts = Set(kept.recordings().map(\.transcript))
        #expect(transcripts == ["hello there"])
        #expect(Set(kept.recordings().map(\.pageKey)) == ["page-inbox", "pinch-page"])
        #expect(kept.recordings().count == 2)
        for recording in kept.recordings() {
            #expect(FileManager.default.fileExists(atPath: kept.audioURL(for: recording).path))
        }
    }

    @MainActor
    @Test func keptRecordingsMatchTheirTranscriptsInOrderOnTheirPage() throws {
        let directory = temporaryDirectory("voice-match")
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = TranscribedVoiceRecordingStore(directoryURL: directory)
        func keep(_ transcript: String, on page: String?) throws {
            let url = try kept.newAudioURL(fileExtension: "caf")
            try Data([1]).write(to: url)
            try kept.keep(audioAt: url, transcript: transcript, pageKey: page)
        }
        try keep("Um so I think we should, uh, ship the release on Friday.", on: "page")
        try keep("Buy eggs and milk today.", on: "page")
        try keep(
            "First we planned the trip to the coast. Then we booked a small cabin near the water for a week.",
            on: "page"
        )
        try keep("Call the plumber about the leak.", on: nil)

        #expect(kept.recording(matching: "I think we should ship the release on Friday.", onPage: "page") != nil)
        #expect(kept.recording(matching: "I think we should ship the release on Friday.", onPage: "other") == nil)
        #expect(kept.recording(matching: "Friday on release the ship should we think I", onPage: "page") == nil)
        #expect(kept.recording(matching: "ship the release", onPage: "page") == nil)
        #expect(kept.recording(matching: "Buy milk today", onPage: "page") != nil)
        #expect(kept.recording(matching: "Then we booked a small cabin near the water for a week.", onPage: "page") != nil)
        #expect(kept.recording(matching: "We should never ship anything at all on a weekend", onPage: "page") == nil)
        #expect(kept.recording(matching: "Call the plumber about the leak.", onPage: "page") == nil)
        #expect(kept.recording(matching: "   ", onPage: "page") == nil)
    }

    @MainActor
    @Test func pruningDropsOldRecordingsThenOldestOverTheSizeLimit() throws {
        let directory = temporaryDirectory("voice-prune")
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = TranscribedVoiceRecordingStore(
            directoryURL: directory,
            maximumAge: 100,
            maximumBytes: 25
        )
        func keep(_ transcript: String, at seconds: TimeInterval) throws {
            let url = try kept.newAudioURL(fileExtension: "caf")
            try Data(repeating: 1, count: 10).write(to: url)
            try kept.keep(audioAt: url, transcript: transcript, pageKey: "page", now: Date(timeIntervalSince1970: seconds))
        }
        try keep("ancient", at: 0)
        try keep("older", at: 150)
        try keep("old", at: 160)
        try keep("new", at: 170)

        #expect(kept.recordings().map(\.transcript) == ["new", "old"])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers.count == 4)
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

    func startLiveTranscription(
        savingAudioTo audioURL: URL?,
        onDraft: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        if let audioURL { try Data([3]).write(to: audioURL) }
        onDraft("draft words")
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
