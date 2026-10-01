import CoreGraphics
import Foundation
import Testing
@testable import Quagmire

@Suite("Reorder slot tracking")
@MainActor
struct EditorViewReorderSlotTests {
    /// Four 24pt paragraphs with no spacing; `b` is lifted, so the frozen
    /// destination frames are a 0–24, c 24–48, d 48–72.
    private func liftSecondRow(touchOffsetY: CGFloat) -> (EditorView, EditorState, [Block]) {
        let blocks = ["a", "b", "c", "d"].map { Block.paragraph(text: AttributedString($0)) }
        let document = Document(id: DocumentID("test"), children: blocks)
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: ReorderSlotTestHost())
        let ids = blocks.map(\.id)
        editor.layoutCache.updateOrder(ids)
        for id in ids { editor.layoutCache.setHeight(24, for: id) }
        editor.layoutCache.contentWidth = 320
        editor.layoutCache.beginReorderFrameSnapshot(rebaseOnNextOrderChange: true)
        let lift = ReorderLift(
            block: blocks[1],
            ids: [blocks[1].id],
            sourceParentID: nil,
            sourcePositions: 1...1,
            draggedSubtreeIDs: [blocks[1].id],
            outlineHeadingLevel: nil,
            sourceFrame: CGRect(x: 0, y: 24, width: 320, height: 24),
            touchOffset: CGSize(width: 10, height: touchOffsetY),
            location: CGPoint(x: 10, y: 24 + touchOffsetY),
            pendingAnchor: false
        )
        state.setReorderLift(lift)
        editor.seedSourceDropTarget(for: lift, snapshot: document.children)
        editor.layoutCache.updateOrder([ids[0], ids[2], ids[3]])
        return (editor, state, blocks)
    }

    @Test func liftKeepsTheSourceRowsIndent() {
        let child = Block.bullet(text: AttributedString("child"))
        let parent = Block.bullet(text: AttributedString("parent"), children: [child])
        let document = Document(id: DocumentID("test"), children: [parent])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: ReorderSlotTestHost())
        editor.layoutCache.updateOrder([parent.id, child.id])
        editor.layoutCache.setHeight(24, for: parent.id)
        editor.layoutCache.setHeight(24, for: child.id)

        editor.preliftReorder(blockID: child.id)

        #expect(state.reorderLift?.sourceDepth == 1)
    }

    @Test func seededSourceSlotRendersItsGap() {
        let (editor, _, blocks) = liftSecondRow(touchOffsetY: 12)
        let rows = editor.visibleRowsForRendering(snapshot: blocks)

        // The hole is exactly the lifted row plus the one extra
        // paragraph-to-paragraph spacing it brings back.
        let spacing = BlockSpacing.gap(before: rows[1].kind, depth: 0, after: rows[0].kind, prevDepth: 0)
        #expect(rows.map(\.id) == [blocks[0].id, blocks[2].id, blocks[3].id])
        #expect(editor.visibleSlotForCurrentDropPath(in: rows) == 1)
        #expect(editor.reorderDriftGap(
            at: 1,
            hoverSlot: 1,
            liftFootprint: nil,
            rows: rows,
            sourceRow: editor.rowsBeforeReorderSourceRemoval(snapshot: blocks)
                .first(where: { $0.id == blocks[1].id })
        ) == 24 + spacing)
    }

    @Test func grabbingNearTheBottomDoesNotHopToTheNextSlot() {
        let (editor, state, blocks) = liftSecondRow(touchOffsetY: 22)
        let seeded = state.currentDropTarget

        editor.applyDropTarget(at: 24 + 22, snapshot: blocks)

        #expect(seeded == .insertAt(DropPath(parent: nil, position: 1)))
        #expect(state.currentDropTarget == seeded)
    }

    @Test func slotChangesAfterTheSameTravelUpOrDownWhereverItWasGrabbed() {
        for touchOffsetY: CGFloat in [2, 12, 22] {
            let (editor, state, blocks) = liftSecondRow(touchOffsetY: touchOffsetY)
            let start = 24 + touchOffsetY

            // Within hysteresis of the neighbor midlines: stays at the source.
            editor.applyDropTarget(at: start + 20, snapshot: blocks)
            #expect(state.currentDropTarget == .insertAt(DropPath(parent: nil, position: 1)))
            editor.applyDropTarget(at: start - 20, snapshot: blocks)
            #expect(state.currentDropTarget == .insertAt(DropPath(parent: nil, position: 1)))

            // Past them: after c going down, before a going up.
            editor.applyDropTarget(at: start + 24, snapshot: blocks)
            #expect(state.currentDropTarget == .insertAt(DropPath(parent: nil, position: 3)))
            editor.applyDropTarget(at: start - 24, snapshot: blocks)
            #expect(state.currentDropTarget == .insertAt(DropPath(parent: nil, position: 0)))
        }
    }
}

@MainActor
private final class ReorderSlotTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}

@Suite("Reorder source slot gap")
@MainActor
struct EditorViewReorderSourceGapTests {
    /// Lay out `rows` at 24pt each, then lift `block` as a long-press would.
    private func lift(_ block: Block, rows: [BlockID], in editor: EditorView) {
        editor.layoutCache.updateOrder(rows)
        for id in rows { editor.layoutCache.setHeight(24, for: id) }
        editor.layoutCache.contentWidth = 320
        editor.preliftReorder(blockID: block.id)
    }

    @Test func liftingTheLastItemOfANestedListKeepsItsGap() {
        let first = Block.bullet(text: AttributedString("first"))
        let last = Block.bullet(text: AttributedString("last"))
        let list = Block.bullet(text: AttributedString("list"), children: [first, last])
        let after = Block.paragraph(text: AttributedString("after"))
        let document = Document(id: DocumentID("test"), children: [list, after])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: ReorderSourceGapTestHost())
        lift(last, rows: [list.id, first.id, last.id, after.id], in: editor)

        let rows = editor.visibleRowsForRendering(snapshot: document.children)
        #expect(rows.map(\.id) == [list.id, first.id, after.id])
        #expect(state.currentDropTarget == .insertAt(DropPath(parent: list.id, position: 1)))
        #expect(editor.visibleSlotForCurrentDropPath(in: rows) == 2)
    }

    @Test func liftingTheLastBlockKeepsTheTrailingGap() {
        let first = Block.paragraph(text: AttributedString("first"))
        let last = Block.paragraph(text: AttributedString("last"))
        let document = Document(id: DocumentID("test"), children: [first, last])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: ReorderSourceGapTestHost())
        lift(last, rows: [first.id, last.id], in: editor)

        let rows = editor.visibleRowsForRendering(snapshot: document.children)
        #expect(rows.map(\.id) == [first.id])
        #expect(editor.visibleSlotForCurrentDropPath(in: rows) == 1)
    }
}

@MainActor
private final class ReorderSourceGapTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}

@Suite("Reorder drop-onto targets under a tall lift")
@MainActor
struct EditorViewReorderTallLiftTests {
    /// Rows a, tall (300pt, lifted), t1, t2, then a collapsed toggle. With
    /// the tall row removed and no gap, the toggle sits at 72–96, right under
    /// a finger 60pt into the lift; on screen it is below the 300pt gap.
    @Test func rowsHiddenUnderTheLiftAreNotDropTargets() {
        let a = Block.paragraph(text: AttributedString("a"))
        let tall = Block.paragraph(text: AttributedString("tall"))
        let t1 = Block.paragraph(text: AttributedString("t1"))
        let t2 = Block.paragraph(text: AttributedString("t2"))
        let toggle = Block.toggle(
            title: AttributedString("toggle"),
            children: [Block.paragraph(text: AttributedString("inside"))]
        )
        let document = Document(id: DocumentID("test"), children: [a, tall, t1, t2, toggle])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: TallLiftTestHost())
        let ids = [a.id, tall.id, t1.id, t2.id, toggle.id]
        editor.layoutCache.updateOrder(ids)
        for id in ids { editor.layoutCache.setHeight(id == tall.id ? 300 : 24, for: id) }
        editor.layoutCache.contentWidth = 320
        editor.layoutCache.beginReorderFrameSnapshot(rebaseOnNextOrderChange: true)
        let lift = ReorderLift(
            block: tall,
            ids: [tall.id],
            sourceParentID: nil,
            sourcePositions: 1...1,
            draggedSubtreeIDs: [tall.id],
            sourceFrame: CGRect(x: 0, y: 24, width: 320, height: 300),
            touchOffset: CGSize(width: 10, height: 60),
            location: CGPoint(x: 10, y: 84),
            pendingAnchor: false
        )
        state.setReorderLift(lift)
        editor.seedSourceDropTarget(for: lift, snapshot: document.children)
        editor.layoutCache.updateOrder([a.id, t1.id, t2.id, toggle.id])

        // Nudging up keeps the source gap rather than dropping into the toggle.
        editor.applyDropTarget(at: 80, snapshot: document.children)

        #expect(state.currentDropTarget == .insertAt(DropPath(parent: nil, position: 1)))
        let rows = editor.visibleRowsForRendering(snapshot: document.children)
        #expect(editor.visibleSlotForCurrentDropPath(in: rows) == 1)
    }
}

@MainActor
private final class TallLiftTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}

@Suite("Reorder drop at origin")
@MainActor
struct EditorViewReorderOriginTests {
    @Test func droppingTheLastChildOfASectionInPlaceKeepsItInTheSection() {
        let first = Block.paragraph(text: AttributedString("first"))
        let last = Block.paragraph(text: AttributedString("last"))
        let section = Block.heading(level: .h2, text: AttributedString("Section"), children: [first, last])
        let next = Block.heading(level: .h2, text: AttributedString("Next"))
        let document = Document(id: DocumentID("test"), children: [section, next])
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: ReorderOriginTestHost())
        let ids = [section.id, first.id, last.id, next.id]
        editor.layoutCache.updateOrder(ids)
        for id in ids { editor.layoutCache.setHeight(24, for: id) }
        editor.layoutCache.contentWidth = 320

        editor.preliftReorder(blockID: last.id)
        #expect(state.currentDropTarget == .insertAt(DropPath(parent: section.id, position: 1)))

        editor.endReorderLift(atY: 60, snapshot: document.children)
        #expect(document.children.map(\.id) == [section.id, next.id])
        #expect(document.find(section.id)?.children.map(\.id) == [first.id, last.id])
    }
}

@MainActor
private final class ReorderOriginTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
