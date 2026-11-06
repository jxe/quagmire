import CoreGraphics
import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Reorder sideways depth")
struct ReorderSidewaysDepthTests {
    @Test func sidewaysTravelPicksLevelsOnlyPastTheThreshold() {
        func steps(_ dx: CGFloat, _ previous: Int = 0) -> Int {
            ReorderDropResolver.sidewaysSteps(dx: dx, previous: previous, threshold: 44, step: 24)
        }
        #expect(steps(0) == 0)
        #expect(steps(30) == 0)
        #expect(steps(-43) == 0)
        #expect(steps(52) == 1)
        #expect(steps(-52) == -1)
        #expect(steps(80) == 2)
        #expect(steps(-100) == -3)
        // Hysteresis: a level holds near its boundary in both directions.
        #expect(steps(46) == 0)
        #expect(steps(40, 1) == 1)
        #expect(steps(36, 1) == 0)
    }

    /// - a
    ///   - b
    ///     - c
    /// - d
    private func nested() -> (Document, EditorView, [VisibleRow], a: Block, b: Block, c: Block, d: Block, moved: Block) {
        let c = Block.bullet(text: AttributedString("c"))
        let b = Block.bullet(text: AttributedString("b"), children: [c])
        let a = Block.bullet(text: AttributedString("a"), children: [b])
        let d = Block.bullet(text: AttributedString("d"))
        let moved = Block.paragraph(text: AttributedString("moved"))
        let document = Document(id: DocumentID("test"), children: [a, d, moved])
        let editor = EditorView(document: document, state: EditorState(), host: SidewaysTestHost())
        let all = computeVisibleLayout(snapshot: document.children, hidden: []) { _ in false }
        let rows = all.filter { $0.id != moved.id }
        return (document, editor, rows, a, b, c, d, moved)
    }

    @Test func theEndOfANestedListOffersEveryDepthOutToTheLeft() {
        let (_, editor, rows, a, b, c, _, moved) = nested()
        // Slot 3: between c and d.
        let defaultPath = editor.dropPath(forVisibleSlot: 3, rows: rows)
        #expect(defaultPath == DropPath(parent: b.id, position: 1))
        let candidates = editor.sidewaysDropCandidates(
            forVisibleSlot: 3, rows: rows, defaultPath: defaultPath,
            ids: [moved.id], draggedSubtreeIDs: [moved.id]
        )
        #expect(candidates.map(\.depth) == [0, 1, 2, 3])
        #expect(candidates.map(\.path) == [
            DropPath(parent: nil, position: 1),
            DropPath(parent: a.id, position: 1),
            DropPath(parent: b.id, position: 1),
            DropPath(parent: c.id, position: 0),
        ])
        func path(_ steps: Int) -> DropPath {
            editor.sidewaysDropPath(
                steps: steps, forVisibleSlot: 3, rows: rows, defaultPath: defaultPath,
                ids: [moved.id], draggedSubtreeIDs: [moved.id]
            )
        }
        #expect(path(0) == defaultPath)
        #expect(path(-1) == DropPath(parent: a.id, position: 1))
        #expect(path(-2) == .root(at: 1))
        #expect(path(-9) == .root(at: 1))
        // One deeper than the row above is the deepest choice.
        #expect(path(1) == DropPath(parent: c.id, position: 0))
        #expect(path(5) == DropPath(parent: c.id, position: 0))
    }

    @Test func theMiddleOfAListStopsAtTheRowBelow() {
        let (_, editor, rows, _, b, _, _, moved) = nested()
        // Slot 2: between b and c, where c is b's child.
        let defaultPath = editor.dropPath(forVisibleSlot: 2, rows: rows)
        let candidates = editor.sidewaysDropCandidates(
            forVisibleSlot: 2, rows: rows, defaultPath: defaultPath,
            ids: [moved.id], draggedSubtreeIDs: [moved.id]
        )
        #expect(candidates.map(\.path) == [DropPath(parent: b.id, position: 0)])
    }
}

@MainActor
private final class SidewaysTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
