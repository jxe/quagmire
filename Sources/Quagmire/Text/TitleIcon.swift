import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The page title's icon is the leading emoji of its text, the Markdown
/// convention hosts use. The row draws it beside the title, and the live
/// editor keeps it in its text (so every offset still matches the model) but
/// hidden: zero width, out of the caret's reach, and safe from deletes.
enum TitleIcon {
    /// UTF-16 length of the leading emoji and the whitespace around it, or 0
    /// when the title has no icon. An emoji-only title is all title.
    static func prefixLength(of string: String) -> Int {
        var length = 0
        var index = string.startIndex
        while index < string.endIndex, string[index].isWhitespace, !string[index].isNewline {
            length += string[index].utf16.count
            index = string.index(after: index)
        }
        guard index < string.endIndex, isEmojiCharacter(string[index]) else { return 0 }
        length += string[index].utf16.count
        index = string.index(after: index)
        while index < string.endIndex, string[index].isWhitespace, !string[index].isNewline {
            length += string[index].utf16.count
            index = string.index(after: index)
        }
        return index < string.endIndex ? length : 0
    }

    /// How wide an emoji is at the title's size, so the page symbol can sit
    /// where emojis do.
    static func emojiAdvance(theme: EditorTheme) -> CGFloat {
        let font = InlineMarksBridge.bodyFont(size: theme.pageTitleSize, bold: true, italic: false, theme: theme)
        return NSAttributedString(string: "📄", attributes: [.font: font]).size().width
    }

    /// The title's icon and the text drawn after it.
    static func split(_ text: AttributedString) -> (emoji: String?, rest: AttributedString) {
        let plain = String(text.characters)
        let length = prefixLength(of: plain)
        guard length > 0 else { return (nil, text) }
        let utf16 = plain.utf16
        let end = String.Index(utf16.index(utf16.startIndex, offsetBy: length), within: plain) ?? plain.endIndex
        let prefix = plain[..<end]
        let emoji = prefix.first(where: isEmojiCharacter).map(String.init)
        let offset = plain.distance(from: plain.startIndex, to: end)
        let rest = AttributedString(text[text.index(text.startIndex, offsetByCharacters: offset)...])
        return (emoji, rest)
    }

    /// The title with its icon replaced by `emoji`.
    static func setting(_ emoji: String, in text: AttributedString) -> AttributedString {
        AttributedString("\(emoji) ") + split(text).rest
    }

    /// Make the first `length` characters of `storage` take no space and no ink.
    static func hide(prefixLength length: Int, in storage: NSMutableAttributedString) {
        guard length > 0, length <= storage.length else { return }
        let range = NSRange(location: 0, length: length)
        let font = PlatformFont.systemFont(ofSize: 1)
        let width = NSAttributedString(
            string: (storage.string as NSString).substring(with: range),
            attributes: [.font: font]
        ).size().width
        storage.beginEditing()
        storage.addAttributes([.font: font, .foregroundColor: PlatformColor.clear], range: range)
        storage.addAttribute(.kern, value: -width, range: NSRange(location: length - 1, length: 1))
        storage.endEditing()
    }

    /// `proposed` kept clear of the hidden prefix.
    static func clampSelection(_ proposed: NSRange, prefixLength length: Int) -> NSRange {
        guard length > 0, proposed.location != NSNotFound, proposed.location < length else { return proposed }
        let end = max(length, NSMaxRange(proposed))
        return NSRange(location: length, length: end - length)
    }

    /// The part of an edit of `range` that leaves the hidden prefix alone, or
    /// nil when nothing of it remains to delete.
    static func clampEdit(_ range: NSRange, replacement: String, prefixLength length: Int) -> NSRange? {
        guard length > 0, range.location != NSNotFound, range.location < length else { return range }
        let end = max(length, NSMaxRange(range))
        if end == length, replacement.isEmpty, range.length > 0 { return nil }
        return NSRange(location: length, length: end - length)
    }
}
