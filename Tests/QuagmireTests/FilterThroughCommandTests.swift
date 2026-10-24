import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Filter Through Command")
struct FilterThroughCommandTests {
    private func text(_ blocks: [Block]) -> [String] {
        blocks.map { String($0.text.characters) }
    }

    @Test func inputSendsSubtreeRootsAndSkipsStructuralRows() {
        let child = Block.bullet(text: AttributedString("child"))
        let parent = Block.bullet(text: AttributedString("b"), children: [child])
        let divider = Block.divider()
        let a = Block.bullet(text: AttributedString("a"))
        let document = Document(id: DocumentID("filter"), children: [parent, divider, a])

        let input = FilterThroughCommand.input(in: document, selection: [parent.id, child.id, divider.id, a.id])

        #expect(input.rows.map(\.id) == [parent.id, a.id])
        #expect(input.stdin == "b\na\n")
    }

    @Test func sortKeepsRowsAndTheirChildren() throws {
        let child = Block.bullet(text: AttributedString("child"))
        let c = Block.todo(text: AttributedString("c"), done: true, children: [child])
        let a = Block.bullet(text: AttributedString("a"))
        let b = Block.bullet(text: AttributedString("b"))
        let after = Block.paragraph(text: AttributedString("after"))
        let document = Document(id: DocumentID("filter"), children: [c, a, b, after])
        let input = FilterThroughCommand.input(in: document, selection: [c.id, a.id, b.id])

        try FilterThroughCommand.apply(
            output: FilterThroughCommand.lines(fromOutput: "a\nb\nc\n"),
            for: input,
            to: document
        )

        #expect(document.children.map(\.id) == [a.id, b.id, c.id, after.id])
        #expect(document.children[2] == c)
    }

    @Test func changedLinesKeepKindAndChildrenInOrder() {
        let child = Block.bullet(text: AttributedString("child"))
        let foo = Block.todo(text: AttributedString("foo"), done: false, children: [child])
        let bar = Block.heading(level: .h2, text: AttributedString("bar"))
        let input = FilterThroughCommandInput(rows: [foo, bar], lines: ["foo", "bar"])

        let rows = FilterThroughCommand.replacementRows(for: input, output: ["FOO", "bar", "new"])

        #expect(text(rows) == ["FOO", "bar", "new"])
        #expect(rows[0].id == foo.id && rows[0].children == [child])
        #expect(rows[0].kind == .todo(text: AttributedString("FOO"), done: false))
        #expect(rows[1] == bar)
        #expect(rows[2].id != foo.id && rows[2].id != bar.id)
        #expect(rows[2].kind == .heading(level: .h2, text: AttributedString("new")))
    }

    @Test func missingLinesRemoveRowsAndDuplicatesMatchOnce() {
        let a1 = Block.bullet(text: AttributedString("a"))
        let a2 = Block.bullet(text: AttributedString("a"))
        let b = Block.bullet(text: AttributedString("b"))
        let input = FilterThroughCommandInput(rows: [a1, a2, b], lines: ["a", "a", "b"])

        #expect(FilterThroughCommand.replacementRows(for: input, output: ["a", "b"]).map(\.id) == [a1.id, b.id])
        #expect(FilterThroughCommand.replacementRows(for: input, output: []).isEmpty)
    }

    @Test func nestedSelectionIsReplacedInPlace() throws {
        let x = Block.bullet(text: AttributedString("x"))
        let y = Block.bullet(text: AttributedString("y"))
        let parent = Block.bullet(text: AttributedString("parent"), children: [x, y])
        let document = Document(id: DocumentID("filter"), children: [parent])
        let input = FilterThroughCommand.input(in: document, selection: [x.id, y.id])

        try FilterThroughCommand.apply(output: ["y", "x"], for: input, to: document)

        #expect(document.find(parent.id)?.children.map(\.id) == [y.id, x.id])
    }

    @Test func staleRowsAreRejected() {
        let a = Block.bullet(text: AttributedString("a"))
        let document = Document(id: DocumentID("filter"), children: [a])
        let input = FilterThroughCommand.input(in: document, selection: [a.id])
        document.setText(a.id, AttributedString("edited"))

        #expect(throws: FilterThroughCommandError.rowsChanged) {
            try FilterThroughCommand.apply(output: ["z"], for: input, to: document)
        }
        #expect(text(document.children) == ["edited"])
    }
}
