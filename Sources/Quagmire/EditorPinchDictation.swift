import Foundation

/// Optional host-owned voice capture used by iOS pinch-to-insert.
///
/// Quagmire owns the insertion and focus policy, while the host owns microphone
/// permission, recording, transcription, recovery, and error presentation.
/// A controller instance represents one shared recorder and must therefore
/// return `false` from `begin()` when another recording is already active.
@MainActor
public final class EditorPinchDictation {
    public typealias DraftHandler = @MainActor @Sendable (_ text: String) -> Void

    public enum Completion: Equatable, Sendable {
        case transcript(String)
        case noSpeech
        case failed
    }

    private let beginAction: @MainActor (_ onDraft: @escaping DraftHandler) async -> Bool
    private let finishAction: @MainActor () async -> Completion
    private let cancelAction: @MainActor () -> Void

    public init(
        begin: @escaping @MainActor () async -> Bool,
        finish: @escaping @MainActor () async -> Completion,
        cancel: @escaping @MainActor () -> Void
    ) {
        self.beginAction = { _ in await begin() }
        self.finishAction = finish
        self.cancelAction = cancel
    }

    /// Creates pinch dictation that can publish a changing, non-authoritative
    /// transcript while the gesture remains active. Drafts are display-only;
    /// Quagmire commits only the value returned by `finish`.
    public init(
        beginWithDrafts: @escaping @MainActor (_ onDraft: @escaping DraftHandler) async -> Bool,
        finish: @escaping @MainActor () async -> Completion,
        cancel: @escaping @MainActor () -> Void
    ) {
        self.beginAction = beginWithDrafts
        self.finishAction = finish
        self.cancelAction = cancel
    }

    func begin(onDraft: @escaping DraftHandler) async -> Bool {
        await beginAction(onDraft)
    }
    func finish() async -> Completion { await finishAction() }
    func cancel() { cancelAction() }

    /// How long a released pinch waits for a recorder still starting up.
    static let beginDeadline: Duration = .seconds(5)
    /// How long a released pinch waits for the host's final transcript. The
    /// pinch is off while it waits, so a host that never answers must not
    /// keep it off for good.
    static let finishDeadline: Duration = .seconds(20)

    /// `operation`'s answer, or `fallback` if it has not answered within
    /// `deadline`. The operation keeps running after a timeout; its late
    /// answer is dropped.
    static func answer<T: Sendable>(
        within deadline: Duration,
        fallback: T,
        _ operation: @escaping @MainActor () async -> T
    ) async -> T {
        let race = FirstAnswer<T>()
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            Task { @MainActor in race.resume(await operation()) }
            Task { @MainActor in
                try? await Task.sleep(for: deadline)
                race.resume(fallback)
            }
        }
    }
}

@MainActor
private final class FirstAnswer<T: Sendable> {
    var continuation: CheckedContinuation<T, Never>?

    func resume(_ value: T) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
