import Foundation
import Testing
@testable import Quagmire

@Suite struct AtomicLinksTests {
    /// "See Values now": the page link "Values" spans 4..<10.
    private func storage(link: String = "values.md") -> NSAttributedString {
        var linked = AttributedString("Values")
        linked.link = URL(string: link)
        let model = AttributedString("See ") + linked + AttributedString(" now")
        return InlineMarksBridge.toNS(model, baseFontSize: 16, baseBold: false, lineSpacing: 0)
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    @Test func arrowRightAtLinkStartJumpsToItsEnd() {
        #expect(AtomicLinks.snapSelection(from: caret(4), to: caret(5), in: storage()) == caret(10))
    }

    @Test func arrowLeftAtLinkEndJumpsToItsStart() {
        #expect(AtomicLinks.snapSelection(from: caret(10), to: caret(9), in: storage()) == caret(4))
    }

    @Test func clickInsideLinkGoesToNearerEdge() {
        #expect(AtomicLinks.snapSelection(from: caret(0), to: caret(5), in: storage()) == caret(4))
        #expect(AtomicLinks.snapSelection(from: caret(0), to: caret(9), in: storage()) == caret(10))
    }

    @Test func caretAtEdgesIsLeftAlone() {
        #expect(AtomicLinks.snapSelection(from: caret(3), to: caret(4), in: storage()) == caret(4))
        #expect(AtomicLinks.snapSelection(from: caret(11), to: caret(10), in: storage()) == caret(10))
    }

    @Test func shiftArrowSelectsWholeLinkAndBack() {
        let s = storage()
        let grown = AtomicLinks.snapSelection(from: caret(4), to: NSRange(location: 4, length: 1), in: s)
        #expect(grown == NSRange(location: 4, length: 6))
        let shrunk = AtomicLinks.snapSelection(from: grown, to: NSRange(location: 4, length: 5), in: s)
        #expect(shrunk == caret(4))
        let leftward = AtomicLinks.snapSelection(from: caret(10), to: NSRange(location: 9, length: 1), in: s)
        #expect(leftward == NSRange(location: 4, length: 6))
    }

    @Test func doubleClickInsideLinkSelectsWholeLink() {
        let s = storage()
        #expect(AtomicLinks.snapSelection(from: caret(6), to: NSRange(location: 5, length: 2), in: s)
            == NSRange(location: 4, length: 6))
    }

    @Test func backspaceAtLinkEndDeletesWholeLink() {
        #expect(AtomicLinks.expandEdit(NSRange(location: 9, length: 1), in: storage()) == NSRange(location: 4, length: 6))
    }

    @Test func forwardDeleteAtLinkStartDeletesWholeLink() {
        #expect(AtomicLinks.expandEdit(NSRange(location: 4, length: 1), in: storage()) == NSRange(location: 4, length: 6))
    }

    @Test func editsOutsideLinksAreUnchanged() {
        let range = NSRange(location: 10, length: 1)
        #expect(AtomicLinks.expandEdit(range, in: storage()) == range)
    }

    @Test func externalLinksStayOrdinaryText() {
        let s = storage(link: "https://example.com")
        #expect(AtomicLinks.snapSelection(from: caret(4), to: caret(5), in: s) == caret(5))
        let range = NSRange(location: 9, length: 1)
        #expect(AtomicLinks.expandEdit(range, in: s) == range)
    }

    @Test func boldPartOfLinkStillMovesAsOne() {
        var head = AttributedString("Val")
        head.link = URL(string: "values.md")
        var tail = AttributedString("ues")
        tail.link = URL(string: "values.md")
        tail[InlineAttributes.BoldAttribute.self] = true
        let s = InlineMarksBridge.toNS(AttributedString("See ") + head + tail, baseFontSize: 16, baseBold: false, lineSpacing: 0)
        #expect(AtomicLinks.snapSelection(from: caret(4), to: caret(5), in: s) == caret(10))
    }
}
