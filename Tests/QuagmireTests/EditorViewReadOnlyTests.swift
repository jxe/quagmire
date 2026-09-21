import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("EditorView read-only presentation")
struct EditorViewReadOnlyTests {
    @Test func authoredMutationsAndExternalTextAreRejected() {
        let block = Block.paragraph(text: AttributedString("Original"))
        let document = Document(id: DocumentID("readonly"), children: [block])
        let editor = EditorView(
            document: document,
            state: EditorState(),
            host: ReadOnlyTestHost(),
            readOnly: true
        )

        editor.mutate("Replace") {
            document.setText(block.id, AttributedString("Changed"))
        }

        #expect(String(document.find(block.id)!.text.characters) == "Original")
        #expect(!editor.insertExternalText(" more", into: block.id))
        #expect(String(document.find(block.id)!.text.characters) == "Original")
    }
}

@MainActor
private final class ReadOnlyTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
