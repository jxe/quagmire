import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The page icon in front of an inline page link, in the live editor.
///
/// The read-only row puts the icon in its text (`documentLinkInlineIcon`). The
/// live editor can't: an extra character would shift every offset the editor
/// shares with the model. So it widens the gap before the link instead,
/// kerning the character in front of it, or indenting a link that starts its
/// paragraph, and the text view draws the icon into that gap.
enum LinkIcons {
    static let symbolName = "doc.text"
    /// How far below the text baseline the symbol's image extends, as a
    /// fraction of its height. UIImage reports this; NSImage doesn't.
    static let macSymbolBaselineFraction: CGFloat = 0.17

    /// Start offsets of the page links that get an icon: every page link
    /// whose label doesn't already lead with an emoji.
    static func iconStarts(in storage: NSAttributedString) -> [Int] {
        var starts: [Int] = []
        let text = storage.string as NSString
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, AtomicLinks.atomicLink(at: range.location, in: storage) != nil else { return }
            let label = text.substring(with: range).trimmingCharacters(in: .whitespaces)
            if let first = label.first, isEmojiCharacter(first) { return }
            starts.append(range.location)
        }
        return starts
    }

    /// The gap an icon takes: the symbol and the space after it, as the
    /// read-only row lays them out.
    static func advance(baseFontSize: CGFloat, baseBold: Bool, theme: EditorTheme) -> CGFloat {
        let font = InlineMarksBridge.bodyFont(size: baseFontSize, bold: baseBold, italic: false, theme: theme)
        let space = NSAttributedString(string: " ", attributes: [.font: font]).size().width
        return (image(theme: theme)?.size.width ?? theme.pageIconSize) + space
    }

    static func image(theme: EditorTheme) -> PlatformImage? {
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: theme.pageIconSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        // Tint every layer with the one colour, as SwiftUI's foreground style
        // does for the read-only icon; palette colours lighten the inner lines.
        let color = NSColor(theme.mutedForeground)
        return NSImage(size: symbol.size, flipped: false) { rect in
            // The colour is translucent: tint with it opaque, then lay the
            // tinted glyph down at its alpha, or the glyph's black shows through.
            let resolved = color.usingColorSpace(.sRGB) ?? color
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setAlpha(resolved.alphaComponent)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            symbol.draw(in: rect)
            resolved.withAlphaComponent(1).set()
            rect.fill(using: .sourceAtop)
            context.endTransparencyLayer()
            return true
        }
        #else
        let configuration = UIImage.SymbolConfiguration(pointSize: theme.pageIconSize, weight: .regular)
        return UIImage(systemName: symbolName, withConfiguration: configuration)?
            .withTintColor(UIColor(theme.mutedForeground), renderingMode: .alwaysOriginal)
        #endif
    }

    /// Reserve the gap in front of every icon link in `storage`, and remove it
    /// wherever a link no longer starts. Run after every edit: typed text takes
    /// the kerning of the character before the caret.
    static func applySpacing(to storage: NSMutableAttributedString, advance: CGFloat) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let text = storage.string as NSString
        let starts = iconStarts(in: storage)
        var indented: Set<Int> = []
        var kerned: [Int] = []
        for start in starts {
            if start == 0 || isNewline(text.character(at: start - 1)) {
                indented.insert(text.paragraphRange(for: NSRange(location: start, length: 0)).location)
            } else {
                kerned.append(start - 1)
            }
        }

        var styles: [(NSRange, NSParagraphStyle)] = []
        var paragraphStart = 0
        while paragraphStart < full.length {
            let paragraph = text.paragraphRange(for: NSRange(location: paragraphStart, length: 0))
            let indent: CGFloat = indented.contains(paragraph.location) ? advance : 0
            storage.enumerateAttribute(.paragraphStyle, in: paragraph) { value, range, _ in
                let style = value as? NSParagraphStyle ?? .default
                guard style.firstLineHeadIndent != indent else { return }
                let updated = style.mutableCopy() as! NSMutableParagraphStyle
                updated.firstLineHeadIndent = indent
                styles.append((range, updated))
            }
            paragraphStart = NSMaxRange(paragraph)
        }

        storage.beginEditing()
        storage.removeAttribute(.kern, range: full)
        for (range, style) in styles {
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        for index in kerned {
            storage.addAttribute(.kern, value: advance, range: NSRange(location: index, length: 1))
        }
        storage.endEditing()
    }

    /// Where to draw an icon whose link starts on a line at `linkMinX`, with
    /// the line's baseline at `baseline` (view coordinates, y down).
    static func iconRect(linkMinX: CGFloat, baseline: CGFloat, advance: CGFloat, imageSize: CGSize, baselineOffsetFromBottom: CGFloat) -> CGRect {
        CGRect(
            x: linkMinX - advance,
            y: baseline - imageSize.height + baselineOffsetFromBottom,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    private static func isNewline(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }
}

#if os(macOS)
typealias PlatformImage = NSImage
#else
typealias PlatformImage = UIImage
#endif
