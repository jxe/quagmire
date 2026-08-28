import Foundation

/// Optional host-owned voice capture used by iOS pinch-to-insert.
///
/// Quagmire owns the insertion and focus policy, while the host owns microphone
/// permission, recording, transcription, recovery, and error presentation.
/// A controller instance represents one shared recorder and must therefore
/// return `false` from `begin()` when another recording is already active.
@MainActor
public final class EditorPinchDictation {
    public enum Completion: Equatable, Sendable {
        case transcript(String)
        case noSpeech
        case failed
    }

    private let beginAction: @MainActor () async -> Bool
    private let finishAction: @MainActor () async -> Completion
    private let cancelAction: @MainActor () -> Void

    public init(
        begin: @escaping @MainActor () async -> Bool,
        finish: @escaping @MainActor () async -> Completion,
        cancel: @escaping @MainActor () -> Void
    ) {
        self.beginAction = begin
        self.finishAction = finish
        self.cancelAction = cancel
    }

    func begin() async -> Bool { await beginAction() }
    func finish() async -> Completion { await finishAction() }
    func cancel() { cancelAction() }
}
