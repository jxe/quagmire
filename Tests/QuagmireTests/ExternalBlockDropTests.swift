import Foundation
import Testing
@testable import Quagmire

/// Blocks dragged from one editor window into another document's editor.
@MainActor
@Suite("External block drops")
struct ExternalBlockDropTests {
    private func editor(_ blocks: [Block], host: ReceivingHost, id: String) -> (EditorView, Document) {
        let document = Document(id: DocumentID(id), children: blocks)
        let editor = EditorView(document: document, state: EditorState(), host: host)
        editor.installUndoApply()
        document.undoManager?.groupsByEvent = false
        return (editor, document)
    }

    private func drag(from editor: EditorView, ids: [BlockID]) -> ExternalBlockDrag {
        let roots = editor.preparedBlocksForTransfer(ids: ids)
        return ExternalBlockDrag(document: editor.document, host: editor.host, ids: ids, roots: roots) {
            editor.removeBlocksAfterTransfer(roots.map(\.id))
        }
    }

    private func texts(_ blocks: [Block]) -> [String] {
        blocks.map { String($0.text.characters) }
    }

    @Test func aMoveLandsAtTheDropPathAndLeavesTheSource() async {
        let sourceHost = ReceivingHost(), destinationHost = ReceivingHost()
        let child = Block.bullet(text: AttributedString("child"))
        let moving = Block.bullet(text: AttributedString("moving"), children: [child])
        let (source, sourceDocument) = editor([.paragraph(text: AttributedString("stays")), moving], host: sourceHost, id: "a")
        let (destination, destinationDocument) = editor(
            [.paragraph(text: AttributedString("one")), .paragraph(text: AttributedString("two"))],
            host: destinationHost, id: "b")

        await destination.receiveExternalBlocks(drag(from: source, ids: [moving.id, child.id]),
                                                at: DropPath(parent: nil, position: 1), isCopy: false)

        #expect(texts(destinationDocument.children) == ["one", "moving", "two"])
        #expect(destinationDocument.children[1].id == moving.id, "a move keeps the blocks' identities")
        #expect(destinationDocument.children[1].children.map(\.id) == [child.id])
        #expect(texts(sourceDocument.children) == ["stays"])
        let received = destinationHost.received.first
        #expect(received != nil)
        #expect(received?.transfer.isCopy == false)
        #expect(received?.transfer.source === sourceDocument)
        #expect(received?.transfer.sourceHost === sourceHost)
        #expect(received?.path == DropPath(parent: nil, position: 1))
        #expect(received?.transfer.originals.map(\.id) == [moving.id])
        #expect(sourceHost.persisted == 1 && destinationHost.persisted == 1, "each side persists its own commit")

        // Each window undoes its own half.
        destinationDocument.undoManager?.undo()
        #expect(texts(destinationDocument.children) == ["one", "two"])
        sourceDocument.undoManager?.undo()
        #expect(texts(sourceDocument.children) == ["stays", "moving"])
    }

    @Test func aRefusedDropChangesNeitherDocument() async {
        let sourceHost = ReceivingHost(), destinationHost = ReceivingHost()
        destinationHost.accepts = false
        let moving = Block.paragraph(text: AttributedString("moving"))
        let (source, sourceDocument) = editor([moving], host: sourceHost, id: "a")
        let (destination, destinationDocument) = editor([.paragraph(text: AttributedString("one"))], host: destinationHost, id: "b")

        await destination.receiveExternalBlocks(drag(from: source, ids: [moving.id]),
                                                at: DropPath(parent: nil, position: 0), isCopy: false)

        #expect(texts(destinationDocument.children) == ["one"])
        #expect(sourceDocument.children.map(\.id) == [moving.id])
        #expect(sourceHost.persisted == 0 && destinationHost.persisted == 0)
    }

    @Test func aCopyLandsWithFreshIdentitiesAndKeepsTheSource() async {
        let sourceHost = ReceivingHost(), destinationHost = ReceivingHost()
        let copied = Block.paragraph(text: AttributedString("copied"))
        let (source, sourceDocument) = editor([copied], host: sourceHost, id: "a")
        let parent = Block.toggle(title: AttributedString("parent"))
        let (destination, destinationDocument) = editor([parent], host: destinationHost, id: "b")

        await destination.receiveExternalBlocks(drag(from: source, ids: [copied.id]),
                                                at: DropPath(parent: parent.id, position: 0), isCopy: true)

        let landed = destinationDocument.children[0].children
        #expect(texts(landed) == ["copied"])
        #expect(landed[0].id != copied.id)
        #expect(destinationHost.received.first?.transfer.isCopy == true)
        #expect(destinationHost.received.first?.transfer.blocks.map { $0.id } == landed.map { $0.id })
        #expect(sourceDocument.children.map(\.id) == [copied.id])
        #expect(sourceHost.persisted == 0)
    }

    @Test func theHostChoosesTheTextThatLands() async {
        let sourceHost = ReceivingHost(), destinationHost = ReceivingHost()
        destinationHost.rewrite = { block in block.withText(AttributedString("rewritten")) }
        let moving = Block.paragraph(text: AttributedString("moving"))
        let (source, _) = editor([moving], host: sourceHost, id: "a")
        let (destination, destinationDocument) = editor([], host: destinationHost, id: "b")

        await destination.receiveExternalBlocks(drag(from: source, ids: [moving.id]),
                                                at: DropPath(parent: nil, position: 0), isCopy: false)

        #expect(texts(destinationDocument.children) == ["rewritten"])
        #expect(destinationDocument.children[0].id == moving.id)
    }

    @Test func identitiesTheDestinationAlreadyUsesAreRenewed() async {
        let sourceHost = ReceivingHost(), destinationHost = ReceivingHost()
        let moving = Block.paragraph(text: AttributedString("moving"))
        let (source, sourceDocument) = editor([moving], host: sourceHost, id: "a")
        let (destination, destinationDocument) = editor([moving], host: destinationHost, id: "b")

        await destination.receiveExternalBlocks(drag(from: source, ids: [moving.id]),
                                                at: DropPath(parent: nil, position: 1), isCopy: false)

        #expect(destinationDocument.children.count == 2)
        #expect(Set(destinationDocument.children.map(\.id)).count == 2)
        #expect(sourceDocument.children.isEmpty)
    }

    @Test func aDropBackIntoItsOwnDocumentIsAnOrdinaryMove() {
        let host = ReceivingHost()
        let blocks = ["a", "b", "c"].map { Block.paragraph(text: AttributedString($0)) }
        let (editor, document) = editor(blocks, host: host, id: "a")
        let drag = drag(from: editor, ids: [blocks[0].id])
        ExternalBlockDrag.active = drag
        defer { ExternalBlockDrag.active = nil }
        editor.state.currentDropTarget = .insertAt(DropPath(parent: nil, position: 3))

        #expect(editor.performExternalBlockDrop(atY: 0))

        #expect(texts(document.children) == ["b", "c", "a"])
        #expect(host.received.isEmpty)
        #expect(editor.state.currentDropTarget == nil)
    }

    @Test func anotherDocumentsDragDoesNotTargetLinkRows() {
        let host = ReceivingHost()
        let (source, _) = editor([.paragraph(text: AttributedString("moving"))], host: host, id: "a")
        let (destination, _) = editor([], host: host, id: "b")
        #expect(!destination.isReceivingForeignBlocks)
        ExternalBlockDrag.active = drag(from: source, ids: source.document.children.map(\.id))
        defer { ExternalBlockDrag.active = nil }
        #expect(destination.isReceivingForeignBlocks)
        #expect(!source.isReceivingForeignBlocks, "its own document's links still receive blocks")
    }

    @Test func aDropIntoALeafOrAHeadingOfTheSameLevelIsRefused() {
        let host = ReceivingHost()
        let paragraph = Block.paragraph(text: AttributedString("leaf"))
        let heading = Block.heading(level: .h2, text: AttributedString("Section"))
        let (source, _) = editor([.heading(level: .h2, text: AttributedString("Moving"))], host: host, id: "a")
        let (destination, document) = editor([paragraph, heading], host: host, id: "b")
        ExternalBlockDrag.active = drag(from: source, ids: source.document.children.map(\.id))
        defer { ExternalBlockDrag.active = nil }

        destination.state.currentDropTarget = .insertAt(DropPath(parent: paragraph.id, position: 0))
        #expect(!destination.performExternalBlockDrop(atY: 0))
        destination.state.currentDropTarget = .asLastChildOf(heading.id)
        #expect(!destination.performExternalBlockDrop(atY: 0))
        #expect(document.children.map(\.id) == [paragraph.id, heading.id])
        #expect(host.received.isEmpty)
        #expect(document.canInsert(source.document.children, at: DropPath(parent: nil, position: 2)))
    }
}

private final class ReceivingHost: EditorHostDefaults {
    var accepts = true
    var rewrite: ((Block) -> Block)?
    private(set) var received: [(transfer: EditorBlockTransfer, path: DropPath)] = []
    private(set) var persisted = 0

    func persistCommit(changes _: [DocumentChange], in _: Document) { persisted += 1 }
    func flush(_: Document) async {}

    func receiveBlocks(_ transfer: EditorBlockTransfer, at path: DropPath, in _: Document) async -> [Block]? {
        received.append((transfer, path))
        guard accepts else { return nil }
        return rewrite.map { transfer.blocks.map($0) } ?? transfer.blocks
    }
}
