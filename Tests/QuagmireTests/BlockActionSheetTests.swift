import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Block action sheet selection")
struct BlockActionSheetTests {
    @Test func additionalRowsJoinWithoutChangingTheAnchor() {
        let first = BlockID()
        let second = BlockID()
        var sheet = EditorView.BlockActionSheet(id: first)

        sheet.selectFromBackgroundSwipe(second)

        #expect(sheet.id == first)
        #expect(sheet.selectedIDs == [first, second])
    }

    @Test func selectingTheSameRowTwiceIsIdempotent() {
        let id = BlockID()
        var sheet = EditorView.BlockActionSheet(id: id)

        sheet.selectFromBackgroundSwipe(id)

        #expect(sheet.selectedIDs == [id])
    }

    @Test func targetsUseDocumentOrderAndCollapseCoveredDescendants() {
        let child = Block.paragraph(text: AttributedString("child"))
        let parent = Block.toggle(title: AttributedString("parent"), children: [child])
        let later = Block.paragraph(text: AttributedString("later"))
        let document = Document(id: DocumentID("test"), children: [parent, later])
        var sheet = EditorView.BlockActionSheet(id: later.id)

        sheet.selectFromBackgroundSwipe(child.id)
        sheet.selectFromBackgroundSwipe(parent.id)

        #expect(sheet.targetIDs(in: document) == [parent.id, later.id])
    }
}
