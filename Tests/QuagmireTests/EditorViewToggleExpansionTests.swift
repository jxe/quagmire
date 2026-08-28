import Foundation
import SwiftUI
import Testing
@testable import Quagmire

@MainActor
@Suite("EditorView toggle expansion policy")
struct EditorViewToggleExpansionTests {
    @Test func nonTitleHeadingsStartExpandedAndTitleDoesNotCollapse() {
        let body = Block.paragraph(text: AttributedString("body"))
        let section = Block.heading(level: .h2, text: AttributedString("Section"), children: [body])
        let title = Block.heading(level: .h1, text: AttributedString("Title"), children: [section])
        let doc = Document(id: DocumentID("test"), children: [title])
        let state = EditorState()
        let host = TestHost()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        #expect(!editor.isCollapsibleSection(title))
        #expect(editor.isCollapsibleSection(section))
        #expect(editor.isSectionExpanded(section))
        #expect(editor.hiddenBlockIDs(in: doc.children).isEmpty)

        editor.toggleSectionExpansion(section)

        #expect(state.collapsedHeadings == [section.id])
        #expect(editor.hiddenBlockIDs(in: doc.children).contains(body.id))
        #expect(host.persistCalls == 0, "folding is view state, not an authored change")
        #expect(!doc.undoManager!.canUndo)

        editor.toggleSectionExpansion(title)
        #expect(state.collapsedHeadings == [section.id])
    }

    @Test func headingLeftAndRightArrowsFoldAndUnfold() {
        let body = Block.paragraph(text: AttributedString("body"))
        let section = Block.heading(level: .h4, text: AttributedString("Section"), children: [body])
        let doc = Document(id: DocumentID("test"), children: [section])
        let state = EditorState()
        state.setCursor(section.id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.handleNavLeftArrow())
        #expect(state.collapsedHeadings.contains(section.id))
        #expect(editor.handleNavRightArrow())
        #expect(!state.collapsedHeadings.contains(section.id))
    }

    @Test func foldAndUnfoldAllPreserveNestedHeadingState() {
        let leaf = Block.paragraph(text: AttributedString("leaf"))
        let inner = Block.heading(level: .h3, text: AttributedString("Inner"), children: [leaf])
        let outer = Block.heading(level: .h2, text: AttributedString("Outer"), children: [inner])
        let title = Block.heading(level: .h1, text: AttributedString("Title"), children: [outer])
        let doc = Document(id: DocumentID("test"), children: [title])
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.canFoldAllHeadings)
        #expect(!editor.canUnfoldAllHeadings)
        editor.foldAllHeadings()

        #expect(state.collapsedHeadings == [outer.id, inner.id])
        #expect(editor.hiddenBlockIDs(in: doc.children).contains(inner.id))
        #expect(!editor.canFoldAllHeadings)
        #expect(editor.canUnfoldAllHeadings)

        editor.toggleSectionExpansion(outer)
        #expect(!state.collapsedHeadings.contains(outer.id))
        #expect(state.collapsedHeadings.contains(inner.id))
        #expect(editor.hiddenBlockIDs(in: doc.children).contains(leaf.id))

        editor.unfoldAllHeadings()
        #expect(state.collapsedHeadings.isEmpty)
        #expect(editor.hiddenBlockIDs(in: doc.children).isEmpty)
        #expect(!editor.canUnfoldAllHeadings)
    }

    @Test func headingChevronLongPressFoldsOrUnfoldsAllFromPressedState() {
        let inner = Block.heading(level: .h3, text: AttributedString("Inner"))
        let outer = Block.heading(level: .h2, text: AttributedString("Outer"), children: [inner])
        let doc = Document(id: DocumentID("test"), children: [outer])
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.handleHeadingChevronLongPress(outer)
        #expect(state.collapsedHeadings == [outer.id, inner.id])

        editor.handleHeadingChevronLongPress(outer)
        #expect(state.collapsedHeadings.isEmpty)
        #expect(!doc.undoManager!.canUndo)
    }

    @Test func headingChevronTouchTargetDoesNotBeginReorder() {
        let section = Block.heading(level: .h2, text: AttributedString("Section"))
        let paragraph = Block.paragraph(text: AttributedString("Body"))
        let doc = Document(id: DocumentID("test"), children: [section, paragraph])
        let editor = EditorView(document: doc, state: EditorState(), host: TestHost())
        editor.layoutCache.contentOriginX = 20
        editor.layoutCache.contentOriginY = 10
        editor.layoutCache.setRealizedInternalFrame(
            CGRect(x: 0, y: 0, width: 300, height: 40),
            for: section.id
        )
        editor.layoutCache.setRealizedInternalFrame(
            CGRect(x: 0, y: 40, width: 300, height: 40),
            for: paragraph.id
        )

        #expect(!editor.shouldBeginIOSReorder(on: section.id, at: CGPoint(x: 300, y: 30)))
        #expect(editor.shouldBeginIOSReorder(on: section.id, at: CGPoint(x: 250, y: 30)))
        #expect(editor.shouldBeginIOSReorder(on: paragraph.id, at: CGPoint(x: 300, y: 70)))
    }

    @Test func foldingRepairsHiddenEditingFocusToVisibleHeading() {
        let leaf = Block.paragraph(text: AttributedString("leaf"))
        let inner = Block.heading(level: .h3, text: AttributedString("Inner"), children: [leaf])
        let outer = Block.heading(level: .h2, text: AttributedString("Outer"), children: [inner])
        let doc = Document(id: DocumentID("test"), children: [outer])
        let state = EditorState()
        state.enterEditMode(on: leaf.id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.foldAllHeadings()

        #expect(state.editingBlock == nil)
        #expect(state.cursor == outer.id)
        #expect(state.selection == [outer.id])
    }

    @Test func focusingAChildAutomaticallyUnfoldsItsHeading() {
        let leaf = Block.paragraph(text: AttributedString("leaf"))
        let section = Block.heading(level: .h6, text: AttributedString("Section"), children: [leaf])
        let doc = Document(id: DocumentID("test"), children: [section])
        let state = EditorState()
        state.collapsedHeadings.insert(section.id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.transferFocus(to: .editor(leaf.id, initialCursor: nil))

        #expect(!state.collapsedHeadings.contains(section.id))
        #expect(state.editingBlock == leaf.id)
    }

    @Test func turnIntoToggleStartsClosedAndClearsTemplateExpansion() {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .templateButton(label: "Details")
            ]
        )
        let state = EditorState()
        let id = doc.children[0].id
        state.expandedTemplates.insert(id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.convert(blockIDs: [id], to: .toggle) == .handled)

        guard case .toggle(let title) = doc.children[0].kind else {
            Issue.record("expected toggle")
            return
        }
        #expect(String(title.characters) == "Details")
        #expect(!state.expandedToggles.contains(id))
        #expect(!state.expandedTemplates.contains(id))
    }

    @Test func autotransformToggleStartsClosed() {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .paragraph(text: AttributedString("> Details"))
            ]
        )
        let state = EditorState()
        let id = doc.children[0].id
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.applyAutotransform(.toggle, remainingText: AttributedString("Details"), blockID: id)

        guard case .toggle(let title) = doc.children[0].kind else {
            Issue.record("expected toggle")
            return
        }
        #expect(String(title.characters) == "Details")
        #expect(state.expandedToggles.isEmpty)
    }

    @Test func documentLinkTurnIntoToggleStartsClosed() async {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .documentLink(label: AttributedString("Child"), reference: DocumentReference("child.md"))
            ]
        )
        let state = EditorState()
        let id = doc.children[0].id
        let host = TestHost(loadedDocumentBlocks: [
            .paragraph(text: AttributedString("body"))
        ])
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        #expect(editor.convert(blockIDs: [id], to: .toggle) == .handled)
        await Task.yield()

        guard case .toggle(let title) = doc.children[0].kind else {
            Issue.record("expected toggle")
            return
        }
        #expect(String(title.characters) == "Child")
        #expect(doc.children[0].children.count == 1)
        #expect(state.expandedToggles.isEmpty)
        #expect(host.didInlineAndRetireDocument)
    }

    @Test func optionArrowMoveDoesNotRevealCollapsedAncestor() {
        let doc = Document(
            id: DocumentID("test"),
            children: [
                .toggle(title: AttributedString("Closed"), children: [
                    .paragraph(text: AttributedString("first")),
                    .paragraph(text: AttributedString("second"))
                ])
            ]
        )
        let state = EditorState()
        let secondID = doc.children[0].children[1].id
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.moveBlocksInDocument(Set([secondID]), by: -1)

        #expect(doc.children[0].children.map { String($0.text.characters) } == ["second", "first"])
        #expect(state.expandedToggles.isEmpty)
    }

    @Test func optionArrowMoveSkipsClosedHeadingForNextOpenSection() {
        let moving = Block.paragraph(text: AttributedString("moving"))
        let first = Block.heading(level: .h2, text: AttributedString("First"), children: [moving])
        let closedBody = Block.paragraph(text: AttributedString("closed body"))
        let closed = Block.heading(level: .h2, text: AttributedString("Closed"), children: [closedBody])
        let openBody = Block.paragraph(text: AttributedString("open body"))
        let open = Block.heading(level: .h2, text: AttributedString("Open"), children: [openBody])
        let doc = Document(id: DocumentID("test"), children: [first, closed, open])
        let state = EditorState()
        state.collapsedHeadings.insert(closed.id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()
        state.setCursor(moving.id)
        editor.wireEditorCommands()

        #expect(editor.editorCommands.can(.canMoveBlockDown))
        editor.moveBlocksInDocument([moving.id], by: 1)

        #expect(doc.children[0].children.isEmpty)
        #expect(doc.children[1].children.map(\.id) == [closedBody.id])
        #expect(doc.children[2].children.map(\.id) == [moving.id, openBody.id])
        #expect(!editor.hiddenBlockIDs(in: doc.children).contains(moving.id))
        #expect(state.collapsedHeadings == [closed.id])
    }

    @Test func optionArrowMoveUpSkipsClosedHeadingForPreviousOpenSection() {
        let firstBody = Block.paragraph(text: AttributedString("first body"))
        let first = Block.heading(level: .h2, text: AttributedString("First"), children: [firstBody])
        let closedBody = Block.paragraph(text: AttributedString("closed body"))
        let closed = Block.heading(level: .h2, text: AttributedString("Closed"), children: [closedBody])
        let moving = Block.paragraph(text: AttributedString("moving"))
        let last = Block.heading(level: .h2, text: AttributedString("Last"), children: [moving])
        let doc = Document(id: DocumentID("test"), children: [first, closed, last])
        let state = EditorState()
        state.collapsedHeadings.insert(closed.id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.moveBlocksInDocument([moving.id], by: -1)

        #expect(doc.children[0].children.map(\.id) == [firstBody.id, moving.id])
        #expect(doc.children[1].children.map(\.id) == [closedBody.id])
        #expect(doc.children[2].children.isEmpty)
        #expect(!editor.hiddenBlockIDs(in: doc.children).contains(moving.id))
    }

    @Test func optionArrowHeadingMoveTreatsClosedHeadingAsOneSection() {
        let first = Block.heading(level: .h2, text: AttributedString("First"))
        let closedBody = Block.paragraph(text: AttributedString("closed body"))
        let closed = Block.heading(level: .h2, text: AttributedString("Closed"), children: [closedBody])
        let last = Block.heading(level: .h2, text: AttributedString("Last"))
        let doc = Document(id: DocumentID("test"), children: [first, closed, last])
        let state = EditorState()
        state.collapsedHeadings.insert(closed.id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.moveBlocksInDocument([first.id], by: 1)

        #expect(doc.children.map(\.id) == [closed.id, first.id, last.id])
        #expect(doc.children[0].children.map(\.id) == [closedBody.id])
        #expect(state.collapsedHeadings == [closed.id])
    }

    @Test func optionArrowMoveDoesNothingWhenClosedHeadingHasNoVisibleDestination() {
        let moving = Block.paragraph(text: AttributedString("moving"))
        let first = Block.heading(level: .h2, text: AttributedString("First"), children: [moving])
        let closed = Block.heading(
            level: .h2,
            text: AttributedString("Closed"),
            children: [.paragraph(text: AttributedString("closed body"))]
        )
        let doc = Document(id: DocumentID("test"), children: [first, closed])
        let state = EditorState()
        state.collapsedHeadings.insert(closed.id)
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()
        editor.wireEditorCommands()
        let before = doc.children

        #expect(!editor.editorCommands.can(.canMoveBlockDown))
        editor.moveBlocksInDocument([moving.id], by: 1)

        #expect(doc.children == before)
        #expect(!doc.undoManager!.canUndo)
    }

    @Test func dropIntoToggleDoesNotExpandDestination() {
        let moving = Block.paragraph(text: AttributedString("moving"))
        let toggle = Block.toggle(title: AttributedString("Closed"))
        let doc = Document(
            id: DocumentID("test"),
            children: [moving, toggle]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        editor.moveBlocks(ids: [moving.id], asChildrenOf: toggle.id, snapshot: [], hidden: [])

        #expect(doc.children.count == 1)
        #expect(doc.children[0].id == toggle.id)
        #expect(doc.children[0].children.map(\.id) == [moving.id])
        #expect(state.expandedToggles.isEmpty)
    }

    @Test func indentStillRevealsCollapsedToggleAncestor() {
        let toggle = Block.toggle(title: AttributedString("Closed"))
        let child = Block.paragraph(text: AttributedString("child"))
        let doc = Document(
            id: DocumentID("test"),
            children: [toggle, child]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.indentBlocks([child.id], by: 1))

        #expect(doc.children.count == 1)
        #expect(doc.children[0].id == toggle.id)
        #expect(doc.children[0].children.map(\.id) == [child.id])
        #expect(state.expandedToggles.contains(toggle.id))
    }

    @Test func indentingSelectedClosedToggleDoesNotExpandItsBody() {
        let parent = Block.bullet(text: AttributedString("parent"))
        let child = Block.paragraph(text: AttributedString("child"))
        let toggle = Block.toggle(title: AttributedString("Closed"), children: [child])
        let doc = Document(
            id: DocumentID("test"),
            children: [parent, toggle]
        )
        let state = EditorState()
        let editor = EditorView(document: doc, state: state, host: TestHost())
        editor.installUndoApply()

        #expect(editor.indentBlocks([toggle.id, child.id], by: 1))

        #expect(doc.children.map(\.id) == [parent.id])
        #expect(doc.children[0].children.map(\.id) == [toggle.id])
        #expect(doc.children[0].children[0].children.map(\.id) == [child.id])
        #expect(state.expandedToggles.isEmpty)
    }

    @Test func crossPageMoveCollapsesCoveredToggleDescendants() async {
        let toggle = Block.toggle(
            title: AttributedString("Details"),
            children: [.paragraph(text: AttributedString("child"))]
        )
        let doc = Document(
            id: DocumentID("test"),
            children: [toggle]
        )
        let host = TestHost()
        let editor = EditorView(document: doc, state: EditorState(), host: host)
        editor.installUndoApply()

        await editor.moveBlocks(ids: [toggle.id, toggle.children[0].id], intoDocument: DocumentReference("target.md"))

        #expect(host.appendedReference?.rawValue == "target.md")
        #expect(host.appendedBlocks.map(\.id) == [toggle.id])
        #expect(host.appendedBlocks.first?.children.map(\.id) == [toggle.children[0].id])
        #expect(doc.children.isEmpty)
    }

    @Test func crossPageCopyUsesFreshIDsAndKeepsSourceSubtree() async {
        let child = Block.paragraph(text: AttributedString("child"))
        let toggle = Block.toggle(
            title: AttributedString("Details"),
            children: [child]
        )
        let doc = Document(
            id: DocumentID("test"),
            children: [toggle]
        )
        let state = EditorState()
        let host = TestHost()
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        await editor.copyBlocks(ids: [toggle.id, child.id], intoDocument: DocumentReference("target.md"))

        #expect(host.appendedReference?.rawValue == "target.md")
        #expect(host.appendedBlocks.count == 1)
        #expect(host.appendedBlocks[0].id != toggle.id)
        #expect(host.appendedBlocks[0].kind == toggle.kind)
        #expect(host.appendedBlocks[0].children.count == 1)
        #expect(host.appendedBlocks[0].children[0].id != child.id)
        #expect(host.appendedBlocks[0].children[0].kind == child.kind)
        #expect(doc.children == [toggle])
        #expect(state.actionToast == "Copied")
    }

    @Test func failedCrossPageCopyKeepsSourceUntouched() async {
        let block = Block.paragraph(text: AttributedString("source"))
        let doc = Document(
            id: DocumentID("test"),
            children: [block]
        )
        let state = EditorState()
        let host = TestHost()
        host.appendSucceeds = false
        let editor = EditorView(document: doc, state: state, host: host)
        editor.installUndoApply()

        await editor.copyBlocks(ids: [block.id], intoDocument: DocumentReference("target.md"))

        #expect(doc.children == [block])
        #expect(state.actionToast == nil)
    }
}

@MainActor
private final class TestHost: EditorHostDefaults {
    var supportsDocumentInlining: Bool { true }
    var loadedDocumentBlocks: [Block]?
    var didInlineAndRetireDocument = false
    var appendedReference: DocumentReference?
    var appendedBlocks: [Block] = []
    var appendSucceeds = true
    var persistCalls = 0

    init(loadedDocumentBlocks: [Block]? = nil) {
        self.loadedDocumentBlocks = loadedDocumentBlocks
    }

    func suggestDocuments(_ query: String, in document: Document) -> [MentionItem] { [] }
    func openDocument(_ reference: DocumentReference) {}
    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { .present(title: nil) }
    func resolveReference(from url: URL, in document: Document) -> DocumentReference? { nil }
    func linkURL(for reference: DocumentReference, in document: Document) -> URL? { URL(string: reference.rawValue) }
    func createDocument(title: String, requestedReference: DocumentReference?, initialContent: [Block]?) async -> DocumentReference? { nil }
    func loadDocumentBlocks(_ reference: DocumentReference) async -> [Block]? { loadedDocumentBlocks }
    func inlineAndRetireDocument(_ reference: DocumentReference, parent: Document) async -> Bool {
        didInlineAndRetireDocument = true
        return true
    }
    func appendToDocument(_ reference: DocumentReference, _ blocks: [Block]) async -> Bool {
        appendedReference = reference
        appendedBlocks = blocks
        return appendSucceeds
    }
    func moveDestination(for blockIDs: [BlockID], candidates: [InDocMoveTarget]) async -> MoveDestination? { nil }
    func navigateBack() {}
    func persistCommit(changes: [DocumentChange], in document: Document) { persistCalls += 1 }
    func flush(_ document: Document) async {}
    func serializeBlocksForPasteboard(_ blocks: [Block]) -> String { "" }
    func parseBlocksFromPasteboard(_ string: String) -> [Block]? { nil }
    func saveImages(_ items: [PastedImage], in document: Document) async -> [String] { [] }
    func linkPreview(for url: URL) async -> LinkPreview? { nil }
    func imageResource(for source: String, in document: Document) async -> EditorImageResource? { nil }
}
