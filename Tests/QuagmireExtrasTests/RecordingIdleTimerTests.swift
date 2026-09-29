import Testing
@testable import QuagmireExtras

@Suite("Recording idle timer")
@MainActor
struct RecordingIdleTimerTests {
    @Test(arguments: [false, true])
    func restoresHostSettingAfterLastRecording(previousValue: Bool) {
        var disabled = previousValue
        var writes: [Bool] = []
        let timer = RecordingIdleTimer(read: { disabled }, write: {
            disabled = $0
            writes.append($0)
        })
        var first: RecordingIdleTimer.Lease? = timer.acquire()
        var second: RecordingIdleTimer.Lease? = timer.acquire()
        #expect(first != nil && second != nil)
        #expect(disabled)
        #expect(writes == [true])

        first = nil
        #expect(disabled)
        #expect(writes == [true])
        second = nil
        #expect(disabled == previousValue)
        #expect(writes == [true, previousValue])

        // Each new recording must capture the host's current preference.
        disabled = !previousValue
        var next: RecordingIdleTimer.Lease? = timer.acquire()
        #expect(next != nil)
        #expect(disabled)
        next = nil
        #expect(disabled == !previousValue)
    }
}
