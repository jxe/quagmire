import SwiftUI

// MARK: - Pinch-open-to-insert (iOS)

/// What a pinch inserts. An unlocked release is always `contextual`; the
/// other styles are chosen while the pinch is locked open.
enum PinchInsertStyle: Equatable, Sendable {
    /// The neighbour-shaped block (bullet, numbered, todo, quote, or
    /// paragraph) with whatever was said.
    case contextual
    /// An H1 made of whatever was said.
    case heading
    /// A bullet nested one level under the row above.
    case indentedBullet
}

/// Sliding an open pinch into the trailing band of the screen locks it:
/// `armed` while the fingers are still down there, `held` once they lift.
/// While held, recording continues until a tap finishes it.
enum PinchLockPhase: Equatable, Sendable {
    case none
    case armed
    case held
}

/// The lock zone for one pinch, measured from where the finger midpoint sat
/// when the gap first opened (`origin`, a fraction of the visible width).
/// Arming takes a slide a third of the way from there to the trailing edge, so a pinch
/// opened near the leading edge travels further than one opened near the
/// middle, and one opened near the trailing edge still needs a deliberate
/// slide rather than locking at once.
///
/// The mirror-image slide toward the leading edge arms typing instead: the
/// recorder stops, and the release inserts the contextual block with the
/// keyboard up.
struct PinchLockZone: Equatable {
    /// Share of the remaining distance to the trailing edge that arms.
    static let travel: CGFloat = 0.35
    /// Keep the zone reachable for a pinch opened hard against the edge.
    static let maximumEnter: CGFloat = 0.92
    /// The leading-edge counterpart of `maximumEnter`, for typing.
    static let minimumTypeEnter: CGFloat = 0.08
    /// Arming releases this far short of `enter`, so a hand resting on the
    /// boundary doesn't flicker in and out.
    static let hysteresis: CGFloat = 0.05

    let origin: CGFloat

    init(origin: CGFloat) {
        self.origin = min(1, max(0, origin))
    }

    /// Midpoint fraction of the visible width that arms the lock.
    var enter: CGFloat {
        min(Self.maximumEnter, origin + (1 - origin) * Self.travel)
    }

    var exit: CGFloat {
        max(origin, enter - Self.hysteresis)
    }

    /// How far a midpoint at `fraction` has slid from the origin toward
    /// arming, 0…1, for the lock preview shown before it arms.
    func progress(fraction: CGFloat) -> CGFloat {
        guard enter > origin else { return 1 }
        return min(1, max(0, (fraction - origin) / (enter - origin)))
    }

    /// The next finger-down phase for a midpoint at `fraction`. `held` is
    /// never produced here; it only follows a release while `armed`.
    func phase(after current: PinchLockPhase, fraction: CGFloat) -> PinchLockPhase {
        switch current {
        case .none: fraction >= enter ? .armed : .none
        case .armed: fraction < exit ? .none : .armed
        case .held: .held
        }
    }

    /// Midpoint fraction of the visible width that arms typing.
    var typeEnter: CGFloat {
        max(Self.minimumTypeEnter, origin - origin * Self.travel)
    }

    var typeExit: CGFloat {
        min(origin, typeEnter + Self.hysteresis)
    }

    /// How far a midpoint at `fraction` has slid from the origin toward
    /// arming typing, 0…1.
    func typeProgress(fraction: CGFloat) -> CGFloat {
        guard typeEnter < origin else { return 1 }
        return min(1, max(0, (origin - fraction) / (origin - typeEnter)))
    }

    /// Whether typing is armed for a midpoint at `fraction`, given whether
    /// it was armed before.
    func isTyping(after current: Bool, fraction: CGFloat) -> Bool {
        current ? fraction <= typeExit : fraction <= typeEnter
    }

    /// A drag on the held capture layer finishes only when it is a
    /// near-stationary tap, so a stray drag doesn't end the recording.
    static let tapSlop: CGFloat = 12

    static func isTap(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) <= tapSlop
    }
}

struct PinchDictationDraft {
    var block: Block
    var slot: Int
    /// When the recorder reported it had started, for the recording cue.
    /// Nil while it is still activating, or when there is no recorder.
    var recordingSince: Date?
    private var contextualBlock: Block
    private var latestTranscript = ""
    private(set) var style: PinchInsertStyle = .contextual

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

    func withStyle(_ style: PinchInsertStyle) -> PinchDictationDraft {
        var copy = self
        copy.style = style
        copy.refreshPreviewBlock()
        return copy
    }

    /// The block to insert, empty: speech arrives through
    /// `applyPinchDictationCompletion` once the recorder finishes.
    var committedBlock: Block {
        switch style {
        case .contextual:
            contextualBlock
        case .heading:
            .heading(level: .h1, text: AttributedString(), id: block.id)
        case .indentedBullet:
            .bullet(text: AttributedString(), id: block.id)
        }
    }

    private mutating func refreshPreviewBlock() {
        switch style {
        case .contextual:
            block = contextualBlock.withText(AttributedString(latestTranscript))
        case .heading:
            let text = latestTranscript.isEmpty ? "Heading" : latestTranscript
            block = .heading(level: .h1, text: AttributedString(text), id: block.id)
        case .indentedBullet:
            block = .bullet(text: AttributedString(latestTranscript), id: block.id)
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
                // The insert's impact fires as the gap animates closed; a
                // cold generator would add its setup to that frame.
                Haptics.prepareHeavy(enabled: configuration.isHapticFeedbackEnabled)
                SoundFX.play(.pinchOpen, enabled: configuration.isAudioFeedbackEnabled)
                preparePinchDictationDraft(at: insertIndex)
                beginPinchDictationIfAvailable()
                pinchLockZone = PinchLockZone(origin: value.horizontalFraction)
            }
            if pinchCrossedInsertThreshold {
                updatePinchLock(fraction: value.horizontalFraction)
                updatePinchTyping(fraction: value.horizontalFraction)
            }
            return true
        } else if state.pinchPreview != nil {
            // Pinched back below deadzone after opening — close the preview
            // visually but keep `pinchGestureActive` latched so a re-open
            // doesn't ping-pong the swipe/reorder gates.
            withAnimation(.spring(response: 0.22, dampingFraction: 0.95)) {
                state.setPinchPreview(nil)
            }
            clearPinchThresholds()
        }
        return false
    }

    /// Reset the pinch's per-gesture bookkeeping (insert-slot anchor + the
    /// threshold-crossed latch + a not-yet-held lock). The preview state
    /// itself is owned by `EditorState.pinchPreview` and cleared separately.
    private func clearPinchThresholds() {
        pinchPendingInsertIndex = nil
        pinchCrossedInsertThreshold = false
        pinchLockProgress = 0
        pinchTypeArmed = false
        pinchTypeProgress = 0
        if pinchLock == .armed {
            pinchLock = .none
            pinchInsertStyle = .contextual
        }
        pinchLockZone = nil
    }

    /// Arm or disarm the lock as the finger midpoint moves across the screen.
    private func updatePinchLock(fraction: CGFloat) {
        let zone = pinchLockZone ?? PinchLockZone(origin: fraction)
        let progress = zone.progress(fraction: fraction)
        if abs(progress - pinchLockProgress) > 0.01 || (progress == 1) != (pinchLockProgress == 1) {
            pinchLockProgress = progress
        }
        let next = zone.phase(after: pinchLock, fraction: fraction)
        guard next != pinchLock else { return }
        // The lock fills and the style buttons appear together on arming,
        // with a firm tap, so the lock is felt before the fingers lift.
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            pinchLock = next
            if next == .none { pinchInsertStyle = .contextual }
        }
        if next == .armed {
            Haptics.medium(enabled: configuration.isHapticFeedbackEnabled)
        } else {
            Haptics.light(enabled: configuration.isHapticFeedbackEnabled)
        }
        configuration.diagnostics.pinch.debug(
            "pinch lock \(String(describing: next), privacy: .public)"
        )
    }

    /// Arm or disarm typing as the finger midpoint slides toward the leading
    /// edge. Arming stops the recorder at once, so nothing is captured while
    /// the fingers are there; sliding back out starts it again.
    private func updatePinchTyping(fraction: CGFloat) {
        guard pinchLock == .none else { return }
        let zone = pinchLockZone ?? PinchLockZone(origin: fraction)
        let progress = zone.typeProgress(fraction: fraction)
        if abs(progress - pinchTypeProgress) > 0.01 || (progress == 1) != (pinchTypeProgress == 1) {
            pinchTypeProgress = progress
        }
        let next = zone.isTyping(after: pinchTypeArmed, fraction: fraction)
        guard next != pinchTypeArmed else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            pinchTypeArmed = next
            if next {
                pinchDictationDraft?.recordingSince = nil
                pinchDictationDraft = pinchDictationDraft?.replacingText(with: "")
            }
        }
        if next {
            cancelPinchDictationIfNeeded()
            Haptics.medium(enabled: configuration.isHapticFeedbackEnabled)
        } else {
            beginPinchDictationIfAvailable()
            Haptics.light(enabled: configuration.isHapticFeedbackEnabled)
        }
        configuration.diagnostics.pinch.debug(
            "pinch typing \(next, privacy: .public)"
        )
    }

    func handlePinchCommit(_ value: PagePinchValue) {
        let preview = state.pinchPreview
        let gap = preview?.gapHeight ?? pinchRubberBand(max(0, value.spreadDelta))

        if gap >= Self.pinchInsertCommitGap, state.editingBlock == nil {
            let slot = pinchPendingInsertIndex
                ?? preview?.insertIndex
                ?? pinchInsertIndex(for: value.startLocation)
            if pinchLock == .armed {
                // Released inside the lock zone: keep the gap and the recorder
                // open. A tap on the held overlay finishes.
                pinchPendingInsertIndex = slot
                Haptics.light(enabled: configuration.isHapticFeedbackEnabled)
                pinchLock = .held
                configuration.diagnostics.pinch.debug("pinch held open")
                return
            }
            commitPinchInsert(at: slot, style: .contextual, typing: pinchTypeArmed)
        } else {
            cancelPinchDictationIfNeeded()
            pinchDictationDraft = nil
            // Collapse without overshoot: a bounce reads as the page wobbling.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.95)) {
                state.setPinchPreview(nil)
            }
        }
        resetPinchGesture()
    }

    /// Finish a held pinch: insert the block in the toggled style.
    func finishLockedPinch() {
        guard pinchLock == .held else { return }
        let slot = pinchPendingInsertIndex
            ?? state.pinchPreview?.insertIndex
            ?? pinchDictationDraft?.slot
        if let slot, state.editingBlock == nil {
            commitPinchInsert(at: slot, style: pinchInsertStyle)
        } else {
            cancelPinchDictationIfNeeded()
            pinchDictationDraft = nil
            // Collapse without overshoot: a bounce reads as the page wobbling.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.95)) {
                state.setPinchPreview(nil)
            }
        }
        withAnimation(.easeOut(duration: 0.16)) {
            resetPinchGesture()
        }
    }

    /// Toggle one of the locked pinch's style buttons. Heading and Indent are
    /// mutually exclusive; toggling the active one returns to contextual.
    func togglePinchInsertStyle(_ style: PinchInsertStyle) {
        guard pinchLock != .none else { return }
        let next: PinchInsertStyle = pinchInsertStyle == style ? .contextual : style
        pinchInsertStyle = next
        pinchDictationDraft = pinchDictationDraft?.withStyle(next)
        Haptics.light(enabled: configuration.isHapticFeedbackEnabled)
    }

    private func resetPinchGesture() {
        clearPinchThresholds()
        pinchLock = .none
        pinchInsertStyle = .contextual
        pinchGestureActive = false
    }

    /// `typing` inserts without dictation and opens the keyboard on the new
    /// block, for a pinch released in the leading type zone.
    private func commitPinchInsert(at slot: Int, style: PinchInsertStyle, typing: Bool = false) {
        // Resolve the visible slot to a tree DropPath, with the visible-row
        // above/below at that slot as neighbour context for kind inference.
        let (rows, _) = layoutCache.currentVisibleRows(
            snapshot: document.children, isCollapsed: isCollapsedSection
        )
        let path = dropPath(forVisibleSlot: slot, rows: rows)
        let above: VisibleRowKind? = (slot - 1 >= 0 && slot - 1 < rows.count) ? rows[slot - 1].kind : nil
        let below: VisibleRowKind? = (slot >= 0 && slot < rows.count) ? rows[slot].kind : nil
        let draft = pinchDictationDraft?.withStyle(style)
        let newBlock = draft?.committedBlock ?? smartInsertBlock(above: above, below: below)
        let usesDictation = !typing && pinchDictation != nil
        // Without a recorder (or when typing was chosen) the pinch is a plain
        // insert that opens the keyboard. With one, the block waits in
        // navigation mode for the transcript (or becomes a blank paragraph
        // on silence).
        let focusesTextBlock = !usesDictation
        configuration.diagnostics.pinch.debug(
            "pinch committed style=\(String(describing: style), privacy: .public) dictation=\(usesDictation, privacy: .public) typing=\(typing, privacy: .public)"
        )
        // Bundle the structural insert and the gap collapse into the same
        // spring transaction so the new row appears inside the opened gap
        // and the surrounding rows close in around it. Without the shared
        // animation transaction the gap snap-closes first and the new row
        // pops in afterwards — visually disjoint.
        Haptics.heavy(enabled: configuration.isHapticFeedbackEnabled)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            insertBlock(newBlock, at: path, focus: focusesTextBlock, indent: style == .indentedBullet)
            if usesDictation {
                transferFocus(to: .nav(cursor: newBlock.id))
            }
            state.setPinchPreview(nil)
        }
        if usesDictation {
            pinchDictationDraft = draft
            finishPinchDictation(for: newBlock.id)
        } else {
            cancelPinchDictationIfNeeded()
            pinchDictationDraft = nil
        }
    }

    private func beginPinchDictationIfAvailable() {
        guard pinchDictationBeginTask == nil,
              pinchDictationCompletionTask == nil,
              let pinchDictation else { return }
        let pendingCancel = pinchDictationCancelTask
        pinchDictationBeginTask = Task { @MainActor in
            // A recorder stopped by sliding into the type zone may still be
            // shutting down; the shared recorder refuses a second begin.
            await pendingCancel?.value
            let started = await pinchDictation.begin { draft in
                updatePinchDictationDraft(draft)
            }
            if started, pinchDictationDraft?.recordingSince == nil {
                pinchDictationDraft?.recordingSince = .now
            }
            return started
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
        let slotDepth = path.parent.flatMap { parent in
            visibleRows.first(where: { $0.id == parent })
        }.map { $0.kind.childDepth(from: $0.depth) } ?? 0
        let depth = slotDepth + (draft.style == .indentedBullet && path.position > 0 ? 1 : 0)
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
        .overlay(alignment: .trailing) {
            // Shown from the insert threshold, so the lock is visible (and
            // its distance readable) before the slide arms it. Once held,
            // the lock gives way to the stop button in the bottom bar.
            if pinchCrossedInsertThreshold || pinchLock != .none {
                // Left to right, as the slides go: type, then lock.
                HStack(spacing: 8) {
                    if pinchLock == .none {
                        PinchTypeBadge(isArmed: pinchTypeArmed, progress: pinchTypeProgress)
                    }
                    if let since = draft.recordingSince {
                        PinchRecordingIndicator(since: since)
                    }
                    if pinchLock != .held && !pinchTypeArmed {
                        PinchLockBadge(phase: pinchLock, progress: pinchLockProgress)
                    }
                }
            }
        }
    }

    private func cancelPinchDictationIfNeeded() {
        guard let beginTask = pinchDictationBeginTask,
              let pinchDictation else { return }
        pinchDictationBeginTask = nil
        pinchDictationCancelTask = Task { @MainActor in
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

        let transcript: String
        switch completion {
        case .transcript(let rawTranscript):
            transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        case .noSpeech, .failed:
            transcript = ""
        }
        guard !transcript.isEmpty else {
            // Nothing was said: whatever style was chosen, leave a blank
            // paragraph selected in navigation mode, without the keyboard.
            if case .paragraph = block.kind {} else {
                mutate("Blank Paragraph") {
                    document.mutate(blockID) { current in
                        current = .paragraph(id: blockID, children: current.children)
                    }
                }
            }
            if isStillWaitingAtInsertedBlock {
                transferFocus(to: .nav(cursor: blockID))
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
