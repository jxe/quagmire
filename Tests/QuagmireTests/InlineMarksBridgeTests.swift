import Testing
import Foundation
import SwiftUI
@testable import Quagmire

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@Suite("InlineMarksBridge.sanitize — keep only markdown-translatable marks")
struct InlineMarksBridgeSanitizeTests {

    private let baseFontSize: CGFloat = 16
    private let lineSpacing: CGFloat = 4

    /// Build an NSAttributedString that mimics what a browser/Pages copy looks like:
    /// foreign font family, custom size, foregroundColor, backgroundColor — plus a
    /// genuine bold run in the middle.
    private func styledSource() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let foreignFont = PlatformFont.systemFont(ofSize: 28)
        let foreignAttrs: [NSAttributedString.Key: Any] = [
            .font: foreignFont,
            .foregroundColor: PlatformColor.red,
            .backgroundColor: PlatformColor.yellow,
        ]
        result.append(NSAttributedString(string: "hello ", attributes: foreignAttrs))

        let boldDesc = foreignFont.fontDescriptor.withSymbolicTraits(.boldTrait)
        #if os(macOS)
        let boldFont = NSFont(descriptor: boldDesc, size: 28) ?? foreignFont
        #else
        let boldFont = UIFont(descriptor: boldDesc ?? foreignFont.fontDescriptor, size: 28)
        #endif
        var boldAttrs = foreignAttrs
        boldAttrs[.font] = boldFont
        result.append(NSAttributedString(string: "world", attributes: boldAttrs))
        return result
    }

    @Test func stripsForeignFontAndColors() {
        let sanitized = InlineMarksBridge.sanitize(
            styledSource(),
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing)

        #expect(sanitized.string == "hello world")

        let full = NSRange(location: 0, length: sanitized.length)
        sanitized.enumerateAttributes(in: full, options: []) { attrs, _, _ in
            // Foreign yellow background was stripped — runs should not carry one.
            #expect(attrs[.backgroundColor] == nil)
            // Foreground is the editor's foreground (not the source's red).
            let fg = attrs[.foregroundColor] as? PlatformColor
            #expect(fg == EditorTheme.default.platformForeground)
            // Font is normalized to the row's base size. The standalone Quagmire
            // test host does not register a custom font resource, so the family
            // may legitimately be the platform fallback here.
            if let font = attrs[.font] as? PlatformFont {
                #expect(font.pointSize == baseFontSize)
            } else {
                Issue.record("missing .font attribute on sanitized run")
            }
        }
    }

    @Test func preservesBoldRun() {
        let sanitized = InlineMarksBridge.sanitize(
            styledSource(),
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing)

        // Walk to the "world" run and confirm its font has the bold trait.
        let nsString = sanitized.string as NSString
        let worldRange = nsString.range(of: "world")
        #expect(worldRange.location != NSNotFound)
        let attrs = sanitized.attributes(at: worldRange.location, effectiveRange: nil)
        guard let font = attrs[.font] as? PlatformFont else {
            Issue.record("missing .font on bold run")
            return
        }
        #expect(font.fontDescriptor.symbolicTraits.contains(.boldTrait))
    }

    @Test func preservesLink() {
        let url = URL(string: "https://example.com")!
        let attr = NSAttributedString(string: "click", attributes: [
            .font: PlatformFont.systemFont(ofSize: 28),
            .foregroundColor: PlatformColor.red,
            .link: url,
        ])
        let sanitized = InlineMarksBridge.sanitize(
            attr,
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing)

        let attrs = sanitized.attributes(at: 0, effectiveRange: nil)
        #expect(attrs[.link] as? URL == url)
        // Links use the normal text color, no underline, and presentation-only
        // semibold that must not become a Markdown bold mark on round-trip.
        let fg = attrs[.foregroundColor] as? PlatformColor
        #expect(fg == EditorTheme.default.platformForeground)
        #expect(attrs[.underlineStyle] == nil)
        guard let font = attrs[.font] as? PlatformFont else {
            Issue.record("missing .font on link run")
            return
        }
        let traits = font.fontDescriptor.fontAttributes[.traits] as? [PlatformFontDescriptor.TraitKey: Any]
        let weight = traits?[.weight] as? CGFloat
        let isSemibold = font.fontDescriptor.symbolicTraits.contains(.boldTrait)
            || (weight ?? 0) >= PlatformFontWeight.semibold.rawValue
        #expect(isSemibold)

        let roundTripped = InlineMarksBridge.toModel(sanitized)
        #expect(roundTripped.runs.first?[InlineAttributes.BoldAttribute.self] != true)
    }

    @Test func preservesExplicitBoldOnLinkRoundTrip() {
        let url = URL(string: "https://example.com")!
        var linked = AttributedString("click")
        linked.link = url
        linked[InlineAttributes.BoldAttribute.self] = true

        let rendered = InlineMarksBridge.toNS(
            linked,
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing
        )
        let roundTripped = InlineMarksBridge.toModel(rendered)

        #expect(roundTripped.runs.first?.link == url)
        #expect(roundTripped.runs.first?[InlineAttributes.BoldAttribute.self] == true)
    }

    @Test func headingBoldNormalizesToPresentationOnlyAfterEditing() {
        var explicitlyBold = AttributedString("Title")
        explicitlyBold[InlineAttributes.BoldAttribute.self] = true
        let rendered = InlineMarksBridge.toNS(
            explicitlyBold,
            baseFontSize: 32,
            baseBold: true,
            lineSpacing: 0
        )

        let editedHeading = InlineMarksBridge.toModel(rendered, baseBold: true)

        #expect(String(editedHeading.characters) == "Title")
        #expect(editedHeading.runs.allSatisfy {
            $0[InlineAttributes.BoldAttribute.self] != true
        })
    }

    @Test func bareHTTPURLBecomesLinkAttribute() {
        let linked = autoLinkBareURLs(in: AttributedString("visit https://example.com/docs now"))
        let linkedRuns = linked.runs.filter { $0.link?.absoluteString == "https://example.com/docs" }
        #expect(linkedRuns.count == 1)
        if let run = linkedRuns.first {
            #expect(String(linked[run.range].characters) == "https://example.com/docs")
        }
    }

    @Test func bareURLInsideInlineCodeIsNotLinked() {
        var code = AttributeContainer()
        code.inlineCode = true
        var text = AttributedString("https://example.com")
        text.mergeAttributes(code)

        let linked = autoLinkBareURLs(in: text)
        #expect(linked.runs.allSatisfy { $0.link == nil })
    }

    @Test func typingAttributesToggleEmptySelectionMarks() {
        let base = InlineMarksBridge.baseTypingAttributes(
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing
        )

        let bold = InlineMarksBridge.typingAttributes(
            toggling: .bold,
            current: base,
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing
        )
        let boldFont = bold[.font] as? PlatformFont
        #expect(boldFont?.fontDescriptor.symbolicTraits.contains(.boldTrait) == true)

        let code = InlineMarksBridge.typingAttributes(
            toggling: .code,
            current: base,
            baseFontSize: baseFontSize,
            baseBold: false,
            lineSpacing: lineSpacing
        )
        let codeFont = code[.font] as? PlatformFont
        #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpaceTrait) == true)
        #expect(code[.backgroundColor] as? PlatformColor == EditorTheme.default.platformCodeBackground)
    }

    @Test func typingAtLinkEndLeavesTheLink() throws {
        var linked = AttributedString("Values")
        linked.link = URL(string: "values.md")
        let model = AttributedString("Integrate with ") + linked
        let storage = InlineMarksBridge.toNS(model, baseFontSize: baseFontSize, baseBold: false, lineSpacing: lineSpacing)
        let atEnd = storage.attributes(at: storage.length - 1, effectiveRange: nil)

        let typing = try #require(InlineMarksBridge.typingAttributesLeavingLink(
            atEnd,
            at: storage.length,
            in: storage,
            baseFontSize: baseFontSize,
            baseBold: false
        ))
        #expect(typing[.link] == nil)

        let typed = NSMutableAttributedString(attributedString: storage)
        typed.append(NSAttributedString(string: " and ", attributes: typing))
        var expected = AttributedString("Integrate with ") + linked
        expected += AttributedString(" and ")
        #expect(InlineMarksBridge.toModel(typed) == expected)
    }

    @Test func typingInsideLinkKeepsTheLink() {
        var linked = AttributedString("Values")
        linked.link = URL(string: "values.md")
        let storage = InlineMarksBridge.toNS(linked, baseFontSize: baseFontSize, baseBold: false, lineSpacing: lineSpacing)
        let inside = storage.attributes(at: 2, effectiveRange: nil)

        #expect(InlineMarksBridge.typingAttributesLeavingLink(
            inside,
            at: 3,
            in: storage,
            baseFontSize: baseFontSize,
            baseBold: false
        ) == nil)
    }

    @Test func typingAfterBoldLinkStaysBold() throws {
        var linked = AttributedString("Values")
        linked.link = URL(string: "values.md")
        linked[InlineAttributes.BoldAttribute.self] = true
        let storage = InlineMarksBridge.toNS(linked, baseFontSize: baseFontSize, baseBold: false, lineSpacing: lineSpacing)
        let atEnd = storage.attributes(at: storage.length - 1, effectiveRange: nil)

        let typing = try #require(InlineMarksBridge.typingAttributesLeavingLink(
            atEnd,
            at: storage.length,
            in: storage,
            baseFontSize: baseFontSize,
            baseBold: false
        ))
        let typed = NSMutableAttributedString(attributedString: storage)
        typed.append(NSAttributedString(string: "!", attributes: typing))
        var bang = AttributedString("!")
        bang[InlineAttributes.BoldAttribute.self] = true
        #expect(InlineMarksBridge.toModel(typed) == linked + bang)
    }
}

@Suite("Pasting a URL over selected text")
struct PasteLinkOverSelectionTests {
    private let url = URL(string: "https://example.com/a?b=1")!

    @Test func aPastedWebURLLinksSelectedText() {
        #expect(InlineMarksBridge.linkTarget(pasted: "https://example.com/a?b=1", over: "back in 2017") == url)
        #expect(InlineMarksBridge.linkTarget(pasted: "  https://example.com/a?b=1\n", over: "words") == url)
    }

    @Test func anythingElsePastesAsUsual() {
        #expect(InlineMarksBridge.linkTarget(pasted: "see https://example.com", over: "words") == nil)
        #expect(InlineMarksBridge.linkTarget(pasted: "example", over: "words") == nil)
        #expect(InlineMarksBridge.linkTarget(pasted: "note:thing", over: "words") == nil)
        #expect(InlineMarksBridge.linkTarget(pasted: "https://example.com", over: "  ") == nil)
        #expect(InlineMarksBridge.linkTarget(pasted: "https://example.com", over: "https://old.example.com") == nil)
    }

    @Test func linkingKeepsMarksAndReplacesAnEarlierLink() {
        var source = AttributedString("old ")
        source.link = URL(string: "https://old.example.com")
        var bold = AttributedString("bold")
        bold[InlineAttributes.BoldAttribute.self] = true
        source += bold
        let linked = InlineMarksBridge.linking(
            InlineMarksBridge.toNS(source, baseFontSize: 16, baseBold: false, lineSpacing: 4),
            to: url,
            baseFontSize: 16,
            baseBold: false,
            lineSpacing: 4
        )
        let model = InlineMarksBridge.toModel(linked)

        #expect(String(model.characters) == "old bold")
        #expect(model.runs.allSatisfy { $0.link == url })
        #expect(model.runs.contains { $0[InlineAttributes.BoldAttribute.self] == true && String(model[$0.range].characters) == "bold" })
    }

    #if os(macOS)
    @MainActor
    @Test func theEditorLinksOnlyTheSelectionAndUndoRestoresIt() throws {
        let block = Block.paragraph(text: AttributedString("As I wrote back in 2017: photos."))
        let parent = MacBlockTextEditor(
            text: .constant(block.text),
            fontSize: 16,
            bold: false,
            lineSpacing: 2,
            theme: .default,
            isFocused: true,
            onFocusChange: { _ in },
            onKey: { _ in .ignored },
            onAutotransform: { _, _ in },
            onOpenLink: { _ in false },
            onCompletionTriggerChange: { _ in },
            completionActive: false,
            consumeInitialCursor: { nil },
            blockID: block.id,
            documentUndoController: nil,
            activeView: nil
        )
        let coordinator = parent.makeCoordinator()
        let editor = ContainedTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.coordinator = coordinator
        editor.delegate = coordinator
        editor.allowsUndo = true
        let undo = UndoManager()
        undo.groupsByEvent = false
        let window = UndoWindow(undo)
        window.contentView = editor
        let source = "As I wrote back in 2017: photos."
        editor.textStorage?.setAttributedString(
            InlineMarksBridge.toNS(AttributedString(source), baseFontSize: 16, baseBold: false, lineSpacing: 2)
        )
        let selected = (source as NSString).range(of: "back in 2017")
        editor.setSelectedRange(selected)

        undo.beginUndoGrouping()
        #expect(editor.linkSelection(toPasted: url.absoluteString))
        undo.endUndoGrouping()

        let model = InlineMarksBridge.toModel(try #require(editor.textStorage))
        #expect(String(model.characters) == source)
        let links = model.runs.filter { $0.link != nil }.map { String(model[$0.range].characters) }
        #expect(links == ["back in 2017"])
        #expect(editor.selectedRange() == NSRange(location: NSMaxRange(selected), length: 0))

        undo.undo()
        let undone = InlineMarksBridge.toModel(try #require(editor.textStorage))
        #expect(String(undone.characters) == source)
        #expect(undone.runs.allSatisfy { $0.link == nil })

        editor.setSelectedRange(selected)
        #expect(!editor.linkSelection(toPasted: "plain words"))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(!editor.linkSelection(toPasted: url.absoluteString))
    }
    #endif
}

#if os(macOS)
@MainActor
private final class UndoWindow: NSWindow {
    private let undo: UndoManager
    init(_ undo: UndoManager) {
        self.undo = undo
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    }
    override var undoManager: UndoManager? { undo }
}
#endif
