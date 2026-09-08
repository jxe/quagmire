import SwiftUI

/// Optional host action driven by a deliberate pull beyond the top of an iOS editor.
///
/// Quagmire reports normalized progress and whether the threshold is currently
/// armed. The host owns the visual treatment and the action performed on release.
public struct EditorTopOverscrollAction {
    public var threshold: CGFloat
    public var onProgress: @MainActor (_ progress: CGFloat, _ isArmed: Bool) -> Void
    public var onRelease: @MainActor (_ committed: Bool) -> Void

    public init(
        threshold: CGFloat = 104,
        onProgress: @escaping @MainActor (_ progress: CGFloat, _ isArmed: Bool) -> Void,
        onRelease: @escaping @MainActor (_ committed: Bool) -> Void
    ) {
        self.threshold = max(1, threshold)
        self.onProgress = onProgress
        self.onRelease = onRelease
    }
}
