import SwiftUI

public struct VoiceRecordingButton<Destination: Codable & Sendable>: View {
    private let session: VoiceRecordingSession<Destination>
    private let start: @MainActor () async -> Void

    public init(
        session: VoiceRecordingSession<Destination>,
        start: @escaping @MainActor () async -> Void
    ) {
        self.session = session
        self.start = start
    }

    public var body: some View {
        Button {
            Task { @MainActor in
                switch session.state {
                case .idle:
                    await start()
                case .recording:
                    await session.stopAndDeliver()
                case .transcribing:
                    session.cancelTranscription()
                }
            }
        } label: {
            switch session.state {
            case .idle:
                if session.isTransitioning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "mic")
                }
            case .recording:
                Image(systemName: "stop.circle.fill").foregroundStyle(.red)
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .overlay {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                    }
            }
        }
        .disabled(session.isTransitioning && session.state != .transcribing)
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch session.state {
        case .idle:
            session.isTransitioning ? "Starting Recording" : "Record Audio"
        case .recording:
            "Stop Recording"
        case .transcribing:
            "Cancel Transcription"
        }
    }
}
