import Foundation
import Testing
@testable import Quagmire

@MainActor
@Suite("Document regions")
struct DocumentRegionTests {
    private func fixture() -> (Document, Block, Block, DocumentRegion) {
        let body = Block.paragraph(text: AttributedString("Body"))
        let link = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("child"))
        let region = DocumentRegion(id: BlockID(), title: AttributedString("Subpages"), blocks: [link])
        let document = Document(id: DocumentID("regions"), children: [body])
        document.setRegions([region])
        return (document, body, link, region)
    }

    @Test func regionRowsAreShownAndFoundButNotContent() {
        let (document, body, link, region) = fixture()
        #expect(document.children.map(\.id) == [body.id])
        #expect(document.displayedChildren.map(\.id) == [body.id, region.id])
        #expect(document.find(link.id) != nil)
        #expect(document.parent(of: link.id) == region.id)
        #expect(document.isRegionBlock(region.id))
        #expect(document.isRegionBlock(link.id))
        #expect(!document.isRegionBlock(body.id))
        #expect(document.region(containing: link.id)?.id == region.id)
        var walked: [BlockID] = []
        document.walk { block, _, _ in walked.append(block.id) }
        #expect(walked == [body.id, region.id, link.id])
    }

    @Test func noEditReachesARegion() {
        let (document, body, link, region) = fixture()
        #expect(!document.mutate(link.id) { $0 = $0.withText(AttributedString("Changed")) })
        #expect(document.removeSubtree(link.id) == nil)
        #expect(!document.insertSubtrees([.paragraph(text: AttributedString("New"))], at: DropPath(parent: region.id, position: 0)))
        #expect(!document.canDrop(ids: [body.id], to: DropPath(parent: region.id, position: 0)))
        #expect(!document.canDrop(ids: [link.id], to: .root(at: 0)))
        #expect(!document.canInsert([.paragraph()], at: DropPath(parent: region.id, position: 0)))
        #expect(!document.canIndent(link.id))
        #expect(!document.canSlideSiblings([region.id], by: -1))
        #expect(document.find(link.id)?.kind == link.kind)
    }

    @Test func aBlockTheDocumentHoldsStaysOutOfTheRegion() {
        let (document, _, link, region) = fixture()
        document.transaction(name: "Place") {
            _ = document.insertSubtrees([link], at: .root(at: 1))
        }
        #expect(document.children.map(\.id).contains(link.id))
        #expect(!document.isRegionBlock(link.id))
        #expect(document.displayedChildren.last?.id == region.id)
        #expect(document.displayedChildren.last?.children.isEmpty == true)
    }

    @Test func regionsAreNotTransactions() {
        let (document, _, _, _) = fixture()
        var commits = 0
        document.didCommitTransaction = { _ in commits += 1 }
        document.setRegions([])
        #expect(commits == 0)
        #expect(document.displayedChildren.count == 1)
    }

    @Test func editingARegionRowStaysInNavigation() {
        let (document, _, _, region) = fixture()
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: RegionTestHost())
        editor.transferFocus(to: .editor(region.id, initialCursor: nil))
        #expect(state.editingBlock == nil)
        #expect(state.cursor == region.id)
    }

    @Test func deletingASelectionLeavesRegionRows() {
        let (document, body, link, _) = fixture()
        let second = Block.paragraph(text: AttributedString("Second"))
        document.transaction(name: "Add") { _ = document.insertSubtrees([second], at: .root(at: 1)) }
        let state = EditorState()
        let editor = EditorView(document: document, state: state, host: RegionTestHost())
        editor.installUndoApply()
        state.setNavSelection(blocks: [second.id, link.id], anchor: second.id, cursor: link.id)
        editor.deleteSelection()
        #expect(document.children.map(\.id) == [body.id])
        #expect(document.find(link.id) != nil)
    }

    @Test func aSlotAmongRegionRowsLandsAtTheDocumentEnd() {
        let (document, _, _, _) = fixture()
        let editor = EditorView(document: document, state: EditorState(), host: RegionTestHost())
        let rows = computeVisibleLayout(snapshot: document.displayedChildren, hidden: []) { _ in false }
        #expect(rows.count == 3)
        for slot in 1...rows.count {
            #expect(editor.dropPath(forVisibleSlot: slot, rows: rows) == .root(at: 1))
        }
    }

    @Test func blocksDroppedOnARegionLeaveWhenTheHostTakesThem() {
        let (document, body, _, region) = fixture()
        let link = Block.documentLink(label: AttributedString("Other"), reference: DocumentReference("other"))
        document.transaction(name: "Add") { _ = document.insertSubtrees([link], at: .root(at: 1)) }
        let host = RegionTestHost()
        let editor = EditorView(document: document, state: EditorState(), host: host)
        editor.installUndoApply()

        host.accepts = false
        #expect(!editor.dropBlocks([body.id], onRegion: region.id))
        #expect(document.children.count == 2)

        host.accepts = true
        #expect(editor.dropBlocks([link.id], onRegion: region.id))
        #expect(document.children.map(\.id) == [body.id])
        #expect(host.received.map(\.id) == [link.id])
        #expect(host.region?.id == region.id)
    }

    @Test func movingARegionLinkMovesItsPage() async {
        let (document, body, link, region) = fixture()
        let host = RegionTestHost()
        let editor = EditorView(document: document, state: EditorState(), host: host)
        #expect(editor.relocatableRegionLinks([link.id]) == [DocumentReference("child")])
        #expect(editor.relocatableRegionLinks([region.id]) == [DocumentReference("child")])
        #expect(editor.relocatableRegionLinks([body.id]) == nil)
        #expect(editor.relocatableRegionLinks([body.id, link.id]) == nil)
        editor.relocateRegionLinks([DocumentReference("child")])
        for _ in 0..<20 where host.relocated.isEmpty { await Task.yield() }
        #expect(host.relocated == [DocumentReference("child")])
        #expect(host.destinations == [nil])
        #expect(document.find(link.id) != nil)
    }

    @Test func movingSeveralRegionLinksIntoAPageMovesTheirPages() async {
        let (document, body, link, _) = fixture()
        let second = Block.documentLink(label: AttributedString("Second"), reference: DocumentReference("second"))
        let region = DocumentRegion(id: BlockID(), title: AttributedString("Subpages"), blocks: [link, second])
        document.setRegions([region])
        let host = RegionTestHost()
        let editor = EditorView(document: document, state: EditorState(), host: host)
        #expect(editor.relocatableRegionLinks([link.id, second.id])
            == [DocumentReference("child"), DocumentReference("second")])
        await editor.moveBlocks(ids: [link.id, second.id], intoDocument: DocumentReference("parent"))
        for _ in 0..<20 where host.relocated.isEmpty { await Task.yield() }
        #expect(host.relocated == [DocumentReference("child"), DocumentReference("second")])
        #expect(host.destinations == [DocumentReference("parent")])
        #expect(host.appended.isEmpty)
        #expect(document.children.map(\.id) == [body.id])
    }
}

@MainActor
private final class RegionTestHost: EditorHostDefaults {
    var relocated: [DocumentReference] = []
    var destinations: [DocumentReference?] = []
    var appended: [Block] = []

    func lookupDocument(_: DocumentReference) -> DocumentLookup { .present(title: "Child") }
    func relocateDocuments(_ references: [DocumentReference], to destination: DocumentReference?, from _: Document) async -> Bool {
        relocated.append(contentsOf: references)
        destinations.append(destination)
        return true
    }
    func appendToDocument(_: DocumentReference, _ blocks: [Block]) async -> Bool {
        appended.append(contentsOf: blocks)
        return true
    }
    var accepts = false
    var received: [Block] = []
    var region: DocumentRegion?

    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
    func receiveBlocks(_ blocks: [Block], inRegion region: DocumentRegion, of _: Document) -> Bool {
        guard accepts else { return false }
        received = blocks
        self.region = region
        return true
    }
}
