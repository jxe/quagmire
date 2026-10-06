import SwiftUI
import UniformTypeIdentifiers

private enum RowSurfaceInternalCoordinateSpace {
    static let name = "RowSurface.internal"
}

/// Render/layout facts for one row in a `RowSurface`.
///
/// This type is deliberately content-agnostic: no `Block`, no editor state, no
/// closures. Semantic rendering and mutation stay in the adapter above.
struct RowSurfaceRow<ID: Hashable>: Equatable {
    let id: ID
    let slot: Int
    let depth: Int
    let spacingBefore: CGFloat
    let pinchGap: CGFloat
    let reorderGap: CGFloat
    let isSourceDimmed: Bool
}

/// Geometry needed for placing the floating reorder lift. The content itself
/// is supplied by `liftContent`, so row semantics stay above the surface.
struct RowSurfaceLift<ID: Hashable>: Equatable {
    let id: ID
    let sourceFrame: CGRect
    let sourceEffectiveOffsetY: CGFloat
    let sourceInternalMinY: CGFloat
    let touchOffset: CGSize
    let location: CGPoint
    /// Where the source row would begin in the source-removed projection.
    /// Nil when the source remains rendered (for example Option-copy).
    let projectedSourceSlot: Int?
    let projectedSourceTopGap: CGFloat
    /// The source slot was installed as the initial destination before the
    /// source-removing layout pass, so that pass must not resolve it again
    /// against already-collapsed rows.
    let hasSeededDropTarget: Bool
}

/// A released lift gliding to rest. After a drop or cancel the overlay moves
/// from where it was released onto its row, which stays hidden until the
/// overlay lands, then the row takes over.
struct RowSurfaceSettle<ID: Hashable>: Equatable {
    /// Lift content to keep rendering while settling.
    let id: ID
    let size: CGSize
    /// Unit point under the finger; the lift scales around it.
    let anchor: UnitPoint
    let releaseCenter: CGPoint
    /// Row the lift lands on. Nil fades the lift out where it was released.
    let destinationID: ID?
    /// The lifted rows are going out of view (into a collapsed section or
    /// another page), so the lift shrinks away into the destination row
    /// instead of covering it.
    let fadesOut: Bool
    let token: UUID
}

/// Lift-time scale and shadow: enough to read as the row picked up off the
/// page, not a separate card.
private enum ReorderLiftStyle {
    static let liftedScale: CGFloat = 1.03
    static let shadowOpacity: Double = 0.10
    static let shadowRadius: CGFloat = 14
    static let shadowY: CGFloat = 6
    static let pickup = Animation.smooth(duration: 0.2)
    static let landing = Animation.smooth(duration: 0.24)
    /// iOS hold-to-lift hint: a full-width tint that deepens over the rest
    /// of the long-press delay, so the hold reads as progressing.
    static let pressHintFill = Color.primary.opacity(0.07)
    static let pressHintIn = Animation.easeIn(duration: 0.35)
    static let pressHintOut = Animation.easeOut(duration: 0.15)
}

private struct RowSurfaceOrder<ID: Hashable>: Equatable {
    let ids: [ID]
    let topGaps: [ID: CGFloat]
    let reorderGaps: [ID: CGFloat]

    init(rows: [RowSurfaceRow<ID>]) {
        self.ids = rows.map(\.id)
        self.topGaps = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.id, row.spacingBefore + row.pinchGap + row.reorderGap)
        })
            .compactMapValues { $0 > 0 ? $0 : nil }
        self.reorderGaps = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.id, row.reorderGap)
        })
            .compactMapValues { $0 > 0 ? $0 : nil }
    }
}

/// Gap open/close while a reorder hole moves between slots. Critically
/// damped: layout that overshoots reads as wobbly under a held finger.
private let reorderGapAnimation = Animation.smooth(duration: 0.26)

func reorderAnchorPreservingOffset(
    sourceEffectiveOffset: CGFloat,
    sourceInternalMinY: CGFloat,
    projectedInternalMinY: CGFloat
) -> CGFloat {
    max(0, sourceEffectiveOffset + projectedInternalMinY - sourceInternalMinY)
}

func reorderEffectiveScrollOffset(rawOffset: CGFloat, topInset: CGFloat) -> CGFloat {
    max(0, rawOffset + topInset)
}

func reorderRawScrollOffset(effectiveOffset: CGFloat, topInset: CGFloat) -> CGFloat {
    max(0, effectiveOffset) - topInset
}

func reorderContentOriginAfterOffsetChange(
    currentOrigin: CGFloat,
    oldOffset: CGFloat,
    newOffset: CGFloat
) -> CGFloat {
    currentOrigin - (newOffset - oldOffset)
}

/// One stable action boundary for `RowSurface`. Rows store no callbacks; the
/// surface maps gestures/hit-tests to IDs and coordinates, then calls these
/// top-level closures.
struct RowSurfaceActions<ID: Hashable> {
    var onHover: (ID?) -> Void = { _ in }
    var onTapRow: (ID, CGPoint) -> Void = { _, _ in }
    var onTapGutter: (ID) -> Void = { _ in }
    var onTapBelowRows: (CGPoint) -> Void = { _ in }

    var onReorderBegin: (ID, _ location: CGPoint, _ anchor: CGPoint) -> Void = { _, _, _ in }
    var shouldBeginIOSReorder: (ID, CGPoint) -> Bool = { _, _ in true }
    var onReorderChanged: (_ location: CGPoint, _ anchor: CGPoint) -> Void = { _, _ in }
    var onReorderEnded: (CGPoint) -> Void = { _ in }
    var onReorderCancelled: () -> Void = {}
    var onReorderAutoscroll: (CGPoint) -> Void = { _ in }
    /// The settle overlay with this token has landed; clear it.
    var onReorderSettled: (UUID) -> Void = { _ in }
    /// iOS: a row is being held and may lift (nil when the hold ends).
    var onReorderPressHint: (ID?) -> Void = { _ in }

    /// Return true when the pinch has crossed the editor's semantic threshold
    /// and should drive edge autoscroll.
    var onPinchUpdate: (PagePinchValue) -> Bool = { _ in false }
    var onPinchCommit: (PagePinchValue) -> Void = { _ in }

    var onExternalDropUpdate: (CGFloat) -> Void = { _ in }
    var onExternalDrop: (_ plainTextPayload: String, _ y: CGFloat) -> Void = { _, _ in }
    var onExternalDropCancel: () -> Void = {}
}

/// Bare row surface: scroll container, row measurement, page-level gestures,
/// gaps, hover hit-testing, autoscroll, and lift placement.
struct RowSurface<ID: Hashable, RowContent: View, LiftContent: View>: View {
    let rows: [RowSurfaceRow<ID>]
    let layoutCache: RowSurfaceLayoutCache<ID>
    let maxContentWidth: CGFloat
    let horizontalPadding: CGFloat
    let topPadding: CGFloat
    let gutterWidth: CGFloat
    let trailingDropHeight: CGFloat
    let activeLift: RowSurfaceLift<ID>?
    let settle: RowSurfaceSettle<ID>?
    let scrollMetrics: PageScrollMetrics
    let topOverscrollAction: EditorTopOverscrollAction?
    @Binding var scrollPosition: ScrollPosition
    let isIOSReorderEnabled: Bool
    let isMacReorderEnabled: Bool
    let isPinchEnabled: Bool
    let pinchPreviewSlot: Int?
    let pinchPreviewMinimumHeight: CGFloat
    let pinchPreview: AnyView?
    let footer: AnyView?
    let header: AnyView?
    let expandedAccessoryRows: Set<ID>
    let accessoryLaneWidth: CGFloat
    let rowMarker: (ID) -> AnyView?
    let rowAccessory: (ID) -> AnyView?
    let actions: RowSurfaceActions<ID>
    let rowContent: (ID) -> RowContent
    /// `isLanding` turns true when a settling lift starts moving onto its
    /// destination, so the content can animate to its destination styling.
    let liftContent: (ID, CGSize, _ isLanding: Bool) -> LiftContent

    @State private var pinchAutoScroll = FrameTicker()
    @State private var pinchAutoScrollVelocity: CGFloat = 0
    @State private var reorderAutoScroll = FrameTicker()
    @State private var reorderAutoScrollVelocity: CGFloat = 0
    @State private var pressHintID: ID?
    /// When the last reorder gesture ended. The finger that lifted a row
    /// also completes a tap when it comes up, so taps in this window belong
    /// to the reorder, not to a row.
    @State private var lastReorderEnd: ContinuousClock.Instant?
    @State private var activeReorderLocation: CGPoint?
    @State private var hoveredRowID: ID?
    /// Where the current settle lands, once measured; animating this in
    /// moves the lift onto its row.
    @State private var settleLanding: ReorderSettleLanding?

    init(
        rows: [RowSurfaceRow<ID>],
        layoutCache: RowSurfaceLayoutCache<ID>,
        maxContentWidth: CGFloat,
        horizontalPadding: CGFloat,
        topPadding: CGFloat = 32,
        gutterWidth: CGFloat,
        trailingDropHeight: CGFloat,
        activeLift: RowSurfaceLift<ID>?,
        settle: RowSurfaceSettle<ID>? = nil,
        scrollMetrics: PageScrollMetrics,
        topOverscrollAction: EditorTopOverscrollAction? = nil,
        scrollPosition: Binding<ScrollPosition>,
        isIOSReorderEnabled: Bool,
        isMacReorderEnabled: Bool,
        isPinchEnabled: Bool,
        pinchPreviewSlot: Int? = nil,
        pinchPreviewMinimumHeight: CGFloat = 0,
        pinchPreview: AnyView? = nil,
        footer: AnyView? = nil,
        header: AnyView? = nil,
        expandedAccessoryRows: Set<ID> = [],
        accessoryLaneWidth: CGFloat = 0,
        rowMarker: @escaping (ID) -> AnyView? = { _ in nil },
        rowAccessory: @escaping (ID) -> AnyView? = { _ in nil },
        actions: RowSurfaceActions<ID>,
        @ViewBuilder rowContent: @escaping (ID) -> RowContent,
        @ViewBuilder liftContent: @escaping (ID, CGSize, _ isLanding: Bool) -> LiftContent
    ) {
        self.rows = rows
        self.layoutCache = layoutCache
        self.maxContentWidth = maxContentWidth
        self.horizontalPadding = horizontalPadding
        self.topPadding = topPadding
        self.gutterWidth = gutterWidth
        self.trailingDropHeight = trailingDropHeight
        self.activeLift = activeLift
        self.settle = settle
        self.scrollMetrics = scrollMetrics
        self.topOverscrollAction = topOverscrollAction
        self._scrollPosition = scrollPosition
        self.isIOSReorderEnabled = isIOSReorderEnabled
        self.isMacReorderEnabled = isMacReorderEnabled
        self.isPinchEnabled = isPinchEnabled
        self.pinchPreviewSlot = pinchPreviewSlot
        self.pinchPreviewMinimumHeight = pinchPreviewMinimumHeight
        self.pinchPreview = pinchPreview
        self.footer = footer
        self.header = header
        self.expandedAccessoryRows = expandedAccessoryRows
        self.accessoryLaneWidth = accessoryLaneWidth
        self.rowMarker = rowMarker; self.rowAccessory = rowAccessory
        self.actions = actions
        self.rowContent = rowContent
        self.liftContent = liftContent
    }

    var body: some View {
        let rowOrder = RowSurfaceOrder(rows: rows)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) { header }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layoutCache.setHeaderHeight($0) }
                ForEach(rows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 0) {
                    pinchPreviewView(at: row.slot)
                    rowContent(row.id)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newHeight in
                            layoutCache.setHeight(newHeight, for: row.id)
                        }
                        .background {
                            GeometryReader { proxy in
                                let frame = proxy.frame(in: .named(RowSurfaceInternalCoordinateSpace.name))
                                Color.clear
                                    // Lazy rows can reappear at the same stack-local
                                    // frame. Geometry changes alone cannot restore an
                                    // entry removed when the row disappeared.
                                    .onAppear {
                                        layoutCache.setRealizedInternalFrame(frame, for: row.id)
                                    }
                                    .onChange(of: frame) { _, frame in
                                        layoutCache.setRealizedInternalFrame(frame, for: row.id)
                                    }
                                    .onDisappear {
                                        layoutCache.removeRealizedInternalFrame(for: row.id)
                                    }
                            }
                            .allowsHitTesting(false)
                        }
                        .overlay(alignment: .topTrailing) {
                            rowMarker(row.id).frame(width: accessoryLaneWidth).offset(x: accessoryLaneWidth)
                        }
                        .padding(
                            .top,
                            row.spacingBefore
                                + (pinchPreviewSlot == row.slot ? 0 : row.pinchGap)
                                + row.reorderGap
                        )
                        .opacity(rowOpacity(row))
                        .animation(reorderGapAnimation, value: row.reorderGap)
                    VStack(spacing: 0) { rowAccessory(row.id) }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            layoutCache.setAccessoryHeight($0, for: row.id)
                        }
                    }
                }
                pinchPreviewView(at: rows.count)
                trailingDropTarget
                if let footer {
                    footer
                }
            }
            .coordinateSpace(name: RowSurfaceInternalCoordinateSpace.name)
            // Associate each row's `BlockID` (the ForEach id) with its laid-out
            // view so `scrollPosition.scrollTo(id:)` can resolve a target that
            // hasn't been measured into the layout cache yet — i.e. a cursor
            // that nav walked onto an off-screen, not-yet-materialized block.
            // Without this the id-scroll fallback in `ensureCursorVisible` is a
            // no-op/jump.
            .scrollTargetLayout()
            .onChange(of: expandedAccessoryRows, initial: true) { _, ids in layoutCache.retainAccessoryHeights(for: ids) }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(PageHoverCoordinateSpace.name))
            } action: { rect in
                layoutCache.contentOriginX = rect.minX
                layoutCache.contentOriginY = rect.minY
                layoutCache.contentWidth = rect.width
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            .padding(.trailing, accessoryLaneWidth)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .frame(maxWidth: .infinity, alignment: .center)
            .iosPageReorder(
                isEnabled: isIOSReorderEnabled,
                layoutCache: layoutCache,
                shouldBegin: { id, point in
                    guard !layoutCache.isAccessoryAtY(point.y),
                          point.x <= layoutCache.contentOriginX + layoutCache.contentWidth else { return false }
                    return actions.shouldBeginIOSReorder(id, point)
                },
                onBegin: { id, location in
                    activeReorderLocation = location
                    // The lift replaces the hint in the same frame.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { pressHintID = nil }
                    actions.onReorderBegin(id, location, location)
                    updateReorderAutoScroll(for: location)
                },
                onChanged: { location in
                    activeReorderLocation = location
                    actions.onReorderChanged(location, location)
                    updateReorderAutoScroll(for: location)
                },
                onEnded: { location in
                    activeReorderLocation = nil
                    lastReorderEnd = .now
                    stopReorderAutoScroll()
                    actions.onReorderEnded(location)
                },
                onCancelled: {
                    activeReorderLocation = nil
                    lastReorderEnd = .now
                    stopReorderAutoScroll()
                    actions.onReorderCancelled()
                },
                onPressHint: { id in
                    actions.onReorderPressHint(id)
                    withAnimation(id == nil ? ReorderLiftStyle.pressHintOut : ReorderLiftStyle.pressHintIn) {
                        pressHintID = id
                    }
                }
            )
            .iosPagePinch(
                isEnabled: isPinchEnabled,
                shouldBegin: { point in
                    !layoutCache.isAccessoryAtY(point.y) &&
                    (accessoryLaneWidth == 0 || point.x <= layoutCache.contentOriginX + layoutCache.contentWidth)
                },
                onUpdate: { value in
                    if actions.onPinchUpdate(value) {
                        updatePinchAutoScroll(for: value.location)
                    } else {
                        stopPinchAutoScroll()
                    }
                },
                onCommit: { value in
                    stopPinchAutoScroll()
                    actions.onPinchCommit(value)
                }
            )
            .iosScrollMetrics(scrollMetrics, topOverscrollAction: topOverscrollAction)
        }
        .coordinateSpace(name: PageHoverCoordinateSpace.name)
        .background(alignment: .topLeading) {
            pressHintBand
        }
        .iosPageTextDropTarget(
            onUpdate: actions.onExternalDropUpdate,
            onDrop: actions.onExternalDrop,
            onCancel: actions.onExternalDropCancel
        )
        .macScrollMetrics(scrollMetrics)
        .macScrollPosition($scrollPosition)
        #if os(macOS)
        .macPageDragReorder(
            layoutCache: layoutCache,
            gutterWidth: gutterWidth,
            isReorderEnabled: isMacReorderEnabled,
            onBegan: { id, location, anchor in
                activeReorderLocation = location
                actions.onReorderBegin(id, location, anchor)
                updateReorderAutoScroll(for: location)
            },
            onChanged: { location, anchor in
                activeReorderLocation = location
                actions.onReorderChanged(location, anchor)
                updateReorderAutoScroll(for: location)
            },
            onEnded: { location in
                activeReorderLocation = nil
                lastReorderEnd = .now
                stopReorderAutoScroll()
                actions.onReorderEnded(location)
            }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                // Hit the rendered row, not a prefix sum of potentially stale
                // heights from rows outside the LazyVStack materialization window.
                updateHover(layoutCache.realizedBlockIDAtPageY(location.y))
            case .ended:
                updateHover(nil)
            }
        }
        #endif
        .tapBelowRows { point in
            handlePageLevelTap(at: point)
        }
        .overlay(alignment: .topLeading) {
            liftOverlay
        }
        .onDisappear {
            updateHover(nil)
            stopPinchAutoScroll()
            stopReorderAutoScroll()
        }
        .onAppear {
            applyRowOrder(rowOrder)
        }
        .task(id: settle?.token) {
            await landSettle()
        }
        .onChange(of: rowOrder) { oldValue, newValue in
            applyRowOrder(newValue)
            if oldValue.ids != newValue.ids {
                finishReorderProjectionChange()
            }
        }
    }

    @ViewBuilder
    private func pinchPreviewView(at slot: Int) -> some View {
        if pinchPreviewSlot == slot, let pinchPreview {
            pinchPreview
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: pinchPreviewMinimumHeight, alignment: .center)
                .allowsHitTesting(false)
        }
    }

    private var trailingDropTarget: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: trailingDropHeight)
            .contentShape(Rectangle())
            .accessibilityIdentifier("block-drop-slot-\(rows.count)")
            .accessibilityLabel("Drop before block \(rows.count + 1)")
            .animation(reorderGapAnimation, value: trailingDropHeight)
    }

    @ViewBuilder
    private var pressHintBand: some View {
        if let id = pressHintID, let frame = layoutCache.realizedFrame(of: id) {
            Rectangle()
                .fill(ReorderLiftStyle.pressHintFill)
                .frame(height: frame.height)
                .frame(maxWidth: .infinity)
                .offset(y: frame.minY)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func rowOpacity(_ row: RowSurfaceRow<ID>) -> Double {
        if let settle, !settle.fadesOut, settle.destinationID == row.id { return 0 }
        return row.isSourceDimmed ? 0.12 : 1
    }

    /// One overlay for both the drag and the settle that follows it, so the
    /// view keeps its identity (and pickup state) across the release.
    @ViewBuilder
    private var liftOverlay: some View {
        if let model = liftOverlayModel {
            ReorderLiftOverlay(
                isLifted: model.isLifted,
                isVisible: model.isVisible,
                center: model.center,
                anchor: model.anchor,
                size: model.size
            ) {
                liftContent(model.id, model.size, model.isLanding)
            }
        }
    }

    private var liftOverlayModel: ReorderLiftOverlayModel<ID>? {
        if let lift = activeLift {
            let size = lift.sourceFrame.size
            return ReorderLiftOverlayModel(
                id: lift.id,
                size: size,
                anchor: reorderLiftAnchor(touchOffset: lift.touchOffset, size: size),
                // Vertical-only: horizontal position never changes the
                // destination, so the lift stays aligned with its column.
                center: CGPoint(
                    x: lift.sourceFrame.midX,
                    y: lift.location.y - lift.touchOffset.height + (size.height / 2)
                ),
                isLifted: true,
                isVisible: true,
                isLanding: false
            )
        }
        guard let settle else { return nil }
        return ReorderLiftOverlayModel(
            id: settle.id,
            size: settle.size,
            anchor: settle.anchor,
            center: settleLanding.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? settle.releaseCenter,
            isLifted: settleLanding == nil,
            isVisible: !(settleLanding?.fadesOut ?? false),
            isLanding: settleLanding != nil
        )
    }

    /// Wait for the destination row's first layout after the drop commits,
    /// then animate the lift onto it and hand off to the row.
    private func landSettle() async {
        settleLanding = nil
        guard let settle else { return }
        var destination: CGRect?
        if let destinationID = settle.destinationID {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(8))
                if Task.isCancelled { return }
                if let frame = layoutCache.realizedFrame(of: destinationID) {
                    destination = frame
                    break
                }
            }
        }
        // Rows span the content width; keep the lift's own height so it lands
        // on the destination's top edge. A destination that never laid out
        // (scrolled away, or none) fades out where it was released.
        let landing = destination.map { frame in
            ReorderSettleLanding(
                frame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: settle.size.height),
                fadesOut: settle.fadesOut
            )
        } ?? ReorderSettleLanding(
            frame: CGRect(
                x: settle.releaseCenter.x - settle.size.width / 2,
                y: settle.releaseCenter.y - settle.size.height / 2,
                width: settle.size.width,
                height: settle.size.height
            ),
            fadesOut: true
        )
        let token = settle.token
        withAnimation(ReorderLiftStyle.landing) {
            settleLanding = landing
        } completion: {
            actions.onReorderSettled(token)
        }
    }

    private func handlePageLevelTap(at point: CGPoint) {
        guard !isTapFromReorderGesture else { return }
        guard !layoutCache.isAccessoryAtY(point.y) else { return }
        if accessoryLaneWidth > 0, point.x > layoutCache.contentOriginX + layoutCache.contentWidth { return }
        if let rowID = layoutCache.realizedBlockIDAtPageY(point.y),
           let frame = layoutCache.realizedFrame(of: rowID) {
            let handleLeft = frame.minX - gutterWidth
            if point.x >= handleLeft, point.x < frame.minX {
                actions.onTapGutter(rowID)
                return
            }
            if point.x >= frame.minX, point.x <= frame.maxX {
                actions.onTapRow(rowID, point)
                return
            }
        }
        actions.onTapBelowRows(point)
    }

    /// The tap recognizer and the reorder long-press see the same touch-up
    /// in either order: suppress while the reorder runs and briefly after.
    private var isTapFromReorderGesture: Bool {
        if activeReorderLocation != nil { return true }
        guard let lastReorderEnd else { return false }
        return ContinuousClock.now - lastReorderEnd < .milliseconds(300)
    }

    private func applyRowOrder(_ order: RowSurfaceOrder<ID>) {
        layoutCache.updateOrder(
            order.ids,
            topGaps: order.topGaps,
            reorderGaps: order.reorderGaps
        )
    }

    /// A move projection removes the source rows, and a heading move may also
    /// remove hundreds of expanded body rows. Move the scroll offset by the
    /// same amount the source anchor moved in the projected stack. This keeps
    /// the lift near the finger and immediately materializes destinations.
    private func finishReorderProjectionChange() {
        guard let lift = activeLift else { return }
        let projectedInternalMinY: CGFloat?
        if let projectedFrame = layoutCache.frame(of: lift.id) {
            projectedInternalMinY = projectedFrame.minY - layoutCache.contentOriginY
        } else if let slot = lift.projectedSourceSlot {
            projectedInternalMinY = layoutCache.projectedInternalRowTop(
                at: slot,
                topGap: lift.projectedSourceTopGap
            )
        } else {
            projectedInternalMinY = nil
        }
        guard let projectedInternalMinY else { return }
        let oldOffset = scrollMetrics.contentOffsetY
        let nextEffectiveOffset = reorderAnchorPreservingOffset(
            sourceEffectiveOffset: lift.sourceEffectiveOffsetY,
            sourceInternalMinY: lift.sourceInternalMinY,
            projectedInternalMinY: projectedInternalMinY
        )
        let nextOffset = reorderRawScrollOffset(
            effectiveOffset: nextEffectiveOffset,
            topInset: scrollMetrics.topInset
        )
        if abs(nextOffset - oldOffset) > 0.5 {
            // `reorderFrame` projects frozen document-local destinations
            // through this origin. Keep it in lockstep with the synchronous
            // scroll write instead of waiting for the next geometry callback;
            // otherwise the lift and target use different coordinate frames
            // for one or more gesture events.
            layoutCache.contentOriginY = reorderContentOriginAfterOffsetChange(
                currentOrigin: layoutCache.contentOriginY,
                oldOffset: oldOffset,
                newOffset: nextOffset
            )
            scrollMetrics.contentOffsetY = nextOffset
            #if os(iOS)
            PageScrollController.shared.scroll(toY: nextOffset)
            #elseif os(macOS)
            if !MacPageScrollController.shared.scroll(toY: nextOffset) {
                scrollPosition.scrollTo(point: CGPoint(x: 0, y: nextOffset))
            }
            #endif
        }

        // The gesture's first tick deliberately did not resolve a destination
        // against the expanded-row snapshot. Now both the outline order and
        // its scroll origin are current, so resolve the hole at the live finger.
        if !lift.hasSeededDropTarget, let location = activeReorderLocation {
            actions.onReorderAutoscroll(location)
        }
    }

    private func updateHover(_ id: ID?) {
        guard hoveredRowID != id else { return }
        hoveredRowID = id
        actions.onHover(id)
    }

    private func updatePinchAutoScroll(for location: CGPoint) {
        let threshold: CGFloat = 88
        let maxVelocity: CGFloat = 520
        let velocity = edgeScrollVelocity(for: location, threshold: threshold, maxVelocity: maxVelocity)
        pinchAutoScrollVelocity = velocity
        if abs(velocity) > 1 {
            startPinchAutoScrollIfNeeded()
        } else {
            stopPinchAutoScroll()
        }
    }

    private func startPinchAutoScrollIfNeeded() {
        guard !pinchAutoScroll.isRunning else { return }
        pinchAutoScroll.start { elapsed in
            let velocity = pinchAutoScrollVelocity
            guard abs(velocity) > 1 else { return false }
            scrollBy(velocity * elapsed)
            return true
        }
    }

    private func stopPinchAutoScroll() {
        pinchAutoScrollVelocity = 0
        pinchAutoScroll.stop()
    }

    private func updateReorderAutoScroll(for location: CGPoint) {
        let threshold: CGFloat = 110
        let maxVelocity: CGFloat = 620
        let velocity = edgeScrollVelocity(for: location, threshold: threshold, maxVelocity: maxVelocity)
        reorderAutoScrollVelocity = velocity
        if abs(velocity) > 1 {
            startReorderAutoScrollIfNeeded()
        } else {
            stopReorderAutoScroll()
        }
    }

    private func startReorderAutoScrollIfNeeded() {
        guard !reorderAutoScroll.isRunning else { return }
        reorderAutoScroll.start { elapsed in
            let velocity = reorderAutoScrollVelocity
            guard abs(velocity) > 1 else { return false }
            scrollBy(velocity * elapsed)
            if let location = activeReorderLocation {
                actions.onReorderAutoscroll(location)
            }
            return true
        }
    }

    private func stopReorderAutoScroll() {
        reorderAutoScrollVelocity = 0
        reorderAutoScroll.stop()
    }

    private func edgeScrollVelocity(for location: CGPoint, threshold: CGFloat, maxVelocity: CGFloat) -> CGFloat {
        let effectiveBottom = scrollMetrics.viewportHeight - scrollMetrics.topInset - scrollMetrics.bottomInset
        guard effectiveBottom > threshold * 2 else { return 0 }

        let topDistance = location.y
        let bottomDistance = effectiveBottom - location.y
        if topDistance < threshold {
            let progress = min(1, max(0, (threshold - topDistance) / threshold))
            return -maxVelocity * progress * progress
        }
        if bottomDistance < threshold {
            let progress = min(1, max(0, (threshold - bottomDistance) / threshold))
            return maxVelocity * progress * progress
        }
        return 0
    }

    /// One autoscroll step. Steps are sub-point at slow speeds and high
    /// refresh rates, so none are dropped.
    private func scrollBy(_ deltaY: CGFloat) {
        #if os(iOS)
        PageScrollController.shared.scroll(byY: deltaY)
        #else
        let maxOffset = max(0, scrollMetrics.contentHeight - scrollMetrics.viewportHeight)
        let nextOffset = min(maxOffset, max(0, scrollMetrics.contentOffsetY + deltaY))
        guard nextOffset != scrollMetrics.contentOffsetY else { return }
        #if os(macOS)
        if !MacPageScrollController.shared.scroll(toY: nextOffset) {
            scrollPosition.scrollTo(point: CGPoint(x: 0, y: nextOffset))
        }
        #else
        scrollPosition.scrollTo(point: CGPoint(x: 0, y: nextOffset))
        #endif
        #endif
    }
}

private struct ReorderSettleLanding {
    let frame: CGRect
    let fadesOut: Bool
}

private struct ReorderLiftOverlayModel<ID> {
    let id: ID
    let size: CGSize
    let anchor: UnitPoint
    let center: CGPoint
    let isLifted: Bool
    let isVisible: Bool
    let isLanding: Bool
}

func reorderLiftAnchor(touchOffset: CGSize, size: CGSize) -> UnitPoint {
    guard size.width > 0, size.height > 0 else { return .center }
    return UnitPoint(
        x: min(1, max(0, touchOffset.width / size.width)),
        y: min(1, max(0, touchOffset.height / size.height))
    )
}

/// The floating row. Animates its own pickup when it appears; the settle
/// animates `isLifted`/`center` from outside.
private struct ReorderLiftOverlay<Content: View>: View {
    let isLifted: Bool
    let isVisible: Bool
    let center: CGPoint
    let anchor: UnitPoint
    let size: CGSize
    @ViewBuilder let content: Content
    @State private var hasPickedUp = false

    var body: some View {
        let lifted = isLifted && hasPickedUp
        content
            .frame(width: size.width, height: size.height, alignment: .leading)
            .shadow(
                color: .black.opacity(lifted ? ReorderLiftStyle.shadowOpacity : 0),
                radius: lifted ? ReorderLiftStyle.shadowRadius : 0,
                y: lifted ? ReorderLiftStyle.shadowY : 0
            )
            .scaleEffect(isVisible ? (lifted ? ReorderLiftStyle.liftedScale : 1) : 0.9, anchor: anchor)
            .opacity(isVisible ? 1 : 0)
            .position(center)
            .allowsHitTesting(false)
            .zIndex(100)
            .onAppear {
                withAnimation(ReorderLiftStyle.pickup) { hasPickedUp = true }
            }
    }
}

extension View {
    @ViewBuilder
    func iosPageTextDropTarget(
        onUpdate: @escaping (CGFloat) -> Void,
        onDrop: @escaping (String, CGFloat) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        self.onDrop(
            of: [UTType.plainText],
            delegate: RowSurfaceTextDropDelegate(
                onUpdate: onUpdate,
                onDrop: onDrop,
                onCancel: onCancel
            )
        )
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct RowSurfaceTextDropDelegate: DropDelegate {
    let onUpdate: (CGFloat) -> Void
    let onDrop: (String, CGFloat) -> Void
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
            guard let string = object as? NSString else {
                Task { @MainActor in
                    withAnimation(dropSpring) { onCancel() }
                }
                return
            }
            let payload = String(string)
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
#endif
