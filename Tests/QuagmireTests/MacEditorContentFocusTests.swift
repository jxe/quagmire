#if os(macOS)
import AppKit
import Testing
@testable import Quagmire

@MainActor
struct MacEditorContentFocusTests {
    @Test func acceptsContentButRejectsToolbarAndMissingResponders() {
        let content = NSView()
        let editor = NSView()
        let toolbar = NSView()
        let search = NSTextField()
        content.addSubview(editor)
        toolbar.addSubview(search)
        #expect(MacEditorContentFocus.Probe.isContentResponder(content, in: content))
        #expect(MacEditorContentFocus.Probe.isContentResponder(editor, in: content))
        #expect(!MacEditorContentFocus.Probe.isContentResponder(search, in: content))
        #expect(!MacEditorContentFocus.Probe.isContentResponder(NSResponder(), in: content))
        #expect(!MacEditorContentFocus.Probe.isContentResponder(nil, in: content))
    }
}
#endif
