import Foundation
import SwiftUI
import Testing
@testable import Quagmire

@MainActor
@Suite("BlockRowModel equality")
struct BlockRowModelTests {
    private func model(
        block: Block = .paragraph(text: AttributedString("body")),
        isSelected: Bool = false,
        isProvisionalText: Bool = false,
        isFindMatch: Bool = false,
        isCurrentFindMatch: Bool = false,
        documentLookups: [String: DocumentLookup] = [:],
        linkPreviews: [URL: LinkPreview] = [:]
    ) -> BlockRowModel {
        BlockRowModel(
            block: block,
            depth: 0,
            isPageTitle: false,
            numberingIndex: nil,
            isSelected: isSelected,
            isEditing: false,
            isActiveEditor: false,
            completionActive: false,
            isIconPickerPresented: false,
            isExpanded: false,
            isDropTarget: false,
            isActionMenuTarget: false,
            isActionMenuPresented: false,
            isPinching: false,
            isProvisionalText: isProvisionalText,
            isFindMatch: isFindMatch,
            isCurrentFindMatch: isCurrentFindMatch,
            reorderSourceOpacity: 1,
            isReorderingThisBlock: false,
            isSelectionHandleRow: false,
            accessibilityID: "block-row-body",
            accessibilityLabelText: "Paragraph: body",
            documentLookups: documentLookups,
            linkPreviews: linkPreviews
        )
    }

    @Test func renderStateChangesAffectEquality() {
        let base = model()
        #expect(base != model(isSelected: true))
        #expect(base != model(isProvisionalText: true))
        #expect(base != model(isFindMatch: true))
        #expect(base != model(isCurrentFindMatch: true))

        let pageBlock = Block.documentLink(label: AttributedString("Old"), reference: DocumentReference("child.md"))
        #expect(model(block: pageBlock, documentLookups: ["child.md": .present(title: "Child")])
            != model(block: pageBlock, documentLookups: ["child.md": .missing]))

        let url = URL(string: "https://example.com")!
        #expect(model(linkPreviews: [url: LinkPreview(url: url, title: "A", iconPNG: nil)])
            != model(linkPreviews: [url: LinkPreview(url: url, title: "B", iconPNG: nil)]))
    }

    @Test func liveTextBindingReadsPastAStaleRowSnapshot() {
        let id = BlockID()
        var live = Block(id: id, kind: .paragraph(text: AttributedString("first")))
        let blockBinding = Binding<Block>(
            get: { live },
            set: { live = $0 }
        )
        let textBinding = liveBlockTextBinding(blockBinding)

        textBinding.wrappedValue = AttributedString("checkpoint")
        #expect(String(live.text.characters) == "checkpoint")

        // This is the important sequence: the native editor commits a typing
        // checkpoint, continues editing before BlockRow is rendered again,
        // then Escape asks the same mounted binding for the current model text.
        #expect(String(textBinding.wrappedValue.characters) == "checkpoint")
        textBinding.wrappedValue = AttributedString("checkpoint plus escape")

        #expect(String(live.text.characters) == "checkpoint plus escape")
        #expect(live.id == id)
    }
}
