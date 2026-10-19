import Foundation
import Testing
@testable import Quagmire

/// Opening linked pages in place, in a new tab, or in a new window.
@MainActor
@Suite("Opening links elsewhere")
struct OpenLinkTests {
    @Test func aHostWithoutTabsOpensEveryLinkInPlace() {
        let host = PlainHost()
        #expect(host.documentOpenTargets.isEmpty)
        host.openDocument(DocumentReference("a.md"), at: .newWindow)
        #expect(host.opened == ["a.md"])
    }

    @Test func aDocumentLinkRowOpensAtTheRequestedTarget() {
        let host = TabbedHost()
        let link = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("child.md"))
        let editor = EditorView(document: Document(id: DocumentID("d"), children: [link]), state: EditorState(), host: host)

        #expect(editor.navigateIntoDocumentLink(link.id, at: .newTab(selecting: false)))
        #expect(editor.navigateIntoDocumentLink(link.id))

        #expect(host.opened.map(\.0) == ["child.md", "child.md"])
        #expect(host.opened.map(\.1) == [.newTab(selecting: false), .current])
    }

    @Test func aRowOffersItsDocumentLinkOrItsPageLinksOnce() {
        let host = TabbedHost()
        var text = AttributedString("See ")
        var first = AttributedString("Plans")
        first.link = URL(string: "plans.md")
        var external = AttributedString(" and web")
        external.link = URL(string: "https://example.org")
        var again = AttributedString(" again")
        again.link = URL(string: "plans.md")
        text += first + external + again
        let paragraph = Block.paragraph(text: text)
        let link = Block.documentLink(label: AttributedString("Child"), reference: DocumentReference("child.md"))
        let editor = EditorView(document: Document(id: DocumentID("d"), children: [paragraph, link]), state: EditorState(), host: host)

        #expect(editor.openableLinks(in: paragraph) == [OpenableLink(title: "Plans", reference: DocumentReference("plans.md"))])
        #expect(editor.openableLinks(in: link) == [OpenableLink(title: "Child title", reference: DocumentReference("child.md"))])
        #expect(EditorView.clickOpenTarget(for: PlainHost()) == .current)
    }
}

private final class PlainHost: EditorHostDefaults {
    private(set) var opened: [String] = []
    func openDocument(_ reference: DocumentReference) { opened.append(reference.rawValue) }
    func persistCommit(changes _: [DocumentChange], in _: Document) {}
    func flush(_: Document) async {}
}

private final class TabbedHost: EditorHostDefaults {
    private(set) var opened: [(String, DocumentOpenTarget)] = []
    var documentOpenTargets: DocumentOpenTargets { [.newTab, .newWindow] }
    func openDocument(_ reference: DocumentReference) { opened.append((reference.rawValue, .current)) }
    func openDocument(_ reference: DocumentReference, at target: DocumentOpenTarget) { opened.append((reference.rawValue, target)) }
    func lookupDocument(_ reference: DocumentReference) -> DocumentLookup { .present(title: "Child title") }
    func resolveReference(from url: URL, in _: Document) -> DocumentReference? {
        url.absoluteString.hasSuffix(".md") ? DocumentReference(url.absoluteString) : nil
    }
    func persistCommit(changes _: [DocumentChange], in _: Document) {}
    func flush(_: Document) async {}
}
