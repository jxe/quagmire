#if os(iOS)
import UIKit
#endif

/// Shares the app-wide idle timer across overlapping recording sessions and
/// restores the host's prior setting when the last recording ends.
@MainActor
final class RecordingIdleTimer {
    static let shared = RecordingIdleTimer(
        read: {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled
            #else
            false
            #endif
        },
        write: { disabled in
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = disabled
            #endif
        }
    )

    private let read: () -> Bool
    private let write: (Bool) -> Void
    private var recordingCount = 0
    private var previousValue = false

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    func acquire() -> Lease {
        if recordingCount == 0 {
            previousValue = read()
            write(true)
        }
        recordingCount += 1
        return Lease(timer: self)
    }

    private func release() {
        recordingCount -= 1
        if recordingCount == 0 { write(previousValue) }
    }

    @MainActor
    final class Lease {
        private let timer: RecordingIdleTimer

        fileprivate init(timer: RecordingIdleTimer) {
            self.timer = timer
        }

        isolated deinit {
            timer.release()
        }
    }
}
