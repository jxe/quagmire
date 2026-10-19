import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import Testing
@testable import Quagmire

@Suite struct TitleIconTests {
    @Test func leadingEmojiAndItsSpaceAreThePrefix() {
        #expect(TitleIcon.prefixLength(of: "📷 Picture of Life") == "📷 ".utf16.count)
        #expect(TitleIcon.prefixLength(of: "⚔️ March") == "⚔️ ".utf16.count)
    }

    @Test func titlesWithoutAnIconHaveNoPrefix() {
        #expect(TitleIcon.prefixLength(of: "Timeline") == 0)
        #expect(TitleIcon.prefixLength(of: "📷") == 0)
        #expect(TitleIcon.prefixLength(of: "") == 0)
    }

    @Test func splitSeparatesIconFromTitle() {
        let (emoji, rest) = TitleIcon.split(AttributedString("📷 Picture of Life"))
        #expect(emoji == "📷")
        #expect(String(rest.characters) == "Picture of Life")
        let plain = TitleIcon.split(AttributedString("Timeline"))
        #expect(plain.emoji == nil)
        #expect(String(plain.rest.characters) == "Timeline")
    }

    @Test func settingAnIconReplacesTheOldOne() {
        #expect(String(TitleIcon.setting("🔄", in: AttributedString("📷 Picture")).characters) == "🔄 Picture")
        #expect(String(TitleIcon.setting("🔄", in: AttributedString("Timeline")).characters) == "🔄 Timeline")
    }

    @Test func caretAndEditsStayClearOfTheIcon() {
        let prefix = 3
        #expect(TitleIcon.clampSelection(NSRange(location: 0, length: 0), prefixLength: prefix) == NSRange(location: 3, length: 0))
        #expect(TitleIcon.clampSelection(NSRange(location: 0, length: 8), prefixLength: prefix) == NSRange(location: 3, length: 5))
        #expect(TitleIcon.clampSelection(NSRange(location: 5, length: 0), prefixLength: prefix) == NSRange(location: 5, length: 0))
        // Backspace right after the icon deletes nothing.
        #expect(TitleIcon.clampEdit(NSRange(location: 2, length: 1), replacement: "", prefixLength: prefix) == nil)
        // Select-all and type keeps the icon.
        #expect(TitleIcon.clampEdit(NSRange(location: 0, length: 8), replacement: "x", prefixLength: prefix) == NSRange(location: 3, length: 5))
    }

    @Test func hiddenIconStillRoundTrips() {
        let title = AttributedString("📷 Picture of Life")
        let storage = NSMutableAttributedString(attributedString: InlineMarksBridge.toNS(title, baseFontSize: 40, baseBold: true, lineSpacing: 0))
        TitleIcon.hide(prefixLength: TitleIcon.prefixLength(of: storage.string), in: storage)
        #expect(InlineMarksBridge.toModel(storage, baseBold: true) == title)
    }
}
