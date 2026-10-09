import Testing
import SwiftUI
#if os(macOS)
import AppKit
#endif
@testable import Quagmire

/// Checks for nav-mode bindings and the action menu's transition into nav mode.
@MainActor
@Suite("Nav-mode key bindings")
struct NavKeyBindingTests {
    init() {
        #if os(macOS)
        _ = NSApplication.shared
        #endif
    }

    @Test func cmdCMapsToCopySelection() {
        #expect(EditorView.navAction(for: "c", modifiers: .command) == .copySelection)
    }

    @Test func cmdVMapsToPaste() {
        #expect(EditorView.navAction(for: "v", modifiers: .command) == .pasteFromPasteboard)
    }

    @Test func cmdXMapsToCut() {
        #expect(EditorView.navAction(for: "x", modifiers: .command) == .cutSelection)
    }

    @Test func cmdBMapsToBold() {
        #expect(EditorView.navAction(for: "b", modifiers: .command) == .toggleInlineMark(.bold))
    }

    @Test func cmdIMapsToItalic() {
        #expect(EditorView.navAction(for: "i", modifiers: .command) == .toggleInlineMark(.italic))
    }

    @Test func cmdShiftSMapsToStrikethrough() {
        #expect(EditorView.navAction(for: "s", modifiers: [.command, .shift]) == .toggleInlineMark(.strikethrough))
    }

    @Test func cmdBAloneIsNotCmdShiftB() {
        // Cmd-B and Cmd-Shift-B should NOT collide. The matcher requires exact
        // modifier match — Cmd-B fires bold, Cmd-Shift-B has no binding.
        #expect(EditorView.navAction(for: "b", modifiers: .command) == .toggleInlineMark(.bold))
        #expect(EditorView.navAction(for: "b", modifiers: [.command, .shift]) == nil)
    }

    @Test func cmdSlashOpensActionMenu() {
        #expect(EditorView.navAction(for: "/", modifiers: .command) == .openBlockActionMenu)
        #expect(EditorView.navAction(for: ".", modifiers: .command) == nil)
    }

    @Test func actionMenuLeavesEditingAndFlushesLiveText() {
        let block = Block.paragraph(text: AttributedString("text"))
        let document = Document(id: DocumentID("test"), children: [block])
        let state = EditorState()
        state.enterEditMode(on: block.id)
        let editor = EditorView(document: document, state: state, host: ActionMenuTestHost())
        editor.installUndoApply()
        var flushedWhileEditing = false
        editor.undoController.flushActiveText = {
            flushedWhileEditing = state.editingBlock == block.id
        }
        editor.wireEditorCommands()

        editor.editorCommands.perform(.openBlockActionMenu)

        #expect(flushedWhileEditing)
        #expect(state.editingBlock == nil)
        #expect(state.cursor == block.id)
        #expect(state.selection == [block.id])
    }

    @Test func actionMenuPreservesNavSelection() {
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.paragraph(text: AttributedString("second"))
        let document = Document(id: DocumentID("test"), children: [first, second])
        let state = EditorState()
        state.setNavSelection(blocks: [first.id, second.id], anchor: first.id, cursor: second.id)
        let editor = EditorView(document: document, state: state, host: ActionMenuTestHost())
        editor.installUndoApply()
        editor.wireEditorCommands()

        editor.editorCommands.perform(.openBlockActionMenu)

        #expect(state.selection == [first.id, second.id])
        #expect(state.cursor == second.id)
    }

    @Test func hostNavigationFocusLeavesEditingAndFlushesText() {
        let block = Block.paragraph(text: AttributedString("text"))
        let document = Document(id: DocumentID("test"), children: [block])
        let state = EditorState()
        state.enterEditMode(on: block.id)
        let editor = EditorView(document: document, state: state, host: ActionMenuTestHost())
        editor.installUndoApply()
        var flushedWhileEditing = false
        editor.undoController.flushActiveText = {
            flushedWhileEditing = state.editingBlock == block.id
        }
        editor.wireEditorCommands()
        editor.editorCommands.focusNavigation()
        #expect(flushedWhileEditing)
        #expect(state.editingBlock == nil)
        #expect(state.cursor == block.id)
        #expect(state.selection == [block.id])
    }

    @Test func hostNavigationFocusPreservesMultipleSelection() {
        let first = Block.paragraph(text: AttributedString("first"))
        let second = Block.paragraph(text: AttributedString("second"))
        let document = Document(id: DocumentID("test"), children: [first, second])
        let state = EditorState()
        state.setNavSelection(blocks: [first.id, second.id], anchor: first.id, cursor: second.id)
        let editor = EditorView(document: document, state: state, host: ActionMenuTestHost())
        editor.wireEditorCommands()
        editor.editorCommands.focusNavigation()
        #expect(state.selection == [first.id, second.id])
        #expect(state.cursor == second.id)
    }

    @Test func cmdKMapsToToggleLink() {
        #expect(EditorView.navAction(for: "k", modifiers: .command) == .toggleLinkOrDocument)
    }

    @Test func cmdReturnMapsToNewBlockBelow() {
        #expect(EditorView.navAction(for: .return, modifiers: .command) == .newBlockBelow)
    }

    @Test func plainReturnEntersEdit() {
        #expect(EditorView.navAction(for: .return, modifiers: []) == .enterEditOrOpenDocument)
    }

    @Test func tabIndents() {
        #expect(EditorView.navAction(for: .tab, modifiers: []) == .indent)
    }

    @Test func backTabWithShiftOutdents() {
        // Canopy's native event path retains Shift on NSBackTabCharacter.
        #expect(EditorView.navAction(for: KeyEquivalent("\u{19}"), modifiers: .shift) == .outdent)
        #expect(EditorView.navAction(for: KeyEquivalent("\u{19}"), modifiers: [.shift, .command]) == nil)
    }

    @Test func backTabOutdents() {
        // Shift+Tab arrives as the BackTab character (U+0019), not .tab + .shift.
        #expect(EditorView.navAction(for: KeyEquivalent("\u{19}"), modifiers: []) == .outdent)
    }

    @Test func shiftedTabOutdents() {
        // Some event paths report Shift+Tab as .tab plus a shift modifier.
        #expect(EditorView.navAction(for: .tab, modifiers: .shift) == .outdent)
    }

    @Test func plainArrowsMoveCursor() {
        #expect(EditorView.navAction(for: .upArrow, modifiers: []) == .moveCursor(delta: -1))
        #expect(EditorView.navAction(for: .downArrow, modifiers: []) == .moveCursor(delta: +1))
    }

    @Test func shiftArrowsExtendSelection() {
        #expect(EditorView.navAction(for: .upArrow, modifiers: .shift) == .extendSelection(delta: -1))
        #expect(EditorView.navAction(for: .downArrow, modifiers: .shift) == .extendSelection(delta: +1))
    }

    @Test func optionArrowsMoveBlock() {
        #expect(EditorView.navAction(for: .upArrow, modifiers: .option) == .moveBlockUp)
        #expect(EditorView.navAction(for: .downArrow, modifiers: .option) == .moveBlockDown)
    }

    @Test func leftRightArrows() {
        #expect(EditorView.navAction(for: .leftArrow, modifiers: []) == .navLeftArrow)
        #expect(EditorView.navAction(for: .rightArrow, modifiers: []) == .navRightArrow)
    }

    @Test func deleteAndBackspaceMapToDelete() {
        #expect(EditorView.navAction(for: .delete, modifiers: []) == .deleteSelection)
        #expect(EditorView.navAction(for: KeyEquivalent("\u{8}"), modifiers: []) == .deleteSelection)
        #expect(EditorView.navAction(for: KeyEquivalent("\u{7F}"), modifiers: []) == .deleteSelection)
    }

    @Test func escapeMapsToEscape() {
        #expect(EditorView.navAction(for: .escape, modifiers: []) == .escape)
    }

    @Test func cmdBracketNavigatesBack() {
        #expect(EditorView.navAction(for: "[", modifiers: .command) == .navigateBack)
    }

    @Test func unboundChordReturnsNil() {
        // Cmd-Q (or anything not in the table) returns nil so SwiftUI can pass
        // the press through to other handlers.
        #expect(EditorView.navAction(for: "q", modifiers: .command) == nil)
        #expect(EditorView.navAction(for: "z", modifiers: .command) == nil) // Cmd-Z is handled separately by the menu
    }
}

private final class ActionMenuTestHost: EditorHostDefaults {
    func persistCommit(changes: [DocumentChange], in document: Document) {}
    func flush(_ document: Document) async {}
}
