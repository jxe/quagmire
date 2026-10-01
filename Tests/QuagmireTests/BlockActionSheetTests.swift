import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Block action sheet selection")
struct BlockActionSheetTests {
    @Test func additionalRowsJoinWithoutChangingTheAnchor() {
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.paragraph(text: AttributedString("second"))
        let document = Document(id: DocumentID("test"), children: [first, second])
        var sheet = EditorView.BlockActionSheet(id: first.id)

        let stillOpen = sheet.toggleFromBackgroundSwipe(second.id, in: document)

        #expect(stillOpen)
        #expect(sheet.id == first.id)
        #expect(sheet.selectedIDs == [first.id, second.id])
    }

    @Test func swipingTheOnlySelectedRowAgainCloses() {
        let only = Block.paragraph(text: AttributedString("only"))
        let document = Document(id: DocumentID("test"), children: [only])
        var sheet = EditorView.BlockActionSheet(id: only.id)

        let stillOpen = sheet.toggleFromBackgroundSwipe(only.id, in: document)

        #expect(!stillOpen)
    }

    @Test func swipingTheAnchorAgainHandsTheMenuToTheFirstRemainingRow() {
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.paragraph(text: AttributedString("second"))
        let third = Block.paragraph(text: AttributedString("third"))
        let document = Document(id: DocumentID("test"), children: [first, second, third])
        var sheet = EditorView.BlockActionSheet(id: second.id)
        _ = sheet.toggleFromBackgroundSwipe(third.id, in: document)
        _ = sheet.toggleFromBackgroundSwipe(first.id, in: document)

        let stillOpen = sheet.toggleFromBackgroundSwipe(second.id, in: document)

        #expect(stillOpen)
        #expect(sheet.id == first.id)
        #expect(sheet.selectedIDs == [first.id, third.id])
    }

    @Test func targetsUseDocumentOrderAndCollapseCoveredDescendants() {
        let child = Block.paragraph(text: AttributedString("child"))
        let parent = Block.toggle(title: AttributedString("parent"), children: [child])
        let later = Block.paragraph(text: AttributedString("later"))
        let document = Document(id: DocumentID("test"), children: [parent, later])
        var sheet = EditorView.BlockActionSheet(id: later.id)

        _ = sheet.toggleFromBackgroundSwipe(child.id, in: document)
        _ = sheet.toggleFromBackgroundSwipe(parent.id, in: document)

        #expect(sheet.targetIDs(in: document) == [parent.id, later.id])
    }
}
