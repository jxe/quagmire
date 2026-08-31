import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Reorder lift, drop targets, and block-move helpers

extension EditorView {
    /// Drift gap rendered above the visible-row at `slot` (or at the trailing
    /// slot == visibleRows.count). Both `hoverSlot` and `liftFootprint` are
    /// precomputed once per body pass — `hoverSlot` is the visible slot
    /// corresponding to the current `dropHoverPath`, `liftFootprint` is the
    /// contiguous range of visible-row slots occupied by the lifted subtree.
    /// The footprint suppression covers "drop where you already are":
    /// anywhere inside the lifted rows, or the slot directly after them.
    func reorderDriftGap(
        at slot: Int,
        hoverSlot: Int?,
        liftFootprint: ClosedRange<Int>?,
        rows: [VisibleRow],
        sourceRow: VisibleRow?
    ) -> CGFloat {
        guard hoverSlot == slot else { return 0 }
        if let f = liftFootprint, f.contains(slot) || slot == f.upperBound + 1 { return 0 }
        guard let lift = state.reorderLift, let sourceRow else { return 42 }

        let previous = slot > 0 ? rows[slot - 1] : nil
        let next = slot < rows.count ? rows[slot] : nil
        let existingNeighborGap = next.map { next in
            BlockSpacing.gap(
                before: next.kind,
                depth: next.depth,
                after: previous?.kind,
                prevDepth: previous?.depth ?? 0
            )
        } ?? 0
        let gapBeforeSource = BlockSpacing.gap(
            before: sourceRow.kind,
            depth: sourceRow.depth,
            after: previous?.kind,
            prevDepth: previous?.depth ?? 0
        )
        let gapAfterSource = next.map { next in
            BlockSpacing.gap(
                before: next.kind,
                depth: next.depth,
                after: sourceRow.kind,
                prevDepth: sourceRow.depth
            )
        } ?? 0
        let insertedFootprint = gapBeforeSource
            + lift.sourceFrame.height
            + gapAfterSource
            - existingNeighborGap
        return max(42, insertedFootprint)
    }

    /// Visible-slot range covered by the active reorder lift's blocks (and
    /// any descendants that render in the visible-row stack). Returns nil if
    /// no lift is active or none of the lifted ids correspond to visible rows.
    func currentLiftFootprint(in rows: [VisibleRow]) -> ClosedRange<Int>? {
        guard let lift = state.reorderLift else { return nil }
        var slots: [Int] = []
        for (k, row) in rows.enumerated() where lift.draggedSubtreeIDs.contains(row.id) {
            slots.append(k)
        }
        guard let lo = slots.min(), let hi = slots.max() else { return nil }
        return lo...hi
    }

    func reorderSourceOpacity(for id: BlockID) -> Double {
        guard let lift = state.reorderLift, lift.ids.contains(id) else { return 1 }
        // Option-drag duplicates — keep originals fully visible so the user
        // sees both the source and the floating ghost at once.
        return lift.isCopy ? 1 : 0.12
    }

    func rowSurfaceLift(in unprojectedRows: [VisibleRow]) -> RowSurfaceLift<BlockID>? {
        guard let lift = state.reorderLift else { return nil }
        var projectionAnchor: (slot: Int, topGap: CGFloat)?
        if !lift.isCopy,
           let sourceIndex = unprojectedRows.firstIndex(where: { $0.id == lift.block.id }) {
            let retainedBefore = unprojectedRows[..<sourceIndex].filter {
                !lift.draggedSubtreeIDs.contains($0.id)
            }
            let previous = retainedBefore.last
            let source = unprojectedRows[sourceIndex]
            projectionAnchor = (
                retainedBefore.count,
                BlockSpacing.gap(
                    before: source.kind,
                    depth: source.depth,
                    after: previous?.kind,
                    prevDepth: previous?.depth ?? 0
                )
            )
        }
        return RowSurfaceLift(
            id: lift.block.id,
            sourceFrame: lift.sourceFrame,
            sourceEffectiveOffsetY: lift.sourceEffectiveOffsetY,
            sourceInternalMinY: lift.sourceInternalMinY,
            touchOffset: lift.touchOffset,
            location: lift.location,
            projectedSourceSlot: projectionAnchor?.slot,
            projectedSourceTopGap: projectionAnchor?.topGap ?? 0,
            hasSeededDropTarget: state.currentDropTarget != nil
        )
    }

    @ViewBuilder
    func reorderLiftContent(for id: BlockID, size: CGSize) -> some View {
        if let lift = state.reorderLift, lift.block.id == id {
            BlockRowPreview(
                block: lift.block,
                depth: 0,
                documentLookups: resolveDocumentLookups(for: lift.block, host: host, in: document),
                theme: configuration.theme
            )
            .frame(width: size.width, height: size.height, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if lift.isCopy {
                    copyBadge
                        .offset(x: -10, y: -10)
                }
            }
        }
    }

    private var copyBadge: some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.green))
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
    }

    /// Pre-mounts the lift in a `pendingAnchor` state at the source row's
    /// center. iOS calls this on long-press completion (where the gesture
    /// value carries no cursor location) so the user gets immediate visual
    /// feedback — source closes and lift overlay appears — instead of
    /// waiting for the first drag event. The next `tickReorderLift(at:)` call
    /// re-anchors `touchOffset` to the actual cursor location.
    func preliftReorder(blockID: BlockID) {
        guard let lift = makeReorderLift(
            blockID: blockID,
            touchOffset: nil,
            location: nil,
            pendingAnchor: true,
            isCopy: false
        ) else { return }
        layoutCache.beginReorderFrameSnapshot(rebaseOnNextOrderChange: true)
        state.setReorderLift(lift)
        seedSourceDropTarget(for: lift, snapshot: document.children)
    }

    /// Build a `ReorderLift` for `blockID`. Returns nil if the block, its row
    /// frame, or its document position is missing. `touchOffset` / `location`
    /// default to the source row's center — used by the iOS prelift, which
    /// mounts before a real cursor anchor is known.
    private func makeReorderLift(
        blockID: BlockID,
        touchOffset: CGSize?,
        location: CGPoint?,
        pendingAnchor: Bool,
        isCopy: Bool
    ) -> ReorderLift? {
        guard let block = document.find(blockID),
              let sourceFrame = reorderSourceFrame(for: blockID)
        else { return nil }
        let ids = dragIDs(for: blockID)
        // The leading H1 is the page title, not a movable section. Moving it
        // would silently transfer title identity to a different H1.
        if ids.contains(where: isPageTitleID) {
            return nil
        }
        let parentID = document.parent(of: blockID)
        // Compute the (parent, positions) pair: positions are the indices of
        // each lifted root within its parent's children list. Single-row
        // drags collapse to a single-position range.
        let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
        let positions = ids.compactMap { id in siblings.firstIndex { $0.id == id } }.sorted()
        let positionRange: ClosedRange<Int> = (positions.first ?? 0)...(positions.last ?? 0)
        // All ids inside any lifted subtree (cycle prevention on drop).
        var allDescendants: Set<BlockID> = []
        for id in ids {
            allDescendants.formUnion(document.subtreeIDs(of: id))
        }
        let roots = document.selectionSubtreeRoots(Set(ids))
        let outlineHeadingLevel: HeadingLevel? = roots == [blockID]
            ? block.headingLevel
            : nil
        return ReorderLift(
            block: block,
            ids: ids,
            sourceParentID: parentID,
            sourcePositions: positionRange,
            draggedSubtreeIDs: allDescendants,
            outlineHeadingLevel: outlineHeadingLevel,
            sourceFrame: sourceFrame,
            sourceEffectiveOffsetY: reorderEffectiveScrollOffset(
                rawOffset: scrollMetrics.contentOffsetY,
                topInset: scrollMetrics.topInset
            ),
            sourceInternalMinY: sourceFrame.minY - layoutCache.contentOriginY,
            touchOffset: touchOffset ?? CGSize(width: sourceFrame.width / 2, height: sourceFrame.height / 2),
            location: location ?? CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
            pendingAnchor: pendingAnchor,
            isCopy: isCopy
        )
    }

    /// Install the source's own insertion slot before SwiftUI removes the
    /// moving rows. This makes source removal and destination-gap opening one
    /// projection instead of briefly collapsing the next row under the still
    /// stationary finger and then resolving one slot too low.
    func seedSourceDropTarget(for lift: ReorderLift, snapshot: [Block]) {
        guard !lift.isCopy else { return }
        let unprojectedRows = rowsBeforeReorderSourceRemoval(snapshot: snapshot)
        guard let sourceIndex = unprojectedRows.firstIndex(where: { $0.id == lift.block.id }) else {
            return
        }
        let sourceSlot = unprojectedRows[..<sourceIndex].filter {
            !lift.draggedSubtreeIDs.contains($0.id)
        }.count
        let rows = visibleRowsRemoving(lift.draggedSubtreeIDs, from: unprojectedRows)
        let path: DropPath?
        if let level = lift.outlineHeadingLevel {
            path = headingDropPath(forOutlineSlot: sourceSlot, rows: rows, level: level)
        } else {
            path = dropPath(forVisibleSlot: sourceSlot, rows: rows)
        }
        if let path, document.canDrop(ids: lift.ids, to: path) {
            state.currentDropTarget = .insertAt(path)
        }
    }

    /// Prefer the live frame used by iOS source hit-testing. The cumulative
    /// frame remains a fallback for platforms or moments where the row has
    /// not published realized geometry yet.
    private func reorderSourceFrame(for blockID: BlockID) -> CGRect? {
        layoutCache.realizedFrame(of: blockID) ?? layoutCache.frame(of: blockID)
    }

    /// Per-event update: creates the lift if missing (macOS click-and-drag
    /// path), re-anchors `touchOffset` if a previous `preliftReorder` left it
    /// pending, then updates `location` and recomputes `dropHoverIndex`.
    ///
    /// `at location` is the current cursor position — drives lift placement
    /// and drop-slot resolution. `anchorAt` is the point that should sit
    /// under the cursor inside the lift; iOS passes the same value as
    /// `location` (the finger may drift up to 36pt during long-press, and we
    /// want the lift to lock to where the finger IS now), macOS passes
    /// `value.startLocation` (the click point — typically in the gutter,
    /// 4pt away from where the gesture-cleared `value.location` is).
    ///
    /// `sourceFrame`, `sourceIndex`, and `touchOffset` are frozen once the
    /// lift exists with a real anchor — the synthesized frame keeps shifting
    /// as the drift gap animates open (it adjusts the source row's height)
    /// and recomputing against a moving frame would drift the lift away from
    /// the cursor.
    func tickReorderLift(blockID: BlockID, at location: CGPoint, anchorAt anchorPoint: CGPoint, snapshot: [Block]) {
        let isCopy = currentReorderCopyIntent()
        var waitingForReorderProjection = false
        if state.reorderLift == nil {
            guard let sourceFrame = reorderSourceFrame(for: blockID),
                  let lift = makeReorderLift(
                      blockID: blockID,
                      touchOffset: CGSize(
                          width: anchorPoint.x - sourceFrame.minX,
                          height: anchorPoint.y - sourceFrame.minY
                      ),
                      location: location,
                      pendingAnchor: false,
                      isCopy: isCopy
                  )
            else { return }
            layoutCache.beginReorderFrameSnapshot(
                rebaseOnNextOrderChange: lift.outlineHeadingLevel != nil || !lift.isCopy
            )
            state.setReorderLift(lift)
            seedSourceDropTarget(for: lift, snapshot: snapshot)
            waitingForReorderProjection = lift.outlineHeadingLevel != nil || !lift.isCopy
        } else if var lift = state.reorderLift {
            if lift.isCopy != isCopy {
                // Toggling Option adds/removes the source rows from the live
                // projection, so the frozen destination geometry must follow
                // that structural transition before freezing again.
                layoutCache.rebaseReorderFrameSnapshotOnNextOrderChange()
                waitingForReorderProjection = true
            }
            if lift.pendingAnchor {
                waitingForReorderProjection = lift.outlineHeadingLevel != nil || !lift.isCopy
                lift.touchOffset = CGSize(
                    width: anchorPoint.x - lift.sourceFrame.minX,
                    height: anchorPoint.y - lift.sourceFrame.minY
                )
                lift.pendingAnchor = false
            }
            lift.location = location
            lift.isCopy = isCopy
            state.setReorderLift(lift)
        }
        // A move removes its source rows from the projection; a heading drag
        // also replaces the ordinary stack with a compact outline. Let
        // RowSurface install and snapshot that projection before resolving a
        // destination against its frames.
        if !waitingForReorderProjection {
            applyDropTarget(at: location.y, snapshot: snapshot)
        }
    }

    /// Option held → drop performs a duplicate. macOS-only; iOS has no
    /// modifier keys during a drag so always returns false there.
    private func currentReorderCopyIntent() -> Bool {
        #if os(macOS)
        return NSEvent.modifierFlags.contains(.option)
        #else
        return false
        #endif
    }

    /// Resolves the drop slot from `y`, then clears the lift and applies the
    /// move inside one no-animation transaction so neither the gap close, the
    /// lift unmount, nor the row reflow springs.
    func endReorderLift(atY y: CGFloat, snapshot: [Block]) {
        guard let lift = state.reorderLift else {
            layoutCache.endReorderFrameSnapshot()
            return
        }
        SoundFX.play(.drop, enabled: configuration.isAudioFeedbackEnabled)
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = state.currentDropTarget ?? resolveDropTarget(atY: y, snapshot: snapshot)
        let ids = lift.ids
        // Re-check Option at drop time so a release-just-before-drop reverts
        // to a move; the drop is the load-bearing read.
        let isCopy = currentReorderCopyIntent()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.currentDropTarget = nil
            state.setReorderLift(nil)
            layoutCache.endReorderFrameSnapshot()
            switch target {
            case .insertAt(let path):
                if isCopy {
                    copyBlocks(ids: ids, to: path, snapshot: snapshot)
                } else {
                    moveBlocks(ids: ids, to: path)
                }
            case .asLastChildOf(let parentID):
                if isCopy {
                    copyBlocks(ids: ids, asChildrenOf: parentID, snapshot: snapshot, hidden: hidden)
                } else {
                    moveBlocks(ids: ids, asChildrenOf: parentID, snapshot: snapshot, hidden: hidden)
                }
            case .intoDocument(_, let reference):
                if isCopy {
                    Task { await copyBlocks(ids: ids, intoDocument: reference) }
                } else {
                    Task { await moveBlocks(ids: ids, intoDocument: reference) }
                }
            }
        }
    }

    func cancelReorderLift() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.currentDropTarget = nil
            state.setReorderLift(nil)
            layoutCache.endReorderFrameSnapshot()
        }
    }

    /// Update `currentDropTarget` based on the live drop point. Source rows
    /// (the lift itself) are excluded from the drop-on hit-test so you can't
    /// drop onto your own collapsed parent.
    func applyDropTarget(at y: CGFloat, snapshot: [Block]) {
        let target = resolveDropTarget(atY: y, snapshot: snapshot)
        if state.currentDropTarget != target {
            state.currentDropTarget = target
        }
    }

    fileprivate func resolveDropTarget(atY y: CGFloat, snapshot: [Block]) -> DropTarget {
        let lift = state.reorderLift
        let liftIDs = lift?.ids ?? []
        // Build the visible-flat layout once and use it for BOTH the hit-test
        // (drop on documentLink / closed parent) and the between-rows slot
        // resolver. Iterating the top-level snapshot directly would miss
        // nested rows; iterating the legacy flat preorder of `snapshot`
        // would double-count blocks that also live inside their parent's
        // `children` array.
        //
        // Hot path: this fires on every drag tick (60+Hz) and every
        // auto-scroll inner tick (16ms). The cache returns the same
        // `[VisibleRow]` for as long as the document is structurally
        // stable, so a sustained drag does zero tree walks here.
        let unprojectedRows = rowsBeforeReorderSourceRemoval(snapshot: snapshot)
        let rows = projectedRowsForActiveReorder(unprojectedRows)

        if let lift, let level = lift.outlineHeadingLevel {
            return resolveHeadingDropTarget(atY: y, rows: rows, level: level, lift: lift)
        }

        // Hit-test for "drop on closed parent" / "drop onto documentLink". Edge
        // band keeps the gap above/below the row reachable for between-rows
        // drops.
        let edgeBand: CGFloat = 6
        for row in rows where !liftIDs.contains(row.id) {
            guard let frame = layoutCache.reorderFrame(of: row.id) else { continue }
            if case .documentLink(let reference) = row.kind,
               y >= frame.minY && y <= frame.maxY {
                // A target that can't take blocks isn't a drop target at all:
                // fall through so the drop lands between rows instead of
                // silently doing nothing on release.
                guard host.lookupDocument(reference).can(.receiveBlocks) else { continue }
                return .intoDocument(row.id, reference)
            }
            guard y > frame.minY + edgeBand && y < frame.maxY - edgeBand else { continue }
            if isCollapsedSection(id: row.id, kind: row.kind) {
                return .asLastChildOf(row.id)
            }
        }

        // Between-rows insertion: resolve "kth visible slot" against the
        // visible-flat row frames, then convert to a tree DropPath using
        // the layout's depth + parent metadata.
        let slot = resolveDropSlot(
            forY: y,
            in: rows,
            previousIndex: visibleSlotForCurrentDropPath(in: rows),
            liftFootprint: currentLiftFootprint(in: rows)
        )
        return .insertAt(dropPath(forVisibleSlot: slot, rows: rows))
    }

    /// Heading drags are outline restructuring, not arbitrary block drops.
    /// Resolve the pointer against the compact outline and select the nearest
    /// legal section boundary. The candidate paths allow crossing between
    /// lower-level heading parents while never dropping into body content.
    func resolveHeadingDropTarget(
        atY y: CGFloat,
        rows: [VisibleRow],
        level: HeadingLevel,
        lift: ReorderLift
    ) -> DropTarget {
        let candidates = headingDropCandidates(rows: rows, level: level, lift: lift)
        guard !candidates.isEmpty else {
            return .insertAt(DropPath(
                parent: lift.sourceParentID,
                position: lift.sourcePositions.lowerBound
            ))
        }
        let previousSlot = state.dropHoverPath.flatMap { path in
            candidates.first(where: { $0.path == path })?.slot
        }
        let rawSlot = resolveDropSlot(
            forY: y,
            in: rows,
            previousIndex: previousSlot,
            liftFootprint: currentLiftFootprint(in: rows)
        )
        let nearest = candidates.min { lhs, rhs in
            let leftDistance = abs(lhs.slot - rawSlot)
            let rightDistance = abs(rhs.slot - rawSlot)
            if leftDistance == rightDistance { return lhs.slot < rhs.slot }
            return leftDistance < rightDistance
        } ?? candidates[0]
        return .insertAt(nearest.path)
    }

    struct HeadingDropCandidate: Equatable {
        let slot: Int
        let path: DropPath
    }

    /// Every gap in the outline maps either to "before this Hn", "after the
    /// preceding Hn", or "at the end of the nearest lower-level section".
    /// Filter those structural paths through the document's normal cycle and
    /// containment validator. H1 slot zero is excluded because it precedes the
    /// fixed page title.
    func headingDropCandidates(
        rows: [VisibleRow],
        level: HeadingLevel,
        lift: ReorderLift
    ) -> [HeadingDropCandidate] {
        var candidateByPath: [DropPath: HeadingDropCandidate] = [:]
        let firstH1Slot: Int = {
            guard level == .h1,
                  let title = document.children.first,
                  isPageTitleID(title.id)
            else { return 0 }
            let titleSubtreeIDs = document.subtreeIDs(of: title.id)
            return rows.lastIndex(where: { titleSubtreeIDs.contains($0.id) }).map { $0 + 1 } ?? 0
        }()
        for slot in 0...rows.count {
            // The page title and its visible body are fixed together. A root
            // H1 cannot be inserted into the middle of that retained subtree.
            guard slot >= firstH1Slot else { continue }
            guard let path = headingDropPath(forOutlineSlot: slot, rows: rows, level: level),
                  document.canDrop(ids: lift.ids, to: path)
            else { continue }
            // Retained page-title body rows can make several visual slots map
            // to the same structural "end of section" path. The final slot is
            // the real boundary after that body; earlier duplicates would put
            // the gap inside the still-visible title content.
            candidateByPath[path] = HeadingDropCandidate(slot: slot, path: path)
        }
        return candidateByPath.values.sorted { $0.slot < $1.slot }
    }

    func headingDropPath(
        forOutlineSlot slot: Int,
        rows: [VisibleRow],
        level: HeadingLevel
    ) -> DropPath? {
        guard slot >= 0, slot <= rows.count else { return nil }

        // A slot immediately before another Hn means before that section in
        // its actual parent's child array (after any introductory body rows).
        if slot < rows.count,
           case .heading(let belowLevel) = rows[slot].kind,
           belowLevel == level {
            let below = rows[slot]
            let siblings = below.parentID.flatMap(document.find)?.children ?? document.children
            guard let position = siblings.firstIndex(where: { $0.id == below.id }) else { return nil }
            // The leading H1 is fixed as the page title.
            if level == .h1, below.parentID == nil, position == 0 { return nil }
            return DropPath(parent: below.parentID, position: position)
        }

        // Otherwise the nearest preceding outline heading owns the boundary.
        // An Hn contributes the slot after itself; a lower-level heading
        // contributes the end of its section, enabling cross-parent moves.
        if slot > 0 {
            for index in stride(from: slot - 1, through: 0, by: -1) {
                let row = rows[index]
                guard case .heading(let rowLevel) = row.kind else { continue }
                if rowLevel == level {
                    let siblings = row.parentID.flatMap(document.find)?.children ?? document.children
                    guard let position = siblings.firstIndex(where: { $0.id == row.id }) else { return nil }
                    return DropPath(parent: row.parentID, position: position + 1)
                }
                if rowLevel < level,
                   let parent = document.find(row.id) {
                    return DropPath(parent: row.id, position: parent.children.count)
                }
            }
        }

        // H1s live only at the document root. Slot zero was rejected above
        // when it was before the fixed title; the trailing root slot is valid.
        if level == .h1, slot == rows.count {
            return DropPath(parent: nil, position: document.children.count)
        }
        return nil
    }

    /// Converts a Y-position into a slot index in `rows` (the full
    /// visible-row layout). The layout cache holds heights for every row
    /// that's ever been measured — including off-screen rows whose
    /// LazyVStack mount has since been recycled — so the answer is in the
    /// full `rows` index space without a sparser-to-full remap. Returns 0
    /// when no row has yet been measured, which `dropPath` handles as
    /// "top of document."
    func resolveDropSlot(
        forY y: CGFloat,
        in rows: [VisibleRow],
        previousIndex: Int? = nil,
        liftFootprint: ClosedRange<Int>? = nil
    ) -> Int {
        let knownFrames: [(rowsIndex: Int, frame: ReorderDropFrame)] = rows.enumerated().compactMap { (k, row) in
            layoutCache.reorderFrame(of: row.id).map { (k, ReorderDropFrame(frame: $0)) }
        }
        guard !knownFrames.isEmpty else { return previousIndex ?? 0 }
        let prevInKnownSpace: Int? = previousIndex.map { prev in
            knownFrames.firstIndex { $0.rowsIndex >= prev } ?? knownFrames.count
        }
        let sourceRangeInKnownSpace: ClosedRange<Int>? = liftFootprint.flatMap { footprint in
            guard let lower = knownFrames.firstIndex(where: { $0.rowsIndex >= footprint.lowerBound }),
                  let upper = knownFrames.lastIndex(where: { $0.rowsIndex <= footprint.upperBound }),
                  lower <= upper
            else { return nil }
            return lower...upper
        }
        let knownSlot = ReorderDropResolver.reorderInsertionIndex(
            forY: y,
            rowFrames: knownFrames.map { $0.frame },
            sourceRange: sourceRangeInKnownSpace,
            previousIndex: prevInKnownSpace
        )
        if knownSlot < knownFrames.count {
            return knownFrames[knownSlot].rowsIndex
        }
        return (knownFrames.last.map { $0.rowsIndex + 1 }) ?? rows.count
    }

    /// Convert a visible-flat slot index to a tree `DropPath`. Decides based
    /// on the parent relationship between the rows above and below the slot,
    /// not on visible depth — heading children render at the heading's
    /// depth (Notion-flush layout), so depth alone can't distinguish
    /// "first child of heading" from "next sibling of heading."
    ///
    /// - slot 0 → top of the document
    /// - trailing slot → append at the document root
    /// - row[k] is a direct child of row[k-1] → drop becomes first child of
    ///   row[k-1] (whether or not depths differ — heading-children look
    ///   visually flat with the heading)
    /// - row[k] and row[k-1] share a parent → drop as the next sibling of
    ///   row[k-1] under that shared parent
    /// - otherwise (we're exiting row[k-1]'s subtree to land in below's
    ///   parent) → drop "before row[k]" at row[k]'s depth
    func dropPath(forVisibleSlot slot: Int, rows: [VisibleRow]) -> DropPath {
        if slot <= 0 {
            return DropPath(parent: nil, position: 0)
        }
        if slot >= rows.count {
            return DropPath(parent: nil, position: document.children.count)
        }
        let above = rows[slot - 1]
        let below = rows[slot]

        // First child of `above`. Catches the heading-flush case where above
        // and below share a depth value but below is structurally inside
        // above. Without this check, the slot would resolve to "next
        // sibling of above" — the wrong scope.
        if below.parentID == above.id {
            return DropPath(parent: above.id, position: 0)
        }

        // Sibling under a shared parent.
        if above.parentID == below.parentID {
            let parentID = above.parentID
            let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
            let i = siblings.firstIndex(where: { $0.id == above.id }) ?? siblings.count - 1
            return DropPath(parent: parentID, position: i + 1)
        }

        // Exiting above's subtree. Drop "before below" in below's parent.
        let parentID = below.parentID
        let siblings: [Block] = parentID.flatMap(document.find)?.children ?? document.children
        let i = siblings.firstIndex(where: { $0.id == below.id }) ?? 0
        return DropPath(parent: parentID, position: i)
    }

    /// Returns the visible-flat slot the current drop hover corresponds to
    /// (if any). Used as a stickiness hint for `ReorderDropResolver` so the
    /// slot doesn't oscillate near gap boundaries.
    func visibleSlotForCurrentDropPath(in rows: [VisibleRow]) -> Int? {
        guard let path = state.dropHoverPath else { return nil }
        if let lift = state.reorderLift,
           let level = lift.outlineHeadingLevel {
            return headingDropCandidates(rows: rows, level: level, lift: lift)
                .first(where: { $0.path == path })?
                .slot
        }
        // Find the row whose (parent, position) matches — i.e. the row whose
        // insertion would land at this DropPath. The slot is "the index of the
        // row that would sit AT or AFTER this drop path's effective position."
        for (k, row) in rows.enumerated() {
            if row.parentID == path.parent {
                let parentChildren: [Block] = path.parent.flatMap(document.find)?.children ?? document.children
                if path.position < parentChildren.count {
                    let target = parentChildren[path.position].id
                    if row.id == target { return k }
                }
            }
        }
        return nil
    }

    func performPayloadDrop(_ payload: BlockDragPayload, atY y: CGFloat, snapshot: [Block]) {
        let hidden = hiddenBlockIDs(in: snapshot)
        let target = state.currentDropTarget ?? resolveDropTarget(atY: y, snapshot: snapshot)
        switch target {
        case .insertAt(let path):
            moveBlocks(ids: payload.ids, to: path)
        case .asLastChildOf(let parentID):
            moveBlocks(ids: payload.ids, asChildrenOf: parentID, snapshot: snapshot, hidden: hidden)
        case .intoDocument(_, let reference):
            Task { await moveBlocks(ids: payload.ids, intoDocument: reference) }
        }
    }

    /// Haptic on drop-target changes during an active reorder. Two layers of
    /// suppression keep this from machine-gunning when the drift gap's
    /// 260ms spring animation makes row frames jitter:
    /// 1. Dedupe on the full `DropTarget` (not just `.insertAt` position), so
    ///    a brief detour through `.asLastChildOf` / `.intoDocument` and back
    ///    to the same `.insertAt` slot doesn't re-fire.
    /// 2. Minimum 60ms between fires — caps the rate when the resolver
    ///    genuinely flips between adjacent slots mid-animation (the
    ///    interpolating row frames can occasionally overrun the 10pt
    ///    hysteresis at the slot boundary).
    func handleDropTargetChange(_ target: DropTarget?) {
        #if os(iOS)
        guard let target else {
            lastDropHapticTarget = nil
            return
        }
        guard lastDropHapticTarget != target else { return }
        let now = Date()
        if let last = lastDropHapticFireAt, now.timeIntervalSince(last) < 0.06 {
            lastDropHapticTarget = target
            return
        }
        lastDropHapticTarget = target
        lastDropHapticFireAt = now
        Haptics.light(enabled: configuration.isHapticFeedbackEnabled)
        #else
        _ = target
        #endif
    }

    /// Compute the BlockIDs to include in a drag started from `blockID`. If the row
    /// is part of a multi-block selection, drag the whole selection (in document
    /// order); otherwise just the single row + its descendants.
    func dragIDs(for blockID: BlockID) -> [BlockID] {
        if state.selection.contains(blockID) && state.selection.count > 1 {
            return effectiveSelectedIDsInDocumentOrder()
        }
        // Single-row drag: the lifted root + all descendants travel together.
        guard let block = document.find(blockID) else { return [blockID] }
        var out: [BlockID] = []
        var seen: Set<BlockID> = []
        collectPreorderIDs(block, into: &out, seen: &seen)
        return out
    }

    /// Move the subtree-rooted set of blocks identified by `ids` to `target`.
    /// Validates with `Document.canDrop(ids:to:)` first (rejects descendant
    /// cycles and containment violations) and then funnels through
    /// `Document.moveSubtrees(_:to:)`.
    fileprivate func moveBlocks(ids: [BlockID], to target: DropPath) {
        guard !ids.isEmpty, document.canDrop(ids: ids, to: target) else { return }
        mutate("Move Block") {
            document.moveSubtrees(ids, to: target)
        }
    }

    /// Drop-on-parent: append `ids` as the parent's last children. Validates
    /// with `Document.canDrop` (rejects cycles + containment violations) then
    /// performs the move. No more indent math — the tree itself encodes depth.
    func moveBlocks(ids: [BlockID], asChildrenOf parentID: BlockID, snapshot _: [Block], hidden _: Set<BlockID>) {
        guard !ids.contains(parentID),
              let parent = document.find(parentID) else { return }
        let target = DropPath(parent: parentID, position: parent.children.count)
        guard document.canDrop(ids: ids, to: target) else { return }
        // Capture a cursor target near the source BEFORE the move, so the nav
        // cursor stays where the user moved from instead of following the
        // blocks into the destination.
        let cursorTarget = nearestCursorAfterRemoval(of: ids)
        mutate("Move Block") {
            document.moveSubtrees(ids, to: target)
        }
        if let id = cursorTarget {
            setCursor(id)
        }
        showActionToast("Moved")
    }

    /// Option-drag duplicate: insert fresh-ID copies of `ids` at `target`,
    /// leaving the originals in place. Selects the new copies.
    fileprivate func copyBlocks(ids: [BlockID], to target: DropPath, snapshot _: [Block]) {
        // Collect originals in document order (so a multi-block selection
        // duplicates in the right order) and deep-copy with fresh IDs.
        let ordered = ids.sorted { (a, b) in
            (document.documentOrder(of: a) ?? .max) < (document.documentOrder(of: b) ?? .max)
        }
        let copies = ordered.compactMap { document.find($0)?.withFreshIDs() }
        guard !copies.isEmpty else { return }
        mutate(copies.count > 1 ? "Duplicate Blocks" : "Duplicate Block") {
            document.insertSubtrees(copies, at: target)
        }
        selectAfterCopy(copies)
    }

    /// Option-drag onto a closed parent: append duplicates as that parent's
    /// last children. Mirrors `moveBlocks(ids:asChildrenOf:...)` for the copy
    /// variant.
    fileprivate func copyBlocks(ids: [BlockID], asChildrenOf parentID: BlockID, snapshot _: [Block], hidden _: Set<BlockID>) {
        guard !ids.contains(parentID),
              let parent = document.find(parentID) else { return }
        let target = DropPath(parent: parentID, position: parent.children.count)
        let ordered = ids.sorted { (a, b) in
            (document.documentOrder(of: a) ?? .max) < (document.documentOrder(of: b) ?? .max)
        }
        let copies = ordered.compactMap { document.find($0)?.withFreshIDs() }
        guard !copies.isEmpty else { return }
        mutate(copies.count > 1 ? "Duplicate Blocks" : "Duplicate Block") {
            document.insertSubtrees(copies, at: target)
        }
        selectAfterCopy(copies)
    }

    /// Set selection to the freshly-inserted copies in document order.
    private func selectAfterCopy(_ copies: [Block]) {
        let ids = copies.map(\.id)
        guard let first = ids.first, let last = ids.last else { return }
        state.setNavSelection(blocks: Set(ids), anchor: first, cursor: last)
    }

    /// Drop-on-documentLink / Move-to picker: append `ids` to the end of the
    /// destination page (cross-document write via `appendToDocument`) and
    /// remove them from this document. Tree shape and relative nesting are
    /// preserved verbatim — the destination receives the subtrees as-is.
    func moveBlocks(ids: [BlockID], intoDocument reference: DocumentReference) async {
        let roots = document.selectionSubtreeRoots(Set(ids))
        let ordered = roots.sorted { (a, b) in
            (document.documentOrder(of: a) ?? .max) < (document.documentOrder(of: b) ?? .max)
        }
        let movingBlocks = ordered.compactMap { document.find($0) }
        guard !movingBlocks.isEmpty else { return }

        guard await host.appendToDocument(reference, movingBlocks) else { return }

        // Capture a cursor target near the source BEFORE removing the blocks,
        // so the nav cursor stays where the user moved from rather than
        // pointing at IDs that no longer exist in this document.
        let cursorTarget = nearestCursorAfterRemoval(of: ordered)
        mutate("Move to DocumentLink") {
            for id in ordered {
                document.removeSubtree(id)
            }
        }
        if let id = cursorTarget {
            setCursor(id)
        }
        showActionToast("Moved")
    }

    /// Option-drop on a documentLink: append fresh-ID copies to the destination
    /// page while leaving the source document untouched. As with a local
    /// duplicate, selecting both a parent and one of its descendants emits
    /// the parent subtree only once.
    func copyBlocks(ids: [BlockID], intoDocument reference: DocumentReference) async {
        let roots = document.selectionSubtreeRoots(Set(ids))
        let ordered = roots.sorted { (a, b) in
            (document.documentOrder(of: a) ?? .max) < (document.documentOrder(of: b) ?? .max)
        }
        let copies = ordered.compactMap { document.find($0)?.withFreshIDs() }
        guard !copies.isEmpty else { return }

        guard await host.appendToDocument(reference, copies) else { return }
        showActionToast("Copied")
    }
}
