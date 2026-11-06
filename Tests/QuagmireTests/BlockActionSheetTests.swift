import Foundation
import Testing
@testable import Quagmire

/// The block menu acts on the nav-mode selection on both platforms. On iOS a
/// swipe on another row while the menu is up toggles that row in it.
@MainActor
@Suite("Block action sheet selection")
struct BlockActionSheetTests {
    private func swipe(
        _ id: BlockID,
        _ selection: inout Selection,
        _ sheet: EditorView.BlockActionSheet,
        in document: Document
    ) -> EditorView.BlockActionSheet? {
        selection.toggle(id, in: document)
        return sheet.following(selection.blocks, in: document)
    }

    @Test func additionalRowsJoinWithoutChangingTheAnchor() {
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.paragraph(text: AttributedString("second"))
        let document = Document(id: DocumentID("test"), children: [first, second])
        var selection = Selection(blocks: [first.id], anchor: first.id, cursor: first.id)

        let sheet = swipe(second.id, &selection, EditorView.BlockActionSheet(id: first.id), in: document)

        #expect(sheet?.id == first.id)
        #expect(selection.blocks == [first.id, second.id])
        #expect(selection.anchor == first.id)
    }

    @Test func swipingTheOnlySelectedRowAgainCloses() {
        let only = Block.paragraph(text: AttributedString("only"))
        let document = Document(id: DocumentID("test"), children: [only])
        var selection = Selection(blocks: [only.id], anchor: only.id, cursor: only.id)

        let sheet = swipe(only.id, &selection, EditorView.BlockActionSheet(id: only.id), in: document)

        #expect(sheet == nil)
        #expect(selection == Selection())
    }

    @Test func swipingTheAnchorAgainHandsTheMenuToTheFirstRemainingRow() {
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.paragraph(text: AttributedString("second"))
        let third = Block.paragraph(text: AttributedString("third"))
        let document = Document(id: DocumentID("test"), children: [first, second, third])
        var selection = Selection(blocks: [second.id], anchor: second.id, cursor: second.id)
        var sheet = EditorView.BlockActionSheet(id: second.id)
        sheet = swipe(third.id, &selection, sheet, in: document)!
        sheet = swipe(first.id, &selection, sheet, in: document)!

        let after = swipe(second.id, &selection, sheet, in: document)

        #expect(after?.id == first.id)
        #expect(selection.blocks == [first.id, third.id])
        #expect(selection.anchor == first.id)
    }

    @Test func targetsUseDocumentOrderAndCollapseCoveredDescendants() {
        let child = Block.paragraph(text: AttributedString("child"))
        let parent = Block.toggle(title: AttributedString("parent"), children: [child])
        let later = Block.paragraph(text: AttributedString("later"))
        let document = Document(id: DocumentID("test"), children: [parent, later])
        var selection = Selection(blocks: [later.id], anchor: later.id, cursor: later.id)

        selection.toggle(child.id, in: document)
        selection.toggle(parent.id, in: document)

        #expect(document.selectionSubtreeRoots(selection.blocks) == [parent.id, later.id])
    }
}
