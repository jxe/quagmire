#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Quagmire

@MainActor
struct TextLayoutParityTests {
    @Test(arguments: [CGFloat(16), 17, 18, 20, 24, 30, 40])
    func editorMatchesDisplayHeight(size: CGFloat) {
        for bold in [false, true] {
            for text in ["", "One line", "First line\nSecond line", "Trailing newline\n",
                         "A paragraph long enough to wrap across several lines in a narrow column."] {
                let spacing: CGFloat = 3.5
                let font = InlineMarksBridge.bodyFont(size: size, bold: bold, italic: false)
                let display = NSHostingView(rootView:
                    Text(text.isEmpty ? " " : text)
                        .font(Font(font))
                        .lineSpacing(spacing)
                        .frame(width: 180, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                )
                // A detached host rounds its fitting size to whole points. A
                // window uses the actual display scale and exposes half-point
                // heights on Retina (two 19pt lines plus 3.5pt spacing = 41.5pt).
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 500),
                                      styleMask: [], backing: .buffered, defer: false)
                window.contentView = display
                let editor = ContainedTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 500))
                editor.textContainerInset = .zero
                editor.textContainer!.lineFragmentPadding = 0
                editor.textStorage!.setAttributedString(InlineMarksBridge.toNS(
                    AttributedString(text), baseFontSize: size, baseBold: bold, lineSpacing: spacing
                ))
                editor.typingAttributes = InlineMarksBridge.baseTypingAttributes(
                    baseFontSize: size, baseBold: bold, lineSpacing: spacing
                )
                let scale = window.backingScaleFactor
                let pixelAlignedEditorHeight = ceil(editor.intrinsicContentSize.height * scale) / scale
                #expect(pixelAlignedEditorHeight == display.fittingSize.height,
                        "size=\(size), bold=\(bold), text=\(text)")
                if !text.isEmpty {
                    #expect(editor.layoutManager!.location(forGlyphAt: 0).y == font.ascender.rounded())
                }
            }
        }
    }
}
#endif
