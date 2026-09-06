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

    @Test func silenceFocusesTheEmptyInsertedBlock() {
        let block = Block.paragraph(text: AttributedString())
        let document = Document(id: DocumentID("test"), children: [block])
        let state = EditorState()
        state.setCursor(block.id)
        let editor = EditorView(document: document, state: state, host: PinchDictationTestHost())
        editor.installUndoApply()

        editor.applyPinchDictationCompletion(.noSpeech, to: block.id)

        #expect(state.editingBlock == block.id)
        #expect(document.find(block.id)!.text.characters.isEmpty)
        #expect(!document.undoManager!.canUndo)
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

    @Test func thirdFingerTapCyclesThroughAllFourInsertionModes() {
        let contextual = Block.bullet(text: AttributedString())
        var draft = PinchDictationDraft(block: contextual, slot: 1)
            .replacingText(with: "spoken contextual text")

        #expect(draft.insertionMode == .contextual)
        #expect(draft.insertionMode.acceptsDictation)
        #expect(String(draft.block.text.characters) == "spoken contextual text")

        draft = draft.cyclingInsertionMode()
        #expect(draft.insertionMode == .divider)
        #expect(!draft.insertionMode.acceptsDictation)
        #expect(draft.block.kind == .divider)

        draft = draft.replacingText(with: "spoken heading text")
        #expect(draft.block.kind == .divider)

        draft = draft.cyclingInsertionMode()
        #expect(draft.insertionMode == .heading)
        #expect(draft.insertionMode.acceptsDictation)
        #expect(String(draft.block.text.characters) == "spoken heading text")
        #expect(draft.committedBlock.kind == .heading(level: .h1, text: AttributedString()))

        draft = draft.cyclingInsertionMode()
        #expect(draft.insertionMode == .emptyParagraph)
        #expect(!draft.insertionMode.acceptsDictation)
        #expect(draft.block.kind == .paragraph(text: AttributedString()))
        #expect(draft.committedBlock.kind == .paragraph(text: AttributedString()))

        draft = draft.cyclingInsertionMode()
        #expect(draft.insertionMode == .contextual)
        #expect(draft.insertionMode.acceptsDictation)
        #expect(String(draft.block.text.characters) == "spoken heading text")
    }

    @Test func thirdTapMustLandInTheOpenSpaceBetweenPinchFingers() {
        let first = CGPoint(x: 20, y: 100)
        let second = CGPoint(x: 220, y: 100)

        #expect(PagePinchThirdTapGeometry.contains(CGPoint(x: 120, y: 110), between: first, and: second))
        #expect(!PagePinchThirdTapGeometry.contains(CGPoint(x: 25, y: 100), between: first, and: second))
        #expect(!PagePinchThirdTapGeometry.contains(CGPoint(x: 120, y: 190), between: first, and: second))
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
