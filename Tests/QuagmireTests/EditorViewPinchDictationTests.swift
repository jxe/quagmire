import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("EditorView pinch dictation")
struct EditorViewPinchDictationTests {
    @Test func transcriptFillsInsertedBlockAndKeepsNavigationMode() {
        let block = Block.bullet(text: AttributedString())
        let document = Document(id: DocumentID("test"), children: [block])
        let state = EditorState()
        state.setCursor(block.id)
        let host = PinchDictationTestHost()
        let editor = EditorView(document: document, state: state, host: host)
        editor.installUndoApply()

        editor.applyPinchDictationCompletion(.transcript("  captured thought  "), to: block.id)

        #expect(String(document.find(block.id)!.text.characters) == "captured thought")
        #expect(state.cursor == block.id)
        #expect(state.editingBlock == nil)
        #expect(document.undoManager!.canUndo)
        #expect(host.persistCalls == 1)
    }

    @Test func silenceLeavesABlankParagraphInNavigationMode() {
        let block = Block.paragraph(text: AttributedString())
        let document = Document(id: DocumentID("test"), children: [block])
        let state = EditorState()
        state.setCursor(block.id)
        let editor = EditorView(document: document, state: state, host: PinchDictationTestHost())
        editor.installUndoApply()

        editor.applyPinchDictationCompletion(.noSpeech, to: block.id)

        #expect(state.cursor == block.id)
        #expect(state.editingBlock == nil)
        #expect(document.find(block.id)!.kind == .paragraph(text: AttributedString()))
        #expect(!document.undoManager!.canUndo)
    }

    @Test func silenceTurnsABulletOrHeadingIntoABlankParagraph() {
        for inserted in [
            Block.bullet(text: AttributedString()),
            Block.heading(level: .h1, text: AttributedString()),
        ] {
            let document = Document(id: DocumentID("test"), children: [inserted])
            let state = EditorState()
            state.setCursor(inserted.id)
            let editor = EditorView(document: document, state: state, host: PinchDictationTestHost())
            editor.installUndoApply()

            editor.applyPinchDictationCompletion(.transcript("   "), to: inserted.id)

            #expect(document.find(inserted.id)!.kind == .paragraph(text: AttributedString()))
            #expect(state.cursor == inserted.id)
            #expect(state.editingBlock == nil)
        }
    }

    @Test func completionDoesNotOverwriteAChangedBlockOrStealMovedFocus() {
        let inserted = Block.paragraph(text: AttributedString("typed instead"))
        let other = Block.paragraph(text: AttributedString("other"))
        let document = Document(id: DocumentID("test"), children: [inserted, other])
        let state = EditorState()
        state.setCursor(other.id)
        let editor = EditorView(document: document, state: state, host: PinchDictationTestHost())
        editor.installUndoApply()

        editor.applyPinchDictationCompletion(.transcript("late transcript"), to: inserted.id)
        editor.applyPinchDictationCompletion(.noSpeech, to: inserted.id)

        #expect(String(document.find(inserted.id)!.text.characters) == "typed instead")
        #expect(state.cursor == other.id)
        #expect(state.editingBlock == nil)
    }

    @Test func volatileDraftChangesOnlyTheProvisionalRow() {
        let existing = Block.paragraph(text: AttributedString("existing"))
        let provisional = Block.bullet(text: AttributedString())
        let document = Document(id: DocumentID("test"), children: [existing])

        let draft = PinchDictationDraft(block: provisional, slot: 1)
            .replacingText(with: "  changing draft  ")

        #expect(String(draft.block.text.characters) == "changing draft")
        #expect(document.children == [existing])
    }

    @Test func lockedStylesShapeThePreviewAndTheCommittedBlock() {
        let contextual = Block.bullet(text: AttributedString())
        var draft = PinchDictationDraft(block: contextual, slot: 1)
            .replacingText(with: "spoken text")

        #expect(draft.style == .contextual)
        #expect(draft.block.kind == .bullet(text: AttributedString("spoken text")))
        #expect(draft.committedBlock.kind == .bullet(text: AttributedString()))

        draft = draft.withStyle(.heading)
        #expect(draft.block.kind == .heading(level: .h1, text: AttributedString("spoken text")))
        #expect(draft.committedBlock.kind == .heading(level: .h1, text: AttributedString()))

        draft = draft.withStyle(.indentedBullet)
        #expect(draft.block.kind == .bullet(text: AttributedString("spoken text")))
        #expect(draft.committedBlock.kind == .bullet(text: AttributedString()))

        draft = draft.withStyle(.divider)
        #expect(!draft.style.acceptsDictation)
        #expect(draft.block.kind == .divider)
        #expect(draft.committedBlock.kind == .divider)

        draft = draft.withStyle(.contextual)
        #expect(draft.block.kind == .bullet(text: AttributedString("spoken text")))
        #expect(draft.committedBlock.id == contextual.id)
    }

    @Test func headingPreviewShowsAPlaceholderUntilSpeechArrives() {
        let draft = PinchDictationDraft(block: .paragraph(), slot: 0).withStyle(.heading)
        #expect(draft.block.kind == .heading(level: .h1, text: AttributedString("Heading")))
    }

    @Test func lockArmsPartWayFromTheOpeningPointToTheTrailingEdge() {
        // Centred: 0.5 + 0.5 × 0.35 = 0.675, releasing below 0.625.
        let centred = PinchLockZone(origin: 0.5)
        #expect(centred.phase(after: .none, fraction: 0.67) == .none)
        #expect(centred.phase(after: .none, fraction: 0.68) == .armed)
        #expect(centred.phase(after: .armed, fraction: 0.64) == .armed)
        #expect(centred.phase(after: .armed, fraction: 0.6) == .none)
        #expect(centred.phase(after: .held, fraction: 0.1) == .held)

        // Leading: 0.2 + 0.8 × 0.35 = 0.48.
        let leading = PinchLockZone(origin: 0.2)
        #expect(leading.phase(after: .none, fraction: 0.47) == .none)
        #expect(leading.phase(after: .none, fraction: 0.49) == .armed)

        // Trailing: 0.8 + 0.2 × 0.35 = 0.87.
        let trailing = PinchLockZone(origin: 0.8)
        #expect(trailing.phase(after: .none, fraction: 0.86) == .none)
        #expect(trailing.phase(after: .none, fraction: 0.88) == .armed)
        #expect(trailing.exit > trailing.origin)

        let edge = PinchLockZone(origin: 0.97)
        #expect(edge.enter == PinchLockZone.maximumEnter)
        #expect(edge.phase(after: .none, fraction: 0.97) == .armed)
    }

    @Test func heldCaptureLayerTellsTapsFromSwipes() {
        #expect(PinchLockZone.release(for: CGSize(width: 3, height: -4)) == .tap)
        #expect(PinchLockZone.release(for: CGSize(width: -120, height: 20)) == .swipe)
        #expect(PinchLockZone.release(for: CGSize(width: 120, height: 90)) == .none)
        #expect(PinchLockZone.release(for: CGSize(width: 10, height: 140)) == .none)
    }

    @Test func slotBelowTheLastNestedBulletContinuesTheSubList() {
        let bar = Block.bullet(text: AttributedString("bar"))
        let foo = Block.bullet(text: AttributedString("foo"), children: [bar])
        let baz = Block.bullet(text: AttributedString("baz"))
        let document = Document(id: DocumentID("test"), children: [foo, baz])
        let editor = EditorView(document: document, state: EditorState(), host: PinchDictationTestHost())
        let (rows, _) = BlockLayoutCache().currentVisibleRows(snapshot: document.children, isCollapsed: { _ in false })

        // Between bar and baz: a sibling after bar, not a root row before baz.
        #expect(editor.dropPath(forVisibleSlot: 2, rows: rows) == DropPath(parent: foo.id, position: 1))
        // Other slots are unchanged.
        #expect(editor.dropPath(forVisibleSlot: 1, rows: rows) == DropPath(parent: foo.id, position: 0))
        #expect(editor.dropPath(forVisibleSlot: 3, rows: rows) == DropPath(parent: nil, position: 2))
    }

    @Test func trailingSlotBelowANestedBulletContinuesTheSubList() {
        let bar = Block.bullet(text: AttributedString("bar"))
        let foo = Block.bullet(text: AttributedString("foo"), children: [bar])
        let document = Document(id: DocumentID("test"), children: [foo])
        let editor = EditorView(document: document, state: EditorState(), host: PinchDictationTestHost())
        let (rows, _) = BlockLayoutCache().currentVisibleRows(snapshot: document.children, isCollapsed: { _ in false })

        #expect(editor.dropPath(forVisibleSlot: 2, rows: rows) == DropPath(parent: foo.id, position: 1))
    }

    @Test func reorderHoverMapsASubListAppendBackToItsSlot() {
        let qux = Block.bullet(text: AttributedString("qux"))
        let bar = Block.bullet(text: AttributedString("bar"), children: [qux])
        let foo = Block.bullet(text: AttributedString("foo"), children: [bar])
        let baz = Block.bullet(text: AttributedString("baz"))
        let document = Document(id: DocumentID("test"), children: [foo, baz])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: PinchDictationTestHost())
        let (rows, _) = BlockLayoutCache().currentVisibleRows(snapshot: document.children, isCollapsed: { _ in false })

        // foo, bar, qux, baz: the slot before baz extends qux's list.
        let path = editor.dropPath(forVisibleSlot: 3, rows: rows)
        #expect(path == DropPath(parent: bar.id, position: 1))
        state.currentDropTarget = .insertAt(path)
        #expect(editor.visibleSlotForCurrentDropPath(in: rows) == 3)
    }

    @Test func slotBelowAHeadingSectionStillLandsAtTheNextHeading() {
        let body = Block.paragraph(text: AttributedString("body"))
        let first = Block.heading(level: .h1, text: AttributedString("One"), children: [body])
        let second = Block.heading(level: .h1, text: AttributedString("Two"))
        let document = Document(id: DocumentID("test"), children: [first, second])
        let editor = EditorView(document: document, state: EditorState(), host: PinchDictationTestHost())
        let (rows, _) = BlockLayoutCache().currentVisibleRows(snapshot: document.children, isCollapsed: { _ in false })

        #expect(editor.dropPath(forVisibleSlot: 2, rows: rows) == DropPath(parent: nil, position: 1))
    }

    @Test func indentedInsertNestsUnderThePreviousSiblingInOneUndoStep() {
        let parent = Block.bullet(text: AttributedString("parent"))
        let document = Document(id: DocumentID("test"), children: [parent])
        let editor = EditorView(document: document, state: EditorState(), host: PinchDictationTestHost())
        editor.installUndoApply()
        let inserted = Block.bullet(text: AttributedString())

        editor.insertBlock(inserted, at: DropPath(parent: nil, position: 1), focus: false, indent: true)

        #expect(document.children.map(\.id) == [parent.id])
        #expect(document.find(parent.id)!.children.map(\.id) == [inserted.id])
        document.undoManager!.undo()
        #expect(document.find(inserted.id) == nil)
        #expect(document.children.map(\.id) == [parent.id])
    }

    @Test func indentedInsertWithNoPreviousSiblingStaysAtTheSlot() {
        let below = Block.paragraph(text: AttributedString("below"))
        let document = Document(id: DocumentID("test"), children: [below])
        let editor = EditorView(document: document, state: EditorState(), host: PinchDictationTestHost())
        editor.installUndoApply()
        let inserted = Block.bullet(text: AttributedString())

        editor.insertBlock(inserted, at: DropPath(parent: nil, position: 0), focus: false, indent: true)

        #expect(document.children.map(\.id) == [inserted.id, below.id])
    }

    @Test func provisionalChildrenUseTheSameRenderedDepthAsCommittedRows() {
        #expect(
            VisibleRowKind(.heading(level: .h2, text: AttributedString()))
                .childDepth(from: 2) == 2
        )
        #expect(VisibleRowKind(.bullet(text: AttributedString())).childDepth(from: 2) == 3)
    }

    @Test func delayedExternalTextTargetsTheOriginallyEditingBlock() {
        let editing = Block.paragraph(text: AttributedString("Before"))
        let voiceHeading = Block.heading(level: .h2, text: AttributedString("🎙 Recordings"))
        let document = Document(id: DocumentID("test"), children: [editing, voiceHeading])
        let state = EditorState()
        state.enterEditMode(on: editing.id)
        let host = PinchDictationTestHost()
        let editor = EditorView(document: document, state: state, host: host)
        editor.installUndoApply()
        editor.wireEditorCommands()

        let target = editor.editorCommands.activeEditingBlock()
        state.enterEditMode(on: voiceHeading.id)
        let inserted = target.map { editor.editorCommands.insertText("spoken words", $0) } ?? false

        #expect(inserted)
        #expect(String(document.find(editing.id)!.text.characters) == "Before spoken words")
        #expect(String(document.find(voiceHeading.id)!.text.characters) == "🎙 Recordings")
        #expect(host.persistCalls == 1)
    }

    @Test func inlineDictationAddsOnlyNeededBoundarySpaces() {
        #expect(inlineDictationInsertion("spoken", in: "Before", replacing: NSRange(location: 6, length: 0)) == " spoken")
        #expect(inlineDictationInsertion("spoken", in: "Before after", replacing: NSRange(location: 6, length: 0)) == " spoken")
        #expect(inlineDictationInsertion(" spoken ", in: "", replacing: NSRange(location: 0, length: 0)) == "spoken")
    }
}

@MainActor
private final class PinchDictationTestHost: EditorHostDefaults {
    var persistCalls = 0

    func persistCommit(changes: [DocumentChange], in document: Document) {
        persistCalls += 1
    }

    func flush(_ document: Document) async {}
}
