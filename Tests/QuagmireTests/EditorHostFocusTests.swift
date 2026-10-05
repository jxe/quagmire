import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Host focus requests")
struct EditorHostFocusTests {
    private func editor(_ blocks: [Block], readOnly: Bool = false) -> (EditorView, EditorState) {
        let state = EditorState()
        let document = Document(id: DocumentID("host-focus"), children: blocks)
        return (EditorView(document: document, state: state, host: HostFocusTestHost(), readOnly: readOnly), state)
    }

    @Test func selectionsClampToTheText() {
        #expect(EditorTextSelection.start.utf16Range(length: 5) == 0..<0)
        #expect(EditorTextSelection.end.utf16Range(length: 5) == 5..<5)
        #expect(EditorTextSelection.caret(9).utf16Range(length: 5) == 5..<5)
        #expect(EditorTextSelection.caret(-1).utf16Range(length: 5) == 0..<0)
        #expect(EditorTextSelection.range(2..<9).utf16Range(length: 5) == 2..<5)
        #expect(clampedSelection(3..<9, length: 5) == NSRange(location: 3, length: 2))
    }

    @Test func editEntersEditModeWithTheSelectionPending() {
        let heading = Block.heading(level: .h1, text: AttributedString("Plans"))
        let (editor, state) = editor([heading])
        state.edit(heading.id, selection: .range(1..<3))
        editor.performHostFocusRequest()
        #expect(state.editingBlock == heading.id)
        #expect(state.pendingInitialCursor == .range(1..<3))
        #expect(state.hostFocusRequest == nil)

        state.edit(heading.id)
        state.pendingInitialCursor = nil
        editor.performHostFocusRequest()
        // Not mounted: the request is carried by the next mount of the block.
        #expect(state.pendingInitialCursor == .range(5..<5))
    }

    @Test func editSelectsInPlaceInTheLiveEditor() {
        let paragraph = Block.paragraph(text: AttributedString("Hello"))
        let (editor, state) = editor([paragraph])
        state.enterEditMode(on: paragraph.id)
        let live = FakeLiveTextView(block: paragraph.id)
        editor.liveTextSelection.attach(live)
        state.edit(paragraph.id, selection: .caret(2))
        editor.performHostFocusRequest()
        #expect(live.applied == [NSRange(location: 2, length: 0)])
        #expect(state.pendingInitialCursor == nil)
    }

    @Test func blocksWithoutEditableTextAreSelected() {
        let divider = Block.divider()
        let (editor, state) = editor([divider])
        state.edit(divider.id)
        editor.performHostFocusRequest()
        #expect(state.editingBlock == nil)
        #expect(state.selection == [divider.id])
    }

    @Test func readOnlyEditorsSelectInsteadOfEditing() {
        let paragraph = Block.paragraph(text: AttributedString("Hello"))
        let (editor, state) = editor([paragraph], readOnly: true)
        state.edit(paragraph.id)
        editor.performHostFocusRequest()
        #expect(state.editingBlock == nil)
        #expect(state.selection == [paragraph.id])
    }

    @Test func missingBlocksAreIgnored() {
        let paragraph = Block.paragraph(text: AttributedString("Hello"))
        let (editor, state) = editor([paragraph])
        state.edit(BlockID())
        editor.performHostFocusRequest()
        #expect(state.editingBlock == nil)
        #expect(state.selection.isEmpty)
        #expect(state.hostFocusRequest == nil)
    }

    @Test func selectAndEndEditing() {
        let first = Block.paragraph(text: AttributedString("One"))
        let second = Block.paragraph(text: AttributedString("Two"))
        let (editor, state) = editor([first, second])
        state.enterEditMode(on: first.id)
        state.endEditing()
        editor.performHostFocusRequest()
        #expect(state.editingBlock == nil)
        #expect(state.selection == [first.id])

        state.select(second.id)
        editor.performHostFocusRequest()
        #expect(state.selection == [second.id])
        #expect(state.cursor == second.id)
    }

    @Test func textSelectionIsTheEditedBlocksOnly() {
        let first = Block.paragraph(text: AttributedString("One"))
        let second = Block.paragraph(text: AttributedString("Two"))
        let state = EditorState()
        state.noteTextSelection(1..<2, in: first.id)
        #expect(state.textSelection == nil)
        state.enterEditMode(on: first.id)
        #expect(state.textSelection == 1..<2)
        state.enterEditMode(on: second.id)
        #expect(state.textSelection == nil)
    }
}

@MainActor
private final class FakeLiveTextView: LiveTextSelectionView {
    let liveBlockID: BlockID?
    var applied: [NSRange] = []
    init(block: BlockID) { liveBlockID = block }
    func applyLiveSelection(_ range: NSRange) { applied.append(range) }
}

@MainActor
private final class HostFocusTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
