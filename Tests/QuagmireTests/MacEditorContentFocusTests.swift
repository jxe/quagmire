#if os(macOS)
import AppKit
import Testing
@testable import Quagmire

@MainActor
struct MacEditorContentFocusTests {
    @Test func queuedTextFocusCannotReclaimResponderAfterEscape() async {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = ContainedTextView(frame: window.contentView!.bounds)
        editor.wantsFocus = true
        // Mounting schedules a focus request. Escape can arrive before it runs,
        // while SwiftUI still has the old text view attached to the window.
        window.contentView!.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        editor.relinquishFocus()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(editor.window === window)
        #expect(!editor.wantsFocus)
        #expect(window.firstResponder === window)

        editor.wantsFocus = true
        editor.claimRequestedFocus(in: window)
        #expect(window.firstResponder === editor)
    }

    @Test func relinquishingOldEditorDoesNotClearNewResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let oldEditor = ContainedTextView(frame: window.contentView!.bounds)
        let newEditor = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(oldEditor)
        window.contentView!.addSubview(newEditor)
        #expect(window.makeFirstResponder(newEditor))
        oldEditor.relinquishFocus()
        #expect(window.firstResponder === newEditor)
    }

    @Test func acceptsWindowResponderAfterLeavingTextEditing() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let editor = NSTextView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(editor)
        #expect(window.makeFirstResponder(editor))
        #expect(window.makeFirstResponder(nil))
        #expect(window.firstResponder === window)
        #expect(MacEditorContentFocus.Probe.isContentResponder(window.firstResponder, in: window.contentView))

        let otherWindow = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        #expect(!MacEditorContentFocus.Probe.isContentResponder(otherWindow, in: window.contentView))
    }

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
