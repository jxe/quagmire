import QuartzCore
#if os(macOS)
import AppKit
#endif

/// Runs a callback once per display refresh with the real time since the
/// previous frame, so motion stays smooth at 120Hz and through dropped
/// frames. Used for edge autoscroll during reorder and pinch.
@MainActor
final class FrameTicker {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var onFrame: ((TimeInterval) -> Bool)?

    var isRunning: Bool { link != nil }

    /// Calls `onFrame` with the elapsed seconds every frame until it returns
    /// false or `stop()` is called.
    func start(_ onFrame: @escaping (TimeInterval) -> Bool) {
        self.onFrame = onFrame
        guard link == nil else { return }
        let target = FrameTickerTarget(ticker: self)
        #if os(iOS)
        let link = CADisplayLink(target: target, selector: #selector(FrameTickerTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        #else
        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: target, selector: #selector(FrameTickerTarget.step(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = nil
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        onFrame = nil
    }

    fileprivate func step(_ link: CADisplayLink) {
        // Cap a long stall (backgrounding, a hitch) to two 60Hz frames so
        // the page never lurches.
        let elapsed = min(lastTimestamp.map { link.timestamp - $0 } ?? link.duration, 1.0 / 30.0)
        lastTimestamp = link.timestamp
        if onFrame?(elapsed) != true {
            stop()
        }
    }
}

/// The display link retains its target; this keeps the ticker itself free
/// to be released.
@MainActor
private final class FrameTickerTarget: NSObject {
    weak var ticker: FrameTicker?

    init(ticker: FrameTicker) {
        self.ticker = ticker
    }

    @objc func step(_ link: CADisplayLink) {
        ticker?.step(link)
    }
}
