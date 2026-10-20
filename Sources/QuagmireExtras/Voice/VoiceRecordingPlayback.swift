import AVFoundation
import Foundation
import Observation
import Quagmire

/// Plays kept recordings back, one at a time.
@MainActor
@Observable
public final class VoiceRecordingPlayer {
    public private(set) var playingRecordingID: UUID?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: PlayerDelegate?

    public init() {}

    public var isPlaying: Bool { playingRecordingID != nil }

    public func play(_ recording: TranscribedVoiceRecording, from store: TranscribedVoiceRecordingStore) throws {
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        #endif
        let player = try AVAudioPlayer(contentsOf: store.audioURL(for: recording))
        let delegate = PlayerDelegate { [weak self] in self?.finish() }
        player.delegate = delegate
        guard player.play() else { throw VoiceRecordingPlaybackError.couldNotPlay }
        self.player = player
        self.delegate = delegate
        playingRecordingID = recording.id
    }

    public func stop() {
        guard player != nil else { return }
        player?.stop()
        finish()
    }

    private func finish() {
        player = nil
        delegate = nil
        playingRecordingID = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: @MainActor () -> Void

    init(onFinish: @escaping @MainActor () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in onFinish() }
    }
}

public enum VoiceRecordingPlaybackError: LocalizedError {
    case couldNotPlay

    public var errorDescription: String? {
        "The recording could not be played."
    }
}

/// A block action that plays the recording a transcribed block came from,
/// among those kept for `pageKey`, the page being edited. While something
/// plays, the action stops it instead.
@MainActor
public enum VoiceRecordingPlaybackActions {
    public static let playRecordingID = "quagmire.play-recording"

    public static func actions(
        store: TranscribedVoiceRecordingStore,
        player: VoiceRecordingPlayer,
        pageKey: String?
    ) -> [EditorBlockAction] {
        guard let pageKey else { return [] }
        let isPlaying = player.isPlaying
        return [EditorBlockAction(
            id: playRecordingID,
            title: isPlaying ? "Stop" : "Play Recording",
            systemImage: isPlaying ? "stop.fill" : "play.fill",
            isApplicable: { context in
                isPlaying || recording(for: context, onPage: pageKey, in: store) != nil
            },
            perform: { context in
                if player.isPlaying {
                    player.stop()
                } else if let recording = recording(for: context, onPage: pageKey, in: store) {
                    try player.play(recording, from: store)
                }
                return []
            }
        )]
    }

    private static func recording(
        for context: BlockActionContext,
        onPage pageKey: String,
        in store: TranscribedVoiceRecordingStore
    ) -> TranscribedVoiceRecording? {
        guard context.blocks.count == 1, let block = context.blocks.first else { return nil }
        return store.recording(matching: String(block.text.characters), onPage: pageKey)
    }
}
