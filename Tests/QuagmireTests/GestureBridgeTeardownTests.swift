import SwiftUI
import Testing
@testable import Quagmire

#if os(iOS)
import UIKit

@MainActor
@Suite(.serialized)
struct IOSGestureBridgeTeardownTests {
    @Test func recyclingPageGesturesLeavesScrollRecognizersIntact() throws {
        let scroll = UIScrollView()
        let originalCount = scroll.gestureRecognizers?.count
        for _ in 0..<20 {
            let pinch = IOSPagePinchGestureBridge(
                isEnabled: true, shouldBegin: { _ in true },
                onUpdate: { _ in }, onCommit: { _ in }
            ).makeCoordinator()
            let pinchHost = IOSPagePinchGestureBridge.HostView()
            pinchHost.coordinator = pinch
            scroll.addSubview(pinchHost)
            pinch.attach(from: pinchHost)
            let pinchRecognizer = try #require(pinch.recognizer)

            let reorder = IOSPageReorderGestureBridge<String>(
                isEnabled: true, layoutCache: RowSurfaceLayoutCache<String>(),
                shouldBegin: { _, _ in true }, onBegin: { _, _ in },
                onChanged: { _ in }, onEnded: { _ in }, onCancelled: {}
            ).makeCoordinator()
            let reorderHost = IOSPageReorderGestureBridge<String>.HostView()
            reorderHost.coordinator = reorder
            scroll.addSubview(reorderHost)
            reorder.attach(from: reorderHost)
            let reorderRecognizer = try #require(reorder.recognizer)

            IOSPagePinchGestureBridge.dismantleUIView(pinchHost, coordinator: pinch)
            IOSPageReorderGestureBridge<String>.dismantleUIView(reorderHost, coordinator: reorder)
            // Repeated teardown must be harmless, including a later window callback.
            IOSPagePinchGestureBridge.dismantleUIView(pinchHost, coordinator: pinch)
            IOSPageReorderGestureBridge<String>.dismantleUIView(reorderHost, coordinator: reorder)
            pinchHost.removeFromSuperview()
            reorderHost.removeFromSuperview()
            #expect(pinchRecognizer.view == nil)
            #expect(reorderRecognizer.view == nil)
            #expect(pinchHost.coordinator == nil)
            #expect(reorderHost.coordinator == nil)
            #expect(scroll.gestureRecognizers?.count == originalCount)
            #expect(scroll.panGestureRecognizer.view === scroll)
        }
    }

    @Test func metricsTeardownRejectsQueuedAndFutureUpdates() async {
        let metrics = PageScrollMetrics()
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let owner = IOSScrollMetricsReader.Coordinator(metrics: metrics, topOverscrollAction: nil)
        let host = IOSScrollMetricsReader.ReaderView()
        host.coordinator = owner
        scroll.addSubview(host)
        owner.update(from: scroll)
        scroll.contentOffset.y = 20
        IOSScrollMetricsReader.dismantleUIView(host, coordinator: owner)
        // The initial publish and KVO publish were queued before dismantling.
        await drainCallbacks()
        #expect(metrics.viewportHeight == 0)
        #expect(metrics.contentOffsetY == 0)
        #expect(PageScrollController.shared.scrollView == nil)
        scroll.contentOffset.y = 50
        host.installIfNeeded()
        await drainCallbacks()
        #expect(metrics.contentOffsetY == 0)
        #expect(PageScrollController.shared.scrollView == nil)
    }

    @Test func oldMetricsOwnerCannotClearReplacementOnSameScrollView() async {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let old = IOSScrollMetricsReader.Coordinator(metrics: PageScrollMetrics(), topOverscrollAction: nil)
        let metrics = PageScrollMetrics()
        let replacement = IOSScrollMetricsReader.Coordinator(metrics: metrics, topOverscrollAction: nil)
        old.update(from: scroll)
        replacement.update(from: scroll)
        old.detach()
        #expect(PageScrollController.shared.owner === replacement)
        #expect(PageScrollController.shared.scrollView === scroll)
        await drainCallbacks()
        #expect(metrics.viewportHeight == 844)
        replacement.detach()
        #expect(PageScrollController.shared.scrollView == nil)
    }

    @Test func reparentingRejectsOldQueuedMetrics() async {
        let metrics = PageScrollMetrics()
        let owner = IOSScrollMetricsReader.Coordinator(metrics: metrics, topOverscrollAction: nil)
        let old = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let current = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        owner.update(from: old)
        owner.update(from: current)
        old.contentOffset.y = 100
        await drainCallbacks()
        #expect(metrics.viewportHeight == 400)
        #expect(metrics.contentOffsetY == 0)
        owner.detach()
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
#endif

#if os(macOS)
import AppKit

@MainActor
@Suite(.serialized)
struct MacScrollBridgeTeardownTests {
    @Test func dismantledReaderCannotReinstallAndOldOwnerCannotClearReplacement() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(scroll)
        let old = MacScrollControllerReader.ReaderView()
        scroll.addSubview(old)
        let replacement = MacScrollControllerReader.ReaderView()
        scroll.addSubview(replacement)
        #expect(MacPageScrollController.shared.owner === replacement)
        MacScrollControllerReader.dismantleNSView(old, coordinator: ())
        old.installIfNeeded()
        #expect(MacPageScrollController.shared.owner === replacement)
        MacScrollControllerReader.dismantleNSView(replacement, coordinator: ())
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(MacPageScrollController.shared.scrollView == nil)
    }

    @Test func temporaryRemovalAllowsReattachment() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(scroll)
        let reader = MacScrollControllerReader.ReaderView()
        scroll.addSubview(reader)
        #expect(MacPageScrollController.shared.scrollView === scroll)
        reader.removeFromSuperview()
        #expect(MacPageScrollController.shared.scrollView == nil)
        scroll.addSubview(reader)
        #expect(MacPageScrollController.shared.scrollView === scroll)
        MacScrollControllerReader.dismantleNSView(reader, coordinator: ())
    }
}
#endif
