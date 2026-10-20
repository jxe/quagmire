import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Live voice preview
//
// A transcript still being spoken shows at the caret as marked text, the way
// an input method previews a composition: in the line, but not part of the
// block. Committing skips it (`textStorageExcludingVoicePreview`), and the
// final transcript replaces it through the ordinary insert.

#if os(macOS)
extension ContainedTextView {
    func showVoicePreview(_ rawText: String) {
        let range = showsVoicePreview && hasMarkedText() ? markedRange() : selectedRange()
        let insertion = inlineDictationInsertion(rawText, in: string, replacing: range)
        guard !insertion.isEmpty else {
            clearVoicePreview()
            return
        }
        showsVoicePreview = true
        setMarkedText(
            insertion,
            selectedRange: NSRange(location: (insertion as NSString).length, length: 0),
            replacementRange: range
        )
    }

    func clearVoicePreview() {
        guard showsVoicePreview else { return }
        showsVoicePreview = false
        guard hasMarkedText() else { return }
        setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: markedRange())
        unmarkText()
    }

    var textStorageExcludingVoicePreview: NSAttributedString {
        let storage = textStorage ?? NSTextStorage()
        guard showsVoicePreview, hasMarkedText() else { return storage }
        let copy = NSMutableAttributedString(attributedString: storage)
        copy.deleteCharacters(in: markedRange())
        return copy
    }
}
#elseif os(iOS)
extension ContainedTextViewIOS {
    func showVoicePreview(_ rawText: String) {
        let range = showsVoicePreview ? (markedNSRange ?? selectedRange) : selectedRange
        let insertion = inlineDictationInsertion(rawText, in: text ?? "", replacing: range)
        guard !insertion.isEmpty else {
            clearVoicePreview()
            return
        }
        showsVoicePreview = true
        // Replaces the current marked text, or the selection when there is none.
        setMarkedText(insertion, selectedRange: NSRange(location: (insertion as NSString).length, length: 0))
    }

    func clearVoicePreview() {
        guard showsVoicePreview else { return }
        showsVoicePreview = false
        guard markedTextRange != nil else { return }
        setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        unmarkText()
    }

    var textStorageExcludingVoicePreview: NSAttributedString {
        guard showsVoicePreview, let marked = markedNSRange else { return textStorage }
        let copy = NSMutableAttributedString(attributedString: textStorage)
        copy.deleteCharacters(in: marked)
        return copy
    }

    private var markedNSRange: NSRange? {
        guard let marked = markedTextRange else { return nil }
        return NSRange(
            location: offset(from: beginningOfDocument, to: marked.start),
            length: offset(from: marked.start, to: marked.end)
        )
    }
}
#endif
