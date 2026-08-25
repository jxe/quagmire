import AVFoundation
import Foundation
import Observation
import OSLog
import Speech

public enum VoiceRecordingState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
}

@MainActor
protocol VoiceRecording: AnyObject {
    var state: VoiceRecordingState { get }
    var unexpectedStopHandler: ((String) -> Void)? { get set }
    func start(recordingAt url: URL) async throws
    func stopAndTranscribe() async throws -> String
    func transcribeSavedRecording(at url: URL) async throws -> String
    func cancel(discardingAudio: Bool)
    func cancelTranscription()
}

@MainActor
@Observable
public final class VoiceRecorder: VoiceRecording {
    public private(set) var state: VoiceRecordingState = .idle
    public var unexpectedStopHandler: ((String) -> Void)?

    private let logger: Logger?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var healthMonitor: Task<Void, Never>?
    private var activeAnalyzer: SpeechAnalyzer?
    private var activeResultTask: Task<String, Error>?
    private var transcriptionWasCancelled = false

    public init(loggingSubsystem: String? = nil) {
        logger = loggingSubsystem.map { Logger(subsystem: $0, category: "voice") }
    }

    public func start(recordingAt url: URL) async throws {
        guard state == .idle else { return }
        try await requestPermissions()

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true, options: [])
        } catch {
            logger?.error("audio session activation failed: \(String(describing: error), privacy: .public)")
            throw VoiceRecorderError.recordingFailed(underlying: (error as NSError).localizedDescription)
        }
        #endif

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            logger?.error("audio recorder initialization failed: \(String(describing: error), privacy: .public)")
            throw VoiceRecorderError.recordingFailed(underlying: (error as NSError).localizedDescription)
        }
        guard recorder.prepareToRecord() else {
            logger?.error("audio recorder preparation failed")
            throw VoiceRecorderError.recordingFailed(underlying: "prepareToRecord failed")
        }
        guard recorder.record() else {
            logger?.error("audio recorder did not start")
            throw VoiceRecorderError.recordingFailed(underlying: "record() returned false")
        }

        self.recorder = recorder
        recordingURL = url
        state = .recording
        startHealthMonitor(for: recorder)
        logger?.log("recording started file=\(url.lastPathComponent, privacy: .public)")
    }

    public func stopAndTranscribe() async throws -> String {
        guard state == .recording, let url = recordingURL else { return "" }
        healthMonitor?.cancel()
        healthMonitor = nil
        state = .transcribing
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()
        transcriptionWasCancelled = false
        defer {
            recordingURL = nil
            state = .idle
        }
        return try await transcribeAudio(at: url)
    }

    public func transcribeSavedRecording(at url: URL) async throws -> String {
        guard state == .idle else { return "" }
        state = .transcribing
        transcriptionWasCancelled = false
        defer { state = .idle }
        return try await transcribeAudio(at: url)
    }

    public func cancel(discardingAudio: Bool = true) {
        healthMonitor?.cancel()
        healthMonitor = nil
        recorder?.stop()
        recorder = nil
        deactivateAudioSession()
        if discardingAudio, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        cancelTranscription()
        recordingURL = nil
        state = .idle
    }

    public func cancelTranscription() {
        guard state == .transcribing else { return }
        transcriptionWasCancelled = true
        activeResultTask?.cancel()
        if let activeAnalyzer {
            Task { await activeAnalyzer.cancelAndFinishNow() }
        }
        state = .idle
    }

    private func startHealthMonitor(for recorder: AVAudioRecorder) {
        healthMonitor?.cancel()
        healthMonitor = Task { @MainActor [weak self, weak recorder] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, let self, self.state == .recording else { return }
                guard recorder?.isRecording == true else {
                    self.handleUnexpectedStop()
                    return
                }
            }
        }
    }

    private func handleUnexpectedStop() {
        healthMonitor?.cancel()
        healthMonitor = nil
        recorder = nil
        deactivateAudioSession()
        recordingURL = nil
        state = .idle
        logger?.error("audio recorder stopped unexpectedly")
        unexpectedStopHandler?(
            "Recording stopped unexpectedly. Any audio captured before it stopped was preserved."
        )
    }

    private func deactivateAudioSession() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            logger?.error("audio session deactivation failed: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    private func requestPermissions() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw VoiceRecorderError.microphonePermissionDenied
        }
        guard await Self.requestSpeechAuthorization() == .authorized else {
            throw VoiceRecorderError.speechPermissionDenied
        }
    }

    nonisolated private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func transcribeAudio(at url: URL) async throws -> String {
        try checkForTranscriptionCancellation()
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            throw VoiceRecorderError.noAudioCaptured
        }
        guard SpeechTranscriber.isAvailable else {
            throw VoiceRecorderError.transcriptionUnavailable
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .autoupdatingCurrent) else {
            throw VoiceRecorderError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await installAssetsIfNeeded(for: transcriber)
        try checkForTranscriptionCancellation()

        let resultTask = Task<String, Error> {
            var chunks: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { chunks.append(text) }
            }
            return chunks.joined(separator: " ")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        activeAnalyzer = analyzer
        activeResultTask = resultTask
        defer {
            activeAnalyzer = nil
            activeResultTask = nil
        }

        do {
            guard let lastSample = try await analyzer.analyzeSequence(from: audioFile) else {
                await analyzer.cancelAndFinishNow()
                throw VoiceRecorderError.noAudioCaptured
            }
            try checkForTranscriptionCancellation()
            try await analyzer.finalizeAndFinish(through: lastSample)
            let transcript = try await resultTask.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                throw VoiceRecorderError.noTranscribableSpeech
            }
            logger?.log("transcription finished characters=\(transcript.count, privacy: .public)")
            return transcript
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func checkForTranscriptionCancellation() throws {
        if transcriptionWasCancelled { throw CancellationError() }
    }

    private func installAssetsIfNeeded(for transcriber: SpeechTranscriber) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                return
            }
            try await request.downloadAndInstall()
        case .unsupported:
            throw VoiceRecorderError.transcriptionUnavailable
        @unknown default:
            throw VoiceRecorderError.transcriptionUnavailable
        }
    }
}

public enum VoiceRecorderError: LocalizedError, Equatable {
    case microphonePermissionDenied
    case speechPermissionDenied
    case recordingFailed(underlying: String?)
    case noAudioCaptured
    case noTranscribableSpeech
    case transcriptionUnavailable
    case unsupportedLocale

    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            "Microphone access is required to record audio."
        case .speechPermissionDenied:
            "Speech recognition permission is required to transcribe audio."
        case .recordingFailed(let underlying):
            if let underlying, !underlying.isEmpty {
                "Recording could not be started: \(underlying)"
            } else {
                "Recording could not be started."
            }
        case .noAudioCaptured:
            "No audio was captured. The recording stopped before any microphone samples arrived."
        case .noTranscribableSpeech:
            "No speech could be transcribed from the recording."
        case .transcriptionUnavailable:
            "Speech transcription is not available on this device."
        case .unsupportedLocale:
            "Speech transcription is not available for your current language."
        }
    }
}
