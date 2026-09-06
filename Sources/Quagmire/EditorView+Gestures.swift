import SwiftUI
import os
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Gesture / interaction plumbing for EditorView: cross-platform View
// modifiers that wrap the per-platform gestures, plus the iOS UIKit
// gesture-recognizer bridges (reorder / pinch / swipe), the scroll-metrics
// reader, the page-level drop delegate, and the small geometry helpers
// (preference key, PRNG) those depend on. None of this touches Editor
// model types directly — it's all closure-based callbacks.

extension View {
    @ViewBuilder
    func iosPageBlockDropTarget(
        onUpdate: @escaping (CGFloat) -> Void,
        onDrop: @escaping (BlockDragPayload, CGFloat) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        self.onDrop(
            of: [UTType.plainText],
            delegate: PageBlockDropDelegate(
                onUpdate: onUpdate,
                onDrop: onDrop,
                onCancel: onCancel
            )
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func blockActionPopover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.popover(isPresented: isPresented) {
            content()
                #if os(iOS)
                .presentationCompactAdaptation(.popover)
                #endif
        }
    }

    @ViewBuilder
    func iosBlockTouchActions(
        isEnabled: Bool,
        configuration: EditorConfiguration,
        onDelete: @escaping () -> Void,
        onShowMenu: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        // Apply unconditionally; gate the gesture via isEnabled so the row's
        // view tree (and its layout) stays stable across pinch / edit mode
        // toggles. Swapping the modifier in/out caused per-row layout churn.
        self.modifier(IOSRowSwipeActions(
            isEnabled: isEnabled,
            configuration: configuration,
            onDelete: onDelete,
            onShowMenu: onShowMenu
        ))
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosPageReorder<ID: Hashable>(
        isEnabled: Bool,
        layoutCache: RowSurfaceLayoutCache<ID>,
        shouldBegin: @escaping (ID, CGPoint) -> Bool,
        onBegin: @escaping (ID, CGPoint) -> Void,
        onChanged: @escaping (CGPoint) -> Void,
        onEnded: @escaping (CGPoint) -> Void,
        onCancelled: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        // Apply unconditionally; gate the recognizer via isEnabled. Avoids
        // ViewBuilder branch flips on every pinch — same pattern as
        // iosPagePinch.
        self.background(
            IOSPageReorderGestureBridge(
                isEnabled: isEnabled,
                layoutCache: layoutCache,
                shouldBegin: shouldBegin,
                onBegin: onBegin,
                onChanged: onChanged,
                onEnded: onEnded,
                onCancelled: onCancelled
            )
        )
        #else
        self
        #endif
    }

    /// Unified page-level pinch: forwards every magnification update so the page
    /// can drive a live insert-gap preview, and forwards `.onEnded` so it can
    /// commit insert (open) or close-to-page-list. Replaces the prior
    /// open-on-row + close-on-page split — both directions now arbitrate
    /// through a single gesture.
    @ViewBuilder
    func iosPagePinch(
        isEnabled: Bool,
        onUpdate: @escaping (PagePinchValue) -> Void,
        onThirdFingerTap: @escaping () -> Void,
        onCommit: @escaping (PagePinchValue) -> Void
    ) -> some View {
        #if os(iOS)
        self.background(
            IOSPagePinchGestureBridge(
                isEnabled: isEnabled,
                onUpdate: onUpdate,
                onThirdFingerTap: onThirdFingerTap,
                onCommit: onCommit
            )
        )
        #else
        self
        #endif
    }

    @ViewBuilder
    func iosScrollMetrics(_ metrics: PageScrollMetrics) -> some View {
        #if os(iOS)
        self.background(IOSScrollMetricsReader(metrics: metrics))
        #else
        self
        #endif
    }

    /// macOS counterpart to `iosScrollMetrics` — wires SwiftUI's
    /// `.onScrollGeometryChange` to publish the same `PageScrollMetrics`. Pinch
    /// and reorder auto-scroll both read from this; programmatic scroll on
    /// macOS goes through `macScrollPosition` below.
    @ViewBuilder
    func macScrollMetrics(_ metrics: PageScrollMetrics) -> some View {
        #if os(macOS)
        self
            .background(MacScrollControllerReader())
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, new in
                metrics.contentOffsetY = new
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, new in
                metrics.contentHeight = new
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, new in
                metrics.viewportHeight = new
            }
        #else
        self
        #endif
    }

    /// macOS-only `.scrollPosition` binding for programmatic scroll (auto-scroll
    /// during pinch / reorder). NOT applied on iOS — there, programmatic scroll
    /// goes through the UIScrollView bridge in `PageScrollController`. Attaching
    /// `.scrollPosition` on iOS competes with that path and silently breaks it.
    @ViewBuilder
    func macScrollPosition(_ position: Binding<ScrollPosition>) -> some View {
        #if os(macOS)
        self.scrollPosition(position)
        #else
        self
        #endif
    }

    /// Tap-below-rows: clicking past the end of the document creates a fresh
    /// trailing paragraph at the document root. Cross-platform — the
    /// underlying `handleTapBelowRows` already gates on cursor position past
    /// the last row's frame, so a click anywhere in the empty trailing
    /// region triggers a new paragraph there.
    @ViewBuilder
    func tapBelowRows(_ onTap: @escaping (CGPoint) -> Void) -> some View {
        // `.gesture` (not `.simultaneousGesture`) so the enclosing ScrollView's
        // pan claims the touch first on iOS — otherwise a rubber-band pull at
        // the bottom of the page fires this tap on release and pops the keyboard.
        self.gesture(
            SpatialTapGesture()
                .onEnded { value in
                    onTap(value.location)
                }
        )
    }

    @ViewBuilder
    func iosEdgeGateNavigateBack() -> some View {
        #if os(iOS)
        self.background(IOSNavigationBackGestureGate())
        #else
        self
        #endif
    }
}

#if os(macOS)
@MainActor
final class MacPageScrollController {
    static let shared = MacPageScrollController()

    weak var scrollView: NSScrollView?

    @discardableResult
    func scroll(toY y: CGFloat) -> Bool {
        guard let scrollView else { return false }
        let clipView = scrollView.contentView
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        let maxOffset = max(0, documentHeight - clipView.bounds.height)
        let clampedY = min(maxOffset, max(0, y))
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clampedY))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }
}

private struct MacScrollControllerReader: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderView {
        ReaderView()
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.installIfNeeded()
    }

    @MainActor
    final class ReaderView: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            installDeferred()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installDeferred()
        }

        func installIfNeeded() {
            guard let scrollView = nearestScrollView() else { return }
            MacPageScrollController.shared.scrollView = scrollView
        }

        private func installDeferred() {
            installIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        private func nearestScrollView() -> NSScrollView? {
            var current = superview
            while let view = current {
                if let scrollView = view as? NSScrollView {
                    return scrollView
                }
                current = view.superview
            }
            return nil
        }
    }
}
#endif

// MARK: - Shared platform-neutral helpers

struct PagePinchValue {
    var startLocation: CGPoint
    var location: CGPoint
    var spreadDelta: CGFloat
}

struct PagePinchThirdTapGeometry {
    static func contains(_ point: CGPoint, between first: CGPoint, and second: CGPoint) -> Bool {
        let dx = second.x - first.x
        let dy = second.y - first.y
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared > 0 else { return false }

        let projection = ((point.x - first.x) * dx + (point.y - first.y) * dy) / distanceSquared
        guard projection >= 0.1, projection <= 0.9 else { return false }

        let closest = CGPoint(x: first.x + projection * dx, y: first.y + projection * dy)
        let perpendicularDistance = hypot(point.x - closest.x, point.y - closest.y)
        let fingerDistance = sqrt(distanceSquared)
        let corridorRadius = min(96, max(48, fingerDistance * 0.4))
        return perpendicularDistance <= corridorRadius
    }
}

/// Reference type so property mutations (driven by every scroll tick) don't
/// reassign `EditorView`'s `@State`-held value and invalidate `body`. The
/// gesture extensions (reorder/pinch auto-scroll) read these properties from
/// the live instance; `EditorView.body` itself never reads them.
@MainActor
final class PageScrollMetrics {
    var viewportHeight: CGFloat = 0
    var contentHeight: CGFloat = 0
    var contentOffsetY: CGFloat = 0
    /// Top + bottom adjusted-content-insets on iOS (nav bar + safe area on top,
    /// home-indicator safe area on bottom). The autoscroll edge bands are
    /// measured against the *content area* (`viewportHeight - topInset -
    /// bottomInset`), not the raw viewport: `pageLocation` already shifts y=0
    /// to "top of content area", and for the bottom band to be symmetric the
    /// edge must sit at the bottom of the content area too. Both default to 0
    /// on macOS — viewport == content area there.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
}

enum PageHoverCoordinateSpace {
    static let name = "EditorView.hover"
}

struct IOSPageReorderGeometry {
    static func pageLocation(
        forScrollViewLocation location: CGPoint,
        contentOffset: CGPoint,
        adjustedTopInset: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: location.x - contentOffset.x,
            y: location.y - effectiveScrollOffsetY(
                contentOffsetY: contentOffset.y,
                adjustedTopInset: adjustedTopInset
            )
        )
    }

    private static func effectiveScrollOffsetY(contentOffsetY: CGFloat, adjustedTopInset: CGFloat) -> CGFloat {
        max(0, contentOffsetY + adjustedTopInset)
    }
}

#if os(iOS)

/// Linear-congruential PRNG — deterministic per seed so the grain pattern
/// stays put across re-renders (and frames during animation).
struct SeededLCG {
    private var state: UInt32
    init(seed: UInt32) { self.state = seed }
    mutating func next01() -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / Double(UInt32.max)
    }
}

// MARK: - iOS UIKit bridges

struct IOSNavigationBackGestureGate: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.installWhenReady()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installWhenReady()
        }

        func installWhenReady() {
            guard let navigationController else { return }
            navigationController.interactiveContentPopGestureRecognizer?.isEnabled = false
            navigationController.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}

/// Page-level reorder gesture. Walks up to the enclosing `UIScrollView`,
/// attaches a `UILongPressGestureRecognizer` to it, and tells the scroll
/// view's pan recognizer to `require(toFail:)` it. UIKit-level coordination
/// is what lets the page scroll on a fast vertical drag (motion exceeds
/// `allowableMovement` before the timer fires → long-press fails → pan
/// proceeds) while still entering reorder on a deliberate hold (timer
/// fires within tolerance → long-press wins → pan never starts).
///
/// Prior SwiftUI implementation used `LongPressGesture.sequenced(before:
/// DragGesture(0))` per row. That triggered SwiftUI's "system gesture gate"
/// after `.first(true)` and stranded touches — no further events to either
/// the row gesture or the scroll view, leaving rows dimmed and scroll
/// blocked. Removing the SwiftUI long-press but keeping `DragGesture(0)`
/// didn't help either: `DragGesture(minimumDistance: 0)` claims the touch
/// at the SwiftUI layer and blocks the scroll view's pan even when our
/// handler ignores the events.
struct IOSPageReorderGestureBridge<ID: Hashable>: UIViewRepresentable {
    var isEnabled: Bool
    var layoutCache: RowSurfaceLayoutCache<ID>
    var shouldBegin: (ID, CGPoint) -> Bool
    var onBegin: (ID, CGPoint) -> Void
    var onChanged: (CGPoint) -> Void
    var onEnded: (CGPoint) -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(from: self)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSPageReorderGestureBridge
        weak var recognizer: UILongPressGestureRecognizer?
        weak var scrollView: UIScrollView?
        private var activeBlockID: ID?

        init(parent: IOSPageReorderGestureBridge) {
            self.parent = parent
        }

        func attach(from view: UIView) {
            guard recognizer == nil else { return }
            var current: UIView? = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
                    lp.minimumPressDuration = 0.5
                    lp.allowableMovement = 8
                    lp.cancelsTouchesInView = false
                    lp.delegate = self
                    lp.isEnabled = parent.isEnabled
                    scroll.addGestureRecognizer(lp)
                    scroll.panGestureRecognizer.require(toFail: lp)
                    self.recognizer = lp
                    self.scrollView = scroll
                    return
                }
                current = v.superview
            }
        }

        func detach() {
            if let recognizer, let scrollView {
                scrollView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
            activeBlockID = nil
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let scrollView else { return }
            let location = pageCoordinateLocation(for: recognizer, scrollView: scrollView)
            switch recognizer.state {
            case .began:
                guard let blockID = parent.layoutCache.realizedBlockIDAtPageY(location.y) else {
                    activeBlockID = nil
                    return
                }
                activeBlockID = blockID
                parent.onBegin(blockID, location)
            case .changed:
                guard activeBlockID != nil else { return }
                parent.onChanged(location)
            case .ended:
                if activeBlockID != nil {
                    parent.onEnded(location)
                }
                activeBlockID = nil
            case .cancelled, .failed:
                if activeBlockID != nil {
                    parent.onCancelled()
                }
                activeBlockID = nil
            default:
                break
            }
        }

        private func pageCoordinateLocation(
            for recognizer: UIGestureRecognizer,
            scrollView: UIScrollView
        ) -> CGPoint {
            IOSPageReorderGeometry.pageLocation(
                forScrollViewLocation: recognizer.location(in: scrollView),
                contentOffset: scrollView.contentOffset,
                adjustedTopInset: scrollView.adjustedContentInset.top
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer,
                  let scrollView else {
                return true
            }
            let location = pageCoordinateLocation(for: gestureRecognizer, scrollView: scrollView)
            guard let blockID = parent.layoutCache.realizedBlockIDAtPageY(location.y) else {
                return false
            }
            return parent.shouldBegin(blockID, location)
        }
    }
}

/// Page-level pinch gesture. Walks up to the enclosing `UIScrollView`, attaches
/// a `UIPinchGestureRecognizer` and reads the live finger positions via
/// `location(ofTouch:in:)` so we can emit the *actual* pixel distance the
/// fingers have spread. SwiftUI's `MagnifyGesture` only exposes a magnification
/// ratio, which forces a magic-number assumption about start finger distance —
/// pinch felt amplified at narrow grips and undersized at wide grips.
struct IOSPagePinchGestureBridge: UIViewRepresentable {
    var isEnabled: Bool
    var onUpdate: (PagePinchValue) -> Void
    var onThirdFingerTap: () -> Void
    var onCommit: (PagePinchValue) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
        context.coordinator.thirdTapRecognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(from: self)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSPagePinchGestureBridge
        weak var recognizer: UIPinchGestureRecognizer?
        weak var thirdTapRecognizer: ThirdFingerPinchTapRecognizer?
        weak var scrollView: UIScrollView?
        private var startDistance: CGFloat = 0
        private var startMidpoint: CGPoint = .zero

        init(parent: IOSPagePinchGestureBridge) {
            self.parent = parent
        }

        func attach(from view: UIView) {
            guard recognizer == nil else { return }
            var current: UIView? = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
                    let thirdTap = ThirdFingerPinchTapRecognizer(target: nil, action: nil)
                    thirdTap.pinchRecognizer = pinch
                    thirdTap.onThirdFingerTap = { [weak self] in
                        self?.parent.onThirdFingerTap()
                    }
                    pinch.cancelsTouchesInView = false
                    pinch.delegate = self
                    pinch.isEnabled = parent.isEnabled
                    thirdTap.cancelsTouchesInView = false
                    thirdTap.delaysTouchesBegan = false
                    thirdTap.delaysTouchesEnded = false
                    thirdTap.delegate = self
                    thirdTap.isEnabled = parent.isEnabled
                    scroll.addGestureRecognizer(pinch)
                    scroll.addGestureRecognizer(thirdTap)
                    self.recognizer = pinch
                    self.thirdTapRecognizer = thirdTap
                    self.scrollView = scroll
                    return
                }
                current = v.superview
            }
        }

        func detach() {
            if let recognizer, let scrollView {
                scrollView.removeGestureRecognizer(recognizer)
            }
            if let thirdTapRecognizer, let scrollView {
                scrollView.removeGestureRecognizer(thirdTapRecognizer)
            }
            recognizer = nil
            thirdTapRecognizer = nil
            scrollView = nil
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let scrollView else { return }
            switch recognizer.state {
            case .began:
                guard recognizer.numberOfTouches >= 2 else { return }
                let p0 = recognizer.location(ofTouch: 0, in: scrollView)
                let p1 = recognizer.location(ofTouch: 1, in: scrollView)
                startDistance = hypot(p0.x - p1.x, p0.y - p1.y)
                let midScroll = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                startMidpoint = pageCoordinateLocation(for: midScroll, scrollView: scrollView)
                parent.onUpdate(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: startDistance))
            case .changed:
                let distance = currentDistance(recognizer: recognizer, scrollView: scrollView)
                parent.onUpdate(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: distance))
            case .ended, .cancelled, .failed:
                let distance = currentDistance(recognizer: recognizer, scrollView: scrollView)
                parent.onCommit(makeValue(recognizer: recognizer, scrollView: scrollView, currentDistance: distance))
            default:
                break
            }
        }

        private func currentDistance(recognizer: UIPinchGestureRecognizer, scrollView: UIScrollView) -> CGFloat {
            guard recognizer.numberOfTouches >= 2 else {
                // One finger lifted before .ended — fall back to scale × startDistance.
                return startDistance * recognizer.scale
            }
            let p0 = recognizer.location(ofTouch: 0, in: scrollView)
            let p1 = recognizer.location(ofTouch: 1, in: scrollView)
            return hypot(p0.x - p1.x, p0.y - p1.y)
        }

        private func makeValue(
            recognizer: UIPinchGestureRecognizer,
            scrollView: UIScrollView,
            currentDistance: CGFloat
        ) -> PagePinchValue {
            let midScroll: CGPoint
            if recognizer.numberOfTouches >= 2 {
                let p0 = recognizer.location(ofTouch: 0, in: scrollView)
                let p1 = recognizer.location(ofTouch: 1, in: scrollView)
                midScroll = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
            } else {
                midScroll = recognizer.location(in: scrollView)
            }
            let midPage = pageCoordinateLocation(for: midScroll, scrollView: scrollView)
            return PagePinchValue(
                startLocation: startMidpoint,
                location: midPage,
                spreadDelta: currentDistance - startDistance
            )
        }

        private func pageCoordinateLocation(
            for scrollLocation: CGPoint,
            scrollView: UIScrollView
        ) -> CGPoint {
            IOSPageReorderGeometry.pageLocation(
                forScrollViewLocation: scrollLocation,
                contentOffset: scrollView.contentOffset,
                adjustedTopInset: scrollView.adjustedContentInset.top
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// A sibling observer for the third touch. `UIPinchGestureRecognizer` does not
/// reliably deliver touches beyond the two it chose for the pinch, so trying
/// to observe the tap from a pinch subclass misses it on device. This gesture
/// never recognizes or prevents anything; it watches the same raw touch stream
/// and emits a callback when an extra touch completes as a tap.
@MainActor
final class ThirdFingerPinchTapRecognizer: UIGestureRecognizer {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Quagmire",
        category: "pinch"
    )

    var onThirdFingerTap: (() -> Void)?
    weak var pinchRecognizer: UIPinchGestureRecognizer?

    private var primaryTouches: [UITouch] = []
    private weak var thirdTouch: UITouch?
    private var thirdTouchStart: CGPoint = .zero
    private var thirdTouchStartTime: TimeInterval = 0
    private var thirdTouchStayedInside = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if primaryTouches.count < 2 {
                primaryTouches.append(touch)
            } else if thirdTouch == nil, let view {
                let point = touch.location(in: view)
                guard pinchIsActive else {
                    Self.logger.debug("extra touch ignored because pinch is not active")
                    continue
                }
                guard pointIsBetweenPrimaryTouches(point, in: view) else {
                    Self.logger.debug(
                        "extra touch outside pinch gap at x=\(point.x, privacy: .public) y=\(point.y, privacy: .public)"
                    )
                    continue
                }
                thirdTouch = touch
                thirdTouchStart = point
                thirdTouchStartTime = touch.timestamp
                thirdTouchStayedInside = true
                Self.logger.debug(
                    "third-finger candidate began at x=\(point.x, privacy: .public) y=\(point.y, privacy: .public)"
                )
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let thirdTouch, touches.contains(thirdTouch), let view {
            let point = thirdTouch.location(in: view)
            if hypot(point.x - thirdTouchStart.x, point.y - thirdTouchStart.y) > 18
                || !pointIsBetweenPrimaryTouches(point, in: view) {
                if thirdTouchStayedInside {
                    Self.logger.debug("third-finger candidate rejected after moving")
                }
                thirdTouchStayedInside = false
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let completedTap: Bool
        if let thirdTouch, touches.contains(thirdTouch), let view {
            let point = thirdTouch.location(in: view)
            let duration = thirdTouch.timestamp - thirdTouchStartTime
            let movement = hypot(point.x - thirdTouchStart.x, point.y - thirdTouchStart.y)
            completedTap = thirdTouchStayedInside
                && duration <= 0.35
                && movement <= 18
                && pointIsBetweenPrimaryTouches(point, in: view)
            Self.logger.debug(
                "third-finger candidate ended accepted=\(completedTap, privacy: .public) duration=\(duration, privacy: .public) movement=\(movement, privacy: .public)"
            )
            clearThirdTouch()
        } else {
            completedTap = false
        }
        if completedTap { onThirdFingerTap?() }
        finishIfPrimaryTouchEnded(in: touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let thirdTouch, touches.contains(thirdTouch) {
            clearThirdTouch()
        }
        finishIfPrimaryTouchEnded(in: touches)
    }

    override func reset() {
        super.reset()
        primaryTouches.removeAll(keepingCapacity: true)
        clearThirdTouch()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    private var pinchIsActive: Bool {
        pinchRecognizer?.state == .began || pinchRecognizer?.state == .changed
    }

    private func pointIsBetweenPrimaryTouches(_ point: CGPoint, in view: UIView) -> Bool {
        guard primaryTouches.count == 2 else { return false }
        return PagePinchThirdTapGeometry.contains(
            point,
            between: primaryTouches[0].location(in: view),
            and: primaryTouches[1].location(in: view)
        )
    }

    private func clearThirdTouch() {
        thirdTouch = nil
        thirdTouchStart = .zero
        thirdTouchStartTime = 0
        thirdTouchStayedInside = false
    }

    private func finishIfPrimaryTouchEnded(in touches: Set<UITouch>) {
        guard primaryTouches.contains(where: { primary in
            touches.contains(where: { $0 === primary })
        }) else { return }
        state = .failed
    }
}

struct PageBlockDropDelegate: DropDelegate {
    let onUpdate: (CGFloat) -> Void
    let onDrop: (BlockDragPayload, CGFloat) -> Void
    let onCancel: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onUpdate(info.location.y)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onCancel()
    }

    func performDrop(info: DropInfo) -> Bool {
        let y = info.location.y
        let dropSpring = Animation.spring(response: 0.26, dampingFraction: 0.76)

        guard let provider = info.itemProviders(for: [UTType.plainText]).first else {
            withAnimation(dropSpring) { onCancel() }
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString,
                  let payload = BlockDragPayload(jsonString: string as String) else {
                Task { @MainActor in
                    withAnimation(dropSpring) { onCancel() }
                }
                return
            }
            Task { @MainActor in
                withAnimation(dropSpring) {
                    onDrop(payload, y)
                    onCancel()
                }
            }
        }
        return true
    }
}

@MainActor
final class PageScrollController {
    static let shared = PageScrollController()

    weak var scrollView: UIScrollView?

    func scroll(toY y: CGFloat) {
        guard let scrollView else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
    }
}

struct IOSScrollMetricsReader: UIViewRepresentable {
    let metrics: PageScrollMetrics

    func makeCoordinator() -> Coordinator {
        Coordinator(metrics: metrics)
    }

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        context.coordinator.metrics = metrics
        uiView.coordinator = context.coordinator
        uiView.installIfNeeded()
    }

    @MainActor
    final class ReaderView: UIView {
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            isUserInteractionEnabled = false
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            installIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            installIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.installIfNeeded()
            }
        }

        func installIfNeeded() {
            guard let scrollView = nearestScrollView() else {
                // NSLog("[REORDER-AS] metrics reader: nearestScrollView returned nil")
                return
            }
            // NSLog("[REORDER-AS] metrics reader: attached to scrollView bounds=%@ adjustedInset=(t:%f b:%f)", NSCoder.string(for: scrollView.bounds), scrollView.adjustedContentInset.top, scrollView.adjustedContentInset.bottom)
            PageScrollController.shared.scrollView = scrollView
            coordinator?.update(from: scrollView)
        }

        private func nearestScrollView() -> UIScrollView? {
            var current = superview
            while let view = current {
                if let scrollView = view as? UIScrollView {
                    return scrollView
                }
                current = view.superview
            }
            return nil
        }
    }

    @MainActor
    final class Coordinator {
        var metrics: PageScrollMetrics
        private weak var observedScrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?

        init(metrics: PageScrollMetrics) {
            self.metrics = metrics
        }

        func update(from scrollView: UIScrollView) {
            if observedScrollView !== scrollView {
                observedScrollView = scrollView
                observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
                boundsObservation = scrollView.observe(\.bounds, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
                contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak scrollView] _, _ in
                    Task { @MainActor in
                        guard let self, let scrollView else { return }
                        self.publish(scrollView)
                    }
                }
            }
            // updateUIView / didMoveToWindow run inside SwiftUI's view-update pass —
            // writing the binding synchronously here trips "Modifying state during
            // view update" and a matching AttributeGraph cycle. Defer like the KVO
            // observers do.
            Task { @MainActor [weak self, weak scrollView] in
                guard let self, let scrollView else { return }
                self.publish(scrollView)
            }
        }

        private func publish(_ scrollView: UIScrollView) {
            metrics.viewportHeight = scrollView.bounds.height
            metrics.contentHeight = scrollView.contentSize.height
            metrics.contentOffsetY = scrollView.contentOffset.y
            metrics.topInset = scrollView.adjustedContentInset.top
            metrics.bottomInset = scrollView.adjustedContentInset.bottom
            // NSLog("[REORDER-AS] metrics publish viewport=%f content=%f offsetY=%f topInset=%f bottomInset=%f", metrics.viewportHeight, metrics.contentHeight, metrics.contentOffsetY, metrics.topInset, metrics.bottomInset)
        }
    }
}

/// Horizontal-swipe actions on a row: leading swipe (right) reveals an
/// `ellipsis.circle.fill` glyph and, past the trigger, opens the row's
/// action sheet. Trailing swipe (left) deletes. SwiftUI's `.swipeActions`
/// only fires inside a `List`, but the page is built on a `VStack` to keep
/// typography control, so this is a manual horizontal pan that tracks the
/// row offset, reveals per-edge action labels, and commits past a threshold.
///
/// The pan is a UIKit bridge rather than a SwiftUI `DragGesture` because
/// SwiftUI drag gestures claim the touch at the SwiftUI layer once their
/// minimum distance is crossed in *any* direction; the page's UIScrollView
/// pan can then never start, killing scrolls that began on a row. Same
/// failure mode the page-reorder bridge documents above. The bridge here
/// installs a `UIPanGestureRecognizer` on the enclosing scroll view and
/// fails it at `gestureRecognizerShouldBegin` time when initial motion is
/// vertical-dominant — releasing the touch back to the scroll view's pan.
struct IOSRowSwipeActions: ViewModifier {
    let isEnabled: Bool
    let configuration: EditorConfiguration
    let onDelete: () -> Void
    let onShowMenu: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var triggered: Bool = false
    @State private var crossedDeleteThreshold: Bool = false

    private let trigger: CGFloat = 96
    private let revealCap: CGFloat = 140

    func body(content: Content) -> some View {
        let rightOffset = min(revealCap, max(0, dragOffset))
        let revealProgress = min(1, rightOffset / trigger)
        let deleteProgress = min(1, max(0, -dragOffset) / trigger)

        let crossed = revealProgress >= 1
        let iconSize: CGFloat = crossed ? 26 : 14 + (revealProgress * 8)

        let isSwiping = revealProgress > 0

        // Layout intent: row size is determined by typography (BlockSpacing /
        // BlockRow's intrinsic padding), NOT by these affordances. Icon goes
        // BEHIND content via .background so its 34pt capsule doesn't propagate
        // upward — overflowing visually if the row is shorter is fine and only
        // happens transiently during a swipe. Pencil line goes ON TOP via
        // .overlay, sized to content.
        content
            .background(isSwiping ? configuration.theme.background : Color.clear)
            .background(alignment: .leading) {
                if isSwiping {
                    ZStack {
                        Capsule()
                            .fill(Color.blue.opacity(0.18))
                            .frame(width: 44, height: 34)
                            .opacity(crossed ? 1 : 0)
                            .scaleEffect(crossed ? 1 : 0.6)

                        Image(systemName: "ellipsis")
                            .foregroundStyle(crossed ? Color.blue : Color.blue.opacity(0.65))
                            .font(.system(size: iconSize, weight: .semibold))
                    }
                    .padding(.leading, 4)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: crossed)
                    .allowsHitTesting(false)
                }
            }
            .offset(x: rightOffset)
            .overlay {
                GeometryReader { geo in
                    pencilLine(
                        rowWidth: geo.size.width,
                        lineLength: geo.size.width * deleteProgress
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .allowsHitTesting(false)
            }
            .background {
                IOSRowSwipeGestureBridge(
                    isEnabled: isEnabled,
                    onChanged: { h in
                        guard !triggered else { return }
                        dragOffset = h
                        // The menu opens on threshold-crossed mid-gesture so the
                        // user can swipe-and-hold to peek the menu. Delete is
                        // destructive — only commits on release, but fire a haptic
                        // when the strike-through completes so the user knows
                        // releasing now will commit.
                        if h >= trigger {
                            fire(onShowMenu)
                        } else if h <= -trigger {
                            if !crossedDeleteThreshold {
                                crossedDeleteThreshold = true
                                Haptics.medium(enabled: configuration.isHapticFeedbackEnabled)
                            }
                        } else {
                            crossedDeleteThreshold = false
                        }
                    },
                    onEnded: { h in
                        if !triggered, h <= -trigger {
                            onDelete()
                            SoundFX.play(.delete, enabled: configuration.isAudioFeedbackEnabled)
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            dragOffset = 0
                        }
                        triggered = false
                        crossedDeleteThreshold = false
                    },
                    onCancelled: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            dragOffset = 0
                        }
                        triggered = false
                        crossedDeleteThreshold = false
                    }
                )
            }
            // Disabling the gesture mid-swipe (e.g. when a pinch starts) needs
            // to also reset the visual swipe state — otherwise a partially-
            // offset row stays offset until the user touches it again.
            .onChange(of: isEnabled) { _, newValue in
                guard !newValue else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    dragOffset = 0
                }
                triggered = false
                crossedDeleteThreshold = false
            }
    }

    private func fire(_ action: () -> Void) {
        triggered = true
        Haptics.medium(enabled: configuration.isHapticFeedbackEnabled)
        action()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            dragOffset = 0
        }
    }

    /// A graphite-style cross-out line drawn in a `Canvas`. Composited from a
    /// soft halo, a crisp core, and a deterministic scatter of grain dots that
    /// simulate the graphite catching on tooth of the paper. The grain pattern
    /// is keyed off a fixed seed so it stays put as the line extends — only the
    /// trailing-aligned mask grows with `lineLength`. At commit the stroke
    /// thickens/darkens and grain density bumps, like the pencil pressed harder.
    @ViewBuilder
    private func pencilLine(rowWidth: CGFloat, lineLength: CGFloat) -> some View {
        let armed = crossedDeleteThreshold
        let coreColor = Color(white: 0.18)
        let coreHeight: CGFloat = armed ? 2.4 : 1.6
        let coreOpacity: Double = armed ? 0.92 : 0.72
        let haloHeight: CGFloat = armed ? 6 : 4
        let haloOpacity: Double = armed ? 0.22 : 0.12
        let grainSpacing: CGFloat = armed ? 0.8 : 1.3
        let grainBoost: Double = armed ? 0.18 : 0

        Canvas { context, size in
            let centerY = size.height / 2

            let halo = Path(CGRect(
                x: 0, y: centerY - haloHeight / 2,
                width: size.width, height: haloHeight
            ))
            context.fill(halo, with: .color(coreColor.opacity(haloOpacity)))

            let core = Path(CGRect(
                x: 0, y: centerY - coreHeight / 2,
                width: size.width, height: coreHeight
            ))
            context.fill(core, with: .color(coreColor.opacity(coreOpacity)))

            var rng = SeededLCG(seed: 0xF1B2C3D4)
            let grainCount = Int(size.width / grainSpacing)
            for _ in 0..<grainCount {
                let x = CGFloat(rng.next01()) * size.width
                let yJitter = (CGFloat(rng.next01()) - 0.5) * 7
                let r = 0.25 + CGFloat(rng.next01()) * 0.7
                let opacity = 0.12 + rng.next01() * 0.42 + grainBoost
                let dot = Path(ellipseIn: CGRect(
                    x: x - r, y: centerY + yJitter - r,
                    width: r * 2, height: r * 2
                ))
                context.fill(dot, with: .color(coreColor.opacity(opacity)))
            }
        }
        .frame(width: rowWidth, height: 12)
        .mask(alignment: .trailing) {
            Color.black.frame(width: lineLength)
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: armed)
    }
}

/// UIKit-bridged horizontal pan, scoped to one row, used by `IOSRowSwipeActions`.
/// Walks up to the enclosing `UIScrollView` and installs a
/// `UIPanGestureRecognizer` on it; gates recognition at begin time on
/// (a) initial touch landing within this row's host view and (b) translation
/// being horizontal-dominant. A vertical-dominant touch fails the recognizer,
/// releasing the touch to the scroll view's pan so the page can scroll.
struct IOSRowSwipeGestureBridge: UIViewRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void
    var onCancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = HostView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recognizer?.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class HostView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                coordinator?.attach(from: self)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: IOSRowSwipeGestureBridge
        weak var recognizer: UIPanGestureRecognizer?
        weak var scrollView: UIScrollView?
        weak var hostView: UIView?

        init(parent: IOSRowSwipeGestureBridge) {
            self.parent = parent
        }

        func attach(from view: UIView) {
            guard recognizer == nil else { return }
            self.hostView = view
            var current: UIView? = view.superview
            while let v = current {
                if let scroll = v as? UIScrollView {
                    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
                    pan.cancelsTouchesInView = false
                    pan.maximumNumberOfTouches = 1
                    pan.delegate = self
                    pan.isEnabled = parent.isEnabled
                    scroll.addGestureRecognizer(pan)
                    self.recognizer = pan
                    self.scrollView = scroll
                    return
                }
                current = v.superview
            }
        }

        func detach() {
            if let recognizer, let scrollView {
                scrollView.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            scrollView = nil
            hostView = nil
        }

        @objc func handlePan(_ rec: UIPanGestureRecognizer) {
            let t = rec.translation(in: rec.view)
            switch rec.state {
            case .changed:
                parent.onChanged(t.x)
            case .ended:
                parent.onEnded(t.x)
            case .cancelled, .failed:
                parent.onCancelled()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === recognizer,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let host = hostView else {
                return true
            }
            // Initial touch must be on this row.
            let p = pan.location(in: host)
            guard host.bounds.contains(p) else { return false }
            // Initial motion must be horizontal-dominant — otherwise fail and
            // let the scroll view's pan take the touch.
            let t = pan.translation(in: host)
            return abs(t.x) > abs(t.y) * 1.4
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

#endif
