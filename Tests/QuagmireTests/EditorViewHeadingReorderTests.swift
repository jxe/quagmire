import CoreGraphics
import Foundation
import Testing
@testable import Quagmire

@Suite("Heading reorder outline")
@MainActor
struct EditorViewHeadingReorderTests {
    @Test func h1DragShowsOnlyH1sAndCannotPrecedePageTitle() {
        let titleBody = Block.paragraph(text: AttributedString("Title body"))
        let title = Block.heading(
            level: .h1,
            text: AttributedString("Title"),
            children: [titleBody]
        )
        let sectionBody = Block.paragraph(text: AttributedString("Section body"))
        let section = Block.heading(
            level: .h1,
            text: AttributedString("Section"),
            children: [sectionBody]
        )
        let last = Block.heading(level: .h1, text: AttributedString("Last"))
        let document = Document(id: DocumentID("test"), children: [title, section, last])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: HeadingReorderTestHost())
        let lift = headingLift(for: section, ids: editor.dragIDs(for: section.id), parent: nil, position: 1)
        state.setReorderLift(lift)

        let rows = editor.visibleRowsForRendering(snapshot: document.children)
        let sourceRow = editor.rowsBeforeReorderSourceRemoval(snapshot: document.children)
            .first(where: { $0.id == section.id })
        let candidates = editor.headingDropCandidates(rows: rows, level: .h1, lift: lift)

        #expect(rows.map(\.id) == [title.id, titleBody.id, last.id])
        #expect(!rows.contains(where: { $0.id == sectionBody.id }))
        #expect(candidates.map(\.slot) == [2, 3])
        #expect(candidates.map(\.path) == [
            DropPath(parent: nil, position: 2),
            DropPath(parent: nil, position: 3)
        ])
        editor.seedSourceDropTarget(for: lift, snapshot: document.children)
        #expect(state.currentDropTarget == .insertAt(candidates[0].path))
        state.currentDropTarget = .insertAt(candidates[0].path)
        #expect(editor.reorderDriftGap(
            at: 2,
            hoverSlot: 2,
            liftFootprint: nil,
            rows: rows,
            sourceRow: sourceRow
        ) == 80)
        state.currentDropTarget = .insertAt(candidates[1].path)
        #expect(editor.reorderDriftGap(
            at: 3,
            hoverSlot: 3,
            liftFootprint: nil,
            rows: rows,
            sourceRow: sourceRow
        ) == 80)

        var tallLift = lift
        tallLift.sourceFrame.size.height = 88
        state.setReorderLift(tallLift)
        #expect(editor.reorderDriftGap(
            at: 3,
            hoverSlot: 3,
            liftFootprint: nil,
            rows: rows,
            sourceRow: sourceRow
        ) == 128)
    }

    @Test func h2OutlineTraversesFoldedH1sAndOffersCrossParentBoundaries() {
        let firstIntro = Block.paragraph(text: AttributedString("First intro"))
        let movingBody = Block.paragraph(text: AttributedString("Moving body"))
        let moving = Block.heading(
            level: .h2,
            text: AttributedString("Moving"),
            children: [movingBody]
        )
        let first = Block.heading(
            level: .h1,
            text: AttributedString("First"),
            children: [firstIntro, moving]
        )
        let secondIntro = Block.paragraph(text: AttributedString("Second intro"))
        let destinationBody = Block.paragraph(text: AttributedString("Destination body"))
        let destination = Block.heading(
            level: .h2,
            text: AttributedString("Destination"),
            children: [destinationBody]
        )
        let second = Block.heading(
            level: .h1,
            text: AttributedString("Second"),
            children: [secondIntro, destination]
        )
        let document = Document(id: DocumentID("test"), children: [first, second])
        let state = EditorState()
        state.collapsedHeadings = [first.id, second.id]
        let editor = EditorView(document: document, state: state, host: HeadingReorderTestHost())
        let movingIDs = editor.dragIDs(for: moving.id)
        let lift = headingLift(for: moving, ids: movingIDs, parent: first.id, position: 1)
        state.setReorderLift(lift)

        let rows = editor.visibleRowsForRendering(snapshot: document.children)
        let candidates = editor.headingDropCandidates(rows: rows, level: .h2, lift: lift)

        #expect(rows.map(\.id) == [first.id, firstIntro.id, second.id, destination.id])
        #expect(state.collapsedHeadings == [first.id, second.id])
        #expect(candidates.map(\.slot) == [2, 3, 4])
        #expect(candidates.map(\.path) == [
            DropPath(parent: first.id, position: 2),
            DropPath(parent: second.id, position: 1),
            DropPath(parent: second.id, position: 2)
        ])

        #expect(document.moveSubtrees(
            movingIDs,
            to: DropPath(parent: second.id, position: 1)
        ))

        #expect(document.children[0].children.map(\.id) == [firstIntro.id])
        #expect(document.children[1].children.map(\.id) == [secondIntro.id, moving.id, destination.id])
        #expect(document.find(moving.id)?.children.map(\.id) == [movingBody.id])
    }

    @Test func pageTitleCannotBeginAReorderLift() {
        let title = Block.heading(level: .h1, text: AttributedString("Title"))
        let section = Block.heading(level: .h1, text: AttributedString("Section"))
        let document = Document(id: DocumentID("test"), children: [title, section])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: HeadingReorderTestHost())
        editor.layoutCache.updateOrder([title.id, section.id])
        editor.layoutCache.setHeight(40, for: title.id)
        editor.layoutCache.setHeight(40, for: section.id)

        #expect(!editor.shouldBeginIOSReorder(on: title.id, at: CGPoint(x: 10, y: 20)))
        editor.preliftReorder(blockID: title.id)
        #expect(state.reorderLift == nil)

        editor.preliftReorder(blockID: section.id)
        #expect(state.reorderLift?.block.id == section.id)
        #expect(state.reorderLift?.outlineHeadingLevel == .h1)
    }

    @Test func ordinaryMoveRemovesItsWholeSubtreeButCopyKeepsIt() {
        let child = Block.paragraph(text: AttributedString("Child"))
        let moving = Block.toggle(title: AttributedString("Moving"), children: [child])
        let last = Block.paragraph(text: AttributedString("Last"))
        let document = Document(id: DocumentID("test"), children: [moving, last])
        let state = EditorState()
        state.expandedToggles.insert(moving.id)
        let editor = EditorView(document: document, state: state, host: HeadingReorderTestHost())
        var lift = headingLift(
            for: moving,
            ids: editor.dragIDs(for: moving.id),
            parent: nil,
            position: 0
        )
        lift.outlineHeadingLevel = nil
        state.setReorderLift(lift)

        #expect(editor.visibleRowsForRendering(snapshot: document.children).map(\.id) == [last.id])

        lift.isCopy = true
        state.setReorderLift(lift)
        #expect(editor.visibleRowsForRendering(snapshot: document.children).map(\.id) == [
            moving.id, child.id, last.id
        ])
    }

    @Test func completedHeadingMoveClearsProjectionAndPreservesFoldState() {
        let title = Block.heading(level: .h1, text: AttributedString("Title"))
        let movingBody = Block.paragraph(text: AttributedString("Moving body"))
        let moving = Block.heading(
            level: .h1,
            text: AttributedString("Moving"),
            children: [movingBody]
        )
        let foldedBody = Block.paragraph(text: AttributedString("Folded body"))
        let folded = Block.heading(
            level: .h1,
            text: AttributedString("Folded"),
            children: [foldedBody]
        )
        let document = Document(id: DocumentID("test"), children: [title, moving, folded])
        let state = EditorState()
        state.collapsedHeadings = [folded.id]
        let editor = EditorView(document: document, state: state, host: HeadingReorderTestHost())
        // `EditorView.onAppear` normally installs this relationship. The unit
        // test calls the completion handler directly, so provide the same
        // transaction wiring explicitly.
        editor.undoController.document = document
        let lift = headingLift(
            for: moving,
            ids: editor.dragIDs(for: moving.id),
            parent: nil,
            position: 1
        )
        state.setReorderLift(lift)
        state.currentDropTarget = .insertAt(DropPath(parent: nil, position: 3))

        editor.endReorderLift(atY: 0, snapshot: document.children)

        #expect(document.children.map(\.id) == [title.id, folded.id, moving.id])
        #expect(state.reorderLift == nil)
        #expect(state.currentDropTarget == nil)
        #expect(state.collapsedHeadings == [folded.id])
        #expect(editor.visibleRowsForRendering(snapshot: document.children).map(\.id) == [
            title.id, folded.id, moving.id, movingBody.id
        ])
    }

    @Test func cancelledHeadingMoveRestoresRowsAndPreservesFoldState() {
        let title = Block.heading(level: .h1, text: AttributedString("Title"))
        let movingBody = Block.paragraph(text: AttributedString("Moving body"))
        let moving = Block.heading(
            level: .h1,
            text: AttributedString("Moving"),
            children: [movingBody]
        )
        let folded = Block.heading(level: .h1, text: AttributedString("Folded"))
        let document = Document(id: DocumentID("test"), children: [title, moving, folded])
        let state = EditorState()
        state.collapsedHeadings = [folded.id]
        let editor = EditorView(document: document, state: state, host: HeadingReorderTestHost())
        let lift = headingLift(
            for: moving,
            ids: editor.dragIDs(for: moving.id),
            parent: nil,
            position: 1
        )
        state.setReorderLift(lift)
        state.currentDropTarget = .insertAt(DropPath(parent: nil, position: 3))

        editor.cancelReorderLift()

        #expect(document.children.map(\.id) == [title.id, moving.id, folded.id])
        #expect(state.reorderLift == nil)
        #expect(state.currentDropTarget == nil)
        #expect(state.collapsedHeadings == [folded.id])
        #expect(editor.visibleRowsForRendering(snapshot: document.children).map(\.id) == [
            title.id, moving.id, movingBody.id, folded.id
        ])
    }

    private func headingLift(
        for block: Block,
        ids: [BlockID],
        parent: BlockID?,
        position: Int
    ) -> ReorderLift {
        ReorderLift(
            block: block,
            ids: ids,
            sourceParentID: parent,
            sourcePositions: position...position,
            draggedSubtreeIDs: Set(ids),
            outlineHeadingLevel: block.headingLevel,
            sourceFrame: CGRect(x: 0, y: 0, width: 300, height: 40),
            touchOffset: CGSize(width: 10, height: 20),
            location: CGPoint(x: 10, y: 20),
            pendingAnchor: false
        )
    }
}

@MainActor
private final class HeadingReorderTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
