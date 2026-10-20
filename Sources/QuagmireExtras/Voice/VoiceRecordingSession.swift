import Foundation
import Observation

public typealias VoiceTranscriptDelivery<Destination> = @MainActor (
    _ transcript: String,
    _ destination: Destination
) async throws -> Void

public enum VoiceRecordingTranscriptionResult: Equatable, Sendable {
    case transcript(String)
    case noSpeech
    case failed
}

@MainActor
@Observable
public final class VoiceRecordingSession<Destination: Codable & Sendable> {
    private let recorder: any VoiceRecording
    private let recoveryStore: PendingVoiceRecordingStore<Destination>
    private let recoveryDelivery: VoiceTranscriptDelivery<Destination>
    private let transcribedStore: TranscribedVoiceRecordingStore?
    private let pageKey: (Destination) -> String?
    private var activeDelivery: VoiceTranscriptDelivery<Destination>?
    private var activeRecording: PendingVoiceRecording<Destination>?
    private var activeLiveAudioURL: URL?
    private var activeDraftHandler: (@MainActor @Sendable (String) -> Void)?
    private var deferredRecoveryIDs: Set<UUID> = []

    public private(set) var isTransitioning = false
    public private(set) var pendingRecovery: PendingVoiceRecording<Destination>?
    public var errorMessage: String?

    public var state: VoiceRecordingState { recorder.state }

    /// With a `transcribedStore`, audio that transcribed successfully is kept
    /// there instead of being deleted, under the page `pageKey` names for its
    /// destination.
    public init(
        recoveryStore: PendingVoiceRecordingStore<Destination>,
        transcribedStore: TranscribedVoiceRecordingStore? = nil,
        pageKey: @escaping (Destination) -> String? = { _ in nil },
        loggingSubsystem: String? = nil,
        recoveryDelivery: @escaping VoiceTranscriptDelivery<Destination>
    ) {
        self.recorder = VoiceRecorder(loggingSubsystem: loggingSubsystem)
        self.recoveryStore = recoveryStore
        self.transcribedStore = transcribedStore
        self.pageKey = pageKey
        self.recoveryDelivery = recoveryDelivery
        finishInitialization()
    }

    init(
        recorder: any VoiceRecording,
        recoveryStore: PendingVoiceRecordingStore<Destination>,
        transcribedStore: TranscribedVoiceRecordingStore? = nil,
        pageKey: @escaping (Destination) -> String? = { _ in nil },
        recoveryDelivery: @escaping VoiceTranscriptDelivery<Destination>
    ) {
        self.recorder = recorder
        self.recoveryStore = recoveryStore
        self.transcribedStore = transcribedStore
        self.pageKey = pageKey
        self.recoveryDelivery = recoveryDelivery
        finishInitialization()
    }

    /// Starts a recording for `destination`. With `onDraft`, it is
    /// transcribed live and `onDraft` receives the transcript so far as it
    /// grows, then an empty string once the recording ends, delivered or not.
    /// Either way its audio is written to the recovery store first, so a
    /// failed transcription can be recovered later.
    public func start(
        destination: Destination,
        delivery: VoiceTranscriptDelivery<Destination>? = nil,
        onDraft: (@MainActor @Sendable (String) -> Void)? = nil
    ) async {
        guard !isTransitioning, state == .idle else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            let recording = try recoveryStore.begin(destination: destination)
            activeRecording = recording
            activeDelivery = delivery ?? recoveryDelivery
            let audioURL = recoveryStore.audioURL(for: recording)
            if let onDraft {
                activeDraftHandler = onDraft
                try await recorder.startLiveTranscription(savingAudioTo: audioURL, onDraft: onDraft)
            } else {
                try await recorder.start(recordingAt: audioURL)
            }
        } catch {
            recorder.cancel(discardingAudio: true)
            if let activeRecording {
                try? FileManager.default.removeItem(at: recoveryStore.audioURL(for: activeRecording))
                try? recoveryStore.remove(activeRecording)
            }
            activeRecording = nil
            activeDelivery = nil
            endDraft()
            errorMessage = error.localizedDescription
        }
    }

    /// Starts the pinch-only live transcription path. Unlike ordinary toolbar
    /// recording, this creates no recovery record and has no destination: the
    /// caller owns the provisional UI and final insertion target. Its audio is
    /// written only when there is a `transcribedStore` to keep it in.
    @discardableResult
    public func startLiveTranscription(
        onDraft: @escaping @MainActor @Sendable (String) -> Void
    ) async -> Bool {
        guard !isTransitioning, state == .idle else { return false }
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            activeRecording = nil
            activeDelivery = nil
            activeLiveAudioURL = try? transcribedStore?.newAudioURL(fileExtension: "m4a")
            try await recorder.startLiveTranscription(
                savingAudioTo: activeLiveAudioURL,
                onDraft: onDraft
            )
            errorMessage = nil
            return state == .recording
        } catch {
            recorder.cancel(discardingAudio: true)
            discardLiveAudio()
            activeRecording = nil
            activeDelivery = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func stopAndDeliver() async {
        guard !isTransitioning, state == .recording else { return }
        isTransitioning = true
        let recording = activeRecording
        let delivery = activeDelivery ?? recoveryDelivery
        activeDelivery = nil
        defer {
            endDraft()
            isTransitioning = false
        }

        do {
            guard let recording else { throw VoiceRecordingSessionError.missingDestination }
            let transcript = try await recorder.stopAndTranscribe()
            try await deliver(transcript, recording.destination, using: delivery)
            keepAudio(
                at: recoveryStore.audioURL(for: recording),
                transcript: transcript,
                pageKey: pageKey(recording.destination)
            )
            try recoveryStore.remove(recording)
            activeRecording = nil
        } catch {
            recorder.cancel(discardingAudio: false)
            if VoiceRecordingFailureDisposition(error: error) == .discard,
               let recording {
                try? recoveryStore.remove(recording)
            }
            activeRecording = nil
            refreshPendingRecovery()
            errorMessage = recoveryFailureMessage(for: error)
        }
    }

    /// Stop the active recording and return its transcript without invoking a
    /// destination delivery. Used when the caller owns an inline insertion
    /// target, such as Quagmire's pinch-to-insert gesture.
    ///
    /// Silence is an ordinary result: its empty audio is discarded and no
    /// alert is produced. Retryable recorder failures still preserve the
    /// pending audio and populate `errorMessage` for the host to surface.
    /// `pageKey` names the page the caller inserts into, for keeping the audio.
    public func stopAndReturnTranscript(pageKey: String? = nil) async -> VoiceRecordingTranscriptionResult {
        guard !isTransitioning, state == .recording else { return .failed }
        isTransitioning = true
        let recording = activeRecording
        activeDelivery = nil
        defer { isTransitioning = false }

        do {
            let rawTranscript = try await recorder.stopAndTranscribe()
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw VoiceRecordingSessionError.emptyTranscript }
            if let recording {
                keepAudio(
                    at: recoveryStore.audioURL(for: recording),
                    transcript: transcript,
                    pageKey: pageKey ?? self.pageKey(recording.destination)
                )
                try recoveryStore.remove(recording)
            } else if let activeLiveAudioURL {
                keepAudio(at: activeLiveAudioURL, transcript: transcript, pageKey: pageKey)
            }
            activeLiveAudioURL = nil
            activeRecording = nil
            errorMessage = nil
            return .transcript(transcript)
        } catch {
            recorder.cancel(discardingAudio: false)
            discardLiveAudio()
            let disposition = VoiceRecordingFailureDisposition(error: error)
            if disposition == .discard, let recording {
                try? recoveryStore.remove(recording)
            }
            activeRecording = nil
            refreshPendingRecovery()
            if disposition == .discard {
                errorMessage = nil
                return .noSpeech
            }
            errorMessage = recording == nil
                ? error.localizedDescription
                : recoveryFailureMessage(for: error)
            return .failed
        }
    }

    public func cancelTranscription() {
        recorder.cancelTranscription()
    }

    public func cancel() {
        recorder.cancel(discardingAudio: true)
        discardLiveAudio()
        endDraft()
        if let activeRecording {
            try? recoveryStore.remove(activeRecording)
        }
        activeRecording = nil
        activeDelivery = nil
        isTransitioning = false
    }

    public func recoverPendingRecording() async {
        guard !isTransitioning, state == .idle, let recording = pendingRecovery else { return }
        pendingRecovery = nil
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            let transcript = try await recorder.transcribeSavedRecording(
                at: recoveryStore.audioURL(for: recording)
            )
            try await deliver(transcript, recording.destination, using: recoveryDelivery)
            keepAudio(
                at: recoveryStore.audioURL(for: recording),
                transcript: transcript,
                pageKey: pageKey(recording.destination)
            )
            try recoveryStore.remove(recording)
        } catch {
            if VoiceRecordingFailureDisposition(error: error) == .discard {
                try? recoveryStore.remove(recording)
            } else {
                deferredRecoveryIDs.insert(recording.id)
            }
            errorMessage = recoveryFailureMessage(for: error)
        }
        refreshPendingRecovery()
    }

    public func deferPendingRecovery() {
        if let pendingRecovery {
            deferredRecoveryIDs.insert(pendingRecovery.id)
        }
        pendingRecovery = nil
    }

    public func reportError(_ message: String) {
        errorMessage = message
    }

    private func finishInitialization() {
        refreshPendingRecovery()
        recorder.unexpectedStopHandler = { [weak self] message in
            self?.handleUnexpectedStop(message)
        }
    }

    private func deliver(
        _ rawTranscript: String,
        _ destination: Destination,
        using delivery: VoiceTranscriptDelivery<Destination>
    ) async throws {
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw VoiceRecordingSessionError.emptyTranscript }
        try await delivery(transcript, destination)
    }

    /// Moves successfully transcribed audio into the transcribed store, if
    /// there is one. Keeping is best effort: the transcript is already
    /// delivered, so a failure here only loses the replay.
    private func keepAudio(at url: URL, transcript: String, pageKey: String?) {
        guard let transcribedStore else { return }
        _ = try? transcribedStore.keep(
            audioAt: url,
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            pageKey: pageKey
        )
    }

    private func discardLiveAudio() {
        if let activeLiveAudioURL {
            try? FileManager.default.removeItem(at: activeLiveAudioURL)
        }
        activeLiveAudioURL = nil
    }

    /// Tells the live draft's owner the recording is over, so it can take
    /// down its preview.
    private func endDraft() {
        let handler = activeDraftHandler
        activeDraftHandler = nil
        handler?("")
    }

    private func handleUnexpectedStop(_ message: String) {
        discardLiveAudio()
        endDraft()
        activeRecording = nil
        activeDelivery = nil
        isTransitioning = false
        refreshPendingRecovery()
        errorMessage = message
    }

    private func refreshPendingRecovery() {
        pendingRecovery = (try? recoveryStore.pendingRecordings())?
            .first { !deferredRecoveryIDs.contains($0.id) }
    }

    private func recoveryFailureMessage(for error: Error) -> String {
        if VoiceRecordingFailureDisposition(error: error) == .discard {
            return error.localizedDescription
        }
        if error is CancellationError {
            return "Transcription was canceled. The audio was preserved and can be recovered later."
        }
        return "\(error.localizedDescription) The audio was preserved and can be recovered later."
    }
}

public enum VoiceRecordingFailureDisposition: Equatable, Sendable {
    case discard
    case preserve

    public init(error: Error) {
        if let recorderError = error as? VoiceRecorderError {
            switch recorderError {
            case .noAudioCaptured, .noTranscribableSpeech:
                self = .discard
            default:
                self = .preserve
            }
        } else if let sessionError = error as? VoiceRecordingSessionError,
                  case .emptyTranscript = sessionError {
            self = .discard
        } else {
            self = .preserve
        }
    }
}

public enum VoiceRecordingSessionError: LocalizedError, Equatable {
    case emptyTranscript
    case missingDestination

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "No speech could be transcribed from the recording."
        case .missingDestination:
            "The recording destination is no longer available."
        }
    }
}
