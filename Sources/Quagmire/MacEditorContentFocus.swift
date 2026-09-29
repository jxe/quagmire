#if os(macOS)
import AppKit
import SwiftUI

/// Native ownership of page navigation and its selection highlight. SwiftUI's
/// FocusState can disagree after NSTextView hands focus back to its hosting view.
struct MacEditorContentFocus: NSViewRepresentable {
    @Binding var hasFocus: Bool

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.changed = { hasFocus = $0 }
        return view
    }

    func updateNSView(_ view: Probe, context: Context) {
        view.changed = { hasFocus = $0 }
        view.refresh()
    }

    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?
        private var notifications: [NSObjectProtocol] = []
        private var lastValue: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = nil
            notifications.forEach(NotificationCenter.default.removeObserver)
            notifications = []
            if let window {
                observation = window.observe(\.firstResponder) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                             NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                    notifications.append(NotificationCenter.default.addObserver(
                        forName: name, object: nil, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refresh() }
                    })
                }
            }
            refresh()
        }

        func refresh() {
            let value = window.map {
                NSApp.isActive && $0.isKeyWindow && Self.isContentResponder(
                    $0.firstResponder, in: $0.contentView, editorAnchor: self
                )
            } ?? false
            guard value != lastValue else { return }
            lastValue = value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastValue == value else { return }
                self.changed?(value)
            }
        }

        static func isContentResponder(_ responder: NSResponder?, in content: NSView?, editorAnchor: NSView? = nil) -> Bool {
            guard let content else { return false }
            // Clearing NSTextView's first responder on Escape leaves the window
            // itself as responder before the hosting view takes over. The
            // editor's existing navigation selection still belongs to the page.
            if let window = content.window, responder === window { return true }
            guard let view = responder as? NSView else { return false }
            guard view === content || view.isDescendant(of: content) else { return false }
            // SwiftUI routes page keys through the editor's ancestor hosting
            // view. Sibling native controls (sidebar lists, search fields) do
            // not own the editor merely because they share its window.
            guard let editorAnchor else { return true }
            return view === editorAnchor || editorAnchor.isDescendant(of: view)
        }

        isolated deinit {
            notifications.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
#endif
