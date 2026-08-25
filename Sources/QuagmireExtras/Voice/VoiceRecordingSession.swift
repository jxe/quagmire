import Foundation
import Observation

public typealias VoiceTranscriptDelivery<Destination> = @MainActor (
    _ transcript: String,
    _ destination: Destination
) async throws -> Void

@MainActor
@Observable
public final class VoiceRecordingSession<Destination: Codable & Sendable> {
    private let recorder: any VoiceRecording
    private let recoveryStore: PendingVoiceRecordingStore<Destination>
    private let recoveryDelivery: VoiceTranscriptDelivery<Destination>
    private var activeDelivery: VoiceTranscriptDelivery<Destination>?
    private var activeRecording: PendingVoiceRecording<Destination>?
    private var deferredRecoveryIDs: Set<UUID> = []

    public private(set) var isTransitioning = false
    public private(set) var pendingRecovery: PendingVoiceRecording<Destination>?
    public var errorMessage: String?

    public var state: VoiceRecordingState { recorder.state }

    public init(
        recoveryStore: PendingVoiceRecordingStore<Destination>,
        loggingSubsystem: String? = nil,
        recoveryDelivery: @escaping VoiceTranscriptDelivery<Destination>
    ) {
        self.recorder = VoiceRecorder(loggingSubsystem: loggingSubsystem)
        self.recoveryStore = recoveryStore
        self.recoveryDelivery = recoveryDelivery
        finishInitialization()
    }

    init(
        recorder: any VoiceRecording,
        recoveryStore: PendingVoiceRecordingStore<Destination>,
        recoveryDelivery: @escaping VoiceTranscriptDelivery<Destination>
    ) {
        self.recorder = recorder
        self.recoveryStore = recoveryStore
        self.recoveryDelivery = recoveryDelivery
        finishInitialization()
    }

    public func start(
        destination: Destination,
        delivery: VoiceTranscriptDelivery<Destination>? = nil
    ) async {
        guard !isTransitioning, state == .idle else { return }
        isTransitioning = true
        defer { isTransitioning = false }

        do {
            let recording = try recoveryStore.begin(destination: destination)
            activeRecording = recording
            activeDelivery = delivery ?? recoveryDelivery
            try await recorder.start(recordingAt: recoveryStore.audioURL(for: recording))
        } catch {
            recorder.cancel(discardingAudio: true)
            if let activeRecording {
                try? recoveryStore.remove(activeRecording)
            }
            activeRecording = nil
            activeDelivery = nil
            errorMessage = error.localizedDescription
        }
    }

    public func stopAndDeliver() async {
        guard !isTransitioning, state == .recording else { return }
        isTransitioning = true
        let recording = activeRecording
        let delivery = activeDelivery ?? recoveryDelivery
        activeDelivery = nil
        defer { isTransitioning = false }

        do {
            guard let recording else { throw VoiceRecordingSessionError.missingDestination }
            let transcript = try await recorder.stopAndTranscribe()
            try await deliver(transcript, recording.destination, using: delivery)
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

    public func cancelTranscription() {
        recorder.cancelTranscription()
    }

    public func cancel() {
        recorder.cancel(discardingAudio: true)
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

    private func handleUnexpectedStop(_ message: String) {
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
