#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Quagmire

@MainActor
@Suite("iOS row swipe recognizer lifetime")
struct IOSRowSwipeGestureBridgeTests {
    private func coordinator() -> IOSRowSwipeGestureBridge.Coordinator {
        IOSRowSwipeGestureBridge(
            isEnabled: true,
            onChanged: { _ in },
            onEnded: { _ in },
            onCancelled: {}
        ).makeCoordinator()
    }

    @Test func dismantlingRemovesRecognizerBeforeHostLeavesScrollView() throws {
        let scroll = UIScrollView()
        let host = IOSRowSwipeGestureBridge.HostView()
        let coordinator = coordinator()
        host.coordinator = coordinator
        scroll.addSubview(host)
        coordinator.attach(from: host)
        let recognizer = try #require(coordinator.recognizer)
        #expect(recognizer.view === scroll)

        // SwiftUI can dismantle the representable before UIKit removes its view.
        // didMoveToWindow alone cannot clean up once the coordinator is gone.
        IOSRowSwipeGestureBridge.dismantleUIView(host, coordinator: coordinator)

        #expect(host.superview === scroll)
        #expect(recognizer.view == nil)
        #expect(coordinator.recognizer == nil)
        #expect(coordinator.scrollView == nil)
        #expect(coordinator.hostView == nil)
        #expect(host.coordinator == nil)
    }

    @Test func recyclingRowsDoesNotAccumulateOrphanRecognizers() throws {
        let scroll = UIScrollView()
        let pinch = UIPinchGestureRecognizer()
        scroll.addGestureRecognizer(pinch)
        let originalCount = scroll.gestureRecognizers?.count

        for _ in 0..<50 {
            let host = IOSRowSwipeGestureBridge.HostView()
            var owner: IOSRowSwipeGestureBridge.Coordinator? = coordinator()
            host.coordinator = owner
            scroll.addSubview(host)
            owner?.attach(from: host)
            let recognizer = try #require(owner?.recognizer)
            weak var releasedOwner = owner

            IOSRowSwipeGestureBridge.dismantleUIView(host, coordinator: try #require(owner))
            owner = nil
            host.removeFromSuperview()

            #expect(releasedOwner == nil)
            #expect(recognizer.view == nil)
            #expect(scroll.gestureRecognizers?.count == originalCount)
            #expect(pinch.view === scroll)
        }
    }

    @Test func temporaryWindowRemovalAllowsReattachment() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scroll = UIScrollView(frame: window.bounds)
        window.addSubview(scroll)
        let host = IOSRowSwipeGestureBridge.HostView()
        let coordinator = coordinator()
        host.coordinator = coordinator
        scroll.addSubview(host)
        let first = try #require(coordinator.recognizer)

        host.removeFromSuperview()
        #expect(first.view == nil)
        #expect(host.coordinator === coordinator)

        scroll.addSubview(host)
        let second = try #require(coordinator.recognizer)
        #expect(second !== first)
        #expect(second.view === scroll)
        coordinator.attach(from: host)
        #expect(coordinator.recognizer === second)

        IOSRowSwipeGestureBridge.dismantleUIView(host, coordinator: coordinator)
        host.removeFromSuperview()
        #expect(second.view == nil)
    }
}
#endif
