import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Asynchronous image lifecycle")
struct AsyncImageLifecycleTests {
    @Test("Image persistence jobs retain paste order")
    func persistenceJobsAreSerialized() async {
        let state = EditorState()
        var events: [String] = []

        state.enqueueImageImport {
            events.append("first-start")
            try? await Task.sleep(for: .milliseconds(20))
            events.append("first-end")
        }
        state.enqueueImageImport {
            events.append("second")
        }

        await state.awaitImageImports()
        #expect(events == ["first-start", "first-end", "second"])
    }

    @Test("Consecutive imports follow the last durable block while it exists")
    func importsRetainInsertionOrder() {
        let state = EditorState()
        let original = Block.paragraph(text: AttributedString("Anchor"))
        let imported = Block.image(source: "Assets/one.png", alt: "")
        let document = Document(id: DocumentID("page"), children: [original, imported])

        state.recordImageImport(imported.id, after: original.id)
        #expect(state.imageImportAnchor(after: original.id, in: document) == imported.id)

        let replaced = Document(id: DocumentID("page"), children: [original])
        #expect(state.imageImportAnchor(after: original.id, in: replaced) == original.id)
    }
}
