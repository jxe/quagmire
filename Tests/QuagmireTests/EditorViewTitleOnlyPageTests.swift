import Foundation
import Testing
@testable import Quagmire

#if os(macOS)
@MainActor
@Suite("Title-only page opens typing under the title")
struct EditorViewTitleOnlyPageTests {
    private func makeEditor(_ children: [Block]) -> (EditorView, Document, EditorState, CommitCountingHost) {
        let document = Document(id: DocumentID("title-only"), children: children)
        let state = EditorState()
        let host = CommitCountingHost()
        let editor = EditorView(document: document, state: state, host: host)
        editor.installUndoApply()
        return (editor, document, state, host)
    }

    @Test func leavingWithoutTypingLeavesNoTrace() throws {
        let title = Block.heading(level: 1, text: AttributedString("Title"))
        let (editor, document, state, host) = makeEditor([title])

        editor.startTypingInTitleOnlyPage()
        let line = try #require(document.children.first?.children.first)
        #expect(state.editingBlock == line.id)
        #expect(host.commits == 0)
        #expect(!editor.undoController.undoManager.canUndo)

        editor.handleEscapeKey()
        editor.settleProvisionalBlock()
        #expect(document.children.count == 1)
        #expect(document.children.first?.id == title.id)
        #expect(document.children.first?.children.isEmpty == true)
        #expect(!editor.undoController.undoManager.canUndo)
        #expect(state.provisionalBlock == nil)
    }

    @Test func closingWhileStillOnTheEmptyLineRemovesIt() throws {
        let title = Block.heading(level: 1, text: AttributedString("Title"))
        let (editor, document, _, _) = makeEditor([title])

        editor.startTypingInTitleOnlyPage()
        editor.settleProvisionalBlock(closing: true)
        #expect(document.children.first?.children.isEmpty == true)
        #expect(!editor.undoController.undoManager.canUndo)
    }

    @Test func typedLineIsKept() throws {
        let title = Block.heading(level: 1, text: AttributedString("Title"))
        let (editor, document, state, host) = makeEditor([title])

        editor.startTypingInTitleOnlyPage()
        let line = try #require(document.children.first?.children.first)
        editor.undoController.transaction(name: "Typing") {
            _ = document.mutate(line.id) { $0.kind = .paragraph(text: AttributedString("hello")) }
        }
        #expect(host.commits == 1)
        editor.handleEscapeKey()
        editor.settleProvisionalBlock()
        #expect(document.find(line.id) != nil)
        #expect(state.provisionalBlock == nil)

        editor.undoController.undoManager.undo()
        let restored = try #require(document.find(line.id))
        if case .paragraph(let text) = restored.kind { #expect(text.characters.isEmpty) }
    }

    @Test func pageWithContentOpensInNavigationMode() {
        let title = Block.heading(level: 1, text: AttributedString("Title"))
        let body = Block.paragraph(text: AttributedString("Body"))
        let (editor, document, state, host) = makeEditor([title, body])

        editor.startTypingInTitleOnlyPage()
        #expect(document.children.count == 2)
        #expect(state.cursor == nil)
        #expect(state.editingBlock == nil)
        #expect(host.commits == 0)
    }
}

@MainActor
private final class CommitCountingHost: EditorHostDefaults {
    var commits = 0
    func persistCommit(changes: [DocumentChange], in document: Document) { commits += 1 }
    func flush(_ document: Document) async {}
}
#endif
