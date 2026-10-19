import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Testing
@testable import Quagmire

@Suite struct LinkIconsTests {
    private func model(_ parts: [(String, String?)]) -> AttributedString {
        var result = AttributedString()
        for (text, link) in parts {
            var piece = AttributedString(text)
            if let link { piece.link = URL(string: link) }
            result += piece
        }
        return result
    }

    private func storage(_ parts: [(String, String?)]) -> NSMutableAttributedString {
        NSMutableAttributedString(attributedString: InlineMarksBridge.toNS(model(parts), baseFontSize: 16, baseBold: false, lineSpacing: 0))
    }

    private func kern(at index: Int, in storage: NSAttributedString) -> CGFloat {
        storage.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
    }

    private func indent(in storage: NSAttributedString) -> CGFloat {
        (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
    }

    @Test func pageLinkGetsGapOnTheCharacterBefore() {
        let s = storage([("Add from ", nil), ("Social", "social.md"), (" now", nil)])
        #expect(kern(at: 8, in: s) > 0)
        #expect(kern(at: 7, in: s) == 0)
        #expect(kern(at: 14, in: s) == 0)
        #expect(indent(in: s) == 0)
    }

    @Test func linkAtStartIndentsTheLine() {
        let s = storage([("Social", "social.md"), (" now", nil)])
        #expect(indent(in: s) > 0)
        #expect(kern(at: 0, in: s) == 0)
    }

    @Test func emojiTitledAndExternalLinksGetNoIcon() {
        let s = storage([("See ", nil), ("📷 Picture of Life", "picture.md"), (" and ", nil), ("site", "https://example.com")])
        #expect(LinkIcons.iconStarts(in: s).isEmpty)
        #expect(kern(at: 3, in: s) == 0)
    }

    @Test func spacingFollowsEdits() {
        let s = storage([("Social", "social.md"), (" now", nil)])
        // Text typed in front of the link: the indent goes, the typed space carries the gap.
        let typingAttributes = s.attributes(at: 0, effectiveRange: nil).filter { $0.key != .link }
        s.insert(NSAttributedString(string: "Hi ", attributes: typingAttributes), at: 0)
        LinkIcons.applySpacing(to: s, advance: 20)
        #expect(indent(in: s) == 0)
        #expect(kern(at: 2, in: s) == 20)
        #expect(kern(at: 1, in: s) == 0)
        // The link deleted: no gap left anywhere.
        s.deleteCharacters(in: NSRange(location: 3, length: 6))
        LinkIcons.applySpacing(to: s, advance: 20)
        #expect(kern(at: 2, in: s) == 0)
        #expect(indent(in: s) == 0)
    }

    @Test func spacingDoesNotReachTheModel() {
        let original = model([("Add from ", nil), ("Social", "social.md")])
        let s = InlineMarksBridge.toNS(original, baseFontSize: 16, baseBold: false, lineSpacing: 0)
        #expect(InlineMarksBridge.toModel(s) == original)
    }
}
