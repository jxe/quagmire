#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
public enum VoiceTranscriptInsertion {
    public static func insertIntoFirstResponder(_ text: String) -> Bool {
        #if os(macOS)
        NSApp.sendAction(
            #selector(NSText.insertText(_:)),
            to: nil,
            from: text
        )
        #else
        UIApplication.shared.sendAction(
            #selector(UIKeyInput.insertText(_:)),
            to: nil,
            from: text,
            for: nil
        )
        #endif
    }
}
