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
    func startLiveTranscription(
        onDraft: @escaping @MainActor @Sendable (String) -> Void
    ) async throws
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
    private var liveCapture: LiveAudioCapture?
    private var liveConversionTask: Task<Void, Error>?
    private var transcriptionWasCancelled = false

    public init(loggingSubsystem: String? = nil) {
        logger = loggingSubsystem.map { Logger(subsystem: $0, category: "voice") }
    }

    public func start(recordingAt url: URL) async throws {
        guard state == .idle else { return }
        try await requestPermissions()
        try activateAudioSession()

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

    public func startLiveTranscription(
        onDraft: @escaping @MainActor @Sendable (String) -> Void
    ) async throws {
        guard state == .idle else { return }
        try await requestPermissions()
        try activateAudioSession()
        transcriptionWasCancelled = false

        guard let locale = await DictationTranscriber.supportedLocale(
            equivalentTo: .autoupdatingCurrent
        ) else {
            throw VoiceRecorderError.unsupportedLocale
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        try await installAssetsIfNeeded(for: transcriber)
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw VoiceRecorderError.transcriptionUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        let capture = LiveAudioCapture()
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        let resultTask = Task<String, Error> { @MainActor in
            var finalized: [String] = []
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal {
                    if !text.isEmpty { finalized.append(text) }
                    volatile = ""
                } else {
                    volatile = text
                }
                onDraft(Self.joinTranscript(finalized: finalized, volatile: volatile))
            }
            return Self.joinTranscript(finalized: finalized, volatile: volatile)
        }

        let conversionTask = Task<Void, Error> {
            defer { inputContinuation.finish() }
            guard let converter = AVAudioConverter(
                from: capture.audioFormat,
                to: analyzerFormat
            ) else {
                throw VoiceRecorderError.recordingFailed(underlying: "audio conversion unavailable")
            }
            for await transferableBuffer in capture.buffers {
                try Task.checkCancellation()
                let buffer = transferableBuffer.value
                let converted = try Self.convert(
                    buffer,
                    to: analyzerFormat,
                    using: converter
                )
                inputContinuation.yield(AnalyzerInput(buffer: converted))
            }
        }

        do {
            try await analyzer.start(inputSequence: inputSequence)
            try capture.start()
        } catch {
            conversionTask.cancel()
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            capture.stop()
            deactivateAudioSession()
            throw error
        }

        activeAnalyzer = analyzer
        activeResultTask = resultTask
        liveCapture = capture
        liveConversionTask = conversionTask
        state = .recording
        logger?.log("ephemeral live transcription started")
    }

    public func stopAndTranscribe() async throws -> String {
        guard state == .recording else { return "" }
        if liveCapture != nil {
            return try await stopLiveAndTranscribe()
        }
        guard let url = recordingURL else { return "" }
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
        liveCapture?.stop()
        liveCapture = nil
        liveConversionTask?.cancel()
        liveConversionTask = nil
        deactivateAudioSession()
        if discardingAudio, let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        cancelTranscription()
        activeResultTask?.cancel()
        activeResultTask = nil
        if let activeAnalyzer {
            Task { await activeAnalyzer.cancelAndFinishNow() }
        }
        activeAnalyzer = nil
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

    private func activateAudioSession() throws {
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
    }

    private func stopLiveAndTranscribe() async throws -> String {
        guard let capture = liveCapture,
              let analyzer = activeAnalyzer,
              let resultTask = activeResultTask else {
            throw VoiceRecorderError.recordingFailed(underlying: "live transcription state was incomplete")
        }

        state = .transcribing
        capture.stop()
        liveCapture = nil
        deactivateAudioSession()
        defer {
            recordingURL = nil
            liveConversionTask = nil
            activeAnalyzer = nil
            activeResultTask = nil
            state = .idle
        }

        do {
            if let liveConversionTask {
                try await liveConversionTask.value
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let transcript = try await resultTask.value
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard capture.capturedFrames > 0 else {
                throw VoiceRecorderError.noAudioCaptured
            }
            guard !transcript.isEmpty else {
                throw VoiceRecorderError.noTranscribableSpeech
            }
            return transcript
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    nonisolated private static func joinTranscript(
        finalized: [String],
        volatile: String
    ) -> String {
        (finalized + (volatile.isEmpty ? [] : [volatile])).joined(separator: " ")
    }

    nonisolated private static func convert(
        _ input: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(capacity, 1)
        ) else {
            throw VoiceRecorderError.recordingFailed(underlying: "audio buffer allocation failed")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw conversionError
                ?? VoiceRecorderError.recordingFailed(underlying: "audio conversion failed")
        }
        return output
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

    private func installAssetsIfNeeded(for module: some SpeechModule) async throws {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            return
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
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

/// Captures the short-lived pinch microphone stream. The durable toolbar path
/// deliberately uses AVAudioRecorder instead; pinch audio is never written.
private final class LiveAudioCapture: @unchecked Sendable {
    let buffers: AsyncStream<TransferableAudioBuffer>
    let audioFormat: AVAudioFormat

    private let engine = AVAudioEngine()
    private let continuation: AsyncStream<TransferableAudioBuffer>.Continuation
    private let lock = NSLock()
    private var storedFrames: AVAudioFramePosition = 0
    private var tapInstalled = false

    init() {
        audioFormat = engine.inputNode.outputFormat(forBus: 0)
        (buffers, continuation) = AsyncStream<TransferableAudioBuffer>.makeStream()
    }

    var capturedFrames: AVAudioFramePosition {
        lock.withLock { storedFrames }
    }

    func start() throws {
        let inputNode = engine.inputNode
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: audioFormat
        ) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.withLock {
                self.storedFrames += AVAudioFramePosition(buffer.frameLength)
            }
            if let copiedBuffer = Self.copy(buffer) {
                self.continuation.yield(TransferableAudioBuffer(value: copiedBuffer))
            }
        }
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            continuation.finish()
            throw error
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        continuation.finish()
    }

    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else { continue }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }
        return copy
    }
}

/// AVAudioPCMBuffer itself predates Swift concurrency. This box transfers the
/// deep copy made by the audio tap to exactly one conversion task; neither
/// side mutates it after transfer.
private struct TransferableAudioBuffer: @unchecked Sendable {
    let value: AVAudioPCMBuffer
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
