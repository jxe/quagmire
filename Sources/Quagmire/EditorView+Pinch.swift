import SwiftUI

// MARK: - Pinch-open-to-insert (iOS)

enum PinchInsertionMode: Equatable, Sendable {
    case contextual
    case emptyParagraph
    case divider
    case heading

    var nextMode: PinchInsertionMode {
        switch self {
        case .contextual: .divider
        case .emptyParagraph: .contextual
        case .divider: .heading
        case .heading: .emptyParagraph
        }
    }

    var acceptsDictation: Bool {
        self == .contextual || self == .heading
    }
}

struct PinchDictationDraft {
    var block: Block
    var slot: Int
    private var contextualBlock: Block
    private var latestTranscript = ""
    private(set) var insertionMode: PinchInsertionMode = .contextual

    init(block: Block, slot: Int) {
        self.block = block
        self.slot = slot
        self.contextualBlock = block.withText(AttributedString())
    }

    func replacingText(with rawText: String) -> PinchDictationDraft {
        var copy = self
        copy.latestTranscript = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.refreshPreviewBlock()
        return copy
    }

    func cyclingInsertionMode() -> PinchDictationDraft {
        var copy = self
        copy.insertionMode = insertionMode.nextMode
        copy.refreshPreviewBlock()
        return copy
    }

    var committedBlock: Block {
        switch insertionMode {
        case .contextual:
            contextualBlock
        case .emptyParagraph:
            .paragraph(text: AttributedString(), id: block.id)
        case .divider:
            .divider(id: block.id)
        case .heading:
            .heading(level: .h1, text: AttributedString(), id: block.id)
        }
    }

    private mutating func refreshPreviewBlock() {
        switch insertionMode {
        case .contextual:
            block = contextualBlock.withText(AttributedString(latestTranscript))
        case .emptyParagraph:
            block = .paragraph(text: AttributedString(), id: block.id)
        case .divider:
            block = .divider(id: block.id)
        case .heading:
            let text = latestTranscript.isEmpty ? "Heading" : latestTranscript
            block = .heading(level: .h1, text: AttributedString(text), id: block.id)
        }
    }
}

extension EditorView {
    static var pinchInsertCommitGap: CGFloat { 40 }
    /// Spread distance the user must cross before any gap or insertion-anchor
    /// commitment happens. Two reasons: (1) UIPinchGestureRecognizer.began
    /// fires only after its internal threshold is crossed, so the first
    /// `.changed` already arrives with `spreadDelta` in the 5–15 px range —
    /// without a deadzone the gap pops open visibly instead of growing from 0.
    /// (2) Fingers naturally drift while spreading (typically downward), so
    /// reading the midpoint at gesture start picks the wrong row; waiting
    /// until the gesture is clearly committed lets us read a settled location.
    static var pinchOpenDeadzone: CGFloat { 12 }

    /// Extra top-padding to reveal an opening pinch-gap above the row at
    /// `index`. Zero unless the active pinch preview is targeting that slot.
    func pinchExtraGap(forIndex index: Int) -> CGFloat {
        guard let preview = state.pinchPreview, preview.insertIndex == index else { return 0 }
        return preview.gapHeight
    }

    /// Soft asymptote past `soft` — gap continues to track fingers but tightens
    /// toward `max`. Replaces a hard clamp, which feels dead at the limit.
    fileprivate func pinchRubberBand(_ x: CGFloat, soft: CGFloat = 140, max: CGFloat = 240) -> CGFloat {
        guard x > soft else { return x }
        let over = x - soft
        let range = max - soft
        return soft + range * (1 - 1 / (1 + over / range))
    }

    /// Track the live finger spread: once the spread crosses `pinchOpenDeadzone`,
    /// open an inline gap at the row pair under the current midpoint; below
    /// that threshold the gesture is treated as not-yet-committed, so no
    /// preview opens and other gestures stay armed. Once the deadzone has
    /// been crossed at any point in the session, `pinchGestureActive` stays
    /// latched until `handlePinchCommit` clears it (so a brief pinch-back
    /// doesn't re-enable reorder/swipe mid-gesture). Pinch-close commits on
    /// release.
    @discardableResult
    func handlePinchUpdate(_ value: PagePinchValue) -> Bool {
        guard state.editingBlock == nil else {
            if state.pinchPreview != nil { state.setPinchPreview(nil) }
            pinchPendingInsertIndex = nil
            return false
        }
        if value.spreadDelta >= Self.pinchOpenDeadzone {
            pinchGestureActive = true
            // Subtract the deadzone so the gap opens at exactly 0 px when the
            // user first crosses the threshold and grows smoothly from there.
            let gapHeight = pinchRubberBand(value.spreadDelta - Self.pinchOpenDeadzone)
            // Compute insertIndex once at deadzone-crossing, from the CURRENT
            // midpoint (not value.startLocation). At this moment the gap hasn't
            // opened so rowFrames are still pre-shift, AND the user's fingers
            // have settled past whatever drift happened during recognizer
            // ramp-up. Anchor it for the rest of the gesture so the gap stays
            // put even as more layout shifts happen.
            let insertIndex = pinchPendingInsertIndex ?? pinchInsertIndex(for: value.location)
            let isFirstOpen = state.pinchPreview == nil
            pinchPendingInsertIndex = insertIndex
            let preview = PinchPreviewState(insertIndex: insertIndex, gapHeight: gapHeight)
            if isFirstOpen {
                // Smooth the nil → open transition. Subsequent updates stay
                // unanimated so the gap tracks fingers in real time.
                withAnimation(.spring(response: 0.18, dampingFraction: 0.85)) {
                    state.setPinchPreview(preview)
                }
            } else {
                state.setPinchPreview(preview)
            }
            if gapHeight >= Self.pinchInsertCommitGap, !pinchCrossedInsertThreshold {
                pinchCrossedInsertThreshold = true
                Haptics.medium(enabled: configuration.isHapticFeedbackEnabled)
                SoundFX.play(.pinchOpen, enabled: configuration.isAudioFeedbackEnabled)
                preparePinchDictationDraft(at: insertIndex)
                beginPinchDictationIfAvailable()
            }
            return true
        } else if state.pinchPreview != nil {
            // Pinched back below deadzone after opening — close the preview
            // visually but keep `pinchGestureActive` latched so a re-open
            // doesn't ping-pong the swipe/reorder gates.
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                state.setPinchPreview(nil)
            }
            clearPinchThresholds()
        }
        return false
    }

    /// Reset the pinch's per-gesture bookkeeping (insert-slot anchor + the
    /// threshold-crossed latch). The preview state itself is owned by
    /// `EditorState.pinchPreview` and cleared separately.
    private func clearPinchThresholds() {
        pinchPendingInsertIndex = nil
        pinchCrossedInsertThreshold = false
    }

    func handlePinchThirdFingerTap() {
        let gapHeight = state.pinchPreview?.gapHeight ?? 0
        guard pinchCrossedInsertThreshold,
              let draft = pinchDictationDraft else {
            configuration.diagnostics.pinch.debug(
                "third-finger callback ignored threshold=\(self.pinchCrossedInsertThreshold, privacy: .public) gap=\(gapHeight, privacy: .public) draft=\(self.pinchDictationDraft != nil, privacy: .public)"
            )
            return
        }
        let cycled = draft.cyclingInsertionMode()
        pinchDictationDraft = cycled
        pinchInsertionMode = cycled.insertionMode
        configuration.diagnostics.pinch.debug(
            "third-finger tap selected \(String(describing: cycled.insertionMode), privacy: .public)"
        )
        Haptics.light(enabled: configuration.isHapticFeedbackEnabled)
    }

    func handlePinchCommit(_ value: PagePinchValue) {
        let preview = state.pinchPreview
        let gap = preview?.gapHeight ?? pinchRubberBand(max(0, value.spreadDelta))

        if gap >= Self.pinchInsertCommitGap, state.editingBlock == nil {
            let slot = pinchPendingInsertIndex
                ?? preview?.insertIndex
                ?? pinchInsertIndex(for: value.startLocation)
            // Resolve the visible slot to a tree DropPath, with the visible-row
            // above/below at that slot as neighbour context for kind inference.
            let (rows, _) = layoutCache.currentVisibleRows(
                snapshot: document.children, isCollapsed: isCollapsedSection
            )
            let path = dropPath(forVisibleSlot: slot, rows: rows)
            let above: VisibleRowKind? = (slot - 1 >= 0 && slot - 1 < rows.count) ? rows[slot - 1].kind : nil
            let below: VisibleRowKind? = (slot >= 0 && slot < rows.count) ? rows[slot].kind : nil
            // The open distance has one semantic threshold. Contextual mode
            // keeps the established neighbour-shaped insertion and optional
            // dictation behavior. A third-finger tap enters the explicit mode
            // cycle; only Heading also consumes the already-running audio.
            let newBlock = pinchDictationDraft?.committedBlock
                ?? smartInsertBlock(above: above, below: below)
            let usesDictation = pinchInsertionMode.acceptsDictation && pinchDictation != nil
            let focusesTextBlock = pinchInsertionMode != .divider && !usesDictation
            configuration.diagnostics.pinch.debug(
                "pinch committed mode=\(String(describing: pinchInsertionMode), privacy: .public) dictation=\(usesDictation, privacy: .public)"
            )
            // Bundle the structural insert and the gap collapse into the same
            // spring transaction so the new row appears inside the opened gap
            // and the surrounding rows close in around it. Without the shared
            // animation transaction the gap snap-closes first and the new row
            // pops in afterwards — visually disjoint.
            Haptics.heavy(enabled: configuration.isHapticFeedbackEnabled)
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                insertBlock(newBlock, at: path, focus: focusesTextBlock)
                if usesDictation {
                    transferFocus(to: .nav(cursor: newBlock.id))
                }
                state.setPinchPreview(nil)
            }
            if usesDictation {
                finishPinchDictation(for: newBlock.id)
            } else {
                cancelPinchDictationIfNeeded()
                pinchDictationDraft = nil
            }
        } else {
            cancelPinchDictationIfNeeded()
            pinchDictationDraft = nil
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                state.setPinchPreview(nil)
            }
        }
        clearPinchThresholds()
        pinchInsertionMode = .contextual
        pinchGestureActive = false
    }

    private func beginPinchDictationIfAvailable() {
        guard pinchDictationBeginTask == nil,
              pinchDictationCompletionTask == nil,
              let pinchDictation else { return }
        pinchDictationBeginTask = Task { @MainActor in
            await pinchDictation.begin { draft in
                updatePinchDictationDraft(draft)
            }
        }
    }

    private func preparePinchDictationDraft(at slot: Int) {
        if var draft = pinchDictationDraft {
            draft.slot = slot
            pinchDictationDraft = draft
            return
        }
        let (rows, _) = layoutCache.currentVisibleRows(
            snapshot: document.children, isCollapsed: isCollapsedSection
        )
        let above = (slot > 0 && slot <= rows.count) ? rows[slot - 1].kind : nil
        let below = (slot >= 0 && slot < rows.count) ? rows[slot].kind : nil
        pinchDictationDraft = PinchDictationDraft(
            block: smartInsertBlock(above: above, below: below),
            slot: slot
        )
    }

    func updatePinchDictationDraft(_ rawText: String) {
        guard let draft = pinchDictationDraft else { return }
        pinchDictationDraft = draft.replacingText(with: rawText)
    }

    func pinchDictationDraftBinding(for blockID: BlockID) -> Binding<Block>? {
        guard let draft = pinchDictationDraft,
              draft.block.id == blockID,
              document.find(blockID) != nil else { return nil }
        return Binding(
            get: { pinchDictationDraft?.block ?? draft.block },
            set: { updated in
                guard var current = pinchDictationDraft,
                      current.block.id == blockID else { return }
                current.block = updated
                pinchDictationDraft = current
            }
        )
    }

    @ViewBuilder
    func pinchDictationDraftRow(
        _ draft: PinchDictationDraft,
        visibleRows: [VisibleRow]
    ) -> some View {
        let path = dropPath(forVisibleSlot: draft.slot, rows: visibleRows)
        let depth = path.parent.flatMap { parent in
            visibleRows.first(where: { $0.id == parent })
        }.map { $0.kind.childDepth(from: $0.depth) } ?? 0
        let previous = draft.slot > 0 && draft.slot <= visibleRows.count
            ? visibleRows[draft.slot - 1]
            : nil
        let spacing = BlockSpacing.gap(
            before: VisibleRowKind(draft.block.kind),
            depth: depth,
            after: previous?.kind,
            prevDepth: previous?.depth ?? 0
        )

        rowView(
            for: Binding(
                get: { pinchDictationDraft?.block ?? draft.block },
                set: { updated in
                    guard var current = pinchDictationDraft else { return }
                    current.block = updated
                    pinchDictationDraft = current
                }
            ),
            depth: depth,
            numberingIndex: nil,
            selectedIDs: [],
            isProvisionalText: true
        )
        .padding(.top, spacing)
        .accessibilityHidden(true)
    }

    private func cancelPinchDictationIfNeeded() {
        guard let beginTask = pinchDictationBeginTask,
              let pinchDictation else { return }
        pinchDictationBeginTask = nil
        Task { @MainActor in
            if await beginTask.value {
                pinchDictation.cancel()
            }
        }
    }

    private func finishPinchDictation(for blockID: BlockID) {
        let beginTask = pinchDictationBeginTask
        pinchDictationBeginTask = nil
        guard let beginTask, let pinchDictation else {
            applyPinchDictationCompletion(.failed, to: blockID)
            return
        }

        pinchDictationCompletionTask = Task { @MainActor in
            let began = await beginTask.value
            guard !Task.isCancelled else {
                if began { pinchDictation.cancel() }
                return
            }
            guard began else {
                pinchDictationDraft = nil
                applyPinchDictationCompletion(.failed, to: blockID)
                pinchDictationCompletionTask = nil
                return
            }
            let completion = await pinchDictation.finish()
            guard !Task.isCancelled else { return }
            applyPinchDictationCompletion(completion, to: blockID)
            pinchDictationDraft = nil
            pinchDictationCompletionTask = nil
        }
    }

    func applyPinchDictationCompletion(
        _ completion: EditorPinchDictation.Completion,
        to blockID: BlockID
    ) {
        guard let block = document.find(blockID), block.text.characters.isEmpty else { return }
        let isStillWaitingAtInsertedBlock = state.editingBlock == nil && state.cursor == blockID

        switch completion {
        case .transcript(let rawTranscript):
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                if isStillWaitingAtInsertedBlock {
                    transferFocus(to: .editor(blockID, initialCursor: nil))
                }
                return
            }
            mutate("Insert Dictation") {
                document.mutate(blockID) { current in
                    current = current.withText(AttributedString(transcript))
                }
            }
            if isStillWaitingAtInsertedBlock {
                transferFocus(to: .nav(cursor: blockID))
            }
        case .noSpeech, .failed:
            if isStillWaitingAtInsertedBlock {
                transferFocus(to: .editor(blockID, initialCursor: nil))
            }
        }
    }

    /// The insert slot for a pinch whose midpoint is at `point` (page hover
    /// coordinate space — same space rowFrames live in). Returns a *visible-row
    /// slot index*, 0...visibleRows.count: the same space `dropPath` and the
    /// drag-drop indicator speak. Walks the visible-row stack (so nested rows
    /// participate) and resolves via `ReorderDropResolver` for parity with the
    /// reorder gesture.
    fileprivate func pinchInsertIndex(for point: CGPoint) -> Int {
        // Hot path: fires on every pinch recognizer tick. The cache
        // returns the same `[VisibleRow]` for as long as the document
        // is structurally stable.
        let (rows, _) = layoutCache.currentVisibleRows(
            snapshot: document.children, isCollapsed: isCollapsedSection
        )
        return resolveDropSlot(forY: point.y, in: rows)
    }
}
