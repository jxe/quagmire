import Foundation
import SwiftUI
import Testing
@testable import Quagmire

@MainActor @Suite("Editor accessories")
struct EditorAccessoryTests {
    private func accessory(_ id: String, _ anchor: EditorAccessoryAnchor) -> EditorAccessory {
        .init(id: id, anchor: anchor, accessibilityLabel: id, isExpanded: .constant(true), marker: { Text("Alternative") }, detail: { Text("Details") })
    }

    @Test func missingAndDuplicateAnchorsFailClosedWithoutChangingTheDocument() {
        let block = Block.paragraph(text: AttributedString("Unchanged source"))
        let document = Document(id: DocumentID("accessories"), children: [block])
        let state = EditorState(); state.setCursor(block.id)
        let absent = Block.paragraph(text: AttributedString()).id
        let editor = EditorView(document: document, state: state, host: AccessoryHost()).accessories([
            accessory("valid", .block(block.id)), accessory("missing", .block(absent)),
            accessory("duplicate", .document), accessory("duplicate", .block(block.id))
        ])
        #expect(editor.missingAccessoryIDs == ["duplicate", "missing"])
        #expect(editor.accessories(at: .document).isEmpty)
        #expect(editor.accessories(at: .block(block.id)).map(\.id) == ["valid"])
        #expect(document.children == [block])
        #expect(state.cursor == block.id)
        #expect(state.editingBlock == nil)
        #expect(document.undoManager?.canUndo != true)
        #expect(EditorAccessoryReveal("valid") != EditorAccessoryReveal("valid"))
    }

    @Test func expandedPanelsShiftRowsButNeverBecomeDocumentHitTargets() {
        let cache = RowSurfaceLayoutCache<String>()
        cache.updateOrder(["a", "b"])
        cache.contentOriginY = 100; cache.contentWidth = 300
        cache.setHeight(30, for: "a"); cache.setHeight(40, for: "b")
        cache.setHeaderHeight(60); cache.setAccessoryHeight(200, for: "a")
        #expect(cache.frame(of: "a")?.height == 30)
        #expect(cache.frame(of: "b")?.minY == 390)
        #expect(cache.blockIDAtY(150) == nil)
        #expect(cache.blockIDAtY(200) == nil)
        #expect(cache.isAccessoryAtY(150))
        #expect(cache.isAccessoryAtY(200))
        #expect(!cache.isAccessoryAtY(400))
        #expect(cache.blockIDAtY(400) == "b")
        // Collapse must clear even a panel whose lazy row has left the screen.
        cache.retainAccessoryHeights(for: [])
        #expect(cache.frame(of: "b")?.minY == 190)
        cache.setHeaderHeight(0)
        #expect(cache.frame(of: "a")?.minY == 100)
        #expect(cache.frame(of: "b")?.minY == 130)
    }

    @Test func externalUndoDoesNotConsumeDocumentHistory() {
        let controller = DocumentUndoController()
        var routed: [Bool] = []
        controller.routeExternalUndo = { routed.append($0); return true }
        controller.undo(); controller.redo()
        #expect(routed == [false, true])
    }
}

@MainActor private final class AccessoryHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
